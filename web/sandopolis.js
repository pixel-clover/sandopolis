"use strict";

let wasm = null;
let emu = null;
let running = false;
let rafId = null;
let canvas, ctx, imageData;
let BUTTONS = {};

// Audio state
let audioCtx = null;
let audioNode = null;
let audioEnabled = true;

// Save state
let db = null;
let currentRomName = "";
let currentSlot = 1;

// Display
let aspectMode = "fit"; // "fit" (4:3), "stretch", "native"

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

const HOTKEYS = {
    F5: "quickSave",
    F8: "quickLoad",
    F6: "save",
    F9: "load",
    F11: "fullscreen",
};

async function init() {
    canvas = document.getElementById("screen");
    ctx = canvas.getContext("2d");
    ctx.imageSmoothingEnabled = false;

    const wasiStubs = {
        fd_write: () => 0, fd_read: () => 0, fd_close: () => 0, fd_seek: () => 0,
        fd_fdstat_get: () => 0, fd_prestat_get: () => -1, fd_prestat_dir_name: () => -1,
        environ_get: () => 0,
        environ_sizes_get: (cp, sp) => {
            const v = new DataView(wasm.instance.exports.memory.buffer);
            v.setUint32(cp, 0, true); v.setUint32(sp, 0, true); return 0;
        },
        args_get: () => 0,
        args_sizes_get: (cp, sp) => {
            const v = new DataView(wasm.instance.exports.memory.buffer);
            v.setUint32(cp, 0, true); v.setUint32(sp, 0, true); return 0;
        },
        clock_time_get: () => 0,
        proc_exit: () => {},
        random_get: (buf, len) => {
            crypto.getRandomValues(new Uint8Array(wasm.instance.exports.memory.buffer, buf, len));
            return 0;
        },
    };

    const response = await fetch("sandopolis.wasm");
    const bytes = await response.arrayBuffer();
    wasm = await WebAssembly.instantiate(bytes, { wasi_snapshot_preview1: wasiStubs });

    const e = wasm.instance.exports;
    BUTTONS = {
        Up: e.sandopolis_button_up(), Down: e.sandopolis_button_down(),
        Left: e.sandopolis_button_left(), Right: e.sandopolis_button_right(),
        A: e.sandopolis_button_a(), B: e.sandopolis_button_b(),
        C: e.sandopolis_button_c(), Start: e.sandopolis_button_start(),
        X: e.sandopolis_button_x(), Y: e.sandopolis_button_y(),
        Z: e.sandopolis_button_z(),
    };

    document.getElementById("rom-input").addEventListener("change", onFileSelected);
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("keyup", onKeyUp);

    // Drag and drop
    const dropZone = document.getElementById("drop-zone");
    dropZone.addEventListener("dragover", (ev) => { ev.preventDefault(); dropZone.classList.add("drag-over"); });
    dropZone.addEventListener("dragleave", () => dropZone.classList.remove("drag-over"));
    dropZone.addEventListener("drop", (ev) => {
        ev.preventDefault(); dropZone.classList.remove("drag-over");
        if (ev.dataTransfer.files.length > 0) loadRom(ev.dataTransfer.files[0]);
    });

    // Settings UI
    document.getElementById("audio-toggle").addEventListener("click", toggleAudio);
    document.getElementById("audio-mode").addEventListener("change", onAudioModeChange);
    document.getElementById("psg-volume").addEventListener("input", onPsgVolumeChange);
    document.getElementById("controller-type").addEventListener("change", onControllerTypeChange);
    document.getElementById("aspect-mode").addEventListener("change", onAspectModeChange);
    document.getElementById("btn-fullscreen").addEventListener("click", toggleFullscreen);
    document.getElementById("btn-quick-save").addEventListener("click", quickSave);
    document.getElementById("btn-quick-load").addEventListener("click", quickLoad);
    document.getElementById("btn-save").addEventListener("click", persistentSave);
    document.getElementById("btn-load").addEventListener("click", persistentLoad);
    document.getElementById("slot-select").addEventListener("change", (ev) => { currentSlot = parseInt(ev.target.value); });
    document.getElementById("settings-toggle").addEventListener("click", () => {
        document.getElementById("settings-panel").classList.toggle("hidden");
    });
    document.getElementById("theme-toggle").addEventListener("click", toggleTheme);

    // Fullscreen change handler
    document.addEventListener("fullscreenchange", onFullscreenChange);

    loadSettings();
    db = await openDB();
    setStatus("Ready. Load a ROM to start.");
}

