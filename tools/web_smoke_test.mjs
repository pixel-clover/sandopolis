// End-to-end smoke test for the browser frontend.
//
// The shader harnesses load web/scene3d.js directly and so never execute
// web/sandopolis.js. That gap once let a deleted function ship: `node --check`
// saw valid syntax, every harness passed, and the 3D view rendered nothing in
// the actual page. This test drives the real page in headless Chromium over
// the DevTools Protocol and fails on any uncaught exception, which is the only
// place that class of bug shows up.
//
// Usage: node tools/web_smoke_test.mjs [--rom PATH] [--keep]
//
// Requires `make web` to have been run. Needs an SMS or Game Gear ROM to
// exercise the 3D path; without one those checks are skipped, not failed,
// because roms/ is deliberately absent from the repository.

import fs from "node:fs";
import path from "node:path";
import http from "node:http";
import {spawn, execSync} from "node:child_process";

const args = process.argv.slice(2);
const romArg = args.includes("--rom") ? args[args.indexOf("--rom") + 1] : null;
const keep = args.includes("--keep");

const WEB_DIR = path.resolve("web");
const MIME = {
    ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
    ".wasm": "application/wasm", ".json": "application/json",
    ".css": "text/css", ".png": "image/png", ".ttf": "font/ttf",
};

const failures = [];
const notes = [];
function check(name, ok, detail) {
    console.log(`  ${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  (" + detail + ")" : ""}`);
    if (!ok) failures.push(name);
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

function findRom() {
    if (romArg) return romArg;
    for (const dir of ["roms", "tests/testroms"]) {
        if (!fs.existsSync(dir)) continue;
        const hit = fs.readdirSync(dir).find(f => /\.(sms|gg|sg)$/i.test(f));
        if (hit) return path.join(dir, hit);
    }
    return null;
}

function findChromium() {
    for (const bin of ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable"]) {
        try {
            execSync(`command -v ${bin}`, {stdio: "pipe"});
            return bin;
        } catch { /* try the next candidate */ }
    }
    return null;
}

// -- static server -----------------------------------------------------------

const server = http.createServer((req, res) => {
    const rel = decodeURIComponent(req.url.split("?")[0]).replace(/^\/+/, "") || "index.html";
    const file = path.join(WEB_DIR, rel);
    if (!file.startsWith(WEB_DIR) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
        res.writeHead(404).end("not found");
        return;
    }
    res.writeHead(200, {
        "Content-Type": MIME[path.extname(file)] || "application/octet-stream",
        "Cache-Control": "no-store",
    });
    fs.createReadStream(file).pipe(res);
});
await new Promise(r => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

if (!fs.existsSync(path.join(WEB_DIR, "sandopolis.wasm"))) {
    console.error("web/sandopolis.wasm is missing. Run `make web` first.");
    server.close();
    process.exit(2);
}

// -- browser -----------------------------------------------------------------

const chromium = findChromium();
if (!chromium) {
    console.error("No Chromium or Chrome binary found; cannot run the web smoke test.");
    server.close();
    process.exit(2);
}

// A snap-confined Chromium silently ignores a --user-data-dir outside its
// sandbox and falls back to the default profile, which fails to start whenever
// the user already has Chromium open (the profile's SingletonLock is held).
// Keep the throwaway profile inside the snap's writable area when it exists,
// so the test never contends with a running browser.
const snapCommon = path.join(process.env.HOME || "", "snap", "chromium", "common");
const profileDir = fs.existsSync(snapCommon)
    ? path.join(snapCommon, "sandopolis-smoke")
    : path.join(process.env.HOME || ".", ".cache", "sandopolis-smoke");
fs.rmSync(profileDir, {recursive: true, force: true});
// Chromium under snap refuses --remote-debugging-port=0, so pick a port and
// poll for readiness instead of parsing stderr for the endpoint.
const debugPort = 9500 + Math.floor(Math.random() * 400);
const browser = spawn(chromium, [
    "--headless=new", "--no-sandbox", "--disable-gpu", "--enable-unsafe-swiftshader",
    "--hide-scrollbars", `--remote-debugging-port=${debugPort}`,
    `--user-data-dir=${profileDir}`, "about:blank",
], {stdio: ["ignore", "ignore", "pipe"]});

let browserExit = null;
browser.on("exit", c => { browserExit = c; });

const cdpHost = `127.0.0.1:${debugPort}`;
{
    const deadline = Date.now() + 30000;
    for (;;) {
        if (browserExit !== null) throw new Error("browser exited early, code " + browserExit);
        try {
            const r = await fetch(`http://${cdpHost}/json/version`);
            if (r.ok) break;
        } catch { /* not listening yet */ }
        if (Date.now() > deadline) throw new Error("timed out waiting for DevTools on " + cdpHost);
        await sleep(250);
    }
}

// Teardown must never turn a passing run into a failure. The killed browser
// can still be flushing its profile directory, so removal is retried and any
// leftover is tolerated.
function cleanup() {
    try { browser.kill("SIGKILL"); } catch { /* already gone */ }
    try { server.close(); } catch { /* already closed */ }
    if (keep) return;
    try {
        fs.rmSync(profileDir, {recursive: true, force: true, maxRetries: 10, retryDelay: 50});
    } catch { /* a stale scratch profile is harmless */ }
}
process.on("exit", cleanup);

const targets = await (await fetch(`http://${cdpHost}/json/list`)).json();
const page = targets.find(t => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener("open", r, {once: true}));

let nextId = 1;
const pending = new Map();
const pageErrors = [];
ws.addEventListener("message", e => {
    const m = JSON.parse(e.data);
    if (m.method === "Runtime.exceptionThrown") {
        const d = m.params.exceptionDetails;
        pageErrors.push(String(d.exception?.description || d.text).split("\n")[0]);
    }
    if (m.id && pending.has(m.id)) {
        const {resolve, reject} = pending.get(m.id);
        pending.delete(m.id);
        m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result);
    }
});
const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, {resolve, reject});
    ws.send(JSON.stringify({id, method, params}));
});
async function ev(expression) {
    const r = await send("Runtime.evaluate", {expression, awaitPromise: true, returnByValue: true});
    if (r.exceptionDetails) {
        throw new Error(String(r.exceptionDetails.exception?.description || r.exceptionDetails.text).split("\n")[0]);
    }
    return r.result.value;
}

