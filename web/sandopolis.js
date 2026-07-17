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
let gainNode = null;
let audioEnabled = true;
let masterVolume = 70;

// Save state
let db = null;
let currentRomName = "";
let currentSlot = 1;
const textDecoder = new TextDecoder();

// Display
let aspectMode = "fit"; // "fit" (4:3), "stretch", "native"
let scaleMode = "fit"; // "fit" (free scaling), "integer" (whole pixel multiples)

// Mapped by ev.code (physical key position) so layout doesn't matter.
const DEFAULT_KEY_MAP = Object.freeze({
    ArrowUp: "Up",
    ArrowDown: "Down",
    ArrowLeft: "Left",
    ArrowRight: "Right",
    KeyA: "A",
    KeyS: "B",
    KeyD: "C",
    Enter: "Start",
    KeyZ: "X",
    KeyX: "Y",
    KeyC: "Z",
});
let keyMap = {...DEFAULT_KEY_MAP};

const HOTKEYS = {
    F5: "quickSave",
    F8: "quickLoad",
    F6: "save",
    F9: "load",
    F11: "fullscreen",
    F1: "help",
};

async function init() {
    canvas = document.getElementById("screen");
    ctx = canvas.getContext("2d");
    ctx.imageSmoothingEnabled = false;

    const ERRNO_NOSYS = 52;
    const wasiStubs = {
        fd_write: () => 0, fd_read: () => 0, fd_close: () => 0, fd_seek: () => 0,
        fd_tell: () => 0, fd_sync: () => 0, fd_datasync: () => 0,
        fd_advise: () => 0, fd_allocate: () => 0, fd_renumber: () => 0,
        fd_pread: () => ERRNO_NOSYS, fd_pwrite: () => ERRNO_NOSYS, fd_readdir: () => ERRNO_NOSYS,
        fd_fdstat_get: () => 0, fd_fdstat_set_flags: () => 0, fd_fdstat_set_rights: () => 0,
        fd_filestat_get: () => 0, fd_filestat_set_size: () => 0, fd_filestat_set_times: () => 0,
        // 8 = WASI EBADF: the std preopen scan loop terminates on it; -1
        // truncates to 0xFFFF, which is not a valid errno tag.
        fd_prestat_get: () => 8, fd_prestat_dir_name: () => 8,
        path_open: () => ERRNO_NOSYS, path_create_directory: () => ERRNO_NOSYS,
        path_link: () => ERRNO_NOSYS, path_readlink: () => ERRNO_NOSYS,
        path_rename: () => ERRNO_NOSYS, path_symlink: () => ERRNO_NOSYS,
        path_remove_directory: () => ERRNO_NOSYS, path_unlink_file: () => ERRNO_NOSYS,
        path_filestat_get: () => ERRNO_NOSYS, path_filestat_set_times: () => ERRNO_NOSYS,
        environ_get: () => 0,
        environ_sizes_get: (cp, sp) => {
            const v = new DataView(wasm.instance.exports.memory.buffer);
            v.setUint32(cp, 0, true);
            v.setUint32(sp, 0, true);
            return 0;
        },
        args_get: () => 0,
        args_sizes_get: (cp, sp) => {
            const v = new DataView(wasm.instance.exports.memory.buffer);
            v.setUint32(cp, 0, true);
            v.setUint32(sp, 0, true);
            return 0;
        },
        clock_time_get: (clockId, precision, timePtr) => {
            // Write a real (zero) timestamp: returning success without
            // writing would hand callers whatever bytes sit at the result
            // pointer as a valid time.
            new DataView(wasm.instance.exports.memory.buffer).setBigUint64(timePtr, 0n, true);
            return 0;
        },
        clock_res_get: (clockId, resPtr) => {
            new DataView(wasm.instance.exports.memory.buffer).setBigUint64(resPtr, 1n, true);
            return 0;
        },
        poll_oneoff: () => ERRNO_NOSYS,
        proc_exit: () => {
        },
        random_get: (buf, len) => {
            crypto.getRandomValues(new Uint8Array(wasm.instance.exports.memory.buffer, buf, len));
            return 0;
        },
    };

    // Fall back to a NOSYS stub for any WASI import the list above does not
    // name, so a std-library upgrade adding imports cannot break instantiation.
    const wasiImports = new Proxy(wasiStubs, {
        get: (target, prop) => target[prop] ?? (() => ERRNO_NOSYS),
    });

    const response = await fetch("sandopolis.wasm");
    const bytes = await response.arrayBuffer();
    wasm = await WebAssembly.instantiate(bytes, {wasi_snapshot_preview1: wasiImports});

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
    document.getElementById("recent-roms").addEventListener("change", (ev) => {
        if (ev.target.value) loadRecentRom(ev.target.value);
        ev.target.selectedIndex = 0;
    });
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("keyup", onKeyUp);
    window.addEventListener("gamepaddisconnected", releaseAllGamepadButtons);
    // Click-to-pause is a 2D-only affordance. While a VR session is active
    // the canvas is not visible to the user and Quest browser sometimes fires
    // synthetic clicks on the focused canvas when a BT controller button is
    // pressed; that would freeze the game on every button press.
    document.getElementById("screen").addEventListener("click", () => {
        if (window.SandopolisVR && window.SandopolisVR.active) return;
        togglePause();
    });

    // Drag and drop
    const dropZone = document.getElementById("drop-zone");
    dropZone.addEventListener("dragover", (ev) => {
        ev.preventDefault();
        dropZone.classList.add("drag-over");
    });
    dropZone.addEventListener("dragleave", () => dropZone.classList.remove("drag-over"));
    dropZone.addEventListener("drop", (ev) => {
        ev.preventDefault();
        dropZone.classList.remove("drag-over");
        if (ev.dataTransfer.files.length > 0) loadRom(ev.dataTransfer.files[0]);
    });

    // Settings UI
    document.getElementById("audio-toggle").addEventListener("click", toggleAudio);
    document.getElementById("master-volume").addEventListener("input", onMasterVolumeChange);
    document.getElementById("controller-type").addEventListener("change", onControllerTypeChange);
    document.getElementById("aspect-mode").addEventListener("change", onAspectModeChange);
    document.getElementById("scale-mode").addEventListener("change", onScaleModeChange);
    document.getElementById("btn-fullscreen").addEventListener("click", toggleFullscreen);
    document.getElementById("btn-quick-save").addEventListener("click", quickSave);
    document.getElementById("btn-quick-load").addEventListener("click", quickLoad);
    document.getElementById("btn-save").addEventListener("click", persistentSave);
    document.getElementById("btn-load").addEventListener("click", persistentLoad);
    document.getElementById("slot-select").addEventListener("change", (ev) => {
        currentSlot = parseInt(ev.target.value);
    });
    document.getElementById("settings-toggle").addEventListener("click", () => {
        document.getElementById("settings-panel").classList.toggle("hidden");
    });
    document.getElementById("theme-toggle").addEventListener("click", toggleTheme);
    document.getElementById("help-btn").addEventListener("click", toggleHelp);
    document.getElementById("help-close").addEventListener("click", toggleHelp);
    document.getElementById("perf-toggle").addEventListener("click", togglePerf);
    document.getElementById("about-btn").addEventListener("click", toggleAbout);
    document.getElementById("about-close").addEventListener("click", toggleAbout);
    document.getElementById("about-overlay").addEventListener("click", (ev) => {
        if (ev.target === ev.currentTarget) toggleAbout();
    });
    document.getElementById("help-overlay").addEventListener("click", (ev) => {
        if (ev.target === ev.currentTarget) toggleHelp();
    });
    document.getElementById("error-dismiss").addEventListener("click", hideError);

    // Close help on Escape
    document.addEventListener("keydown", (ev) => {
        if (ev.key === "Escape") {
            if (helpOpen) {
                toggleHelp();
                ev.preventDefault();
            } else if (aboutOpen) {
                toggleAbout();
                ev.preventDefault();
            }
        }
    });

    // Fullscreen change handler
    document.addEventListener("fullscreenchange", onFullscreenChange);

    // Auto-pause when the tab is hidden so the browser's rAF throttling
    // doesn't slow the emulator and drain the audio buffer in the background.
    document.addEventListener("visibilitychange", onVisibilityChange);

    loadSettings();
    initRemapUI();
    db = await openDB();
    await populateRecentRoms();

    if (window.SandopolisVR) {
        window.SandopolisVR.init({
            canvas,
            buttons: BUTTONS,
            onTick: () => tickEmulator(performance.now()),
            onButton: (player, btn, down) => {
                if (emu) wasm.instance.exports.sandopolis_set_button(emu, player, btn, down);
            },
            isRomLoaded: () => !!emu,
            getAspectMode: () => aspectMode,
            onSessionStart: () => {
                // Click-to-unpause is disabled inside VR, so entering VR
                // with the game paused would show a permanently frozen
                // screen with no way to resume from the headset.
                if (emu && !running) togglePause();
            },
            onSessionEnd: () => {
                // Pause the emulator when leaving VR so the game doesn't run unattended.
                if (emu && running) {
                    togglePause();
                    showToast("VR exited: click screen to resume");
                }
            },
        });
    }

    setStatus("We are ready. Load a ROM to start playing!");
}