// IndexedDB

function openDB() {
    return new Promise((resolve, reject) => {
        const req = indexedDB.open("sandopolis-saves", 1);
        req.onupgradeneeded = () => req.result.createObjectStore("states");
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
    });
}

function dbPut(key, value) {
    return new Promise((resolve, reject) => {
        const tx = db.transaction("states", "readwrite");
        tx.objectStore("states").put(value, key);
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
    });
}

function dbGet(key) {
    return new Promise((resolve, reject) => {
        const tx = db.transaction("states", "readonly");
        const req = tx.objectStore("states").get(key);
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
    });
}

// Settings

function loadSettings() {
    try {
        const saved = JSON.parse(localStorage.getItem("sandopolis-settings") || "{}");
        if (saved.audioEnabled !== undefined) audioEnabled = saved.audioEnabled;
        if (saved.audioMode !== undefined) document.getElementById("audio-mode").value = saved.audioMode;
        if (saved.psgVolume !== undefined) document.getElementById("psg-volume").value = saved.psgVolume;
        if (saved.controllerType !== undefined) document.getElementById("controller-type").value = saved.controllerType;
        if (saved.slot !== undefined) { currentSlot = saved.slot; document.getElementById("slot-select").value = saved.slot; }
        if (saved.aspectMode !== undefined) { aspectMode = saved.aspectMode; document.getElementById("aspect-mode").value = saved.aspectMode; }
        if (saved.theme) applyTheme(saved.theme);
    } catch (_) {}
    updateAudioToggleLabel();
    document.getElementById("psg-volume-label").textContent = document.getElementById("psg-volume").value + "%";
    applyAspectMode();
}

function saveSettings() {
    localStorage.setItem("sandopolis-settings", JSON.stringify({
        audioEnabled,
        audioMode: document.getElementById("audio-mode").value,
        psgVolume: document.getElementById("psg-volume").value,
        controllerType: document.getElementById("controller-type").value,
        slot: currentSlot,
        aspectMode,
        theme: document.documentElement.getAttribute("data-theme") || "dark",
    }));
}

function applySettings() {
    if (!emu) return;
    const e = wasm.instance.exports;
    e.sandopolis_set_audio_mode(emu, parseInt(document.getElementById("audio-mode").value));
    e.sandopolis_set_psg_volume(emu, parseInt(document.getElementById("psg-volume").value));
    e.sandopolis_set_controller_type(emu, 0, parseInt(document.getElementById("controller-type").value));
}

function onAudioModeChange() { applySettings(); saveSettings(); }
function onPsgVolumeChange() {
    document.getElementById("psg-volume-label").textContent = document.getElementById("psg-volume").value + "%";
    applySettings(); saveSettings();
}
function onControllerTypeChange() { applySettings(); saveSettings(); }

function onAspectModeChange() {
    aspectMode = document.getElementById("aspect-mode").value;
    applyAspectMode();
    saveSettings();
}

function applyAspectMode() {
    const c = document.getElementById("screen");
    c.classList.remove("aspect-fit", "aspect-stretch", "aspect-native");
    c.classList.add("aspect-" + aspectMode);
}

// Theme

function toggleTheme() {
    const current = document.documentElement.getAttribute("data-theme") || "dark";
    applyTheme(current === "dark" ? "light" : "dark");
    saveSettings();
}

