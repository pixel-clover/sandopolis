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
    const LAYOUT_VERSION = 4;
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
        tileAtlas: 5292,
        lineScrollX: 136364,
        genFlags: 136844, genPlaneW: 136848, genPlaneH: 136850,
        genWinW: 136852, genReg17: 136854, genReg18: 136855, genSpriteCount: 136856,
        genPalette2: 136860,
        genALineHscroll: 136988, genBLineHscroll: 137468,
        genAColVscroll: 137948, genBColVscroll: 137988,
        genSprites: 138028,
        genPlaneA: 138988, genPlaneB: 155372, genWindow: 171756,
    };

    const MAX_COLUMNS = 32;
    const MAX_SPRITES = 64;
    const MAX_TILES = 2048;
    const GEN_PLANE_CELLS = 4096;
    const GEN_WINDOW_CELLS = 2048;
    const GEN_MAX_SPRITES = 80;
    const GEN_SPRITE_BYTES = 12;
    const GEN_FLAG_SH = 1 << 0;
    const GEN_FLAG_INTERLACE2 = 1 << 1;
    const GEN_FLAG_H40 = 1 << 2;
    const GEN_FLAG_COL_VSCROLL = 1 << 3;
    const MAX_LINES = 240;
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
    const Z_BACKDROP = -0.34;
    const Z_BG_LOW = 0.0;
    // Range the background bands are spread across when parallax reveals
    // depth. Kept clearly behind the sprite layer.
    const Z_BG_PARALLAX_NEAR = 0.04;
    const Z_BG_PARALLAX_FAR = -0.22;
    const Z_SPRITES = 0.14;
    const Z_BG_HIGH = 0.24;
    const Z_HUD = 0.45;

    // Extrusion turns each flat layer into a slab. Slices are cheap because
    // they are instanced, so the whole slab is still one draw call.
    const EXTRUDE_SLICES = 10;
    const Z_EXTRUDE_SPRITE = 0.05;
    const Z_EXTRUDE_BG = 0.03;

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
            lineScrollX: new Uint16Array(memoryBuffer, ptr + OFF.lineScrollX, MAX_LINES),
            // Genesis section (zeroed for the other systems).
            genFlags: view.getUint32(OFF.genFlags, true),
            genPlaneW: view.getUint16(OFF.genPlaneW, true),
            genPlaneH: view.getUint16(OFF.genPlaneH, true),
            genWinW: view.getUint16(OFF.genWinW, true),
            genReg17: view.getUint8(OFF.genReg17),
            genReg18: view.getUint8(OFF.genReg18),
            genSpriteCount: view.getUint8(OFF.genSpriteCount),
            genPalette2: new Uint32Array(memoryBuffer, ptr + OFF.genPalette2, 32),
            genALineHscroll: new Int16Array(memoryBuffer, ptr + OFF.genALineHscroll, MAX_LINES),
            genBLineHscroll: new Int16Array(memoryBuffer, ptr + OFF.genBLineHscroll, MAX_LINES),
            genAColVscroll: new Uint16Array(memoryBuffer, ptr + OFF.genAColVscroll, 20),
            genBColVscroll: new Uint16Array(memoryBuffer, ptr + OFF.genBColVscroll, 20),
            genSprites: new DataView(memoryBuffer, ptr + OFF.genSprites, GEN_MAX_SPRITES * GEN_SPRITE_BYTES),
            genPlaneA: new Uint8Array(memoryBuffer, ptr + OFF.genPlaneA, GEN_PLANE_CELLS * CELL_BYTES),
            genPlaneB: new Uint8Array(memoryBuffer, ptr + OFF.genPlaneB, GEN_PLANE_CELLS * CELL_BYTES),
            genWindow: new Uint8Array(memoryBuffer, ptr + OFF.genWindow, GEN_WINDOW_CELLS * CELL_BYTES),
        };
    }

    function readGenSprite(scene, i) {
        const d = scene.genSprites;
        const at = i * GEN_SPRITE_BYTES;
        return {
            x: d.getInt16(at, true),
            y: d.getInt16(at + 2, true),
            tileBase: d.getUint16(at + 4, true),
            hSize: d.getUint8(at + 6),
            vSize: d.getUint8(at + 7),
            palette: d.getUint8(at + 8),
            flags: d.getUint8(at + 9),
            slot: d.getUint8(at + 10),
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
    out vec2 v_px;         // position within the picture, in pixels
    out float v_t;         // 0 at the topmost slice, 1 at the base plane
    uniform mat4 u_mvp;
    uniform vec4 u_rect;   // x, y, width, height in picture pixels
    uniform vec2 u_picture;
    uniform float u_z;
    uniform float u_extrude;   // slab depth; 0 draws a single flat plane
    uniform int u_slices;
    void main() {
        // a_pos is a unit quad in 0..1. Map it into the picture rectangle,
        // then into world space with the picture one unit tall and the
        // origin at its centre. Picture Y runs downward, world Y upward.
        vec2 px = u_rect.xy + a_pos * u_rect.zw;
        v_uv = a_pos;
        v_px = px;

        // Extrusion: the quad is drawn once per instance, each a slice
        // stepped back from the front face. Because every slice is scaled to
        // its own depth (below), the slices stack into a solid prism that is
        // pixel-identical to the flat picture when viewed head-on, and only
        // shows its sides once the camera moves off axis.
        // t = 0 is the topmost slice, t = 1 the shared base plane. Slabs
        // therefore rise *toward* the viewer out of a common floor, which is
        // what makes one tile visibly taller than its neighbour. Extruding
        // away from a shared front plane instead would hide every height
        // difference behind the front faces of a gap-free tilemap.
        float t = (u_slices > 1) ? float(gl_InstanceID) / float(u_slices - 1) : 0.0;
        float z = u_z + (1.0 - t) * u_extrude;
        v_t = t;

        // Shrink nearer layers and enlarge farther ones so every layer covers
        // the same solid angle from the design viewpoint.
        float scale = (${REFERENCE_DISTANCE.toFixed(4)} - z) / ${REFERENCE_DISTANCE.toFixed(4)};
        vec2 world = vec2(
            (px.x - u_picture.x * 0.5) / u_picture.y,
            (u_picture.y * 0.5 - px.y) / u_picture.y
        ) * scale;
        gl_Position = u_mvp * vec4(world, z, 1.0);
    }`;

    const COMMON_FS_HEAD = `#version 300 es
    precision highp float;
    // Must match the vertex stage: GLSL ES gives int no default precision in
    // fragment shaders, and a uniform shared with the vertex stage has to
    // agree or the program fails to link.
    precision highp int;
    precision highp usampler2D;
    out vec4 outColor;
    uniform usampler2D u_atlas;
    uniform sampler2D u_palette;
    uniform sampler2D u_heights;   // per-tile extrusion height, 0..1
    uniform int u_slices;
    uniform vec4 u_viewport;   // x, y, width, height in picture pixels

    float tileHeight(uint tile) {
        return texelFetch(u_heights, ivec2(int(tile), 0), 0).r;
    }

    /// A tile of height h occupies the slices from t = 1 - h down to the
    /// base at t = 1; anything nearer than that is empty air above it.
    /// A single-slice draw is a flat plane (the HUD band, or extrusion
    /// turned off) with no notion of slab height, so nothing is carved:
    /// otherwise a profile height below 1 would blank the whole quad.
    bool aboveTile(float h, float t) {
        return u_slices > 1 && t < 1.0 - h;
    }

    /// Shade relative to the tile's own top rather than the global slice
    /// index, so every tile keeps a full-brightness top face however tall
    /// the profile made it.
    ///
    /// The tile's true top, 1 - h, almost never lands exactly on the slice
    /// grid, so the first slice that survives sits slightly below it. Shading
    /// straight from 1 - h would therefore treat that top face as if it were
    /// already partway down the side and darken it: a tile of height 0.1 with
    /// 17 slices came out at 79% brightness. Measure from the first surviving
    /// slice instead, which is by definition the visible top.
    float slabShade(float h, float t) {
        float step = 1.0 / max(float(u_slices - 1), 1.0);
        float firstSlice = ceil((1.0 - h) / step - 0.001) * step;
        return 1.0 - 0.55 * clamp((t - firstSlice) / max(h, 0.001), 0.0, 1.0);
    }

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
    }

    uniform usampler2D u_shMask;   // 0 shadow, 1 normal, 2 highlight
    uniform bool u_shMode;

    /// Shadow/highlight intensity transform, bit-exact with the
    /// rasterizer's integer arithmetic (shadow c>>1, highlight c/2+0x80).
    vec3 shApply(vec3 c, ivec2 px) {
        if (!u_shMode) return c;
        uint m = texelFetch(u_shMask, px, 0).r;
        if (m == 1u) return c;
        vec3 b = floor(c * 255.0 + 0.5);
        if (m == 0u) return floor(b / 2.0) / 255.0;
        return min(floor(b / 2.0) + 128.0, 255.0) / 255.0;
    }`;

    const BACKGROUND_FS = COMMON_FS_HEAD + `
    in vec2 v_uv;
    in vec2 v_px;
    in float v_t;
    uniform usampler2D u_map;
    uniform usampler2D u_lineScroll;   // horizontal scroll per picture line
    uniform vec2 u_picture;
    uniform vec2 u_scroll;
    uniform float u_rows;
    uniform float u_verticalWrap;
    uniform float u_hudRows;
    uniform float u_hudCols;
    uniform int u_layer;
    uniform bool u_leftBlank;

    void main() {
        vec2 px = floor(v_px);
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
        // Scroll is sampled per line, so a mid-frame rewrite splits the
        // screen into bands moving at different rates.
        float hscroll = hLocked
            ? 0.0
            : float(texelFetch(u_lineScroll, ivec2(int(px.y), 0), 0).r);
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
        float h = tileHeight(tile);
        if (aboveTile(h, v_t)) discard;

        float fineY = mod(effY, 8.0);
        float fineX = mod(scrolledX, 8.0);
        float ty = ((flags & 2u) != 0u) ? 7.0 - fineY : fineY;
        float tx = ((flags & 1u) != 0u) ? 7.0 - fineX : fineX;

        outColor = lookupTilePixel(tile, uint(tx), uint(ty), uint(cell.b) * 16u);
        outColor.rgb *= slabShade(h, v_t);
    }`;

    const SPRITE_FS = COMMON_FS_HEAD + `
    in vec2 v_uv;
    in vec2 v_px;
    in float v_t;
    uniform vec4 u_rect;
    uniform uint u_tile;
    uniform bool u_doubled;
    uniform uint u_bank;

    void main() {
        vec2 local = floor(v_px) - u_rect.xy;
        clipToViewport(floor(v_px));

        uint sx = uint(local.x);
        uint sy = uint(local.y);
        // The hardware zoom bit doubles each source pixel on both axes.
        uint srcCol = u_doubled ? sx / 2u : sx;
        uint srcRow = u_doubled ? sy / 2u : sy;
        // Tall sprites continue into the next pattern after eight rows.
        uint tile = u_tile + (srcRow >= 8u ? 1u : 0u);
        float h = tileHeight(tile);
        if (aboveTile(h, v_t)) discard;

        outColor = lookupTilePixel(tile, srcCol, srcRow % 8u, u_bank);
        outColor.rgb *= slabShade(h, v_t);
    }`;

    // Genesis scroll plane. The map texture holds the raw name table; per-line
    // horizontal scroll and per-column vertical scroll come from small lookup
    // textures, mirroring src/video/render.zig.
    const GEN_PLANE_FS = COMMON_FS_HEAD + `
    in vec2 v_px;
    in float v_t;
    uniform usampler2D u_map;          // plane cells, u_mapW texels per row
    uniform usampler2D u_lineScroll;   // 240x2 rows: 0 = A, 1 = B
    uniform usampler2D u_colVscroll;   // 20x2 rows: 0 = A, 1 = B
    uniform int u_scrollRow;
    uniform int u_mapW;                // window name-table width in cells
    uniform int u_planeW;              // plane size in tiles
    uniform int u_planeH;
    uniform bool u_colMode;            // per-column vertical scroll
    uniform bool u_h40;
    uniform int u_layer;               // 0 = low priority pass, 1 = high
    // Window handling: 0 = ignore the window (plane B), 1 = skip the window
    // region (plane A), 2 = draw only the window region (window map).
    uniform int u_winMode;
    uniform uint u_reg17;
    uniform uint u_reg18;

    int scrollAt(int line, int row) {
        uint raw = texelFetch(u_lineScroll, ivec2(line, row), 0).r;
        return raw > 32767u ? int(raw) - 65536 : int(raw);
    }

    bool inWindow(ivec2 px) {
        // The window replaces plane A above/below a row boundary and left/
        // right of a column split, per registers 18 and 17.
        bool down = (u_reg18 & 0x80u) != 0u;
        int boundary = int(u_reg18 & 0x1Fu) * 8;
        if (down == (px.y >= boundary)) return true;
        int splitCells = int(u_reg17 & 0x1Fu);
        bool right = (u_reg17 & 0x80u) != 0u;
        int screenCells = u_h40 ? 20 : 16;
        if (splitCells == 0) return right;
        if (splitCells > screenCells) return !right;
        int splitX = splitCells * 16;
        return right ? (px.x >= splitX) : (px.x < splitX);
    }

    void main() {
        ivec2 px = ivec2(floor(v_px));
        clipToViewport(vec2(px));
        if (u_winMode == 1 && inWindow(px)) discard;
        if (u_winMode == 2 && !inWindow(px)) discard;

        int wrapX;
        int wrapY;
        uvec4 cell;
        if (u_winMode == 2) {
            // The window plane never scrolls. Its name table is u_mapW cells
            // wide, stored in a 64-texel-wide texture.
            wrapX = px.x;
            wrapY = px.y;
            int index = (wrapY >> 3) * u_mapW + (wrapX >> 3);
            cell = texelFetch(u_map, ivec2(index & 63, index >> 6), 0);
        } else {
            int hscroll = scrollAt(px.y, u_scrollRow);
            int vscroll;
            if (u_colMode) {
                int shift = hscroll & 15;
                if (shift != 0 && px.x < shift) {
                    // Columns hidden by fine scroll read an undefined VSRAM
                    // slot: H40 ANDs both planes' column 19, H32 reads zero.
                    vscroll = u_h40
                        ? int(texelFetch(u_colVscroll, ivec2(19, 0), 0).r &
                              texelFetch(u_colVscroll, ivec2(19, 1), 0).r)
                        : 0;
                } else {
                    int pair = (shift != 0 ? px.x - shift : px.x) / 16;
                    vscroll = int(texelFetch(u_colVscroll, ivec2(min(pair, 19), u_scrollRow), 0).r);
                }
            } else {
                vscroll = int(texelFetch(u_colVscroll, ivec2(0, u_scrollRow), 0).r);
            }

            int planeWpx = u_planeW * 8;
            int planeHpx = u_planeH * 8;
            wrapX = ((px.x - hscroll) % planeWpx + planeWpx) % planeWpx;
            wrapY = ((px.y + vscroll) % planeHpx + planeHpx) % planeHpx;
            // Plane cells are linear in the 64-texel-wide map texture.
            int index = (wrapY >> 3) * u_planeW + (wrapX >> 3);
            cell = texelFetch(u_map, ivec2(index & 63, index >> 6), 0);
        }

        uint tile = cell.r + (cell.g << 8u);
        uint flags = cell.a;
        bool priority = (flags & 4u) != 0u;
        if (u_layer == 0 && priority) discard;
        if (u_layer == 1 && !priority) discard;

        float h = tileHeight(tile);
        if (aboveTile(h, v_t)) discard;

        int fx = wrapX & 7;
        int fy = wrapY & 7;
        if ((flags & 1u) != 0u) fx = 7 - fx;
        if ((flags & 2u) != 0u) fy = 7 - fy;

        outColor = lookupTilePixel(tile, uint(fx), uint(fy), uint(cell.b));
        outColor.rgb = shApply(outColor.rgb, px) * slabShade(h, v_t);
    }`;

    // Genesis sprite: up to 4x4 tiles, patterns advancing column-major, with
    // whole-sprite flips.
    const GEN_SPRITE_FS = COMMON_FS_HEAD + `
    in vec2 v_px;
    in float v_t;
    uniform vec4 u_rect;
    uniform uint u_tile;
    uniform uint u_bank;
    uniform int u_vSize;
    uniform bool u_hFlip;
    uniform bool u_vFlip;
    uniform bool u_highSprite;

    void main() {
        vec2 local = floor(v_px) - u_rect.xy;
        clipToViewport(floor(v_px));

        int sx = int(local.x);
        int sy = int(local.y);
        if (u_hFlip) sx = int(u_rect.z) - 1 - sx;
        if (u_vFlip) sy = int(u_rect.w) - 1 - sy;

        uint tile = u_tile + uint((sx >> 3) * u_vSize + (sy >> 3));
        float h = tileHeight(tile);
        if (aboveTile(h, v_t)) discard;

        // Peek the color index first: in shadow/highlight mode, palette 3
        // colors 14 and 15 are operators, never drawn as pixels.
        uint rawCi = texelFetch(u_atlas, ivec2(
            int(tile % ${ATLAS_TILES_X}u) * 8 + (sx & 7),
            int(tile / ${ATLAS_TILES_X}u) * 8 + (sy & 7)), 0).r;
        if (u_shMode && u_bank == 48u && (rawCi == 14u || rawCi == 15u)) discard;

        outColor = lookupTilePixel(tile, uint(sx & 7), uint(sy & 7), u_bank);
        // Priority sprites and color 14 of any palette always display at
        // normal intensity; everything else honors the mask.
        if (!(u_highSprite || rawCi == 14u)) {
            outColor.rgb = shApply(outColor.rgb, ivec2(floor(v_px)));
        }
        outColor.rgb *= slabShade(h, v_t);
    }`;

    const SOLID_FS = `#version 300 es
    precision highp float;
    precision highp int;
    precision highp usampler2D;
    in vec2 v_uv;
    in vec2 v_px;
    in float v_t;
    out vec4 outColor;
    uniform vec4 u_color;
    uniform usampler2D u_shMask;
    uniform bool u_shMode;
    void main() {
        outColor = u_color;
        if (u_shMode) {
            uint m = texelFetch(u_shMask, ivec2(floor(v_px)), 0).r;
            if (m != 1u) {
                vec3 b = floor(outColor.rgb * 255.0 + 0.5);
                outColor.rgb = (m == 0u)
                    ? floor(b / 2.0) / 255.0
                    : min(floor(b / 2.0) + 128.0, 255.0) / 255.0;
            }
        }
    }`;

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
        const genPlaneProgram = compileProgram(gl, QUAD_VS, GEN_PLANE_FS);
        const genSpriteProgram = compileProgram(gl, QUAD_VS, GEN_SPRITE_FS);

        const bgU = uniforms(gl, bgProgram, [
            "u_mvp", "u_rect", "u_picture", "u_z", "u_extrude", "u_slices", "u_atlas", "u_palette", "u_heights", "u_map",
            "u_scroll", "u_rows", "u_verticalWrap", "u_hudRows", "u_hudCols",
            "u_layer", "u_viewport", "u_leftBlank", "u_lineScroll",
        ]);
        const spU = uniforms(gl, spriteProgram, [
            "u_mvp", "u_rect", "u_picture", "u_z", "u_extrude", "u_slices", "u_atlas", "u_palette", "u_heights",
            "u_tile", "u_doubled", "u_bank", "u_viewport",
        ]);
        const soU = uniforms(gl, solidProgram, [
            "u_mvp", "u_rect", "u_picture", "u_z", "u_extrude", "u_slices", "u_color",
            "u_shMask", "u_shMode",
        ]);
        const gpU = uniforms(gl, genPlaneProgram, [
            "u_mvp", "u_rect", "u_picture", "u_z", "u_extrude", "u_slices",
            "u_atlas", "u_palette", "u_heights", "u_viewport",
            "u_map", "u_lineScroll", "u_colVscroll", "u_scrollRow", "u_mapW",
            "u_planeW", "u_planeH", "u_colMode", "u_h40", "u_layer",
            "u_winMode", "u_reg17", "u_reg18", "u_shMask", "u_shMode",
        ]);
        const gsU = uniforms(gl, genSpriteProgram, [
            "u_mvp", "u_rect", "u_picture", "u_z", "u_extrude", "u_slices",
            "u_atlas", "u_palette", "u_heights", "u_viewport",
            "u_tile", "u_bank", "u_vSize", "u_hFlip", "u_vFlip",
            "u_highSprite", "u_shMask", "u_shMode",
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
        const paletteTex = makeTexture(gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, 64, 1, gl.NEAREST);
        const lineScrollTex = makeTexture(gl.R16UI, gl.RED_INTEGER, gl.UNSIGNED_SHORT, MAX_LINES, 1, gl.NEAREST);
        // Genesis: plane cell maps (4096 cells at 64 texels per row), the
        // window map, per-line hscroll for both planes, and column vscroll.
        const genPlaneATex = makeTexture(gl.RGBA8UI, gl.RGBA_INTEGER, gl.UNSIGNED_BYTE, 64, 64, gl.NEAREST);
        const genPlaneBTex = makeTexture(gl.RGBA8UI, gl.RGBA_INTEGER, gl.UNSIGNED_BYTE, 64, 64, gl.NEAREST);
        const genWindowTex = makeTexture(gl.RGBA8UI, gl.RGBA_INTEGER, gl.UNSIGNED_BYTE, 64, 32, gl.NEAREST);
        const genLineScrollTex = makeTexture(gl.R16UI, gl.RED_INTEGER, gl.UNSIGNED_SHORT, MAX_LINES, 2, gl.NEAREST);
        const genColVscrollTex = makeTexture(gl.R16UI, gl.RED_INTEGER, gl.UNSIGNED_SHORT, 20, 2, gl.NEAREST);
        // Shadow/highlight state per picture pixel: 0 shadow, 1 normal,
        // 2 highlight. Computed on the CPU because sprite operators need
        // read-modify-write semantics a single GL pass cannot express.
        const genShMaskTex = makeTexture(gl.R8UI, gl.RED_INTEGER, gl.UNSIGNED_BYTE, 320, 240, gl.NEAREST);
        const genShMask = new Uint8Array(320 * 240);
        const heightsTex = makeTexture(gl.R8, gl.RED, gl.UNSIGNED_BYTE, MAX_TILES, 1, gl.NEAREST);

        // Staging buffers, reused every frame.
        const atlasStaging = new Uint8Array(ATLAS_W * ATLAS_H);
        const mapStaging = new Uint8Array(MAX_COLUMNS * MAX_COLUMNS * 4);
        const paletteStaging = new Uint8Array(64 * 4);
        const lineScrollStaging = new Uint16Array(MAX_LINES);
        const genLineScrollStaging = new Uint16Array(MAX_LINES * 2);
        const genColVscrollStaging = new Uint16Array(40);
        // Plane B parallax: Genesis games split the far plane into bands with
        // per-line scroll (layered skies, water). Same velocity inference as
        // the SMS path, applied to plane B's per-line values.
        const genPrevB = new Int16Array(MAX_LINES);
        const genVelB = new Float32Array(MAX_LINES);
        let genHavePrev = false;
        let genBands = [{y0: 0, y1: 0, z: -0.12}];
        // Per-tile extrusion height. Full height everywhere reproduces the
        // profile-free look, so a game with no profile is unaffected.
        const heightsStaging = new Uint8Array(MAX_TILES).fill(255);
        let heightsDirty = true;

        // Parallax depth inference. A band of the screen that scrolls faster
        // than another is nearer to the viewer, which is the only depth cue
        // the hardware gives away for free. Velocity is measured against the
        // previous frame and smoothed, because a single frame's delta is
        // noisy and drops to zero whenever the game pauses scrolling.
        const prevLineScroll = new Uint16Array(MAX_LINES);
        const lineVelocity = new Float32Array(MAX_LINES);
        let havePrevScroll = false;
        let parallaxEnabled = true;
        let extrudeEnabled = true;
        // "scene" leaves the HUD as a plane inside the diorama. "overlay"
        // pins it to the screen so it stays square-on and readable while the
        // camera orbits, which is what a desktop viewer wants. A headset
        // wants "scene", because there the diorama is a fixed object in the
        // room and the viewer walks around it.
        let hudMode = "scene";
        let sliceCount = EXTRUDE_SLICES;
        // Depth of a full-height slab. The profile-free default is shallow,
        // just enough to give flat art some body. A per-game profile assigns
        // heights across this range, so it usually wants a deeper slab for
        // the variation between water and a tower to actually read.
        let extrudeDepth = Z_EXTRUDE_BG;
        let autoSlices = true;

        /// One slice per ~1.5 source pixels keeps the stack solid without
        /// paying for slices finer than the art.
        function slicesForDepth(depth) {
            const px = depth * 192;
            return Math.max(6, Math.min(24, Math.ceil(px / 1.5)));
        }
        // Cheap instrumentation so the cost can be read on the device that
        // actually matters rather than guessed at on a desktop.
        const stats = {uploadMs: 0, drawMs: 0, drawCalls: 0, slices: 0, bands: 0, dirtyTiles: 0};
        let bands = [{y0: 0, y1: 0, z: Z_BG_LOW}];

        let current = null;
        let atlasUploaded = false;
        // 0 collapses every layer onto one plane, reproducing the flat
        // picture. 1 is the default diorama spacing.
        let depthScale = 1.0;

        function setDepthScale(v) {
            if (!Number.isFinite(v)) return;
            depthScale = Math.max(0, Math.min(4, v));
        }

        function getDepthScale() {
            return depthScale;
        }

        function upload(scene) {
            current = scene;
            if (!scene || !scene.contentValid) return;
            const t0 = performance.now();

            // Repack the tile atlas into the 2D texture layout. The staging
            // buffer mirrors the texture, so only tiles the VDP actually
            // rewrote need repacking, and only the affected rows of the
            // texture need re-uploading. A game animating a handful of tiles
            // therefore costs a handful of tiles of work, not all 512.
            let dirtyCount = 0;
            let firstBand = -1, lastBand = -1;
            for (let t = 0; t < MAX_TILES; t++) {
                if (atlasUploaded && !((scene.tileDirty[t >> 3] >> (t & 7)) & 1)) continue;
                dirtyCount++;
                const band = (t / ATLAS_TILES_X) | 0;
                if (firstBand < 0) firstBand = band;
                lastBand = band;

                const tx = (t % ATLAS_TILES_X) * 8;
                const ty = band * 8;
                const src = t * PIXELS_PER_TILE;
                for (let row = 0; row < 8; row++) {
                    const dst = (ty + row) * ATLAS_W + tx;
                    const from = src + row * 8;
                    atlasStaging[dst] = scene.tileAtlas[from];
                    atlasStaging[dst + 1] = scene.tileAtlas[from + 1];
                    atlasStaging[dst + 2] = scene.tileAtlas[from + 2];
                    atlasStaging[dst + 3] = scene.tileAtlas[from + 3];
                    atlasStaging[dst + 4] = scene.tileAtlas[from + 4];
                    atlasStaging[dst + 5] = scene.tileAtlas[from + 5];
                    atlasStaging[dst + 6] = scene.tileAtlas[from + 6];
                    atlasStaging[dst + 7] = scene.tileAtlas[from + 7];
                }
            }
            stats.dirtyTiles = dirtyCount;
            if (dirtyCount > 0) {
                const y0 = firstBand * 8;
                const rows = (lastBand - firstBand + 1) * 8;
                gl.bindTexture(gl.TEXTURE_2D, atlasTex.tex);
                gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
                // Upload only the band of rows containing changed tiles.
                gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, y0, ATLAS_W, rows,
                    atlasTex.format, atlasTex.type,
                    atlasStaging.subarray(y0 * ATLAS_W, (y0 + rows) * ATLAS_W));
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

            for (let i = 0; i < 64; i++) {
                const argb = i < 32 ? scene.palette[i] : scene.genPalette2[i - 32];
                paletteStaging[i * 4] = (argb >> 16) & 0xFF;
                paletteStaging[i * 4 + 1] = (argb >> 8) & 0xFF;
                paletteStaging[i * 4 + 2] = argb & 0xFF;
                paletteStaging[i * 4 + 3] = 0xFF;
            }
            gl.bindTexture(gl.TEXTURE_2D, paletteTex.tex);
            gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 64, 1,
                paletteTex.format, paletteTex.type, paletteStaging);

            if (heightsDirty) {
                gl.bindTexture(gl.TEXTURE_2D, heightsTex.tex);
                gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
                gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, MAX_TILES, 1,
                    heightsTex.format, heightsTex.type, heightsStaging);
                heightsDirty = false;
            }

            if (scene.system === 3) {
                // Genesis: the scene's cell byte layout (tile lo, tile hi,
                // palette, flags) is exactly an RGBA8UI texel, so the plane
                // maps upload without repacking.
                gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
                gl.bindTexture(gl.TEXTURE_2D, genPlaneATex.tex);
                gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 64, 64,
                    genPlaneATex.format, genPlaneATex.type, scene.genPlaneA);
                gl.bindTexture(gl.TEXTURE_2D, genPlaneBTex.tex);
                gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 64, 64,
                    genPlaneBTex.format, genPlaneBTex.type, scene.genPlaneB);
                gl.bindTexture(gl.TEXTURE_2D, genWindowTex.tex);
                gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 64, 32,
                    genWindowTex.format, genWindowTex.type, scene.genWindow);

                genLineScrollStaging.set(scene.genALineHscroll, 0);
                genLineScrollStaging.set(scene.genBLineHscroll, MAX_LINES);
                gl.bindTexture(gl.TEXTURE_2D, genLineScrollTex.tex);
                gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, MAX_LINES, 2,
                    genLineScrollTex.format, genLineScrollTex.type, genLineScrollStaging);

                genColVscrollStaging.set(scene.genAColVscroll, 0);
                genColVscrollStaging.set(scene.genBColVscroll, 20);
                gl.bindTexture(gl.TEXTURE_2D, genColVscrollTex.tex);
                gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 20, 2,
                    genColVscrollTex.format, genColVscrollTex.type, genColVscrollStaging);

                if (scene.genFlags & GEN_FLAG_SH) {
                    computeGenShMask(scene);
                    gl.bindTexture(gl.TEXTURE_2D, genShMaskTex.tex);
                    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 320, 240,
                        genShMaskTex.format, genShMaskTex.type, genShMask);
                }

                updateGenParallax(scene);
            } else {
                lineScrollStaging.set(scene.lineScrollX);
                gl.bindTexture(gl.TEXTURE_2D, lineScrollTex.tex);
                gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, MAX_LINES, 1,
                    lineScrollTex.format, lineScrollTex.type, lineScrollStaging);

                updateParallax(scene);
            }
            stats.uploadMs = performance.now() - t0;
        }

        /// Shortest signed distance between two scroll values. The register is
        /// eight bits, so 255 to 0 is a step of one, not a jump of 255.
        function scrollDelta(now, before) {
            return ((now - before + 128) & 0xFF) - 128;
        }

        function updateParallax(scene) {
            const h = Math.min(MAX_LINES, scene.pictureHeight);
            if (havePrevScroll) {
                for (let y = 0; y < h; y++) {
                    const v = Math.abs(scrollDelta(scene.lineScrollX[y], prevLineScroll[y]));
                    // Hold the previous estimate when nothing moved, so a
                    // stationary screen keeps the depth it had been given.
                    lineVelocity[y] = v === 0
                        ? lineVelocity[y]
                        : lineVelocity[y] * 0.8 + v * 0.2;
                }
            }
            prevLineScroll.set(scene.lineScrollX);
            havePrevScroll = true;
            bands = computeBands(scene, h);
        }

        /// Shadow/highlight mask, mirroring the reconstruction in
        /// src/testing/scene_recon.zig: everything starts in shadow, the
        /// priority bit of any plane cell lifts its pixels to normal (even
        /// transparent ones), and palette-3 color 14/15 sprite pixels act as
        /// highlight/shadow operators in link order.
        function computeGenShMask(scene) {
            const w = scene.pictureWidth, h = scene.pictureHeight;
            genShMask.fill(0, 0, 320 * 240);

            const planeWpx = scene.genPlaneW * 8;
            const planeHpx = scene.genPlaneH * 8;
            const colMode = (scene.genFlags & GEN_FLAG_COL_VSCROLL) !== 0;
            const h40 = (scene.genFlags & GEN_FLAG_H40) !== 0;

            function liftPlane(cells, lineScroll, colVscroll, isA) {
                for (let y = 0; y < h; y++) {
                    // Window layout: skip plane A where the window replaces it.
                    let winFull = false, winStart = -1, winEnd = -1;
                    if (isA) {
                        const down = (scene.genReg18 & 0x80) !== 0;
                        const boundary = (scene.genReg18 & 0x1F) * 8;
                        if (down === (y >= boundary)) { winFull = true; } else {
                            const splitCells = scene.genReg17 & 0x1F;
                            const right = (scene.genReg17 & 0x80) !== 0;
                            const screenCells = h40 ? 20 : 16;
                            if (splitCells === 0) { if (right) winFull = true; }
                            else if (splitCells > screenCells) { if (!right) winFull = true; }
                            else {
                                const splitX = Math.min(splitCells * 16, w);
                                if (right) { winStart = splitX; winEnd = w; }
                                else { winStart = 0; winEnd = splitX; }
                            }
                        }
                        if (winFull) continue;
                    }
                    const hscroll = lineScroll[y];
                    const shift = hscroll & 15;
                    for (let x = 0; x < w; x++) {
                        if (isA && winStart >= 0 && x >= winStart && x < winEnd) continue;
                        let vscroll = colVscroll[0];
                        if (colMode) {
                            if (shift !== 0 && x < shift) {
                                vscroll = h40 ? (scene.genAColVscroll[19] & scene.genBColVscroll[19]) : 0;
                            } else {
                                const pair = Math.min(((shift !== 0 ? x - shift : x) >> 4), 19);
                                vscroll = colVscroll[pair];
                            }
                        }
                        const wx = ((x - hscroll) % planeWpx + planeWpx) % planeWpx;
                        const wy = ((y + vscroll) % planeHpx + planeHpx) % planeHpx;
                        const idx = ((wy >> 3) * scene.genPlaneW + (wx >> 3)) * 4;
                        if (cells[idx + 3] & 4) genShMask[y * 320 + x] = 1;
                    }
                }
            }

            liftPlane(scene.genPlaneB, scene.genBLineHscroll, scene.genBColVscroll, false);
            liftPlane(scene.genPlaneA, scene.genALineHscroll, scene.genAColVscroll, true);

            // Window cells lift where the window shows.
            for (let y = 0; y < h; y++) {
                const down = (scene.genReg18 & 0x80) !== 0;
                const boundary = (scene.genReg18 & 0x1F) * 8;
                let s0 = -1, s1 = -1;
                if (down === (y >= boundary)) { s0 = 0; s1 = w; } else {
                    const splitCells = scene.genReg17 & 0x1F;
                    const right = (scene.genReg17 & 0x80) !== 0;
                    const screenCells = h40 ? 20 : 16;
                    if (splitCells === 0) { if (right) { s0 = 0; s1 = w; } }
                    else if (splitCells > screenCells) { if (!right) { s0 = 0; s1 = w; } }
                    else {
                        const splitX = Math.min(splitCells * 16, w);
                        if (right) { s0 = splitX; s1 = w; } else { s0 = 0; s1 = splitX; }
                    }
                }
                for (let x = Math.max(0, s0); x < s1; x++) {
                    const idx = (((y >> 3) * scene.genWinW + (x >> 3)) * 4);
                    if (scene.genWindow[idx + 3] & 4) genShMask[y * 320 + x] = 1;
                }
            }

            // Sprite operators, in link order.
            for (let i = 0; i < scene.genSpriteCount; i++) {
                const sp = readGenSprite(scene, i);
                if (sp.palette !== 48) continue;
                const wpx = sp.hSize * 8, hpx = sp.vSize * 8;
                for (let ry = 0; ry < hpx; ry++) {
                    const y = sp.y + ry;
                    if (y < 0 || y >= h) continue;
                    let sy = (sp.flags & 2) ? hpx - 1 - ry : ry;
                    for (let rx = 0; rx < wpx; rx++) {
                        const x = sp.x + rx;
                        if (x < 0 || x >= w) continue;
                        let sx = (sp.flags & 1) ? wpx - 1 - rx : rx;
                        const tile = sp.tileBase + ((sx >> 3) * sp.vSize + (sy >> 3));
                        const ci = scene.tileAtlas[tile * 64 + (sy & 7) * 8 + (sx & 7)];
                        const at = y * 320 + x;
                        if (ci === 14) {
                            genShMask[at] = genShMask[at] === 0 ? 1 : 2;
                        } else if (ci === 15) {
                            genShMask[at] = 0;
                        }
                    }
                }
            }
        }

        function updateGenParallax(scene) {
            const h = Math.min(MAX_LINES, scene.pictureHeight);
            if (genHavePrev) {
                for (let y = 0; y < h; y++) {
                    const v = Math.min(64, Math.abs(scene.genBLineHscroll[y] - genPrevB[y]));
                    genVelB[y] = v === 0 ? genVelB[y] : genVelB[y] * 0.8 + v * 0.2;
                }
            }
            genPrevB.set(scene.genBLineHscroll.subarray(0, MAX_LINES));
            genHavePrev = true;
            genBands = computeGenBands(h);
        }

        /// Plane B depth bands from scroll velocity, spread across the space
        /// behind plane A. A single flat band is the default.
        function computeGenBands(h) {
            const GEN_B_FAR = -0.22;
            const GEN_B_NEAR = -0.06;
            const flat = [{y0: 0, y1: h, z: -0.12}];
            if (!parallaxEnabled || h === 0) return flat;

            let min = Infinity, max = -Infinity;
            for (let y = 0; y < h; y++) {
                if (genVelB[y] < min) min = genVelB[y];
                if (genVelB[y] > max) max = genVelB[y];
            }
            if (!(max - min > 0.25)) return flat;

            const LEVELS = 6;
            const level = y => Math.min(LEVELS - 1,
                Math.floor((genVelB[y] - min) / (max - min) * LEVELS));
            const zFor = lv => GEN_B_FAR + (lv / (LEVELS - 1)) * (GEN_B_NEAR - GEN_B_FAR);

            const out = [];
            let start = 0, cur = level(0);
            for (let y = 1; y <= h; y++) {
                const lv = y < h ? level(y) : -1;
                if (lv !== cur) {
                    out.push({y0: start, y1: y, z: zFor(cur)});
                    start = y;
                    cur = lv;
                }
            }
            return out.length > 16 ? flat : out;
        }

        /// Group lines into depth bands by how fast they scroll. Runs of
        /// similar speed become one quad, so the draw count stays small even
        /// when every line has a slightly different scroll value.
        function computeBands(scene, h) {
            const flat = [{y0: 0, y1: h, z: Z_BG_LOW}];
            if (!parallaxEnabled || h === 0) return flat;

            let min = Infinity, max = -Infinity;
            for (let y = 0; y < h; y++) {
                if (lineVelocity[y] < min) min = lineVelocity[y];
                if (lineVelocity[y] > max) max = lineVelocity[y];
            }
            // No meaningful spread means no parallax split to infer.
            if (!(max - min > 0.25)) return flat;

            const LEVELS = 6;
            const level = y => Math.min(LEVELS - 1,
                Math.floor((lineVelocity[y] - min) / (max - min) * LEVELS));
            const zFor = lv => Z_BG_PARALLAX_FAR +
                (lv / (LEVELS - 1)) * (Z_BG_PARALLAX_NEAR - Z_BG_PARALLAX_FAR);

            const out = [];
            let start = 0, cur = level(0);
            for (let y = 1; y <= h; y++) {
                const lv = y < h ? level(y) : -1;
                if (lv !== cur) {
                    out.push({y0: start, y1: y, z: zFor(cur)});
                    start = y;
                    cur = lv;
                }
            }
            // Pathological cases (per-line wobble) would cost a draw call per
            // line, so fall back to a single flat plane instead.
            return out.length > 16 ? flat : out;
        }

        // Depths for the six Genesis compositing layers, back to front in the
        // hardware's priority order. High-priority plane tiles really do
        // cover sprites, so their depth is in front of the low sprite layer.
        const GEN_Z = {bLow: -0.12, aLow: 0.0, sLow: 0.10, bHigh: 0.16, aHigh: 0.22, sHigh: 0.30};

        function drawGenesis(scene, mvp) {
            let calls = 1; // the backdrop already drew
            const h40 = (scene.genFlags & GEN_FLAG_H40) !== 0;
            const shMode = (scene.genFlags & GEN_FLAG_SH) !== 0;

            function bindShMask(u) {
                gl.activeTexture(gl.TEXTURE6);
                gl.bindTexture(gl.TEXTURE_2D, genShMaskTex.tex);
                gl.uniform1i(u.u_shMask, 6);
                gl.uniform1i(u.u_shMode, shMode ? 1 : 0);
            }
            const colMode = (scene.genFlags & GEN_FLAG_COL_VSCROLL) !== 0;
            const slices = extrudeEnabled ? (autoSlices ? slicesForDepth(extrudeDepth) : sliceCount) : 1;
            // The inter-layer gaps are fixed, so cap the slab depth below the
            // smallest gap to keep one layer from poking through the next.
            const ext = extrudeEnabled ? Math.min(extrudeDepth, 0.05) * depthScale : 0;

            function planePass(mapTex, scrollRow, winMode, layer, z, bandY0, bandY1) {
                const y0 = bandY0 === undefined ? 0 : bandY0;
                const y1 = bandY1 === undefined ? scene.pictureHeight : bandY1;
                if (y0 >= y1) return;
                gl.useProgram(genPlaneProgram);
                bindShared(gpU, scene);
                gl.activeTexture(gl.TEXTURE2);
                gl.bindTexture(gl.TEXTURE_2D, mapTex.tex);
                gl.uniform1i(gpU.u_map, 2);
                gl.activeTexture(gl.TEXTURE3);
                gl.bindTexture(gl.TEXTURE_2D, genLineScrollTex.tex);
                gl.uniform1i(gpU.u_lineScroll, 3);
                gl.activeTexture(gl.TEXTURE5);
                gl.bindTexture(gl.TEXTURE_2D, genColVscrollTex.tex);
                gl.uniform1i(gpU.u_colVscroll, 5);
                gl.uniformMatrix4fv(gpU.u_mvp, false, mvp);
                gl.uniform4f(gpU.u_rect, 0, y0, scene.pictureWidth, y1 - y0);
                gl.uniform1f(gpU.u_z, z * depthScale);
                gl.uniform1f(gpU.u_extrude, ext);
                gl.uniform1i(gpU.u_slices, slices);
                gl.uniform1i(gpU.u_scrollRow, scrollRow);
                gl.uniform1i(gpU.u_mapW, winMode === 2 ? scene.genWinW : 64);
                gl.uniform1i(gpU.u_planeW, scene.genPlaneW);
                gl.uniform1i(gpU.u_planeH, scene.genPlaneH);
                gl.uniform1i(gpU.u_colMode, colMode ? 1 : 0);
                gl.uniform1i(gpU.u_h40, h40 ? 1 : 0);
                gl.uniform1i(gpU.u_layer, layer);
                gl.uniform1i(gpU.u_winMode, winMode);
                gl.uniform1ui(gpU.u_reg17, scene.genReg17);
                gl.uniform1ui(gpU.u_reg18, scene.genReg18);
                bindShMask(gpU);
                gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, slices);
                calls++;
            }

            function spritePass(highPass, z) {
                gl.useProgram(genSpriteProgram);
                bindShared(gsU, scene);
                gl.uniformMatrix4fv(gsU.u_mvp, false, mvp);
                gl.uniform1f(gsU.u_z, z * depthScale);
                gl.uniform1f(gsU.u_extrude, ext);
                gl.uniform1i(gsU.u_slices, slices);
                bindShMask(gsU);
                gl.uniform1i(gsU.u_highSprite, highPass ? 1 : 0);
                for (let i = 0; i < scene.genSpriteCount; i++) {
                    const sp = readGenSprite(scene, i);
                    if (((sp.flags & 4) !== 0) !== highPass) continue;
                    const w = sp.hSize * 8;
                    const h = sp.vSize * 8;
                    if (sp.x + w <= 0 || sp.y + h <= 0 ||
                        sp.x >= scene.pictureWidth || sp.y >= scene.pictureHeight) continue;
                    gl.uniform4f(gsU.u_rect, sp.x, sp.y, w, h);
                    gl.uniform1ui(gsU.u_tile, sp.tileBase);
                    gl.uniform1ui(gsU.u_bank, sp.palette);
                    gl.uniform1i(gsU.u_vSize, sp.vSize);
                    gl.uniform1i(gsU.u_hFlip, (sp.flags & 1) !== 0 ? 1 : 0);
                    gl.uniform1i(gsU.u_vFlip, (sp.flags & 2) !== 0 ? 1 : 0);
                    gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, slices);
                    calls++;
                }
            }

            // Plane B low priority, split into the depth bands its own
            // per-line scroll implies. The band rect only limits the quad's
            // rows; the scroll lookup stays per line, so this is a depth
            // grouping, never a rendering approximation.
            for (const band of genBands.length ? genBands : [{y0: 0, y1: scene.pictureHeight, z: GEN_Z.bLow}]) {
                planePass(genPlaneBTex, 1, 0, 0, band.z, band.y0, Math.min(band.y1, scene.pictureHeight));
            }
            planePass(genPlaneATex, 0, 1, 0, GEN_Z.aLow);
            planePass(genWindowTex, 0, 2, 0, GEN_Z.aLow);
            spritePass(false, GEN_Z.sLow);
            planePass(genPlaneBTex, 1, 0, 1, GEN_Z.bHigh);
            planePass(genPlaneATex, 0, 1, 1, GEN_Z.aHigh);
            planePass(genWindowTex, 0, 2, 1, GEN_Z.aHigh);
            spritePass(true, GEN_Z.sHigh);

            stats.drawCalls = calls;
            stats.slices = slices;
            stats.bands = genBands.length;
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
            gl.activeTexture(gl.TEXTURE4);
            gl.bindTexture(gl.TEXTURE_2D, heightsTex.tex);
            gl.uniform1i(u.u_heights, 4);
        }

        /// Draw the diorama. `mvp` already includes the projection, the view,
        /// and any model transform placing the picture in the world.
        function draw(mvp, hudMvp) {
            const scene = current;
            if (!scene || !scene.contentValid) return;
            const t0 = performance.now();
            let calls = 0;

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
            gl.uniform1f(soU.u_extrude, 0);
            gl.uniform1i(soU.u_slices, 1);
            gl.uniform4f(soU.u_color,
                ((scene.backdrop >> 16) & 0xFF) / 255,
                ((scene.backdrop >> 8) & 0xFF) / 255,
                (scene.backdrop & 0xFF) / 255, 1.0);
            // Program uniforms persist, so the shadow/highlight state must
            // be set every frame or a previous Genesis game would tint the
            // backdrop of whatever runs next.
            const backdropSh = scene.system === 3 && (scene.genFlags & GEN_FLAG_SH) !== 0;
            gl.uniform1i(soU.u_shMode, backdropSh ? 1 : 0);
            if (backdropSh) {
                gl.activeTexture(gl.TEXTURE6);
                gl.bindTexture(gl.TEXTURE_2D, genShMaskTex.tex);
                gl.uniform1i(soU.u_shMask, 6);
            }
            gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, 1);

            if (!scene.displayEnabled) {
                gl.bindVertexArray(null);
                return;
            }

            if (scene.system === 3) {
                drawGenesis(scene, mvp);
                gl.bindVertexArray(null);
                stats.drawMs = performance.now() - t0;
                return;
            }

            const verticalWrap = scene.rows > 28 ? 256 : 224;

            function bindBackground(layer) {
                gl.useProgram(bgProgram);
                bindShared(bgU, scene);
                gl.activeTexture(gl.TEXTURE2);
                gl.bindTexture(gl.TEXTURE_2D, mapTex.tex);
                gl.uniform1i(bgU.u_map, 2);
                gl.activeTexture(gl.TEXTURE3);
                gl.bindTexture(gl.TEXTURE_2D, lineScrollTex.tex);
                gl.uniform1i(bgU.u_lineScroll, 3);
                gl.uniformMatrix4fv(bgU.u_mvp, false, mvp);
                gl.uniform2f(bgU.u_scroll, scene.scrollX, scene.scrollY);
                gl.uniform1f(bgU.u_rows, scene.rows);
                gl.uniform1f(bgU.u_verticalWrap, verticalWrap);
                gl.uniform1f(bgU.u_hudRows, scene.hudRows);
                gl.uniform1f(bgU.u_hudCols, scene.hudCols);
                gl.uniform1i(bgU.u_layer, layer);
                gl.uniform1i(bgU.u_leftBlank, scene.leftColumnBlanked ? 1 : 0);
            }

            const slices = extrudeEnabled
                ? (autoSlices ? slicesForDepth(extrudeDepth) : sliceCount)
                : 1;
            const bgExtrude = extrudeEnabled ? extrudeDepth * depthScale : 0;
            const spriteExtrude = extrudeEnabled
                ? Math.max(extrudeDepth, Z_EXTRUDE_SPRITE) * depthScale : 0;
            // Slabs now grow toward the viewer, so each layer's base has to
            // clear the tallest slab of the layer beneath it. Fixed depths
            // would let a deep profile push the terrain through the sprites.
            const gap = 0.03 * depthScale;
            const zSprites = Math.max(Z_SPRITES * depthScale, bgExtrude + gap);
            const zBgHigh = Math.max(Z_BG_HIGH * depthScale, zSprites + spriteExtrude + gap);
            const zHud = Math.max(Z_HUD * depthScale, zBgHigh + bgExtrude + gap);

            function drawBand(y0, y1, z, extrude, count) {
                gl.uniform4f(bgU.u_rect, 0, y0, scene.pictureWidth, y1 - y0);
                gl.uniform1f(bgU.u_z, z * depthScale);
                gl.uniform1f(bgU.u_extrude, extrude);
                gl.uniform1i(bgU.u_slices, count);
                gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, count);
                calls++;
            }

            // Low-priority background, split into bands at the depths the
            // game's own parallax implies.
            bindBackground(LAYER_BG_LOW);
            for (const b of bands) drawBand(b.y0, b.y1, b.z, bgExtrude, slices);

            // Sprites, each its own quad so they read as separate objects
            // when the camera moves off axis.
            //
            // Every sprite sits at the same depth, so with GL_LESS the first
            // one drawn keeps the pixel and later ones are rejected. That is
            // exactly the hardware rule, where the lowest-numbered sprite
            // table slot wins, provided slots are drawn in ascending order.
            gl.useProgram(spriteProgram);
            bindShared(spU, scene);
            gl.uniformMatrix4fv(spU.u_mvp, false, mvp);
            gl.uniform1f(spU.u_z, zSprites);
            gl.uniform1f(spU.u_extrude, spriteExtrude);
            gl.uniform1i(spU.u_slices, slices);
            for (let i = 0; i < scene.spriteCount; i++) {
                const sp = readSprite(scene, i);
                if (sp.width === 0 || sp.height === 0) continue;
                gl.uniform4f(spU.u_rect, sp.x, sp.y, sp.width, sp.height);
                gl.uniform1ui(spU.u_tile, sp.tileIndex);
                gl.uniform1i(spU.u_doubled, (sp.flags & 8) !== 0 ? 1 : 0);
                gl.uniform1ui(spU.u_bank, sp.palette);
                gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, slices);
                calls++;
            }

            // Priority tiles are foreground by definition, so they keep a
            // fixed depth in front of the sprites rather than joining a band.
            bindBackground(LAYER_BG_HIGH);
            drawBand(full[1], full[1] + full[3], zBgHigh / depthScale, bgExtrude, slices);

            // The HUD is drawn last either way. As an overlay it also ignores
            // depth, so it can never be buried inside the diorama.
            bindBackground(LAYER_HUD);
            if (hudMode === "overlay" && hudMvp) {
                gl.uniformMatrix4fv(bgU.u_mvp, false, hudMvp);
                gl.disable(gl.DEPTH_TEST);
                drawBand(full[1], full[1] + full[3], 0, 0, 1);
                gl.enable(gl.DEPTH_TEST);
                gl.uniformMatrix4fv(bgU.u_mvp, false, mvp);
            } else {
                drawBand(full[1], full[1] + full[3], zHud / depthScale, 0, 1);
            }

            gl.bindVertexArray(null);
            stats.drawCalls = calls + 1;   // plus the backdrop
            stats.slices = slices;
            stats.bands = bands.length;
            stats.drawMs = performance.now() - t0;
        }

        function dispose() {
            gl.deleteProgram(bgProgram);
            gl.deleteProgram(spriteProgram);
            gl.deleteProgram(solidProgram);
            gl.deleteProgram(genPlaneProgram);
            gl.deleteProgram(genSpriteProgram);
            gl.deleteVertexArray(vao);
            gl.deleteBuffer(vbo);
            gl.deleteTexture(atlasTex.tex);
            gl.deleteTexture(mapTex.tex);
            gl.deleteTexture(paletteTex.tex);
            gl.deleteTexture(lineScrollTex.tex);
            gl.deleteTexture(genPlaneATex.tex);
            gl.deleteTexture(genPlaneBTex.tex);
            gl.deleteTexture(genWindowTex.tex);
            gl.deleteTexture(genLineScrollTex.tex);
            gl.deleteTexture(genColVscrollTex.tex);
            gl.deleteTexture(genShMaskTex.tex);
            gl.deleteTexture(heightsTex.tex);
        }

        return {
            upload: upload,
            draw: draw,
            dispose: dispose,
            setDepthScale: setDepthScale,
            getDepthScale: getDepthScale,
            setParallaxEnabled: (v) => { parallaxEnabled = !!v; },
            setExtrudeEnabled: (v) => { extrudeEnabled = !!v; },
            setHudMode: (m) => { hudMode = (m === "overlay") ? "overlay" : "scene"; },
            setSliceCount: (n) => { sliceCount = Math.max(1, Math.min(32, n | 0)); autoSlices = false; },
            /// Force a full atlas re-upload on the next frame. Needed when a
            /// new ROM loads: its fresh scene buffer only marks tiles dirty
            /// against itself, so tiles that are empty in the new game but
            /// were not in the old one would otherwise stay stale.
            invalidate: () => { atlasUploaded = false; genHavePrev = false; havePrevScroll = false; },
            setExtrudeDepth: (v) => { extrudeDepth = Math.max(0, Math.min(0.6, v)); },
            getStats: () => stats,
            /// Apply a per-game 3D profile. Passing null restores uniform
            /// full-height extrusion, which is the profile-free appearance.
            applyProfile: (profile) => {
                const clamp01 = v => Math.max(0, Math.min(1, v));
                extrudeDepth = profile && typeof profile.extrudeDepth === "number"
                    ? Math.max(0, Math.min(0.6, profile.extrudeDepth))
                    : Z_EXTRUDE_BG;
                autoSlices = true;
                const base = profile && typeof profile.defaultHeight === "number"
                    ? clamp01(profile.defaultHeight) : 1;
                heightsStaging.fill(Math.round(base * 255));
                if (profile && Array.isArray(profile.tiles)) {
                    for (const rule of profile.tiles) {
                        const from = Math.max(0, rule.from | 0);
                        const to = Math.min(MAX_TILES - 1, (rule.to === undefined ? rule.from : rule.to) | 0);
                        const v = Math.round(clamp01(rule.height) * 255);
                        for (let t = from; t <= to; t++) heightsStaging[t] = v;
                    }
                }
                heightsDirty = true;
            },
            getBands: () => bands,
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
        // Orbiting would otherwise swing the status display away from the
        // viewer, so on desktop the HUD is pinned to the screen.
        renderer.setHudMode(options.hudMode || "overlay");
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
            renderer.draw(multiply(proj, view), screenLockedMatrix(w / h));
        }

        /// Maps the picture straight onto the canvas, ignoring the camera,
        /// so the HUD keeps its own square-on orientation. Fits by height and
        /// letterboxes horizontally, preserving the picture's aspect.
        function screenLockedMatrix(canvasAspect) {
            const m = scaleXYZ(2 / canvasAspect, 2, 0);
            m[14] = -0.9;   // pin to the near plane, in front of everything
            return m;
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
            setParallaxEnabled: renderer.setParallaxEnabled,
            setExtrudeEnabled: renderer.setExtrudeEnabled,
            setHudMode: renderer.setHudMode,
            setSliceCount: renderer.setSliceCount,
            getStats: renderer.getStats,
            applyProfile: renderer.applyProfile,
            invalidate: renderer.invalidate,
            setExtrudeDepth: renderer.setExtrudeDepth,
            getBands: renderer.getBands,
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
