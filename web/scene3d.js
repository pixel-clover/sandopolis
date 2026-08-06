// 3D diorama renderer for Sandopolis frame scenes.
//
// Consumes the `FrameScene` buffer produced by `sandopolis_scene_extract`
// and draws it as depth-separated layers instead of a flat picture:
//
//   backdrop  ->  background (low priority)  ->  sprites  ->
//   background (high priority)  ->  HUD
//
// The HUD layer is the region the VDP locked against scrolling, which games
// use for status displays, so it stays flat at the front instead of being
// pushed into the scene.
//
// No per-game profiles are involved. Every Master System and Game Gear title
// renders with the same automatic layer assignment.
//
// This file owns no XR state. `createRenderer(gl)` works on any WebGL2
// context, so the desktop viewer and the WebXR theater share it.

(function () {
    "use strict";

    // Binary layout of `FrameScene`, pinned by a unit test in src/scene.zig.
    // LAYOUT_VERSION must match `sandopolis_scene_layout_version()`.
    const LAYOUT_VERSION = 1;
    const MAGIC = 0x534E4353; // "SCNS"

    const OFF = {
        magic: 0, version: 4,
        system: 8, mode: 9, columns: 10, rows: 11,
        pictureWidth: 12, pictureHeight: 14,
        viewportX: 16, viewportY: 18, viewportWidth: 20, viewportHeight: 22,
        scrollX: 24, scrollY: 26,
        tileCount: 28, spriteCount: 30, hudRows: 31, hudCols: 32,
        flags: 36, backdrop: 40,
        palette: 44,
        cells: 172,
        sprites: 4268,
        tileDirty: 5036,
        tileAtlas: 5100,
    };

    const MAX_COLUMNS = 32;
    const MAX_SPRITES = 64;
    const MAX_TILES = 512;
    const PIXELS_PER_TILE = 64;
    const CELL_BYTES = 4;
    const SPRITE_BYTES = 12;

    const FLAG_DISPLAY_ENABLED = 1 << 0;
    const FLAG_LEFT_COLUMN_BLANKED = 1 << 1;
    const FLAG_CONTENT_VALID = 1 << 2;

    // Tile atlas texture: 512 tiles laid out 32 across, 16 down.
    const ATLAS_TILES_X = 32;
    const ATLAS_TILES_Y = MAX_TILES / ATLAS_TILES_X;
    const ATLAS_W = ATLAS_TILES_X * 8;
    const ATLAS_H = ATLAS_TILES_Y * 8;

    // Layer depths in world units, with the picture one unit tall. These are
    // multiplied by the renderer's depth scale, so the diorama can be flattened
    // back toward the original 2D picture or exaggerated.
    const Z_BACKDROP = -0.30;
    const Z_BG_LOW = 0.0;
    const Z_SPRITES = 0.14;
    const Z_BG_HIGH = 0.24;
    const Z_HUD = 0.45;

    const LAYER_BG_LOW = 0;
    const LAYER_BG_HIGH = 1;
    const LAYER_HUD = 2;

    // Design viewing distance. Each layer is scaled by its distance from this
    // point so that, viewed head-on from here, every layer projects to exactly
    // the same size and the diorama reproduces the original flat picture.
    // Moving the camera off this point is what reveals the depth.
    const REFERENCE_DISTANCE = 2.2;

    function layerScale(z) {
        return (REFERENCE_DISTANCE - z) / REFERENCE_DISTANCE;
    }

    // -- Scene parsing --

    /// Read a scene buffer out of WebAssembly memory into plain typed views.
    /// Returns null when the buffer is absent, has the wrong magic, or was
    /// produced by a layout this file does not understand.
    function parseScene(memoryBuffer, ptr, len) {
        if (!ptr || !len) return null;
        const view = new DataView(memoryBuffer, ptr, len);
        if (view.getUint32(OFF.magic, true) !== MAGIC) return null;
        if (view.getUint32(OFF.version, true) !== LAYOUT_VERSION) return null;

        const flags = view.getUint32(OFF.flags, true);
        return {
            system: view.getUint8(OFF.system),
            mode: view.getUint8(OFF.mode),
            columns: view.getUint8(OFF.columns),
            rows: view.getUint8(OFF.rows),
            pictureWidth: view.getUint16(OFF.pictureWidth, true),
            pictureHeight: view.getUint16(OFF.pictureHeight, true),
            viewportX: view.getUint16(OFF.viewportX, true),
            viewportY: view.getUint16(OFF.viewportY, true),
            viewportWidth: view.getUint16(OFF.viewportWidth, true),
            viewportHeight: view.getUint16(OFF.viewportHeight, true),
            scrollX: view.getUint16(OFF.scrollX, true),
            scrollY: view.getUint16(OFF.scrollY, true),
            spriteCount: view.getUint8(OFF.spriteCount),
            hudRows: view.getUint8(OFF.hudRows),
            hudCols: view.getUint8(OFF.hudCols),
            flags: flags,
            contentValid: (flags & FLAG_CONTENT_VALID) !== 0,
            displayEnabled: (flags & FLAG_DISPLAY_ENABLED) !== 0,
            leftColumnBlanked: (flags & FLAG_LEFT_COLUMN_BLANKED) !== 0,
            backdrop: view.getUint32(OFF.backdrop, true),
            // Views over the same WebAssembly memory, valid until it grows.
            palette: new Uint32Array(memoryBuffer, ptr + OFF.palette, 32),
            cells: new Uint8Array(memoryBuffer, ptr + OFF.cells, MAX_COLUMNS * MAX_COLUMNS * CELL_BYTES),
            sprites: new DataView(memoryBuffer, ptr + OFF.sprites, MAX_SPRITES * SPRITE_BYTES),
            tileDirty: new Uint8Array(memoryBuffer, ptr + OFF.tileDirty, MAX_TILES / 8),
            tileAtlas: new Uint8Array(memoryBuffer, ptr + OFF.tileAtlas, MAX_TILES * PIXELS_PER_TILE),
        };
    }

    function readSprite(scene, i) {
        const d = scene.sprites;
        const at = i * SPRITE_BYTES;
        return {
            x: d.getInt16(at, true),
            y: d.getInt16(at + 2, true),
            tileIndex: d.getUint16(at + 4, true),
            slot: d.getUint8(at + 6),
            palette: d.getUint8(at + 7),
            width: d.getUint8(at + 8),
            height: d.getUint8(at + 9),
            flags: d.getUint8(at + 10),
        };
    }

    // -- Shaders --

    const QUAD_VS = `#version 300 es
    in vec2 a_pos;
    out vec2 v_uv;
    uniform mat4 u_mvp;
    uniform vec4 u_rect;   // x, y, width, height in picture pixels
    uniform vec2 u_picture;
    uniform float u_z;
    uniform float u_layerScale;
    void main() {
        // a_pos is a unit quad in 0..1. Map it into the picture rectangle,
        // then into world space with the picture one unit tall and the
        // origin at its centre. Picture Y runs downward, world Y upward.
        vec2 px = u_rect.xy + a_pos * u_rect.zw;
        v_uv = a_pos;
        vec2 world = vec2(
            (px.x - u_picture.x * 0.5) / u_picture.y,
            (u_picture.y * 0.5 - px.y) / u_picture.y
        );
        // Shrink nearer layers and enlarge farther ones so every layer covers
        // the same solid angle from the design viewpoint.
        world *= u_layerScale;
        gl_Position = u_mvp * vec4(world, u_z, 1.0);
    }`;

    const COMMON_FS_HEAD = `#version 300 es
    precision highp float;
    precision highp usampler2D;
    out vec4 outColor;
    uniform usampler2D u_atlas;
    uniform sampler2D u_palette;
    uniform vec4 u_viewport;   // x, y, width, height in picture pixels

    vec4 lookupTilePixel(uint tile, uint tx, uint ty, uint bank) {
        ivec2 at = ivec2(
            int(tile % ${ATLAS_TILES_X}u) * 8 + int(tx),
            int(tile / ${ATLAS_TILES_X}u) * 8 + int(ty)
        );
        uint ci = texelFetch(u_atlas, at, 0).r;
        if (ci == 0u) discard;
        return texelFetch(u_palette, ivec2(int(bank + ci), 0), 0);
    }

    void clipToViewport(vec2 px) {
        if (px.x < u_viewport.x || px.x >= u_viewport.x + u_viewport.z ||
            px.y < u_viewport.y || px.y >= u_viewport.y + u_viewport.w) discard;
    }`;

    const BACKGROUND_FS = COMMON_FS_HEAD + `
    in vec2 v_uv;
    uniform usampler2D u_map;
    uniform vec2 u_picture;
    uniform vec2 u_scroll;
    uniform float u_rows;
    uniform float u_verticalWrap;
    uniform float u_hudRows;
    uniform float u_hudCols;
    uniform int u_layer;
    uniform bool u_leftBlank;

    void main() {
        vec2 px = floor(v_uv * u_picture);
        clipToViewport(px);
        if (u_leftBlank && px.x < 8.0) discard;

        float col = floor(px.x / 8.0);
        bool hLocked = u_hudRows > 0.0 && px.y < u_hudRows * 8.0;
        bool vLocked = u_hudCols > 0.0 && col >= (32.0 - u_hudCols);
        bool isHud = hLocked || vLocked;

        if (u_layer == ${LAYER_HUD}) {
            if (!isHud) discard;
        } else if (isHud) {
            discard;
        }

        // Mirror the VDP's scroll arithmetic. Locked regions ignore the
        // corresponding scroll axis.
        float hscroll = hLocked ? 0.0 : u_scroll.x;
        float coarse = mod(floor(hscroll / 8.0), 32.0);
        float fine = mod(hscroll, 8.0);
        // Fine scrolling leaves the leftmost pixels on the backdrop rather
        // than wrapping them in from the right edge.
        if (!hLocked && fine > 0.0 && px.x < fine) discard;

        float scrolledX = hLocked ? px.x : px.x - fine;
        float sourceCol = hLocked ? col : mod(floor(scrolledX / 8.0) + 32.0 - coarse, 32.0);
        float effY = vLocked ? px.y : mod(px.y + u_scroll.y, u_verticalWrap);
        float row = floor(effY / 8.0);
        if (row >= u_rows) discard;

        uvec4 cell = texelFetch(u_map, ivec2(int(sourceCol), int(row)), 0);
        uint tile = cell.r + (cell.g << 8u);
        uint flags = cell.a;
        bool priority = (flags & 4u) != 0u;

        if (u_layer == ${LAYER_BG_LOW} && priority) discard;
        if (u_layer == ${LAYER_BG_HIGH} && !priority) discard;

        float fineY = mod(effY, 8.0);
        float fineX = mod(scrolledX, 8.0);
        float ty = ((flags & 2u) != 0u) ? 7.0 - fineY : fineY;
        float tx = ((flags & 1u) != 0u) ? 7.0 - fineX : fineX;

        outColor = lookupTilePixel(tile, uint(tx), uint(ty), uint(cell.b) * 16u);
    }`;

    const SPRITE_FS = COMMON_FS_HEAD + `
    in vec2 v_uv;
    uniform vec4 u_rect;
    uniform uint u_tile;
    uniform bool u_doubled;
    uniform uint u_bank;

    void main() {
        vec2 local = floor(v_uv * u_rect.zw);
        clipToViewport(u_rect.xy + local);

        uint sx = uint(local.x);
        uint sy = uint(local.y);
        // The hardware zoom bit doubles each source pixel on both axes.
        uint srcCol = u_doubled ? sx / 2u : sx;
        uint srcRow = u_doubled ? sy / 2u : sy;
        // Tall sprites continue into the next pattern after eight rows.
        uint tile = u_tile + (srcRow >= 8u ? 1u : 0u);

        outColor = lookupTilePixel(tile, srcCol, srcRow % 8u, u_bank);
    }`;

    const SOLID_FS = `#version 300 es
    precision highp float;
    in vec2 v_uv;
    out vec4 outColor;
    uniform vec4 u_color;
    void main() { outColor = u_color; }`;

    // -- Renderer --

    function compileProgram(gl, vsSrc, fsSrc) {
        function compile(type, src) {
            const sh = gl.createShader(type);
            gl.shaderSource(sh, src);
            gl.compileShader(sh);
            if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
                const log = gl.getShaderInfoLog(sh);
                gl.deleteShader(sh);
                throw new Error("Scene3D shader compile error: " + log);
            }
            return sh;
        }
        const vs = compile(gl.VERTEX_SHADER, vsSrc);
        const fs = compile(gl.FRAGMENT_SHADER, fsSrc);
        const p = gl.createProgram();
        gl.attachShader(p, vs);
        gl.attachShader(p, fs);
        gl.linkProgram(p);
        gl.detachShader(p, vs);
        gl.detachShader(p, fs);
        gl.deleteShader(vs);
        gl.deleteShader(fs);
        if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
            const log = gl.getProgramInfoLog(p);
            gl.deleteProgram(p);
            throw new Error("Scene3D program link error: " + log);
        }
        return p;
    }

    function uniforms(gl, program, names) {
        const out = {};
        for (const n of names) out[n] = gl.getUniformLocation(program, n);
        return out;
    }

    function createRenderer(gl) {
        const bgProgram = compileProgram(gl, QUAD_VS, BACKGROUND_FS);
        const spriteProgram = compileProgram(gl, QUAD_VS, SPRITE_FS);
        const solidProgram = compileProgram(gl, QUAD_VS, SOLID_FS);

        const bgU = uniforms(gl, bgProgram, [
            "u_mvp", "u_rect", "u_picture", "u_z", "u_layerScale", "u_atlas", "u_palette", "u_map",
            "u_scroll", "u_rows", "u_verticalWrap", "u_hudRows", "u_hudCols",
            "u_layer", "u_viewport", "u_leftBlank",
        ]);
        const spU = uniforms(gl, spriteProgram, [
            "u_mvp", "u_rect", "u_picture", "u_z", "u_layerScale", "u_atlas", "u_palette",
            "u_tile", "u_doubled", "u_bank", "u_viewport",
        ]);
        const soU = uniforms(gl, solidProgram, [
            "u_mvp", "u_rect", "u_picture", "u_z", "u_layerScale", "u_color",
        ]);

        // Unit quad shared by every layer; the vertex shader places it.
        const vao = gl.createVertexArray();
        gl.bindVertexArray(vao);
        const vbo = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([
            0, 0, 1, 0, 1, 1,
            0, 0, 1, 1, 0, 1,
        ]), gl.STATIC_DRAW);
        // Attribute 0 is a_pos in all three programs.
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
        gl.bindVertexArray(null);

        function makeTexture(internalFormat, format, type, w, h, filter) {
            const t = gl.createTexture();
            gl.bindTexture(gl.TEXTURE_2D, t);
            gl.texStorage2D(gl.TEXTURE_2D, 1, internalFormat, w, h);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
            return {tex: t, format: format, type: type};
        }

        const atlasTex = makeTexture(gl.R8UI, gl.RED_INTEGER, gl.UNSIGNED_BYTE, ATLAS_W, ATLAS_H, gl.NEAREST);
        const mapTex = makeTexture(gl.RGBA8UI, gl.RGBA_INTEGER, gl.UNSIGNED_BYTE, MAX_COLUMNS, MAX_COLUMNS, gl.NEAREST);
        const paletteTex = makeTexture(gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, 32, 1, gl.NEAREST);

        // Staging buffers, reused every frame.
        const atlasStaging = new Uint8Array(ATLAS_W * ATLAS_H);
        const mapStaging = new Uint8Array(MAX_COLUMNS * MAX_COLUMNS * 4);
        const paletteStaging = new Uint8Array(32 * 4);

        let current = null;
        let atlasUploaded = false;
        // 0 collapses every layer onto one plane, reproducing the flat
        // picture. 1 is the default diorama spacing.
        let depthScale = 1.0;

        function setDepthScale(v) {
            depthScale = Math.max(0, Math.min(4, v));
        }

        function getDepthScale() {
            return depthScale;
        }

        function upload(scene) {
            current = scene;
            if (!scene || !scene.contentValid) return;

            // Repack the linear tile atlas into the 2D texture layout. The
            // dirty bits let a static screen skip this entirely.
            let anyDirty = !atlasUploaded;
            if (!anyDirty) {
                for (let i = 0; i < scene.tileDirty.length; i++) {
                    if (scene.tileDirty[i] !== 0) { anyDirty = true; break; }
                }
            }
            if (anyDirty) {
                for (let t = 0; t < MAX_TILES; t++) {
                    const tx = (t % ATLAS_TILES_X) * 8;
                    const ty = ((t / ATLAS_TILES_X) | 0) * 8;
                    const src = t * PIXELS_PER_TILE;
                    for (let row = 0; row < 8; row++) {
                        const dst = (ty + row) * ATLAS_W + tx;
                        for (let x = 0; x < 8; x++) {
                            atlasStaging[dst + x] = scene.tileAtlas[src + row * 8 + x];
                        }
                    }
                }
                gl.bindTexture(gl.TEXTURE_2D, atlasTex.tex);
                gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
                gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, ATLAS_W, ATLAS_H,
                    atlasTex.format, atlasTex.type, atlasStaging);
                atlasUploaded = true;
            }

            for (let i = 0; i < MAX_COLUMNS * MAX_COLUMNS; i++) {
                const at = i * CELL_BYTES;
                const tile = scene.cells[at] | (scene.cells[at + 1] << 8);
                mapStaging[i * 4] = tile & 0xFF;
                mapStaging[i * 4 + 1] = (tile >> 8) & 0xFF;
                // Palette bank is stored as an entry offset; the shader wants
                // it as a bank number.
                mapStaging[i * 4 + 2] = scene.cells[at + 2] >= 16 ? 1 : 0;
                mapStaging[i * 4 + 3] = scene.cells[at + 3];
            }
            gl.bindTexture(gl.TEXTURE_2D, mapTex.tex);
            gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
            gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, MAX_COLUMNS, MAX_COLUMNS,
                mapTex.format, mapTex.type, mapStaging);

            for (let i = 0; i < 32; i++) {
                const argb = scene.palette[i];
                paletteStaging[i * 4] = (argb >> 16) & 0xFF;
                paletteStaging[i * 4 + 1] = (argb >> 8) & 0xFF;
                paletteStaging[i * 4 + 2] = argb & 0xFF;
                paletteStaging[i * 4 + 3] = 0xFF;
            }
            gl.bindTexture(gl.TEXTURE_2D, paletteTex.tex);
            gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 32, 1,
                paletteTex.format, paletteTex.type, paletteStaging);
        }

        function bindShared(u, scene) {
            gl.uniform2f(u.u_picture, scene.pictureWidth, scene.pictureHeight);
            gl.uniform4f(u.u_viewport,
                scene.viewportX, scene.viewportY,
                scene.viewportWidth, scene.viewportHeight);
            gl.activeTexture(gl.TEXTURE0);
            gl.bindTexture(gl.TEXTURE_2D, atlasTex.tex);
            gl.uniform1i(u.u_atlas, 0);
            gl.activeTexture(gl.TEXTURE1);
            gl.bindTexture(gl.TEXTURE_2D, paletteTex.tex);
            gl.uniform1i(u.u_palette, 1);
        }

        /// Draw the diorama. `mvp` already includes the projection, the view,
        /// and any model transform placing the picture in the world.
        function draw(mvp) {
            const scene = current;
            if (!scene || !scene.contentValid) return;

            const full = [0, 0, scene.pictureWidth, scene.pictureHeight];
            gl.bindVertexArray(vao);

            // Backdrop, so transparent tile pixels do not show the void.
            gl.useProgram(solidProgram);
            gl.uniformMatrix4fv(soU.u_mvp, false, mvp);
            gl.uniform2f(soU.u_picture, scene.pictureWidth, scene.pictureHeight);
            gl.uniform4f(soU.u_rect,
                scene.viewportX, scene.viewportY,
                scene.viewportWidth, scene.viewportHeight);
            gl.uniform1f(soU.u_z, Z_BACKDROP * depthScale);
            gl.uniform1f(soU.u_layerScale, layerScale(Z_BACKDROP * depthScale));
            gl.uniform4f(soU.u_color,
                ((scene.backdrop >> 16) & 0xFF) / 255,
                ((scene.backdrop >> 8) & 0xFF) / 255,
                (scene.backdrop & 0xFF) / 255, 1.0);
            gl.drawArrays(gl.TRIANGLES, 0, 6);

            if (!scene.displayEnabled) return;

            const verticalWrap = scene.rows > 28 ? 256 : 224;

            function drawBackgroundLayer(layer, z) {
                gl.useProgram(bgProgram);
                bindShared(bgU, scene);
                gl.activeTexture(gl.TEXTURE2);
                gl.bindTexture(gl.TEXTURE_2D, mapTex.tex);
                gl.uniform1i(bgU.u_map, 2);
                gl.uniformMatrix4fv(bgU.u_mvp, false, mvp);
                gl.uniform4f(bgU.u_rect, full[0], full[1], full[2], full[3]);
                gl.uniform1f(bgU.u_z, z * depthScale);
                gl.uniform1f(bgU.u_layerScale, layerScale(z * depthScale));
                gl.uniform2f(bgU.u_scroll, scene.scrollX, scene.scrollY);
                gl.uniform1f(bgU.u_rows, scene.rows);
                gl.uniform1f(bgU.u_verticalWrap, verticalWrap);
                gl.uniform1f(bgU.u_hudRows, scene.hudRows);
                gl.uniform1f(bgU.u_hudCols, scene.hudCols);
                gl.uniform1i(bgU.u_layer, layer);
                gl.uniform1i(bgU.u_leftBlank, scene.leftColumnBlanked ? 1 : 0);
                gl.drawArrays(gl.TRIANGLES, 0, 6);
            }

            drawBackgroundLayer(LAYER_BG_LOW, Z_BG_LOW);

            // Sprites, each its own quad so they read as separate objects
            // when the camera moves off axis. Table order decides overlap.
            gl.useProgram(spriteProgram);
            bindShared(spU, scene);
            gl.uniformMatrix4fv(spU.u_mvp, false, mvp);
            gl.uniform1f(spU.u_z, Z_SPRITES * depthScale);
            gl.uniform1f(spU.u_layerScale, layerScale(Z_SPRITES * depthScale));
            for (let i = scene.spriteCount - 1; i >= 0; i--) {
                const sp = readSprite(scene, i);
                if (sp.width === 0 || sp.height === 0) continue;
                gl.uniform4f(spU.u_rect, sp.x, sp.y, sp.width, sp.height);
                gl.uniform1ui(spU.u_tile, sp.tileIndex);
                gl.uniform1i(spU.u_doubled, (sp.flags & 8) !== 0 ? 1 : 0);
                gl.uniform1ui(spU.u_bank, sp.palette);
                gl.drawArrays(gl.TRIANGLES, 0, 6);
            }

            drawBackgroundLayer(LAYER_BG_HIGH, Z_BG_HIGH);
            drawBackgroundLayer(LAYER_HUD, Z_HUD);

            gl.bindVertexArray(null);
        }

        function dispose() {
            gl.deleteProgram(bgProgram);
            gl.deleteProgram(spriteProgram);
            gl.deleteProgram(solidProgram);
            gl.deleteVertexArray(vao);
            gl.deleteBuffer(vbo);
            gl.deleteTexture(atlasTex.tex);
            gl.deleteTexture(mapTex.tex);
            gl.deleteTexture(paletteTex.tex);
        }

        return {
            upload: upload,
            draw: draw,
            dispose: dispose,
            setDepthScale: setDepthScale,
            getDepthScale: getDepthScale,
        };
    }

    // -- Matrix helpers (column major, matching vr.js) --

    function identity() {
        return new Float32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
    }

    function multiply(a, b) {
        const out = new Float32Array(16);
        for (let j = 0; j < 4; j++) {
            for (let i = 0; i < 4; i++) {
                let s = 0;
                for (let k = 0; k < 4; k++) s += a[k * 4 + i] * b[j * 4 + k];
                out[j * 4 + i] = s;
            }
        }
        return out;
    }

    function perspective(fovY, aspect, near, far) {
        const f = 1 / Math.tan(fovY / 2);
        const out = new Float32Array(16);
        out[0] = f / aspect;
        out[5] = f;
        out[10] = (far + near) / (near - far);
        out[11] = -1;
        out[14] = (2 * far * near) / (near - far);
        return out;
    }

    function lookAt(eye, center, up) {
        const zx = eye[0] - center[0], zy = eye[1] - center[1], zz = eye[2] - center[2];
        let zl = Math.hypot(zx, zy, zz) || 1;
        const z = [zx / zl, zy / zl, zz / zl];
        const xr = [
            up[1] * z[2] - up[2] * z[1],
            up[2] * z[0] - up[0] * z[2],
            up[0] * z[1] - up[1] * z[0],
        ];
        let xl = Math.hypot(xr[0], xr[1], xr[2]) || 1;
        const x = [xr[0] / xl, xr[1] / xl, xr[2] / xl];
        const y = [
            z[1] * x[2] - z[2] * x[1],
            z[2] * x[0] - z[0] * x[2],
            z[0] * x[1] - z[1] * x[0],
        ];
        return new Float32Array([
            x[0], y[0], z[0], 0,
            x[1], y[1], z[1], 0,
            x[2], y[2], z[2], 0,
            -(x[0] * eye[0] + x[1] * eye[1] + x[2] * eye[2]),
            -(y[0] * eye[0] + y[1] * eye[1] + y[2] * eye[2]),
            -(z[0] * eye[0] + z[1] * eye[1] + z[2] * eye[2]),
            1,
        ]);
    }

    function scaleXYZ(sx, sy, sz) {
        return new Float32Array([sx, 0, 0, 0, 0, sy, 0, 0, 0, 0, sz, 0, 0, 0, 0, 1]);
    }

    function translate(x, y, z) {
        return new Float32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1]);
    }

    // -- Desktop viewer --

    /// A self-contained orbit-camera view of the diorama, for looking at the
    /// scene without a headset. Owns its own canvas and WebGL2 context.
    /// `opts.onClick` fires on a tap that was not an orbit drag, so the page
    /// can keep the flat canvas's click-to-pause affordance available while
    /// the 3D view has replaced it.
    function createViewer(canvas, opts) {
        const gl = canvas.getContext("webgl2", {antialias: true, alpha: false});
        if (!gl) return null;

        const options = opts || {};
        const renderer = createRenderer(gl);
        // Yaw and pitch in radians, distance in world units with the picture
        // one unit tall.
        let yaw = 0.45, pitch = 0.28, distance = 2.6;
        let dragging = false, lastX = 0, lastY = 0;
        // Distinguish a click from an orbit drag.
        let downX = 0, downY = 0, moved = 0;
        const CLICK_SLOP = 5;

        function onDown(ev) {
            dragging = true;
            lastX = downX = ev.clientX;
            lastY = downY = ev.clientY;
            moved = 0;
            canvas.setPointerCapture(ev.pointerId);
        }

        function onMove(ev) {
            if (!dragging) return;
            yaw += (ev.clientX - lastX) * 0.006;
            pitch += (ev.clientY - lastY) * 0.006;
            pitch = Math.max(-1.2, Math.min(1.2, pitch));
            lastX = ev.clientX;
            lastY = ev.clientY;
            moved = Math.max(moved, Math.hypot(ev.clientX - downX, ev.clientY - downY));
            // The page only drives rendering while the emulator is running, so
            // redraw here too or the view would freeze while paused.
            redraw();
        }

        function onUp(ev) {
            const wasDragging = dragging;
            dragging = false;
            if (canvas.hasPointerCapture(ev.pointerId)) canvas.releasePointerCapture(ev.pointerId);
            if (wasDragging && moved <= CLICK_SLOP && options.onClick) options.onClick();
        }

        function onWheel(ev) {
            ev.preventDefault();
            distance = Math.max(0.8, Math.min(8, distance * (1 + Math.sign(ev.deltaY) * 0.1)));
            redraw();
        }

        canvas.addEventListener("pointerdown", onDown);
        canvas.addEventListener("pointermove", onMove);
        canvas.addEventListener("pointerup", onUp);
        canvas.addEventListener("pointercancel", onUp);
        canvas.addEventListener("wheel", onWheel, {passive: false});

        function resetView() {
            yaw = 0.45;
            pitch = 0.28;
            distance = 2.6;
            redraw();
        }

        function faceOn() {
            yaw = 0;
            pitch = 0;
            distance = 2.2;
            redraw();
        }

        function setView(newYaw, newPitch, newDistance) {
            yaw = newYaw;
            pitch = Math.max(-1.2, Math.min(1.2, newPitch));
            distance = Math.max(0.8, Math.min(8, newDistance));
        }

        function render(scene) {
            renderer.upload(scene);
            drawFrame();
        }

        /// Redraw the last uploaded scene, for camera changes that happen
        /// while the emulator is paused and not driving new frames.
        function redraw() {
            drawFrame();
        }

        function drawFrame() {
            const dpr = Math.min(window.devicePixelRatio || 1, 2);
            const w = Math.max(1, Math.round(canvas.clientWidth * dpr));
            const h = Math.max(1, Math.round(canvas.clientHeight * dpr));
            if (canvas.width !== w || canvas.height !== h) {
                canvas.width = w;
                canvas.height = h;
            }

            gl.viewport(0, 0, w, h);
            gl.enable(gl.DEPTH_TEST);
            gl.clearColor(0.03, 0.04, 0.06, 1);
            gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

            const eye = [
                Math.sin(yaw) * Math.cos(pitch) * distance,
                Math.sin(pitch) * distance,
                Math.cos(yaw) * Math.cos(pitch) * distance,
            ];
            const proj = perspective(Math.PI / 4, w / h, 0.05, 100);
            const view = lookAt(eye, [0, 0, 0], [0, 1, 0]);
            renderer.draw(multiply(proj, view));
        }

        function dispose() {
            canvas.removeEventListener("pointerdown", onDown);
            canvas.removeEventListener("pointermove", onMove);
            canvas.removeEventListener("pointerup", onUp);
            canvas.removeEventListener("pointercancel", onUp);
            canvas.removeEventListener("wheel", onWheel);
            renderer.dispose();
        }

        return {
            render: render,
            redraw: redraw,
            resetView: resetView,
            faceOn: faceOn,
            setView: setView,
            setDepthScale: renderer.setDepthScale,
            getDepthScale: renderer.getDepthScale,
            dispose: dispose,
        };
    }

    window.SandopolisScene3D = {
        LAYOUT_VERSION: LAYOUT_VERSION,
        parseScene: parseScene,
        readSprite: readSprite,
        createRenderer: createRenderer,
        createViewer: createViewer,
        multiply: multiply,
        translate: translate,
        scaleXYZ: scaleXYZ,
        perspective: perspective,
        lookAt: lookAt,
        identity: identity,
    };
})();
