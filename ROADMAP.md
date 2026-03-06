## Project Roadmap

This document outlines the features implemented in Sandopolis emulator and the future goals for the project.

> [!IMPORTANT]
> This roadmap is a work in progress and is subject to change.
> Checkbox meaning:
> - `[x]` implemented and wired into the current emulator flow.
> - `[ ]` incomplete, partial, or not yet hardware-accurate.

### Core System

- [x] Project Scaffolding: Build system, SDL3 integration, memory bus structure.
- [x] ROM Loading: `.bin` / `.md` loading and `.smd` deinterleave support.
- [x] M68000 CPU Integration: Rocket68 C core wired through Sandopolis bus callbacks.
- [x] Frame Scheduler: Chunked master-clock stepping with per-line mode-aware HINT/HBlank events and VBlank interrupt path.
- [x] Z80 Core Integration: jgz80 bridge with host callbacks.
- [x] Z80 Bus Control (Basic): BUSREQ/RESET registers and 68k window gating.
- [ ] Memory Mapping (Complete): Remaining mirror/open-bus/edge behavior.
- [ ] Bus Arbitration (Accurate): Cycle-accurate 68k/Z80 contention behavior.

### Video Display Processor

- [x] VDP Registers: Implement mode registers, scroll data, DMA configuration.
- [x] VRAM / CRAM / VSRAM: Memory storage for tiles, palettes, and scroll data.
- [x] Pattern/Tile Rendering: Decoding 4bpp tiles.
- [x] Plane A / Plane B: Background layer rendering with scrolling and priority passes.
- [x] Sprites: SAT parsing and line rendering with priority pass.
- [x] DMA (Basic): 68k->VDP transfer path, fill-trigger, VRAM copy mode, and VDP-owned transfer progression.
- [x] Shadow/Highlight Mode: Full S/H rendering with special sprite palette handling.
- [x] Sprite Limits: Per-line count/dot-overflow limits with x=0 masking.
- [x] H32/H40 Mode: Support for both 256px and 320px display widths.
- [x] Status Register: VInt pending, sprite overflow, sprite collision, and FIFO empty/full flags.
- [x] Interlace Mode 2: Double-resolution tile height support.
- [x] Display Enable: Proper blanking when display bit is cleared.
- [x] VRAM Read Buffer: Prefetch buffer for correct VRAM read behavior.
- [ ] DMA Timing: Memory-to-VRAM startup delay, non-fill DMA CPU halting, and post-DMA replay delay are modeled; cycle-accurate transfer/stall behavior remains incomplete.
- [ ] FIFO Emulation: FIFO queueing, status bits, write-side wait accounting, read-side drain waits, and queued-read prefetch behavior are implemented; remaining per-access timing/control-port behavior is incomplete.
- [ ] VDP Accuracy: Mode-aware HV/status timing has improved; remaining hardware-accurate quirks, conflict behavior, exact port timing, and broader open-bus behavior are still incomplete.

### Audio Subsystem

- [x] Z80 CPU Core: jgz80 integrated via C bridge.
- [x] Audio Timing: Master-clock accumulation into FM/PSG frame counts.
- [x] Mixer: Audio output integration via SDL3.
- [x] Basic FM/PSG Output: Synthesized output from latched YM/PSG register state.
- [ ] SN76489 (PSG): Chip-accurate emulation.
- [ ] YM2612 (FM): Chip-accurate 6-channel FM emulation.
- [ ] Audio Fidelity: Hardware-faithful mixing/filter/timing behavior.

### Input and Interaction

- [x] Input Mapping (Basic): Keyboard and gamepad mapped to player 1 controls.
- [x] Controller I/O (Basic): Timed TH behavior and 3/6-button protocol path implemented.
- [ ] Controller I/O (Complete): Full edge-case behavior and broader device coverage.
- [ ] Input Mapping: Player 1/player 2 keyboard/gamepad bindings and keyboard hotkeys are configurable via `sandopolis_input.cfg` or `SANDOPOLIS_INPUT_CONFIG`; UI/profile/device-management polish is still incomplete.
- [x] SRAM Support: Header-driven and checksum-forced cartridge SRAM with persistent `.sav` load/store.

### Compatibility and Tooling

- [x] Regression Coverage: CPU reset, bus behavior, VDP timing slices, DMA/FIFO/control-port timing checks, SRAM persistence, and audio register paths.
- [x] Boot Smoke Test: ROM startup progression check (Sonic test).
- [ ] Timing Accuracy: Slice-based scheduling still needs cycle-interleaved bus timing despite mode-aware per-line event points.
- [ ] Debugger:
    - [ ] Register views.
    - [ ] Disassembler.
    - [ ] Memory editor.
    - [ ] VDP viewer (Tile/Sprite debugger).
- [ ] Compatibility Test Suite: Pass broad external test ROM suites (e.g., acid tests).

### Future Goals

- [ ] Sega CD / 32X (Long term).
- [ ] WebAssembly Build: Run Sandopolis in the browser.
- [ ] Libretro Core: Integration with RetroArch.
