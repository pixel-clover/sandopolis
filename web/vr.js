// WebXR theater mode for Sandopolis. Renders the emulator canvas as a textured quad inside an immersive-vr session
// and forwards Quest/WebXR controller input to the emulator. Requires WebGL2 and an immersive-vr capable browser.

(function () {
    "use strict";

    const QUAD_WIDTH = 3.2;
    const QUAD_ASPECT = 4 / 3;
    const QUAD_DISTANCE = -2.5;
    const STICK_THRESHOLD = 0.5;

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
    let prevButtonState = {};

    function isVRSupportable() {
        return typeof navigator !== "undefined"
            && "xr" in navigator
            && typeof navigator.xr.isSessionSupported === "function";
    }

    function reportDiag(msg) {
        let el = document.getElementById("vr-diag");
        if (!el) {
            el = document.createElement("div");
            el.id = "vr-diag";
            el.style.cssText = "margin:8px auto;padding:6px 10px;max-width:680px;"
                + "font-family:monospace;font-size:12px;text-align:center;"
                + "background:rgba(255,200,40,0.12);border:1px solid #C8A830;"
                + "color:#C8A830;border-radius:4px;";
            const sb = document.querySelector(".status-bar");
            if (sb && sb.parentNode) sb.parentNode.insertBefore(el, sb);
            else document.body.appendChild(el);
        }
        el.textContent = "[VR] " + msg;
        console.info("[VR]", msg);
    }

    async function probe(buttonEl) {
        const secure = typeof window !== "undefined" && window.isSecureContext;
        // Always reveal the button so the user sees the feature exists.
        buttonEl.style.display = "";
        if (!isVRSupportable()) {
            buttonEl.disabled = true;
            buttonEl.textContent = "VR n/a";
            reportDiag("navigator.xr missing. Origin=" + location.origin
                + " secureContext=" + secure
                + (secure ? "" : ". WebXR requires HTTPS (or localhost)."));
            return;
        }
        try {
            const supported = await navigator.xr.isSessionSupported("immersive-vr");
            if (supported) {
                reportDiag("immersive-vr supported. Click 'Enter VR' to start.");
            } else {
                buttonEl.disabled = true;
                reportDiag("immersive-vr NOT supported. secureContext=" + secure
                    + (secure ? ". Is a headset connected?"
                              : ". Serve the page over HTTPS (try ngrok or cloudflared)."));
            }
        } catch (err) {
            reportDiag("isSessionSupported threw: " + (err && err.message ? err.message : err));
        }
    }

    async function enter(buttonEl) {
        if (active) return;
        let s;
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
        gl = glCanvas.getContext("webgl2", { xrCompatible: true });
        if (!gl) {
            console.warn("WebXR theater mode requires WebGL2.");
            await s.end();
            return;
        }
        if (gl.makeXRCompatible) {
            try { await gl.makeXRCompatible(); } catch (_) { /* already compatible */ }
        }

        baseLayer = new XRWebGLLayer(s, gl);
        s.updateRenderState({ baseLayer });
        try {
            refSpace = await s.requestReferenceSpace("local-floor");
        } catch (_) {
            refSpace = await s.requestReferenceSpace("local");
        }

        setupGL();
        session = s;
        active = true;
        prevButtonState = {};
        session.addEventListener("end", () => handleSessionEnd(buttonEl));
        session.requestAnimationFrame(onXRFrame);
        buttonEl.textContent = "Exit VR";
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

        const halfW = QUAD_WIDTH / 2;
        const halfH = QUAD_WIDTH / QUAD_ASPECT / 2;
        const verts = new Float32Array([
            -halfW, -halfH, 0, 1,
             halfW, -halfH, 1, 1,
             halfW,  halfH, 1, 0,
            -halfW, -halfH, 0, 1,
             halfW,  halfH, 1, 0,
            -halfW,  halfH, 0, 0,
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
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
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

    function pollControllers() {
        if (!session || !onButton || !buttonNames) return;
        const PLAYER = 0;
        const press = (name, down) => {
            const wasDown = prevButtonState[name] || false;
            if (wasDown === down) return;
            prevButtonState[name] = down;
            onButton(PLAYER, buttonNames[name], down);
        };
        let lx = 0, ly = 0, anyController = false;
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
                if (gp.axes.length >= 4) { lx = gp.axes[2]; ly = gp.axes[3]; }
                else if (gp.axes.length >= 2) { lx = gp.axes[0]; ly = gp.axes[1]; }
                press("X", b(4));
                press("Y", b(5));
                press("Z", b(0));
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
    }

    function onXRFrame(_time, frame) {
        if (!active || !session) return;
        session.requestAnimationFrame(onXRFrame);

        const pose = frame.getViewerPose(refSpace);
        if (!pose) return;

        if (onTick) onTick();
        pollControllers();
        uploadCanvasTexture();

        gl.bindFramebuffer(gl.FRAMEBUFFER, baseLayer.framebuffer);
        gl.clearColor(0.02, 0.02, 0.04, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        gl.useProgram(program);
        gl.bindVertexArray(vao);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, texture);
        gl.uniform1i(sampLoc, 0);

        const model = translateZ(QUAD_DISTANCE);
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

    function attachButton() {
        if (buttonEl) return buttonEl;
        buttonEl = document.getElementById("btn-vr");
        if (!buttonEl) return null;
        buttonEl.addEventListener("click", () => {
            if (active && session) session.end();
            else if (sourceCanvas) enter(buttonEl);
            else reportDiag("Load a ROM first, then click Enter VR.");
        });
        return buttonEl;
    }

    function autoProbe() {
        const btn = attachButton();
        if (btn) probe(btn);
        else reportDiag("Could not find Enter VR button (#btn-vr) in the page.");
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
            attachButton();
        },
        get active() { return active; },
    };
})();
