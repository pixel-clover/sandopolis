// WebXR theater mode for Sandopolis. Renders the emulator canvas as a textured quad inside an immersive-vr session
// and forwards Quest/WebXR controller input to the emulator. Requires WebGL2 and an immersive-vr capable browser.

(function () {
    "use strict";

    const QUAD_WIDTH = 3.2;
    const QUAD_ASPECT = 4 / 3;
    const QUAD_DISTANCE = -2.5;
    const STICK_THRESHOLD = 0.5;
    const EXIT_HOLD_MS = 1000;

    let leftGripPressedAt = 0;

    let session = null;
    let gl = null;
    let glCanvas = null;
    let refSpace = null;
    let baseLayer = null;
    let program, vao, posLoc, uvLoc, mvpLoc, sampLoc, texture;
    let sourceCanvas = null;
    let onTick = null;
    let onButton = null;
    let buttonNames = null;
    let active = false;
    let entering = false;
    let prevButtonState = {};

    function isVRSupportable() {
        return typeof navigator !== "undefined"
            && "xr" in navigator
            && typeof navigator.xr.isSessionSupported === "function";
    }

    async function probe(buttonEl) {
        if (!isVRSupportable()) {
            // Hide the button: WebXR isn't reachable on this browser.
            buttonEl.style.display = "none";
            return;
        }
        try {
            const supported = await navigator.xr.isSessionSupported("immersive-vr");
            if (supported) {
                buttonEl.style.display = "";
            } else {
                buttonEl.style.display = "none";
            }
        } catch (err) {
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
        if (buttonEl) buttonEl.textContent = "Enter VR";
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
        const fs = `#version 300 es
        precision mediump float;
        in vec2 v_uv;
        out vec4 outColor;
        uniform sampler2D u_tex;
        void main() {
            outColor = texture(u_tex, v_uv);
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
             1,  1, 1, 0,
            -1, -1, 0, 1,
             1,  1, 1, 0,
            -1,  1, 0, 0,
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
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
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

    function translateZ(z) {
        return new Float32Array([
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, z, 1,
        ]);
    }

    function quadScaleMatrix() {
        const w = (sourceCanvas && sourceCanvas.width) || 320;
        const h = (sourceCanvas && sourceCanvas.height) || 224;
        const mode = (getAspectMode && getAspectMode()) || "fit";
        // "fit" forces the canonical 4:3 TV aspect; the other modes
        // (stretch, native) use the canvas's pixel aspect directly.
        const aspect = (mode === "fit") ? QUAD_ASPECT : (w / h);
        const halfW = QUAD_WIDTH / 2;
        const halfH = halfW / aspect;
        return new Float32Array([
            halfW, 0, 0, 0,
            0, halfH, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]);
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
        gl.clearColor(0.02, 0.02, 0.04, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        gl.useProgram(program);
        gl.bindVertexArray(vao);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, texture);
        gl.uniform1i(sampLoc, 0);

        const model = mulMat4(translateZ(QUAD_DISTANCE), quadScaleMatrix());
        for (const view of pose.views) {
            const vp = baseLayer.getViewport(view);
            gl.viewport(vp.x, vp.y, vp.width, vp.height);
            const mv = mulMat4(view.transform.inverse.matrix, model);
            const mvp = mulMat4(view.projectionMatrix, mv);
            gl.uniformMatrix4fv(mvpLoc, false, mvp);
            gl.drawArrays(gl.TRIANGLES, 0, 6);
        }
    }

    let buttonEl = null;
    let isRomLoaded = null;
    let getAspectMode = null;

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
            attachButton();
        },
        get active() {
            return active;
        },
    };
})();