function applyTheme(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    document.getElementById("theme-toggle").textContent = theme === "dark" ? "LIGHT" : "DARK";
}

// Fullscreen

function toggleFullscreen() {
    const container = document.getElementById("screen-container");
    if (document.fullscreenElement) {
        document.exitFullscreen();
    } else {
        container.requestFullscreen().catch(() => {});
    }
}

function onFullscreenChange() {
    const container = document.getElementById("screen-container");
    if (document.fullscreenElement) {
        container.classList.add("fullscreen");
    } else {
        container.classList.remove("fullscreen");
    }
}

function toggleAudio() {
    audioEnabled = !audioEnabled;
    updateAudioToggleLabel();
    if (audioCtx) {
        if (audioEnabled) audioCtx.resume(); else audioCtx.suspend();
    }
    saveSettings();
}

function updateAudioToggleLabel() {
    document.getElementById("audio-toggle").textContent = audioEnabled ? "AUDIO ON" : "AUDIO OFF";
}

// Audio (Firefox-compatible: no outputChannelCount, handle mono fallback)

async function initAudio() {
    if (audioCtx) return;
    try {
        audioCtx = new AudioContext({ sampleRate: 48000 });
        await audioCtx.audioWorklet.addModule("audio-worklet.js");
        audioNode = new AudioWorkletNode(audioCtx, "sandopolis-audio", {
            numberOfOutputs: 1,
            channelCount: 2,
            channelCountMode: "explicit",
            channelInterpretation: "speakers",
        });
        audioNode.connect(audioCtx.destination);
        if (!audioEnabled) audioCtx.suspend();
    } catch (err) {
        console.warn("Web Audio init failed:", err);
        audioCtx = null; audioNode = null;
    }
}

function renderAudio() {
    if (!emu || !audioNode) return;
    const e = wasm.instance.exports;
    const sampleCount = e.sandopolis_audio_render(emu);
    if (sampleCount === 0) return;
    const bufPtr = e.sandopolis_audio_buffer_ptr(emu);
    const samples = new Int16Array(e.memory.buffer, bufPtr, sampleCount);
    audioNode.port.postMessage(new Int16Array(samples));
}

// Save/Load

function quickSave() {
    if (!emu) return;
    showToast(wasm.instance.exports.sandopolis_quick_save(emu) ? "Quick state saved" : "Save failed");
}

function quickLoad() {
    if (!emu) return;
    showToast(wasm.instance.exports.sandopolis_quick_load(emu) ? "Quick state loaded" : "No quick save found");
}

async function persistentSave() {
    if (!emu || !db) return;
    const e = wasm.instance.exports;
    const ptr = e.sandopolis_save_state(emu);
    if (!ptr) { showToast("Save failed"); return; }
    const len = e.sandopolis_save_state_len(emu);
    const data = new Uint8Array(e.memory.buffer, ptr, len).slice();
    e.sandopolis_free_save_buffer(emu);
    await dbPut(`${currentRomName}:slot${currentSlot}`, data);
    showToast(`Saved to slot ${currentSlot}`);
}

async function persistentLoad() {
    if (!emu || !db) return;
    const data = await dbGet(`${currentRomName}:slot${currentSlot}`);
    if (!data) { showToast(`No save in slot ${currentSlot}`); return; }
    const e = wasm.instance.exports;
    const ptr = e.sandopolis_alloc(data.length);
    if (!ptr) { showToast("Memory allocation failed"); return; }
    new Uint8Array(e.memory.buffer, ptr, data.length).set(data);
    const ok = e.sandopolis_load_state(emu, ptr, data.length);
    e.sandopolis_free(ptr, data.length);
    showToast(ok ? `Loaded slot ${currentSlot}` : "Load failed");
}

// Toast

function showToast(msg) {
    const el = document.getElementById("toast");
    el.textContent = msg;
    el.classList.add("visible");
    clearTimeout(el._timer);
    el._timer = setTimeout(() => el.classList.remove("visible"), 2000);
}

