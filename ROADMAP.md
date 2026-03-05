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
- [x] Frame Scheduler: Per-line active/HBlank stepping and VBlank interrupt path.
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
- [x] DMA (Basic): 68k->VDP transfer path, fill-trigger, and VRAM copy mode.
- [x] Shadow/Highlight Mode: Full S/H rendering with special sprite palette handling.
- [x] Sprite Limits: Per-line count/dot-overflow limits with x=0 masking.
- [x] H32/H40 Mode: Support for both 256px and 320px display widths.
- [x] Status Register: VInt pending, sprite overflow, and sprite collision flags.
- [x] Interlace Mode 2: Double-resolution tile height support.
- [x] Display Enable: Proper blanking when display bit is cleared.
- [x] VRAM Read Buffer: Prefetch buffer for correct VRAM read behavior.
- [ ] DMA Timing: Cycle-accurate transfer/stall behavior.
- [ ] FIFO Emulation: Write queue with proper timing.
- [ ] VDP Accuracy: Remaining hardware-accurate quirks/conflict behavior.

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
- [x] Controller I/O (Basic): TH cycling and 3/6-button protocol path implemented.
- [ ] Controller I/O (Complete): Full edge-case behavior and broader device coverage.
- [ ] Input Mapping: Configurable keyboard/gamepad binding.
- [ ] SRAM Support: Save game functionality for RPGs.

### Compatibility and Tooling

- [x] Regression Coverage: CPU reset, bus behavior, VDP timing slices, and audio register paths.
- [x] Boot Smoke Test: ROM startup progression check (Sonic test).
- [ ] Timing Accuracy: Cycle-accurate bus timing.
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
