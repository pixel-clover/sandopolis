// WebXR theater mode for Sandopolis. Renders the emulator canvas as a textured quad inside an immersive-vr session
// and forwards Quest/WebXR controller input to the emulator. Requires WebGL2 and an immersive-vr capable browser.

(function () {
    "use strict";

    const QUAD_WIDTH = 1.4;
    const QUAD_ASPECT = 4 / 3;
    const QUAD_DISTANCE = -1.8;
    const SCREEN_Y = 1.2;
    const BEZEL_THICKNESS = 0.06;
    const BEZEL_DEPTH = 0.05;       // Half-depth of the bezel cube.
    const BEZEL_OFFSET = 0.015;     // How far the bezel front sits behind the screen plane.
    const STAND_HEIGHT = 0.7;
    const STAND_DEPTH = 0.4;
    const ROOM_HALF_W = 4.0;
    const ROOM_HALF_D = 4.0;
    const ROOM_HEIGHT = 3.0;
    const STICK_THRESHOLD = 0.5;
    const EXIT_HOLD_MS = 1000;

    let leftGripPressedAt = 0;

    let session = null;
    let gl = null;
    let glCanvas = null;
    let refSpace = null;
    let baseLayer = null;
    let program, vao, posLoc, uvLoc, mvpLoc, sampLoc, texture;
    let roomProgram, roomVao, roomVertCount, roomMvpLoc;
    let solidProgram, solidVao, solidMvpLoc, solidColorLoc;
    let sourceCanvas = null;
    let onTick = null;
    let onButton = null;
    let buttonNames = null;
    let active = false;
    let entering = false;
    let prevButtonState = {};
    // Result of the immersive-vr probe: "checking" | "supported" | "unsupported" | "no-api".
    let probeResult = "checking";

    function isVRSupportable() {
        return typeof navigator !== "undefined"
            && "xr" in navigator
            && typeof navigator.xr.isSessionSupported === "function";
    }

    async function probe(buttonEl) {
        if (!isVRSupportable()) {
            probeResult = "no-api";
            buttonEl.style.display = "none";
            return;
        }
        try {
            const supported = await navigator.xr.isSessionSupported("immersive-vr");
            probeResult = supported ? "supported" : "unsupported";
            buttonEl.style.display = supported ? "" : "none";
        } catch (err) {
            probeResult = "unsupported";
            console.warn("[VR] isSessionSupported threw:", err);
            buttonEl.style.display = "none";
        }
    }

    async function enter(buttonEl) {
        if (active || entering) return;
        entering = true;
        let s = null;
        try {
            try {
                s = await navigator.xr.requestSession("immersive-vr", {
                    optionalFeatures: ["local-floor"],
                });
            } catch (err) {
                console.warn("[VR] requestSession failed:", err);
                const status = document.getElementById("status");
                if (status) {
                    const reason = (err && err.message) ? err.message : String(err);
                    const hint = window.isSecureContext ? "" : " (page must be served over HTTPS)";
                    status.textContent = "VR unavailable: " + reason + hint;
                }
                return;
            }

            glCanvas = document.createElement("canvas");
            gl = glCanvas.getContext("webgl2", {xrCompatible: true});
            if (!gl) {
                console.warn("WebXR theater mode requires WebGL2.");
                await s.end();
                s = null;
                return;
            }
            if (gl.makeXRCompatible) {
                try {
                    await gl.makeXRCompatible();
                } catch (_) { /* already compatible */
                }
            }

            baseLayer = new XRWebGLLayer(s, gl);
            s.updateRenderState({baseLayer});
            try {
                refSpace = await s.requestReferenceSpace("local-floor");
            } catch (_) {
                refSpace = await s.requestReferenceSpace("local");
            }

            try {
                setupGL();
            } catch (err) {
                console.warn("[VR] setupGL failed:", err);
                await s.end();
                s = null;
                return;
            }

            session = s;
            s = null;
            active = true;
            prevButtonState = {};
            session.addEventListener("end", () => handleSessionEnd(buttonEl));
            session.requestAnimationFrame(onXRFrame);
            buttonEl.textContent = "Exit VR";
        } finally {
            entering = false;
        }
    }

    function handleSessionEnd(buttonEl) {
        active = false;
        session = null;
        gl = null;
        glCanvas = null;
        baseLayer = null;
        refSpace = null;
        program = null;
        vao = null;
        texture = null;
        roomProgram = null;
        roomVao = null;
        solidProgram = null;
        solidVao = null;
        if (buttonEl) buttonEl.textContent = "Enter VR";
        if (onSessionEndCallback) {
            try {
                onSessionEndCallback();
            } catch (err) {
                console.warn("[VR] onSessionEnd callback threw:", err);
            }
        }
    }

    function setupGL() {
        const vs = `#version 300 es
        in vec2 a_pos;
        in vec2 a_uv;
        out vec2 v_uv;
        uniform mat4 u_mvp;
        void main() {
            v_uv = a_uv;
            gl_Position = u_mvp * vec4(a_pos.x, a_pos.y, 0.0, 1.0);
        }`;
        // CRT-feel screen shader. Layers (in order):
        //   1. Subtle barrel curvature, with the area outside the curved
        //      rectangle clipped to black (CRT tube edge).
        //   2. Sharp-bilinear sample of the emulator framebuffer.
        //   3. Scanlines at the source-pixel rate.
        //   4. Vignette fade toward the corners.
        //   5. Warm phosphor tint.
        const fs = `#version 300 es
        precision mediump float;
        in vec2 v_uv;
        out vec4 outColor;
        uniform sampler2D u_tex;
        const float CURVE = 0.08;
        const float SCANLINE_DEPTH = 0.25;
        const float VIGNETTE = 0.45;
        void main() {
            vec2 cuv = v_uv * 2.0 - 1.0;
            cuv += cuv * (cuv.yx * cuv.yx) * CURVE;
            vec2 warped = (cuv + 1.0) * 0.5;
            if (warped.x < 0.0 || warped.x > 1.0 || warped.y < 0.0 || warped.y > 1.0) {
                outColor = vec4(0.0, 0.0, 0.0, 1.0);
                return;
            }
            vec2 texSize = vec2(textureSize(u_tex, 0));
            vec2 texelUV = warped * texSize;
            vec2 floored = floor(texelUV) + 0.5;
            vec2 frac = texelUV - floored;
            vec2 dx = fwidth(texelUV);
            vec2 sharp = floored + clamp(frac / dx + 0.5, 0.0, 1.0) - 0.5;
            vec3 col = texture(u_tex, sharp / texSize).rgb;

            float scan = 0.5 + 0.5 * cos(texelUV.y * 6.28318);
            col *= 1.0 - SCANLINE_DEPTH * (1.0 - scan);

            vec2 vd = warped - 0.5;
            col *= 1.0 - dot(vd, vd) * VIGNETTE;

            col *= vec3(1.04, 0.99, 0.95);

            outColor = vec4(col, 1.0);
        }`;
        program = compileProgram(vs, fs);
        posLoc = gl.getAttribLocation(program, "a_pos");
        uvLoc = gl.getAttribLocation(program, "a_uv");
        mvpLoc = gl.getUniformLocation(program, "u_mvp");
        sampLoc = gl.getUniformLocation(program, "u_tex");

        // Unit quad in local space; the model matrix scales it per frame so
        // the quad mirrors the source canvas's aspect (and aspect-mode setting).
        const verts = new Float32Array([
            -1, -1, 0, 1,
            1, -1, 1, 1,
            1, 1, 1, 0,
            -1, -1, 0, 1,
            1, 1, 1, 0,
            -1, 1, 0, 0,
        ]);
        vao = gl.createVertexArray();
        gl.bindVertexArray(vao);
        const vbo = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
        gl.bufferData(gl.ARRAY_BUFFER, verts, gl.STATIC_DRAW);
        gl.enableVertexAttribArray(posLoc);
        gl.vertexAttribPointer(posLoc, 2, gl.FLOAT, false, 16, 0);
        gl.enableVertexAttribArray(uvLoc);
        gl.vertexAttribPointer(uvLoc, 2, gl.FLOAT, false, 16, 8);
        gl.bindVertexArray(null);

        texture = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, texture);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

        setupRoom();
        setupSolid();
    }

    function setupSolid() {
        const vs = `#version 300 es
        in vec3 a_pos;
        uniform mat4 u_mvp;
        void main() { gl_Position = u_mvp * vec4(a_pos, 1.0); }`;
        const fs = `#version 300 es
        precision mediump float;
        uniform vec3 u_color;
        out vec4 outColor;
        void main() { outColor = vec4(u_color, 1.0); }`;
        solidProgram = compileProgram(vs, fs);
        solidMvpLoc = gl.getUniformLocation(solidProgram, "u_mvp");
        solidColorLoc = gl.getUniformLocation(solidProgram, "u_color");
        const pos = gl.getAttribLocation(solidProgram, "a_pos");

        // Unit cube: 24 unique vertices (4 per face, 6 faces) drawn as 36 indices via repeated triangles.
        const v = [
            // x=-1
            [-1, -1, -1], [-1, -1, 1], [-1, 1, 1], [-1, -1, -1], [-1, 1, 1], [-1, 1, -1],
            // x=+1
            [1, -1, 1], [1, -1, -1], [1, 1, -1], [1, -1, 1], [1, 1, -1], [1, 1, 1],
            // y=-1
            [-1, -1, -1], [1, -1, -1], [1, -1, 1], [-1, -1, -1], [1, -1, 1], [-1, -1, 1],
            // y=+1
            [-1, 1, 1], [1, 1, 1], [1, 1, -1], [-1, 1, 1], [1, 1, -1], [-1, 1, -1],
            // z=-1
            [1, -1, -1], [-1, -1, -1], [-1, 1, -1], [1, -1, -1], [-1, 1, -1], [1, 1, -1],
            // z=+1
            [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, -1, 1], [1, 1, 1], [-1, 1, 1],
        ];
        const arr = new Float32Array(v.flat());
        solidVao = gl.createVertexArray();
        gl.bindVertexArray(solidVao);
        const vbo = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
        gl.bufferData(gl.ARRAY_BUFFER, arr, gl.STATIC_DRAW);
        gl.enableVertexAttribArray(pos);
        gl.vertexAttribPointer(pos, 3, gl.FLOAT, false, 12, 0);
        gl.bindVertexArray(null);
    }

    function scaleXYZ(sx, sy, sz) {
        return new Float32Array([
            sx, 0, 0, 0,
            0, sy, 0, 0,
            0, 0, sz, 0,
            0, 0, 0, 1,
        ]);
    }

    function setupRoom() {
        const vs = `#version 300 es
        in vec3 a_pos;
        in vec3 a_color;
        flat out vec3 v_color;
        out vec3 v_world;
        uniform mat4 u_mvp;
        void main() {
            v_color = a_color;
            v_world = a_pos;
            gl_Position = u_mvp * vec4(a_pos, 1.0);
        }`;
        const fs = `#version 300 es
        precision mediump float;
        flat in vec3 v_color;
        in vec3 v_world;
        out vec4 outColor;
        void main() {
            // 1m grid lines: dark seams between tiles (floor uses xz, walls use the relevant pair).
            vec2 g;
            if (abs(v_world.y - 0.0) < 0.001 || abs(v_world.y - 3.0) < 0.001) {
                g = abs(fract(v_world.xz) - 0.5);
            } else if (abs(abs(v_world.x) - 4.0) < 0.001) {
                g = abs(fract(v_world.zy) - 0.5);
            } else {
                g = abs(fract(v_world.xy) - 0.5);
            }
            float grid = smoothstep(0.48, 0.5, max(g.x, g.y)) * 0.35;

            // Soft "screen-as-light-source" falloff so the wall behind the
            // screen is brighter than the corners, evoking a TV-lit room.
            vec3 lightPos = vec3(0.0, 1.4, -2.5);
            float d = length(v_world - lightPos);
            float fall = clamp(2.0 / (1.0 + d * d * 0.3), 0.0, 1.0);

            vec3 c = v_color * (0.35 + 0.65 * fall) * (1.0 - grid);
            outColor = vec4(c, 1.0);
        }`;
        roomProgram = compileProgram(vs, fs);
        roomMvpLoc = gl.getUniformLocation(roomProgram, "u_mvp");
        const rPos = gl.getAttribLocation(roomProgram, "a_pos");
        const rCol = gl.getAttribLocation(roomProgram, "a_color");

        const hx = ROOM_HALF_W, hz = ROOM_HALF_D, h = ROOM_HEIGHT;
        const FLOOR = [0.13, 0.10, 0.08];
        const WALL = [0.10, 0.12, 0.18];
        const CEIL = [0.05, 0.05, 0.07];

        const data = [];

        function quad(p0, p1, p2, p3, c) {
            data.push(...p0, ...c, ...p1, ...c, ...p2, ...c,
                ...p0, ...c, ...p2, ...c, ...p3, ...c);
        }

        // Floor
        quad([-hx, 0, -hz], [hx, 0, -hz], [hx, 0, hz], [-hx, 0, hz], FLOOR);
        // Ceiling
        quad([-hx, h, -hz], [-hx, h, hz], [hx, h, hz], [hx, h, -hz], CEIL);
        // Back wall (-z, behind screen)
        quad([-hx, 0, -hz], [-hx, h, -hz], [hx, h, -hz], [hx, 0, -hz], WALL);
        // Front wall (+z, behind user)
        quad([hx, 0, hz], [hx, h, hz], [-hx, h, hz], [-hx, 0, hz], WALL);
        // Left wall (-x)
        quad([-hx, 0, hz], [-hx, h, hz], [-hx, h, -hz], [-hx, 0, -hz], WALL);
        // Right wall (+x)
        quad([hx, 0, -hz], [hx, h, -hz], [hx, h, hz], [hx, 0, hz], WALL);

        roomVertCount = data.length / 6;
        roomVao = gl.createVertexArray();
        gl.bindVertexArray(roomVao);
        const vbo = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(data), gl.STATIC_DRAW);
        gl.enableVertexAttribArray(rPos);
        gl.vertexAttribPointer(rPos, 3, gl.FLOAT, false, 24, 0);
        gl.enableVertexAttribArray(rCol);
        gl.vertexAttribPointer(rCol, 3, gl.FLOAT, false, 24, 12);
        gl.bindVertexArray(null);
    }

    function compileProgram(vsSrc, fsSrc) {
        function compile(type, src) {
            const sh = gl.createShader(type);
            gl.shaderSource(sh, src);
            gl.compileShader(sh);
            if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
                throw new Error("Shader compile error: " + gl.getShaderInfoLog(sh));
            }
            return sh;
        }

        const p = gl.createProgram();
        gl.attachShader(p, compile(gl.VERTEX_SHADER, vsSrc));
        gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fsSrc));
        gl.linkProgram(p);
        if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
            throw new Error("Program link error: " + gl.getProgramInfoLog(p));
        }
        return p;
    }

    function uploadCanvasTexture() {
        if (!sourceCanvas || sourceCanvas.width === 0 || sourceCanvas.height === 0) return;
        gl.bindTexture(gl.TEXTURE_2D, texture);
        // UVs already flip the canvas: bottom-left vertex maps to v=1.
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, sourceCanvas);
    }

    // Column-major 4x4 multiply: out = a * b. Element (row, col) is m[col*4 + row].
    function mulMat4(a, b) {
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

    function translate(x, y, z) {
        return new Float32Array([
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            x, y, z, 1,
        ]);
    }

    function quadHalfDims() {
        const w = (sourceCanvas && sourceCanvas.width) || 320;
        const h = (sourceCanvas && sourceCanvas.height) || 224;
        const mode = (getAspectMode && getAspectMode()) || "fit";
        // "fit" forces the canonical 4:3 TV aspect; the other modes
        // (stretch, native) use the canvas's pixel aspect directly.
        const aspect = (mode === "fit") ? QUAD_ASPECT : (w / h);
        const halfW = QUAD_WIDTH / 2;
        const halfH = halfW / aspect;
        return {halfW, halfH};
    }

    function pollControllers(time) {
        if (!session || !onButton || !buttonNames) return false;
        const PLAYER = 0;
        const press = (name, down) => {
            const wasDown = prevButtonState[name] || false;
            if (wasDown === down) return;
            prevButtonState[name] = down;
            onButton(PLAYER, buttonNames[name], down);
        };
        let lx = 0, ly = 0, anyController = false, leftGripHeld = false;
        for (const src of session.inputSources) {
            const gp = src.gamepad;
            if (!gp) continue;
            anyController = true;
            const b = (i) => i < gp.buttons.length && gp.buttons[i].pressed;
            // WebXR standard mapping for hand controllers:
            //   buttons[0] = trigger, [1] = grip, [3] = thumbstick press,
            //   [4] = primary face (A/X), [5] = secondary face (B/Y).
            //   axes[2,3] = thumbstick (axes[0,1] = trackpad on devices that have one).
            if (src.handedness === "left") {
                if (gp.axes.length >= 4) {
                    lx = gp.axes[2];
                    ly = gp.axes[3];
                } else if (gp.axes.length >= 2) {
                    lx = gp.axes[0];
                    ly = gp.axes[1];
                }
                press("X", b(4));
                press("Y", b(5));
                press("Z", b(0));
                leftGripHeld = b(1);
            } else if (src.handedness === "right") {
                press("A", b(4));
                press("B", b(5));
                press("C", b(0));
                press("Start", b(3) || b(1));
            }
        }
        if (anyController) {
            press("Up", ly < -STICK_THRESHOLD);
            press("Down", ly > STICK_THRESHOLD);
            press("Left", lx < -STICK_THRESHOLD);
            press("Right", lx > STICK_THRESHOLD);
        }

        // Exit gesture: hold left grip for 1 second to end the session.
        if (leftGripHeld) {
            if (leftGripPressedAt === 0) leftGripPressedAt = time;
            else if (time - leftGripPressedAt >= EXIT_HOLD_MS) {
                leftGripPressedAt = 0;
                return true;
            }
        } else {
            leftGripPressedAt = 0;
        }
        return false;
    }

    function onXRFrame(time, frame) {
        if (!active || !session) return;
        session.requestAnimationFrame(onXRFrame);

        const pose = frame.getViewerPose(refSpace);
        if (!pose) return;

        if (onTick) onTick();
        if (pollControllers(time)) {
            session.end();
            return;
        }
        uploadCanvasTexture();

        gl.bindFramebuffer(gl.FRAMEBUFFER, baseLayer.framebuffer);
        gl.enable(gl.DEPTH_TEST);
        gl.clearColor(0.02, 0.02, 0.04, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        const dims = quadHalfDims();
        const screenScale = scaleXYZ(dims.halfW, dims.halfH, 1);
        const screenModel = mulMat4(translate(0, SCREEN_Y, QUAD_DISTANCE), screenScale);

        // Bezel: dark frame behind the screen. Front face sits BEZEL_OFFSET
        // metres behind the screen plane to avoid z-fighting with the quad.
        const bezelHalfW = dims.halfW + BEZEL_THICKNESS;
        const bezelHalfH = dims.halfH + BEZEL_THICKNESS;
        const bezelCenterZ = QUAD_DISTANCE - BEZEL_OFFSET - BEZEL_DEPTH;
        const bezelModel = mulMat4(
            translate(0, SCREEN_Y, bezelCenterZ),
            scaleXYZ(bezelHalfW, bezelHalfH, BEZEL_DEPTH)
        );

        // TV stand: a media console centered slightly behind the screen plane.
        // STAND_HEIGHT is set so the stand's top sits just under the screen.
        const standModel = mulMat4(
            translate(0, STAND_HEIGHT / 2, QUAD_DISTANCE - 0.1),
            scaleXYZ(bezelHalfW * 0.9, STAND_HEIGHT / 2, STAND_DEPTH / 2)
        );

        for (const view of pose.views) {
            const vp = baseLayer.getViewport(view);
            gl.viewport(vp.x, vp.y, vp.width, vp.height);
            const viewProj = mulMat4(view.projectionMatrix, view.transform.inverse.matrix);

            // Room
            gl.useProgram(roomProgram);
            gl.bindVertexArray(roomVao);
            gl.uniformMatrix4fv(roomMvpLoc, false, viewProj);
            gl.drawArrays(gl.TRIANGLES, 0, roomVertCount);

            // Bezel + stand share the solid program.
            gl.useProgram(solidProgram);
            gl.bindVertexArray(solidVao);
            gl.uniform3f(solidColorLoc, 0.04, 0.04, 0.05);
            gl.uniformMatrix4fv(solidMvpLoc, false, mulMat4(viewProj, bezelModel));
            gl.drawArrays(gl.TRIANGLES, 0, 36);
            gl.uniform3f(solidColorLoc, 0.07, 0.06, 0.05);
            gl.uniformMatrix4fv(solidMvpLoc, false, mulMat4(viewProj, standModel));
            gl.drawArrays(gl.TRIANGLES, 0, 36);

            // Screen quad
            gl.useProgram(program);
            gl.bindVertexArray(vao);
            gl.activeTexture(gl.TEXTURE0);
            gl.bindTexture(gl.TEXTURE_2D, texture);
            gl.uniform1i(sampLoc, 0);
            const mv = mulMat4(view.transform.inverse.matrix, screenModel);
            const mvp = mulMat4(view.projectionMatrix, mv);
            gl.uniformMatrix4fv(mvpLoc, false, mvp);
            gl.drawArrays(gl.TRIANGLES, 0, 6);
        }
    }

    let buttonEl = null;
    let isRomLoaded = null;
    let getAspectMode = null;
    let onSessionEndCallback = null;

    function attachButton() {
        if (buttonEl) return buttonEl;
        buttonEl = document.getElementById("btn-vr");
        if (!buttonEl) return null;
        buttonEl.addEventListener("click", () => {
            if (entering) return;
            if (active && session) session.end();
            else if (isRomLoaded && isRomLoaded()) enter(buttonEl);
            else showToastIfPossible("Load a ROM first");
        });
        return buttonEl;
    }

    function showToastIfPossible(msg) {
        const toast = document.getElementById("toast");
        if (!toast) return;
        toast.textContent = msg;
        toast.classList.add("visible");
        clearTimeout(toast._vrTimer);
        toast._vrTimer = setTimeout(() => toast.classList.remove("visible"), 2000);
    }

    function autoProbe() {
        const btn = attachButton();
        if (btn) probe(btn);
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", autoProbe);
    } else {
        autoProbe();
    }

    window.SandopolisVR = {
        init(opts) {
            sourceCanvas = opts.canvas;
            onTick = opts.onTick;
            onButton = opts.onButton;
            buttonNames = opts.buttons;
            isRomLoaded = opts.isRomLoaded || null;
            getAspectMode = opts.getAspectMode || null;
            onSessionEndCallback = opts.onSessionEnd || null;
            attachButton();
        },
        get active() {
            return active;
        },
        get status() {
            return probeResult;
        },
    };
})();
