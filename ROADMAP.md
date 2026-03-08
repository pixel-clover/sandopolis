## Project roadmap

This document outlines the features implemented in Sandopolis emulator and the future goals for the project.

> [!IMPORTANT]
> This roadmap is a work in progress and is subject to change.

### Core system

- [x] Project scaffolding: Build system, SDL3 integration, memory bus structure.
- [x] ROM loading: `.bin` / `.md` loading and `.smd` deinterleave support.
- [x] M68000 CPU integration: Rocket 68 core is wired through Sandopolis bus callbacks.
- [x] Frame scheduler: Chunked master-clock stepping with per-line mode-aware HINT/HBlank events and VBlank interrupt path.
- [x] Z80 core integration: jgz80 bridge with host callbacks.
- [x] Z80 bus control (basic): BUSREQ/RESET registers and 68k window gating.
- [ ] Memory mapping (complete): Remaining mirror/open-bus/edge behavior.
- [ ] Bus arbitration (accurate): Per-access Z80→68K contention with interleaved VDP progression is modeled; full cycle-accurate mid-instruction arbitration remains incomplete.

### Video display processor

- [x] VDP registers: Implement mode registers, scroll data, DMA configuration.
- [x] VRAM / CRAM / VSRAM: Memory storage for tiles, palettes, and scroll data.
- [x] Pattern/tile rendering: Decoding 4bpp tiles.
- [x] Plane A / Plane B: Background layer rendering with scrolling and priority passes.
- [x] Sprites: SAT parsing and line rendering with priority pass.
- [x] DMA (basic): 68k->VDP transfer path, fill-trigger, VRAM copy mode, and VDP-owned transfer progression.
- [x] Shadow/highlight mode: Full S/H rendering with special sprite palette handling.
- [x] Sprite limits: Per-line count/dot-overflow limits with x=0 masking.
- [x] H32/H40 mode: Support for both 256px and 320px display widths.
- [x] Status register: VInt pending, sprite overflow, sprite collision, and FIFO empty/full flags.
- [x] Interlace mode 2: Double-resolution tile height support.
- [x] Display enable: Proper blanking when the display bit is cleared.
- [x] VRAM read buffer: Prefetch buffer for correct VRAM read behavior.
- [ ] DMA timing: Memory-to-VRAM startup delay, non-fill DMA CPU halting with mode-aware halt quantum, and post-DMA replay delay are modeled; cycle-accurate transfer/stall behavior remains incomplete.
- [ ] FIFO emulation: FIFO queueing with mode-aware access slot timing (H32/H40, active/blanking), status bits, write-side wait accounting, read-side drain waits, and queued-read prefetch behavior are implemented; remaining per-access timing/control-port behavior is incomplete.
- [ ] VDP accuracy: Mode-aware HV/status timing has improved; remaining hardware-accurate quirks, conflict behavior, exact port timing, and broader open-bus behavior are still incomplete.

### Audio subsystem

- [x] Z80 CPU core: jgz80 integrated via C bridge.
- [x] Audio timing: Master-clock accumulation into FM/PSG frame counts.
- [x] Mixer: Audio output integration via SDL3.
- [x] FM/PSG output: Chunked rendering pipeline with per-event timestamped write application, rate conversion, and stereo mixing via SDL3.
- [x] SN76489 (PSG): Chip-accurate emulation (ported from clownmdemu-core). Reachable from both Z80 (`0x7F11`) and M68K (VDP port `0xC00011`).
- [x] YM2612 (FM): 6-channel FM synthesis with all 8 algorithms, ADSR envelopes with key scaling, SSG-EG envelope modes, LFO AM/FM, channel 3 special mode, DAC, timer A/B with CSM mode, die-accurate logsin/exp ROM tables, and full 24-slot internal clock cycle model.
- [ ] YM2612 accuracy: Remaining chip-accurate edge-case phase/rate/timer behavior is incomplete.
- [x] Audio filtering: 2nd-order biquad low-pass filter (~8.5 kHz) on YM2612 output and DC-blocking high-pass filters (~20 Hz) on the final mix.
- [ ] Audio fidelity: Remaining hardware-faithful mixing/filter/timing behavior (e.g., per-channel panning differences, analog output stage modeling).

### Input and interaction

- [x] Input mapping (basic): Default keyboard bindings for player 1/player 2, default gamepad bindings for the first two controllers, and keyboard hotkeys.
- [x] Controller I/O (basic): Timed TH behavior and 3/6-button protocol path implemented.
- [ ] Controller I/O (complete): Per-port 3-button/6-button controller selection is configurable, and the frontend now has a basic raw SDL joystick fallback for non-gamepad controllers; full edge-case behavior and broader device coverage remain incomplete.
- [ ] Input mapping: Player 1/player 2 keyboard/gamepad bindings, keyboard hotkeys, and analog thresholds are configurable via `sandopolis_input.cfg` or `SANDOPOLIS_INPUT_CONFIG`; UI/profile/device-management polish is still incomplete.
- [x] SRAM support: Header-driven and checksum-forced cartridge SRAM with persistent `.sav` load/store.

### Compatibility and tooling

- [x] Regression coverage: CPU reset, bus behavior, VDP timing slices, DMA/FIFO/control-port timing checks, SRAM persistence, and audio register paths.
- [x] Boot smoke test: ROM startup progression check (Sonic test).
- [ ] Timing accuracy: Slice-based scheduling still needs cycle-interleaved bus timing despite mode-aware per-line event points.
- [ ] Debugger:
    - [x] Register views.
    - [x] Disassembler.
    - [ ] Memory editor.
    - [ ] VDP viewer (Tile/Sprite debugger).
- [x] Test ROM collection: Community/public-domain hardware verification ROMs in `tests/testroms/`.
- [ ] Compatibility test suite: Pass broad external test ROM suites (e.g., acid tests).

### Future goals

- [ ] Sega CD / 32X (long term).
- [ ] WebAssembly build: Run Sandopolis in the browser.
- [ ] Libretro core: Integration with RetroArch.