// -- checks ------------------------------------------------------------------

console.log(`\nweb smoke test  (chromium: ${chromium}, port ${port})\n`);

await send("Runtime.enable");
await send("Network.enable");
await send("Network.setCacheDisabled", {cacheDisabled: true});
await send("Page.enable");
await send("Page.navigate", {url: `http://127.0.0.1:${port}/index.html`});
await sleep(4000);

// `wasm` is a top-level `let` in a classic script, so it lives in the global
// lexical environment and is not a property of `window`.
check("page loads and instantiates the core",
    await ev(`typeof wasm !== "undefined" && !!(wasm && wasm.instance && wasm.instance.exports.sandopolis_create)`));
check("scene3d.js is present", await ev(`!!window.SandopolisScene3D`));

const coreVer = await ev(`wasm.instance.exports.sandopolis_scene_layout_version()`);
const jsVer = await ev(`window.SandopolisScene3D.LAYOUT_VERSION`);
check("scene layout version agrees between core and JS", coreVer === jsVer, `core ${coreVer}, js ${jsVer}`);

const rom = findRom();
if (!rom) {
    notes.push("No .sms or .gg ROM found, so the 3D checks were skipped. Pass --rom PATH to run them.");
} else {
    const b64 = fs.readFileSync(rom).toString("base64");
    const ext = rom.toLowerCase().match(/\.(sms|gg|sg)$/);
    const name = "smoke" + (ext ? ext[0] : ".sms");
    await ev(`(async () => {
        const bin = atob("${b64}");
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        const dt = new DataTransfer();
        dt.items.add(new File([bytes], "${name}"));
        const input = document.getElementById("rom-input");
        input.files = dt.files;
        input.dispatchEvent(new Event("change", {bubbles: true}));
        return true;
    })()`);
    await sleep(5000);

    check("ROM loads and the emulator runs",
        await ev(`!!emu && wasm.instance.exports.sandopolis_frame_count(emu) > 60`),
        path.basename(rom));
    check("scene extraction returns content",
        await ev(`wasm.instance.exports.sandopolis_scene_extract(emu) === 1`));
    check("3D toggle is enabled", await ev(`!document.getElementById("btn-3d").disabled`));

    // Measure the flat picture before switching, so both views describe the
    // same emulator state.
    await ev(`window.__lum = (px) => {
        const v = [];
        for (let i = 0; i < px.length; i += 4) {
            const l = 0.2126*px[i] + 0.7152*px[i+1] + 0.0722*px[i+2];
            if (l > 24) v.push(l);
        }
        if (!v.length) return {p90: 0, frac: 0};
        v.sort((a,b) => a-b);
        return {p90: +v[Math.floor(v.length*0.9)].toFixed(1), frac: +(v.length/(px.length/4)).toFixed(4)};
    }; true`);
    const flat = await ev(`(() => { const c = document.getElementById("screen");
        return window.__lum(c.getContext("2d").getImageData(0,0,c.width,c.height).data); })()`);

    await ev(`document.getElementById("btn-3d").click()`);
    await sleep(1500);
    check("3D mode activates", await ev(`document.getElementById("screen-container").classList.contains("mode-3d")`));

    // Draw and read back in one task: a WebGL canvas without
    // preserveDrawingBuffer reads back blank once the frame has composited.
    const three = await ev(`(() => {
        const c = document.getElementById("screen3d");
        const gl = c.getContext("webgl2");
        window.sandopolisScene3D.faceOn();
        window.sandopolisScene3D.redraw();
        const px = new Uint8Array(4 * c.width * c.height);
        gl.readPixels(0, 0, c.width, c.height, gl.RGBA, gl.UNSIGNED_BYTE, px);
        return window.__lum(px);
    })()`);
    check("3D view renders something", three.frac > 0.002, `coverage ${three.frac}`);

    // Guards the slice-shading regression that dimmed every tile top.
    const ratio = flat.p90 > 0 ? three.p90 / flat.p90 : 0;
    check("3D brightness matches the flat picture", ratio > 0.9,
        `p90 flat ${flat.p90} vs 3D ${three.p90}`);

    const stats = await ev(`JSON.stringify(window.sandopolisScene3D.stats())`);
    check("renderer reports draw activity",
        !!stats && JSON.parse(stats).drawCalls > 0, stats);
}

const unique = [...new Set(pageErrors)];
check("no uncaught page exceptions", unique.length === 0,
    unique.length ? unique.join(" | ") : "none");

for (const n of notes) console.log(`\n  note: ${n}`);
console.log(`\n${failures.length ? "FAILED: " + failures.join(", ") : "all checks passed"}\n`);
ws.close();
process.exit(failures.length ? 1 : 0);