// IndexedDB

function openDB() {
    return new Promise((resolve, reject) => {
        const req = indexedDB.open("sandopolis-saves", 2);
        req.onupgradeneeded = (ev) => {
            const db = req.result;
            if (!db.objectStoreNames.contains("states")) db.createObjectStore("states");
            if (!db.objectStoreNames.contains("roms")) db.createObjectStore("roms");
        };
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

// Recent ROMs (cached in IndexedDB, max 10)

const MAX_RECENT_ROMS = 10;

async function saveRecentRom(name, bytes) {
    // Each IndexedDB transaction does only synchronous work and is awaited
    // via tx.oncomplete. Chaining requests across awaits in one transaction
    // can race the auto-commit and throw TransactionInactiveError.
    await new Promise((resolve, reject) => {
        const tx = db.transaction("roms", "readwrite");
        tx.objectStore("roms").put({name, bytes, timestamp: Date.now()}, name);
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
    });

    const allEntries = await new Promise((resolve, reject) => {
        const tx = db.transaction("roms", "readonly");
        const req = tx.objectStore("roms").getAll();
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
    });
    if (allEntries.length <= MAX_RECENT_ROMS) return;
    allEntries.sort((a, b) => b.timestamp - a.timestamp);
    const toDelete = allEntries.slice(MAX_RECENT_ROMS);
    await new Promise((resolve, reject) => {
        const tx = db.transaction("roms", "readwrite");
        const store = tx.objectStore("roms");
        for (const old of toDelete) store.delete(old.name);
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
    });
}

async function getRecentRoms() {
    try {
        const tx = db.transaction("roms", "readonly");
        const store = tx.objectStore("roms");
        const entries = await new Promise((resolve, reject) => {
            const req = store.getAll();
            req.onsuccess = () => resolve(req.result);
            req.onerror = () => reject(req.error);
        });
        entries.sort((a, b) => b.timestamp - a.timestamp);
        return entries;
    } catch (_) {
        return [];
    }
}

async function populateRecentRoms() {
    const entries = await getRecentRoms();
    const select = document.getElementById("recent-roms");
    // Clear existing options except the placeholder
    while (select.options.length > 1) select.remove(1);
    if (entries.length === 0) {
        select.style.display = "none";
        return;
    }
    for (const entry of entries) {
        const opt = document.createElement("option");
        opt.value = entry.name;
        opt.textContent = entry.name;
        select.appendChild(opt);
    }
    select.style.display = "";
}

async function loadRecentRom(name) {
    const entry = await new Promise((resolve, reject) => {
        const tx = db.transaction("roms", "readonly");
        const req = tx.objectStore("roms").get(name);
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
    });
    if (!entry) return;
    // Bump timestamp so this ROM moves to the top of the recents list.
    // Wrapped in its own awaited transaction so we don't race the auto-commit;
    // logged on failure but not blocking, since the ROM still loads either way.
    new Promise((resolve, reject) => {
        const tx = db.transaction("roms", "readwrite");
        tx.objectStore("roms").put({...entry, timestamp: Date.now()}, name);
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
    }).catch((err) => console.warn("Recent ROM timestamp update failed:", err));
    const blob = new Blob([entry.bytes]);
    blob.name = entry.name;
    blob.arrayBuffer = () => Promise.resolve(entry.bytes.buffer.slice(
        entry.bytes.byteOffset, entry.bytes.byteOffset + entry.bytes.byteLength));
    await loadRom(blob);
}

// Settings

function loadSettings() {
    try {
        const saved = JSON.parse(localStorage.getItem("sandopolis-settings") || "{}");
        if (saved.audioEnabled !== undefined) audioEnabled = saved.audioEnabled;
        if (saved.controllerType !== undefined) document.getElementById("controller-type").value = saved.controllerType;
        if (saved.slot !== undefined) {
            currentSlot = saved.slot;
            document.getElementById("slot-select").value = saved.slot;
        }
        if (saved.aspectMode !== undefined) {
            aspectMode = saved.aspectMode;
            document.getElementById("aspect-mode").value = saved.aspectMode;
        }
        if (saved.masterVolume !== undefined) {
            masterVolume = saved.masterVolume;
            document.getElementById("master-volume").value = saved.masterVolume;
        }
        // The saved map is complete (saveSettings persists all bindings);
        // spreading defaults underneath would resurrect bindings the user
        // deliberately remapped away.
        if (saved.keyMap) keyMap = {...saved.keyMap};
        if (saved.scaleMode !== undefined) {
            scaleMode = saved.scaleMode;
            document.getElementById("scale-mode").value = saved.scaleMode;
        }
        if (saved.theme) applyTheme(saved.theme);
    } catch (_) {
    }
    updateAudioToggleLabel();
    document.getElementById("master-volume-label").textContent = masterVolume + "%";
    applyAspectMode();
}

function saveSettings() {
    try {
        localStorage.setItem("sandopolis-settings", JSON.stringify({
            audioEnabled,
            controllerType: document.getElementById("controller-type").value,
            slot: currentSlot,
            aspectMode,
            keyMap,
            scaleMode,
            masterVolume,
            theme: document.documentElement.getAttribute("data-theme") || "light",
        }));
    } catch (_) {
        // localStorage may be full or unavailable
    }
}

function applySettings() {
    if (!emu) return;
    const e = wasm.instance.exports;
    e.sandopolis_set_controller_type(emu, 0, parseInt(document.getElementById("controller-type").value));
}

function onControllerTypeChange() {
    applySettings();
    saveSettings();
}

function onAspectModeChange() {
    aspectMode = document.getElementById("aspect-mode").value;
    applyAspectMode();
    saveSettings();
}

function onScaleModeChange() {
    scaleMode = document.getElementById("scale-mode").value;
    applyAspectMode();
    saveSettings();
}

function applyAspectMode() {
    const c = document.getElementById("screen");
    const sc = document.getElementById("screen-container");
    c.classList.remove("aspect-fit", "aspect-stretch", "aspect-native", "integer-scale");
    sc.classList.remove("integer-container");
    c.style.width = "";
    c.style.height = "";
    clearTimeout(resizeTimer);

    if (scaleMode === "integer") {
        c.classList.add("integer-scale");
        sc.classList.add("integer-container");
        c.style.aspectRatio = "";
        applyIntegerScale();
    } else {
        c.classList.add("aspect-" + aspectMode);
        // Native mode: set aspect ratio from actual canvas dimensions
        if (aspectMode === "native") {
            const w = c.width || 320;
            const h = c.height || 224;
            c.style.aspectRatio = w + " / " + h;
        } else {
            c.style.aspectRatio = "";
        }
    }
}

function applyIntegerScale() {
    const c = document.getElementById("screen");
    const sc = document.getElementById("screen-container");
    const nativeW = c.width || 320;
    const nativeH = c.height || 224;

    // Determine nominal display dimensions based on aspect mode
    let nominalW, nominalH;
    if (aspectMode === "fit") {
        nominalH = nativeH;
        nominalW = nativeH * (4 / 3);
    } else if (aspectMode === "native") {
        nominalW = nativeW;
        nominalH = nativeH;
    } else {
        // Stretch: use native ratio for integer mode
        nominalW = nativeW;
        nominalH = nativeH;
    }

    // Get available space
    let containerW, containerH;
    if (sc.classList.contains("fullscreen")) {
        containerW = window.innerWidth;
        containerH = window.innerHeight;
    } else {
        containerW = sc.clientWidth;
        containerH = sc.clientWidth * 0.75; // max height based on container width
    }

    const scale = Math.max(1, Math.floor(Math.min(containerW / nominalW, containerH / nominalH)));
    const displayW = Math.round(nominalW * scale);
    const displayH = Math.round(nominalH * scale);

    c.style.width = displayW + "px";
    c.style.height = displayH + "px";
}

// Recompute integer scale on window resize
let resizeTimer = null;
window.addEventListener("resize", () => {
    if (scaleMode === "integer") {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(applyIntegerScale, 50);
    }
});

// Keyboard remapping

const REMAP_BUTTONS = ["Up", "Down", "Left", "Right", "A", "B", "C", "Start", "X", "Y", "Z"];

function keyDisplayName(code) {
    if (!code) return "·";
    if (code.startsWith("Key")) return code.slice(3);
    if (code.startsWith("Arrow")) return code.slice(5);
    if (code === "Enter") return "Enter";
    if (code.startsWith("Digit")) return code.slice(5);
    return code.replace(/([a-z])([A-Z])/g, "$1 $2");
}

function keyForButton(btn) {
    for (const [code, mapped] of Object.entries(keyMap)) {
        if (mapped === btn) return code;
    }
    return null;
}

function initRemapUI() {
    const grid = document.getElementById("remap-grid");
    grid.innerHTML = "";
    for (const btn of REMAP_BUTTONS) {
        const row = document.createElement("div");
        row.className = "remap-row";
        const lbl = document.createElement("label");
        lbl.textContent = btn;
        const rbtn = document.createElement("button");
        rbtn.className = "remap-btn";
        rbtn.dataset.btn = btn;
        rbtn.textContent = keyDisplayName(keyForButton(btn));
        rbtn.title = "Click to rebind " + btn + " button";
        rbtn.addEventListener("click", () => startListening(rbtn, btn));
        row.append(lbl, rbtn);
        grid.appendChild(row);
    }
    document.getElementById("remap-reset").addEventListener("click", resetKeyMap);
}

let activeRemapCleanup = null;

function startListening(rbtn, btn) {
    // Cancel any active listener
    if (activeRemapCleanup) activeRemapCleanup();
    rbtn.classList.add("listening");
    rbtn.textContent = "Press a key...";

    function onKey(ev) {
        ev.preventDefault();
        ev.stopPropagation();
        cleanup();
        if (ev.code === "Escape") {
            rbtn.textContent = keyDisplayName(keyForButton(btn));
            return;
        }
        const newCode = ev.code;
        // If this key is already bound to another button, swap
        const existingBtn = keyMap[newCode];
        const oldCode = keyForButton(btn);
        if (existingBtn && existingBtn !== btn) {
            // Remove old mapping for the new code
            delete keyMap[newCode];
            // Assign old code to the displaced button
            if (oldCode) {
                keyMap[oldCode] = existingBtn;
            }
        }
        // Remove old binding for this button
        if (oldCode) delete keyMap[oldCode];
        // Set new binding
        keyMap[newCode] = btn;
        saveSettings();
        refreshRemapLabels();
    }

    function cleanup() {
        document.removeEventListener("keydown", onKey, true);
        rbtn.classList.remove("listening");
        activeRemapCleanup = null;
    }

    activeRemapCleanup = cleanup;
    document.addEventListener("keydown", onKey, true);
}

function refreshRemapLabels() {
    const btns = document.querySelectorAll(".remap-btn");
    for (const rbtn of btns) {
        rbtn.textContent = keyDisplayName(keyForButton(rbtn.dataset.btn));
    }
}

function resetKeyMap() {
    keyMap = {...DEFAULT_KEY_MAP};
    saveSettings();
    refreshRemapLabels();
}

// Theme

function toggleTheme() {
    const current = document.documentElement.getAttribute("data-theme") || "light";
    applyTheme(current === "dark" ? "light" : "dark");
    saveSettings();
}

function applyTheme(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    document.getElementById("theme-toggle").textContent = theme === "dark" ? "Dark" : "Light";
}

function readWasmString(ptrFn, lenFn) {
    if (!wasm) return "--";
    const e = wasm.instance.exports;
    const ptr = ptrFn(e);
    const len = lenFn(e);
    return textDecoder.decode(new Uint8Array(e.memory.buffer, ptr, len));
}

function updateAboutInfo() {
    const versionEl = document.getElementById("about-version");
    const buildEl = document.getElementById("about-build");
    const audioEl = document.getElementById("about-audio");
    const videoEl = document.getElementById("about-video");
    if (!wasm) {
        versionEl.textContent = "--";
        buildEl.textContent = "--";
        audioEl.textContent = "--";
        videoEl.textContent = "--";
        return;
    }

    const e = wasm.instance.exports;
    const ver = readWasmString(() => e.sandopolis_version_ptr(), () => e.sandopolis_version_len());
    const gitRef = readWasmString(() => e.sandopolis_git_hash_ptr(), () => e.sandopolis_git_hash_len());
    const time = readWasmString(() => e.sandopolis_build_time_ptr(), () => e.sandopolis_build_time_len());
    // gitRef is "branch@hash"; avoid repeating the version when built from a tag
    const atIdx = gitRef.lastIndexOf("@");
    const branch = atIdx >= 0 ? gitRef.slice(0, atIdx) : gitRef;
    const hash = atIdx >= 0 ? gitRef.slice(atIdx + 1) : "";
    const branchIsVersion = branch === ver || branch === "v" + ver || branch === "HEAD";
    if (hash && !branchIsVersion) {
        versionEl.textContent = `${ver} (${branch}@${hash})`;
    } else if (hash) {
        versionEl.textContent = `${ver} (${hash})`;
    } else {
        versionEl.textContent = ver;
    }
    buildEl.textContent = `${readWasmString(() => e.sandopolis_build_label_ptr(), () => e.sandopolis_build_label_len())} · ${time}`;
    audioEl.textContent = `YM2612 + SN76489 at ${Math.round(e.sandopolis_audio_sample_rate() / 1000)} kHz`;

    const width = e.sandopolis_video_width();
    const height = emu ? e.sandopolis_screen_height(emu) : 224;
    videoEl.textContent = `${width}x${height} ARGB Canvas`;

    document.getElementById("about-save-version").textContent = "v" + e.sandopolis_save_state_version();

    const vrEl = document.getElementById("about-vr");
    if (vrEl) {
        const status = window.SandopolisVR ? window.SandopolisVR.status : "no-api";
        const labels = {
            supported: "Detected (immersive-vr)",
            unsupported: "WebXR present, no headset",
            "no-api": "Not available (no WebXR)",
            checking: "Checking...",
        };
        vrEl.textContent = labels[status] || "Unknown";
    }
}

// Help overlay

let helpOpen = false;
// Counts simultaneously-open overlays (help, about). State capture and
// resume only fire on the 0->1 and 1->0 transitions so two overlays opening
// at once cannot lose the original "was running" state.
let overlayDepth = 0;
let wasRunningBeforeOverlay = false;

function togglePause() {
    if (!emu) return;
    if (running) {
        running = false;
        if (rafId) cancelAnimationFrame(rafId);
        if (audioCtx) audioCtx.suspend();
        setStatus("Paused: click screen to resume");
    } else {
        running = true;
        resumeFrame();
        if (audioCtx && audioEnabled) audioCtx.resume();
        setStatus("Playing now: " + currentRomName);
    }
}

function pauseForOverlay() {
    if (overlayDepth === 0) wasRunningBeforeOverlay = running;
    overlayDepth++;
    if (running) {
        running = false;
        if (rafId) cancelAnimationFrame(rafId);
        if (audioCtx) audioCtx.suspend();
    }
}

let pausedByVisibility = false;

function onVisibilityChange() {
    if (document.hidden) {
        if (running) {
            pausedByVisibility = true;
            running = false;
            if (rafId) cancelAnimationFrame(rafId);
            if (audioCtx) audioCtx.suspend();
        }
    } else if (pausedByVisibility) {
        pausedByVisibility = false;
        if (emu) {
            running = true;
            resumeFrame();
            if (audioCtx && audioEnabled) audioCtx.resume();
        }
    }
}

function resumeAfterOverlay() {
    if (overlayDepth > 0) overlayDepth--;
    if (overlayDepth > 0) return;
    if (wasRunningBeforeOverlay && emu) {
        running = true;
        resumeFrame();
        if (audioCtx && audioEnabled) audioCtx.resume();
    }
}

function toggleHelp() {
    const overlay = document.getElementById("help-overlay");
    if (helpOpen) {
        overlay.classList.remove("visible");
        helpOpen = false;
        resumeAfterOverlay();
    } else {
        pauseForOverlay();
        overlay.classList.add("visible");
        helpOpen = true;
    }
}

// Performance HUD

let perfVisible = false;
let perfInterval = null;

function togglePerf() {
    perfVisible = !perfVisible;
    const hud = document.getElementById("perf-hud");
    if (perfVisible) {
        hud.classList.remove("hidden");
        perfInterval = setInterval(updatePerf, 500);
    } else {
        hud.classList.add("hidden");
        if (perfInterval) {
            clearInterval(perfInterval);
            perfInterval = null;
        }
    }
}

function updatePerf() {
    const e = wasm ? wasm.instance.exports : null;
    const fps = document.getElementById("fps-display").textContent || "--";
    document.getElementById("perf-fps").textContent = fps;
    const fpsNum = parseInt(fps);
    document.getElementById("perf-frame-ms").textContent = fpsNum > 0 ? (1000 / fpsNum).toFixed(1) + " ms" : "--";

    if (e && emu) {
        // Resolution & display mode
        const w = e.sandopolis_screen_width(emu);
        const h = e.sandopolis_screen_height(emu);
        const isPal = e.sandopolis_is_pal(emu);
        document.getElementById("perf-resolution").textContent = w + "x" + h;

        const sysType = e.sandopolis_system_type ? e.sandopolis_system_type(emu) : 0;
        const sysName = sysType === 3 ? "SG-1000" : sysType === 2 ? "Game Gear" : sysType === 1 ? "SMS" : "Genesis";
        const mode = e.sandopolis_display_mode(emu);
        const parts = [sysName];
        if (sysType === 0) parts.push((mode & 1) ? "H40" : "H32");
        parts.push(isPal ? "PAL" : "NTSC");
        if (mode & 2) parts.push("Interlace");
        if (mode & 4) parts.push("S/H");
        document.getElementById("perf-display").textContent = parts.join(" ");

        // ROM info
        const titlePtr = e.sandopolis_rom_title_ptr(emu);
        if (titlePtr) {
            const titleLen = e.sandopolis_rom_title_len();
            const titleBytes = new Uint8Array(e.memory.buffer, titlePtr, titleLen);
            document.getElementById("perf-rom-title").textContent = textDecoder.decode(titleBytes).trim();
        } else {
            document.getElementById("perf-rom-title").textContent = "N/A";
        }
        const romSize = e.sandopolis_rom_size(emu);
        if (romSize >= 1048576) {
            document.getElementById("perf-rom-size").textContent = (romSize / 1048576).toFixed(1) + " MB";
        } else {
            document.getElementById("perf-rom-size").textContent = (romSize / 1024).toFixed(0) + " KB";
        }
        document.getElementById("perf-checksum").textContent = e.sandopolis_rom_checksum_valid(emu) ? "OK" : "MISMATCH";

        // Frame count
        const frames = e.sandopolis_frame_count(emu);
        const seconds = frames / (isPal ? 50 : 60);
        const mm = Math.floor(seconds / 60).toString().padStart(2, "0");
        const ss = Math.floor(seconds % 60).toString().padStart(2, "0");
        document.getElementById("perf-frame-count").textContent = frames + " (" + mm + ":" + ss + ")";
    }

    if (wasm) {
        const bytes = wasm.instance.exports.memory.buffer.byteLength;
        document.getElementById("perf-wasm-mem").textContent = (bytes / 1048576).toFixed(1) + " MB";
    }
    if (performance.memory) {
        document.getElementById("perf-js-heap").textContent = (performance.memory.usedJSHeapSize / 1048576).toFixed(1) + " MB";
    } else {
        document.getElementById("perf-js-heap").textContent = "N/A";
    }
    if (audioCtx && audioNode) {
        document.getElementById("perf-audio").textContent = audioCtx.state + " @ " + audioCtx.sampleRate + "Hz";
    } else {
        document.getElementById("perf-audio").textContent = "OFF";
    }

    const gpDescriptions = [];
    const gamepads = navigator.getGamepads ? navigator.getGamepads() : [];
    for (const gp of gamepads) {
        if (!gp || !gp.connected) continue;
        const map = gp.mapping || "unmapped";
        const shortId = (gp.id || "?").slice(0, 28);
        gpDescriptions.push(`[${map}] ${shortId} (${gp.buttons.length}b/${gp.axes.length}a)`);
    }
    document.getElementById("perf-gamepads").textContent =
        gpDescriptions.length ? gpDescriptions.join("; ") : "none";
}

// About modal

let aboutOpen = false;

function toggleAbout() {
    const overlay = document.getElementById("about-overlay");
    if (aboutOpen) {
        overlay.classList.remove("visible");
        aboutOpen = false;
        resumeAfterOverlay();
    } else {
        pauseForOverlay();
        updateAboutInfo();
        if (wasm) {
            const bytes = wasm.instance.exports.memory.buffer.byteLength;
            document.getElementById("about-wasm-size").textContent = (bytes / 1048576).toFixed(1) + " MB";
        }
        overlay.classList.add("visible");
        aboutOpen = true;
    }
}

// Fullscreen

function toggleFullscreen() {
    const container = document.getElementById("screen-container");
    if (document.fullscreenElement) {
        document.exitFullscreen();
        return;
    }
    if (!emu) {
        showToast("Load a ROM first");
        return;
    }
    container.requestFullscreen().catch(() => {
        showToast("Fullscreen not available");
    });
}

function onFullscreenChange() {
    const container = document.getElementById("screen-container");
    if (document.fullscreenElement) {
        container.classList.add("fullscreen");
    } else {
        container.classList.remove("fullscreen");
    }
    if (scaleMode === "integer") setTimeout(applyIntegerScale, 50);
}

function onMasterVolumeChange() {
    masterVolume = parseInt(document.getElementById("master-volume").value);
    document.getElementById("master-volume-label").textContent = masterVolume + "%";
    if (gainNode) gainNode.gain.value = masterVolume / 100;
    saveSettings();
}

function flushWorkletAudio() {
    if (audioNode) audioNode.port.postMessage("flush");
    audioBufferLevel = 0;
}

function toggleAudio() {
    audioEnabled = !audioEnabled;
    updateAudioToggleLabel();
    if (audioCtx) {
        if (audioEnabled) audioCtx.resume(); else audioCtx.suspend();
    }
    // Drop whatever sits in the worklet ring so re-enabling audio never
    // replays stale samples or starts hundreds of milliseconds behind.
    flushWorkletAudio();
    saveSettings();
}

function updateAudioToggleLabel() {
    document.getElementById("audio-toggle").textContent = audioEnabled ? "ON" : "OFF";
}

// Audio (Firefox-compatible: no outputChannelCount, handle mono fallback)

async function initAudio() {
    if (audioCtx) return;
    try {
        audioCtx = new AudioContext({sampleRate: 48000});
        if (audioCtx.sampleRate !== 48000) {
            console.warn("Audio: requested 48kHz but got " + audioCtx.sampleRate + "Hz; browser will resample");
        }
        await audioCtx.audioWorklet.addModule("audio-worklet.js");
        const srcRate = wasm
            ? wasm.instance.exports.sandopolis_audio_sample_rate()
            : audioCtx.sampleRate;
        audioNode = new AudioWorkletNode(audioCtx, "sandopolis-audio", {
            numberOfOutputs: 1,
            channelCount: 2,
            channelCountMode: "explicit",
            channelInterpretation: "speakers",
            processorOptions: {srcRate},
        });
        audioNode.port.onmessage = (e) => {
            if (e.data && e.data.type === "level") {
                audioBufferLevel = e.data.count;
                audioBufferCapacity = e.data.capacity;
            }
        };
        gainNode = audioCtx.createGain();
        gainNode.gain.value = masterVolume / 100;
        audioNode.connect(gainNode);
        gainNode.connect(audioCtx.destination);
        if (!audioEnabled) audioCtx.suspend();
    } catch (err) {
        console.warn("Web Audio init failed:", err);
        audioCtx = null;
        audioNode = null;
        gainNode = null;
    }
}

let renderAudioFrameCount = 0;

function renderAudio() {
    if (!emu || !audioNode) return;
    const e = wasm.instance.exports;
    const sampleCount = e.sandopolis_audio_render(emu);
    if (sampleCount === 0) return;
    // The core's audio is always drained above so its event queues don't
    // back up, but don't fill the worklet ring while nothing is playing:
    // a suspended context stops draining and the ring would hold stale
    // audio indefinitely.
    if (!audioEnabled || !audioCtx || audioCtx.state !== "running") return;
    const bufPtr = e.sandopolis_audio_buffer_ptr(emu);
    // Re-read memory.buffer after render call (may have grown via memory.grow)
    const samples = new Int16Array(e.memory.buffer, bufPtr, sampleCount);
    audioNode.port.postMessage(samples.slice());
    // Query buffer level for pacing at ~30 Hz; the rate-trim controller is
    // gentle, so mildly stale feedback is fine but fresher converges faster.
    if ((++renderAudioFrameCount % 2) === 0) {
        audioNode.port.postMessage("query-level");
    }
}

// Save/Load

function quickSave() {
    if (!emu) {
        showToast("Load a ROM first");
        return;
    }
    showToast(wasm.instance.exports.sandopolis_quick_save(emu) ? "Quick state saved" : "Save failed");
}

function quickLoad() {
    if (!emu) {
        showToast("Load a ROM first");
        return;
    }
    showToast(wasm.instance.exports.sandopolis_quick_load(emu) ? "Quick state loaded" : "No quick save found");
}

async function persistentSave() {
    if (!emu) {
        showToast("Load a ROM first");
        return;
    }
    if (!db) {
        showToast("Storage unavailable");
        return;
    }
    const e = wasm.instance.exports;
    const ptr = e.sandopolis_save_state(emu);
    if (!ptr) {
        showToast("Save failed");
        return;
    }
    const len = e.sandopolis_save_state_len(emu);
    const data = new Uint8Array(e.memory.buffer, ptr, len).slice();
    e.sandopolis_free_save_buffer(emu);
    await dbPut(`${currentRomName}:slot${currentSlot}`, data);
    showToast(`Saved to slot ${currentSlot}`);
}

async function persistentLoad() {
    if (!emu) {
        showToast("Load a ROM first");
        return;
    }
    if (!db) {
        showToast("Storage unavailable");
        return;
    }
    const data = await dbGet(`${currentRomName}:slot${currentSlot}`);
    if (!data) {
        showToast(`No save in slot ${currentSlot}`);
        return;
    }
    const e = wasm.instance.exports;
    const ptr = e.sandopolis_alloc(data.length);
    if (!ptr) {
        showToast("Memory allocation failed");
        return;
    }
    new Uint8Array(e.memory.buffer, ptr, data.length).set(data);
    const ok = e.sandopolis_load_state(emu, ptr, data.length);
    e.sandopolis_free(ptr, data.length);
    if (ok) {
        frameInterval = e.sandopolis_is_pal(emu) ? (1000 / 49.7015) : (1000 / 59.9227);
    }
    showToast(ok ? `Loaded slot ${currentSlot}` : "Load failed");
}

// Toast

function showToast(msg) {
    const el = document.getElementById("toast");
    el.textContent = msg;
    el.classList.add("visible");
    // Shared timer property with vr.js's showVrToast: both must clear the
    // same handle or one side's stale timer hides the other's message.
    clearTimeout(el._toastTimer);
    el._toastTimer = setTimeout(() => el.classList.remove("visible"), 2000);
}

// ROM loading

function onFileSelected(ev) {
    if (ev.target.files.length > 0) loadRom(ev.target.files[0]);
    // Clear the input so picking the same file again re-fires "change"
    // (used to restart a game by re-selecting its ROM).
    ev.target.value = "";
}

async function loadRom(file) {
    // Close any open overlays through their toggles so overlayDepth stays
    // balanced; closing them by hand left the depth stuck above zero and
    // permanently broke overlay pause/resume for the session. The restart
    // below supersedes the resume this triggers.
    if (helpOpen) toggleHelp();
    if (aboutOpen) toggleAbout();

    const e = wasm.instance.exports;
    if (emu) {
        running = false;
        if (rafId) cancelAnimationFrame(rafId);
        e.sandopolis_destroy(emu);
        emu = null;
    }

    // Reset pacing and audio-buffer telemetry so the freshly-loaded ROM
    // doesn't inherit fast/slow pacing or stale buffer-fill numbers from
    // the previous game. Without this the first second of playback can run
    // at ~2x or ~0.5x speed.
    rateTrim = 1.0;
    audioBufferLevel = 0;
    audioBufferCapacity = 1;
    renderAudioFrameCount = 0;
    // Also drop buffered samples in the worklet so the previous game's
    // audio tail never plays under the new one.
    flushWorkletAudio();

    await initAudio();

    const buffer = await file.arrayBuffer();
    const romBytes = new Uint8Array(buffer);
    const romPtr = e.sandopolis_alloc(romBytes.length);
    if (!romPtr) {
        setStatus("Failed to allocate memory.");
        return;
    }
    new Uint8Array(e.memory.buffer).set(romBytes, romPtr);
    // Detect system from file extension: 0=auto, 1=SMS, 2=GG, 3=SG-1000
    const name = (file.name || "").toLowerCase();
    const systemHint = name.endsWith(".sg") || name.endsWith(".sg.zip") ? 3
        : name.endsWith(".gg") || name.endsWith(".gg.zip") ? 2
            : name.endsWith(".sms") || name.endsWith(".sms.zip") ? 1 : 0;
    emu = e.sandopolis_create(romPtr, romBytes.length, systemHint);
    e.sandopolis_free(romPtr, romBytes.length);
    if (!emu) {
        setStatus("Failed to initialize emulator.");
        return;
    }

    currentRomName = file.name;
    saveRecentRom(file.name, romBytes).then(populateRecentRoms).catch(() => {
    });
    applySettings();

    // Resume AudioContext on user gesture (required by browsers)
    if (audioCtx && audioCtx.state === "suspended" && audioEnabled) {
        audioCtx.resume();
    }

    const isPal = e.sandopolis_is_pal(emu);
    const sysType = e.sandopolis_system_type ? e.sandopolis_system_type(emu) : 0;
    const sysLabel = sysType === 1 ? "SMS" : "Genesis";
    setStatus(`Playing now: ${file.name} (${sysLabel} ${isPal ? "PAL 50Hz" : "NTSC 60Hz"})`);
    if (aboutOpen) updateAboutInfo();

    running = true;
    // Use precise Genesis frame rates to avoid audio drift.
    // NTSC: 53693175 / (262*3420) = 59.9227 fps
    // PAL: 53203424 / (313*3420) = 49.7015 fps
    frameInterval = isPal ? (1000 / 49.7015) : (1000 / 59.9227);
    lastFrameTime = performance.now();
    rafId = requestAnimationFrame(frameLoop);
}

let frameInterval = 1000 / 60;
let lastFrameTime = 0;
// Audio buffer level feedback from the AudioWorklet.
let audioBufferLevel = 0;
let audioBufferCapacity = 1;

function frameLoop(now) {
    if (!running) return;
    rafId = requestAnimationFrame(frameLoop);
    tickEmulator(now);
}

// Frame pacing: fixed-timestep accumulator with audio-driven rate trim.
//
// Emulation is decoupled from the display refresh rate: each rAF tick runs
// however many emulated frames the elapsed wall time calls for (0 to
// MAX_FRAME_STEPS), carrying the fractional remainder forward, so the exact
// console frame rate is held on any panel (60/75/120/144 Hz). Drift between
// the emulator clock and the audio device clock is absorbed by trimming the
// effective frame interval by a fraction of a percent to hold the worklet
// ring buffer at a small fixed level, instead of skipping whole frames.
const MAX_FRAME_STEPS = 3;
// Target buffered audio in interleaved stereo samples at 48kHz (~90 ms).
const AUDIO_TARGET_SAMPLES = 8640;
let rateTrim = 1.0;

function updateRateTrim() {
    if (!audioNode || !audioCtx || audioCtx.state !== "running" || audioBufferCapacity <= 1) {
        rateTrim = 1.0;
        return;
    }
    // Proportional control: buffer above target runs slightly slower so the
    // device drains it, below target slightly faster. Steady-state trim stays
    // well under 0.5%; the 5% clamp only engages while (re)filling after a
    // ROM load or a stall.
    const err = (audioBufferLevel - AUDIO_TARGET_SAMPLES) / AUDIO_TARGET_SAMPLES;
    rateTrim = 1 + Math.max(-0.05, Math.min(0.05, err * 0.05));
}

function tickEmulator(now) {
    if (!running || !emu) return;

    updateRateTrim();
    const effInterval = frameInterval * rateTrim;
    const elapsed = now - lastFrameTime;
    if (elapsed < effInterval) return;

    let steps = Math.floor(elapsed / effInterval);
    if (steps > MAX_FRAME_STEPS) {
        // Long stall (hidden tab, GC pause): drop the backlog instead of
        // fast-forwarding the game to catch up.
        steps = 1;
        lastFrameTime = now;
    } else {
        lastFrameTime += steps * effInterval;
    }

    const e = wasm.instance.exports;
    pollGamepads();
    for (let i = 0; i < steps; i++) {
        e.sandopolis_run_frame(emu);
        renderAudio();
        updateFps();
    }

    const width = e.sandopolis_screen_width(emu);
    const height = e.sandopolis_screen_height(emu);
    const fbPtr = e.sandopolis_framebuffer_ptr(emu);
    const fbLen = e.sandopolis_framebuffer_len(emu);

    if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
        imageData = ctx.createImageData(width, height);
        applyAspectMode();
    }
    if (!imageData) imageData = ctx.createImageData(width, height);

    const fb = new Uint32Array(e.memory.buffer, fbPtr, fbLen);
    const pixels = imageData.data;
    // Framebuffer rows are `stride` pixels apart (320 on Genesis even in 256-wide H32 mode);
    // reading rows packed at `width` shears the image.
    const stride = e.sandopolis_framebuffer_stride(emu);
    for (let y = 0; y < height; y++) {
        const rowBase = y * stride;
        if (rowBase + width > fbLen) break;
        for (let x = 0; x < width; x++) {
            const argb = fb[rowBase + x];
            const off = (y * width + x) * 4;
            pixels[off] = (argb >> 16) & 0xFF;
            pixels[off + 1] = (argb >> 8) & 0xFF;
            pixels[off + 2] = argb & 0xFF;
            pixels[off + 3] = 0xFF;
        }
    }
    ctx.putImageData(imageData, 0, 0);
}

function resumeFrame() {
    lastFrameTime = performance.now();
    rafId = requestAnimationFrame(frameLoop);
}

// Input

function onKeyDown(ev) {
    if (HOTKEYS[ev.key]) {
        ev.preventDefault();
        ({
            quickSave,
            quickLoad,
            save: persistentSave,
            load: persistentLoad,
            fullscreen: toggleFullscreen,
            help: toggleHelp
        })[HOTKEYS[ev.key]]();
        return;
    }
    if (!emu) return;
    const btn = keyMap[ev.code] || keyMap[ev.key];
    if (btn && BUTTONS[btn] !== undefined) {
        ev.preventDefault();
        wasm.instance.exports.sandopolis_set_button(emu, 0, BUTTONS[btn], true);
    }
}

function onKeyUp(ev) {
    if (!emu) return;
    const btn = keyMap[ev.code] || keyMap[ev.key];
    if (btn && BUTTONS[btn] !== undefined) {
        ev.preventDefault();
        wasm.instance.exports.sandopolis_set_button(emu, 0, BUTTONS[btn], false);
    }
}

// Gamepad support (standard mapping: https://w3c.github.io/gamepad/#remapping)

// Per-player edge state, keyed by Genesis button name (not source button index)
// so two source buttons mapping to the same Genesis button OR together rather
// than racing each other on release.
const prevGamepadStates = [{}, {}];

// Standard gamepad button index -> Genesis button (face buttons only).
// Xbox: A=0 B=1 X=2 Y=3 LB=4 RB=5 Start=9 L3=10.
// Genesis bottom row: A B C  top row: X Y Z  plus Start, Mode.
// Multiple source buttons may map to the same Genesis button; pollGamepads
// ORs them so releasing one while another is still held does not falsely
// release the Genesis button.
const GAMEPAD_FACE_MAP = [
    [2, "A"],     // X → Genesis A (leftmost face)
    [0, "B"],     // A → Genesis B (bottom face)
    [1, "C"],     // B → Genesis C (rightmost face)
    [3, "Y"],     // Y → Genesis Y
    [4, "X"],     // LB → Genesis X
    [5, "Z"],     // RB → Genesis Z
    [9, "Start"], // Menu/Start → Genesis Start
    [10, "Start"],// L3 → Genesis Start (alt)
];

const AXIS_THRESHOLD = 0.5;

function releaseAllGamepadButtons() {
    // A disconnected pad (unplug, battery sleep) never sends releases for
    // buttons it held, and stdPlayer compaction can hand its stale edge
    // state to another pad. Release everything and start clean.
    prevGamepadStates[0] = {};
    prevGamepadStates[1] = {};
    if (!emu || !wasm) return;
    const e = wasm.instance.exports;
    for (let player = 0; player < 2; player++) {
        for (const name in BUTTONS) {
            e.sandopolis_set_button(emu, player, BUTTONS[name], false);
        }
    }
}

function pollGamepads() {
    if (!emu) return;
    const xrActive = window.SandopolisVR && window.SandopolisVR.active;
    const gamepads = navigator.getGamepads ? navigator.getGamepads() : [];
    const e = wasm.instance.exports;

    let stdPlayer = 0;
    for (let gi = 0; gi < gamepads.length; gi++) {
        const gp = gamepads[gi];
        if (!gp || !gp.connected) continue;

        // Distinguish real XR hand controllers (which always carry a `hand`
        // field of "left" or "right") from BT gamepads that some Quest
        // browser builds also label "xr-standard". The hand field is the
        // authoritative signal; the mapping string alone is unreliable.
        const isXrHand = gp.hand === "left" || gp.hand === "right";
        if (isXrHand) {
            if (!xrActive) applyXrController(gp);
            continue;
        }
        if (stdPlayer >= 2) continue;

        // Compute the OR of all source buttons mapped to the same Genesis
        // button, then edge-detect by Genesis-button name. Without OR'ing
        // first, releasing one of two co-mapped sources falsely releases the
        // Genesis button while the other source is still held.
        const desired = {};
        for (const [bi, name] of GAMEPAD_FACE_MAP) {
            if (bi >= gp.buttons.length) continue;
            if (BUTTONS[name] === undefined) continue;
            desired[name] = desired[name] || gp.buttons[bi].pressed;
        }
        const prev = prevGamepadStates[stdPlayer];
        for (const name in desired) {
            const isDown = !!desired[name];
            if (prev[name] !== isDown) {
                prev[name] = isDown;
                e.sandopolis_set_button(emu, stdPlayer, BUTTONS[name], isDown);
            }
        }

        const lx = gp.axes.length >= 2 ? gp.axes[0] : 0;
        const ly = gp.axes.length >= 2 ? gp.axes[1] : 0;
        const dp = (i) => gp.buttons.length > i && gp.buttons[i].pressed;
        e.sandopolis_set_button(emu, stdPlayer, BUTTONS.Up, dp(12) || ly < -AXIS_THRESHOLD);
        e.sandopolis_set_button(emu, stdPlayer, BUTTONS.Down, dp(13) || ly > AXIS_THRESHOLD);
        e.sandopolis_set_button(emu, stdPlayer, BUTTONS.Left, dp(14) || lx < -AXIS_THRESHOLD);
        e.sandopolis_set_button(emu, stdPlayer, BUTTONS.Right, dp(15) || lx > AXIS_THRESHOLD);
        stdPlayer++;
    }
}

function isRightXrController(gp) {
    if (gp.hand === "right") return true;
    if (gp.hand === "left") return false;
    return /right/i.test(gp.id || "");
}

function applyXrController(gp) {
    const e = wasm.instance.exports;
    const PLAYER = 0;
    const isRight = isRightXrController(gp);
    const b = (i) => i < gp.buttons.length && gp.buttons[i].pressed;
    // xr-standard layout: [0]=trigger, [1]=grip, [3]=stick press, [4]=A/X, [5]=B/Y.
    // axes[2,3] are the thumbstick on Quest controllers; axes[0,1] would be a trackpad.
    if (isRight) {
        e.sandopolis_set_button(emu, PLAYER, BUTTONS.A, b(4));
        e.sandopolis_set_button(emu, PLAYER, BUTTONS.B, b(5));
        e.sandopolis_set_button(emu, PLAYER, BUTTONS.C, b(0));
        e.sandopolis_set_button(emu, PLAYER, BUTTONS.Start, b(3) || b(1));
    } else {
        e.sandopolis_set_button(emu, PLAYER, BUTTONS.X, b(4));
        e.sandopolis_set_button(emu, PLAYER, BUTTONS.Y, b(5));
        e.sandopolis_set_button(emu, PLAYER, BUTTONS.Z, b(0));
        const sx = gp.axes.length >= 4 ? gp.axes[2] : (gp.axes[0] || 0);
        const sy = gp.axes.length >= 4 ? gp.axes[3] : (gp.axes[1] || 0);
        e.sandopolis_set_button(emu, PLAYER, BUTTONS.Up, sy < -AXIS_THRESHOLD);
        e.sandopolis_set_button(emu, PLAYER, BUTTONS.Down, sy > AXIS_THRESHOLD);
        e.sandopolis_set_button(emu, PLAYER, BUTTONS.Left, sx < -AXIS_THRESHOLD);
        e.sandopolis_set_button(emu, PLAYER, BUTTONS.Right, sx > AXIS_THRESHOLD);
    }
}

// Error banner

function showError(msg) {
    const banner = document.getElementById("error-banner");
    document.getElementById("error-msg").textContent = msg;
    banner.classList.add("visible");
    clearTimeout(banner._timer);
    banner._timer = setTimeout(hideError, 10000);
}

function hideError() {
    document.getElementById("error-banner").classList.remove("visible");
}

// FPS counter

let fpsFrameCount = 0;
let fpsLastTime = performance.now();

function updateFps() {
    fpsFrameCount++;
    const now = performance.now();
    if (now - fpsLastTime >= 1000) {
        const fps = Math.round(fpsFrameCount * 1000 / (now - fpsLastTime));
        document.getElementById("fps-display").textContent = fps + " FPS";
        fpsFrameCount = 0;
        fpsLastTime = now;
    }
}

function setStatus(msg) {
    document.getElementById("status").textContent = msg;
}

init().catch(err => {
    console.error("Sandopolis init failed:", err);
    setStatus("Failed to load emulator.");
    showError("Failed to load WASM module: " + err.message);
});
