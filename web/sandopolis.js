"use strict";

let wasm = null;
let machine = null;
let running = false;
let rafId = null;
let canvas, ctx, imageData;
let BUTTONS = {};

const KEY_MAP = {
    ArrowUp:    "Up",
    ArrowDown:  "Down",
    ArrowLeft:  "Left",
    ArrowRight: "Right",
    z:          "A",
    x:          "B",
    c:          "C",
    Enter:      "Start",
    a:          "X",
    s:          "Y",
    d:          "Z",
};

async function init() {
    canvas = document.getElementById("screen");
    ctx = canvas.getContext("2d");
    ctx.imageSmoothingEnabled = false;

    const wasiStubs = {
        fd_write: () => 0,
        fd_read: () => 0,
        fd_close: () => 0,
        fd_seek: () => 0,
        fd_fdstat_get: () => 0,
        fd_prestat_get: () => -1,
        fd_prestat_dir_name: () => -1,
        environ_get: () => 0,
        environ_sizes_get: (count_ptr, size_ptr) => {
            const view = new DataView(wasm.instance.exports.memory.buffer);
            view.setUint32(count_ptr, 0, true);
            view.setUint32(size_ptr, 0, true);
            return 0;
        },
        args_get: () => 0,
        args_sizes_get: (count_ptr, size_ptr) => {
            const view = new DataView(wasm.instance.exports.memory.buffer);
            view.setUint32(count_ptr, 0, true);
            view.setUint32(size_ptr, 0, true);
            return 0;
        },
        clock_time_get: () => 0,
        proc_exit: () => {},
        random_get: (buf, len) => {
            const bytes = new Uint8Array(wasm.instance.exports.memory.buffer, buf, len);
            crypto.getRandomValues(bytes);
            return 0;
        },
    };

    const response = await fetch("sandopolis.wasm");
    const bytes = await response.arrayBuffer();
    wasm = await WebAssembly.instantiate(bytes, {
        wasi_snapshot_preview1: wasiStubs,
    });

    // Cache button constants from WASM
    const e = wasm.instance.exports;
    BUTTONS = {
        Up:    e.sandopolis_button_up(),
        Down:  e.sandopolis_button_down(),
        Left:  e.sandopolis_button_left(),
        Right: e.sandopolis_button_right(),
        A:     e.sandopolis_button_a(),
        B:     e.sandopolis_button_b(),
        C:     e.sandopolis_button_c(),
        Start: e.sandopolis_button_start(),
        X:     e.sandopolis_button_x(),
        Y:     e.sandopolis_button_y(),
        Z:     e.sandopolis_button_z(),
    };

    document.getElementById("rom-input").addEventListener("change", onFileSelected);
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("keyup", onKeyUp);

    // Drag and drop
    const dropZone = document.getElementById("drop-zone");
    dropZone.addEventListener("dragover", (e) => { e.preventDefault(); dropZone.classList.add("drag-over"); });
    dropZone.addEventListener("dragleave", () => dropZone.classList.remove("drag-over"));
    dropZone.addEventListener("drop", (e) => {
        e.preventDefault();
        dropZone.classList.remove("drag-over");
        if (e.dataTransfer.files.length > 0) loadRom(e.dataTransfer.files[0]);
    });

    document.getElementById("status").textContent = "Ready. Load a ROM to start.";
}

function onFileSelected(e) {
    if (e.target.files.length > 0) loadRom(e.target.files[0]);
}

async function loadRom(file) {
    const e = wasm.instance.exports;

    // Destroy previous instance
    if (machine) {
        running = false;
        if (rafId) cancelAnimationFrame(rafId);
        e.sandopolis_destroy(machine);
        machine = null;
    }

    const buffer = await file.arrayBuffer();
    const romBytes = new Uint8Array(buffer);

    // Allocate WASM memory and copy ROM data
    const romPtr = e.sandopolis_alloc(romBytes.length);
    if (!romPtr) {
        document.getElementById("status").textContent = "Failed to allocate memory for ROM.";
        return;
    }
    const wasmMem = new Uint8Array(e.memory.buffer);
    wasmMem.set(romBytes, romPtr);

    // Create emulator
    machine = e.sandopolis_create(romPtr, romBytes.length);
    e.sandopolis_free(romPtr, romBytes.length);

    if (!machine) {
        document.getElementById("status").textContent = "Failed to initialize emulator.";
        return;
    }

    const isPal = e.sandopolis_is_pal(machine);
    document.getElementById("status").textContent =
        `Playing: ${file.name} (${isPal ? "PAL 50Hz" : "NTSC 60Hz"})`;

    // Start render loop
    running = true;
    const targetFps = isPal ? 50 : 60;
    const frameInterval = 1000 / targetFps;
    let lastTime = performance.now();

    function frame(now) {
        if (!running) return;
        rafId = requestAnimationFrame(frame);

        const delta = now - lastTime;
        if (delta < frameInterval * 0.8) return; // Simple frame pacing
        lastTime = now;

        e.sandopolis_run_frame(machine);

        const width = e.sandopolis_screen_width(machine);
        const height = e.sandopolis_screen_height(machine);
        const fbPtr = e.sandopolis_framebuffer_ptr(machine);
        const fbLen = e.sandopolis_framebuffer_len(machine);

        // Resize canvas if needed
        if (canvas.width !== width || canvas.height !== height) {
            canvas.width = width;
            canvas.height = height;
            imageData = ctx.createImageData(width, height);
        }
        if (!imageData) {
            imageData = ctx.createImageData(width, height);
        }

        // Copy ARGB framebuffer to RGBA ImageData
        const fb = new Uint32Array(e.memory.buffer, fbPtr, fbLen);
        const pixels = imageData.data;
        const count = Math.min(fbLen, width * height);
        for (let i = 0; i < count; i++) {
            const argb = fb[i];
            const off = i * 4;
            pixels[off]     = (argb >> 16) & 0xFF; // R
            pixels[off + 1] = (argb >> 8)  & 0xFF; // G
            pixels[off + 2] =  argb        & 0xFF; // B
            pixels[off + 3] = 0xFF;                 // A
        }
        ctx.putImageData(imageData, 0, 0);
    }

    rafId = requestAnimationFrame(frame);
}

function onKeyDown(e) {
    if (!machine) return;
    const btn = KEY_MAP[e.key];
    if (btn && BUTTONS[btn] !== undefined) {
        e.preventDefault();
        wasm.instance.exports.sandopolis_set_button(machine, 0, BUTTONS[btn], true);
    }
}

function onKeyUp(e) {
    if (!machine) return;
    const btn = KEY_MAP[e.key];
    if (btn && BUTTONS[btn] !== undefined) {
        e.preventDefault();
        wasm.instance.exports.sandopolis_set_button(machine, 0, BUTTONS[btn], false);
    }
}

init().catch(err => {
    console.error("Sandopolis init failed:", err);
    const status = document.getElementById("status");
    if (status) status.textContent = "Failed to load: " + err.message;
});