// ROM loading

function onFileSelected(ev) {
    if (ev.target.files.length > 0) loadRom(ev.target.files[0]);
}

async function loadRom(file) {
    const e = wasm.instance.exports;
    if (emu) {
        running = false;
        if (rafId) cancelAnimationFrame(rafId);
        e.sandopolis_destroy(emu);
        emu = null;
    }

    await initAudio();

    const buffer = await file.arrayBuffer();
    const romBytes = new Uint8Array(buffer);
    const romPtr = e.sandopolis_alloc(romBytes.length);
    if (!romPtr) { setStatus("Failed to allocate memory."); return; }
    new Uint8Array(e.memory.buffer).set(romBytes, romPtr);
    emu = e.sandopolis_create(romPtr, romBytes.length);
    e.sandopolis_free(romPtr, romBytes.length);
    if (!emu) { setStatus("Failed to initialize emulator."); return; }

    currentRomName = file.name;
    applySettings();

    // Resume AudioContext on user gesture (required by browsers)
    if (audioCtx && audioCtx.state === "suspended" && audioEnabled) {
        audioCtx.resume();
    }

    const isPal = e.sandopolis_is_pal(emu);
    setStatus(`Playing: ${file.name} (${isPal ? "PAL 50Hz" : "NTSC 60Hz"})`);

    running = true;
    const frameInterval = 1000 / (isPal ? 50 : 60);
    let lastTime = performance.now();

    function frame(now) {
        if (!running) return;
        rafId = requestAnimationFrame(frame);
        if (now - lastTime < frameInterval * 0.8) return;
        lastTime = now;

        e.sandopolis_run_frame(emu);
        renderAudio();

        const width = e.sandopolis_screen_width(emu);
        const height = e.sandopolis_screen_height(emu);
        const fbPtr = e.sandopolis_framebuffer_ptr(emu);
        const fbLen = e.sandopolis_framebuffer_len(emu);

        if (canvas.width !== width || canvas.height !== height) {
            canvas.width = width; canvas.height = height;
            imageData = ctx.createImageData(width, height);
        }
        if (!imageData) imageData = ctx.createImageData(width, height);

        const fb = new Uint32Array(e.memory.buffer, fbPtr, fbLen);
        const pixels = imageData.data;
        const count = Math.min(fbLen, width * height);
        for (let i = 0; i < count; i++) {
            const argb = fb[i]; const off = i * 4;
            pixels[off] = (argb >> 16) & 0xFF;
            pixels[off + 1] = (argb >> 8) & 0xFF;
            pixels[off + 2] = argb & 0xFF;
            pixels[off + 3] = 0xFF;
        }
        ctx.putImageData(imageData, 0, 0);
    }
    rafId = requestAnimationFrame(frame);
}

// Input

function onKeyDown(ev) {
    if (HOTKEYS[ev.key]) {
        ev.preventDefault();
        ({ quickSave, quickLoad, save: persistentSave, load: persistentLoad, fullscreen: toggleFullscreen })[HOTKEYS[ev.key]]();
        return;
    }
    if (!emu) return;
    const btn = KEY_MAP[ev.key];
    if (btn && BUTTONS[btn] !== undefined) {
        ev.preventDefault();
        wasm.instance.exports.sandopolis_set_button(emu, 0, BUTTONS[btn], true);
    }
}

function onKeyUp(ev) {
    if (!emu) return;
    const btn = KEY_MAP[ev.key];
    if (btn && BUTTONS[btn] !== undefined) {
        ev.preventDefault();
        wasm.instance.exports.sandopolis_set_button(emu, 0, BUTTONS[btn], false);
    }
}

function setStatus(msg) { document.getElementById("status").textContent = msg; }

init().catch(err => {
    console.error("Sandopolis init failed:", err);
    setStatus("Failed to load: " + err.message);
});
