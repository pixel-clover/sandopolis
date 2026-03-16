## Project Roadmap

This document outlines the features implemented in Sandopolis emulator and the future goals for the project.

> [!IMPORTANT]
> This roadmap is a work in progress and is subject to change.

### Core System

- [x] Project scaffolding, SDL3 integration, and memory bus structure
- [x] ROM loading with `.bin`, `.md`, and `.smd` deinterleave support
- [x] M68000 CPU via rocket68 with bus callbacks
- [x] Z80 CPU via jgz80 C bridge with host callbacks
- [x] Frame scheduler with per-line HINT/HBlank/VBlank event handling
- [x] Z80 bus control with BUSREQ/RESET and 68K window gating
- [ ] Per-access 68K/Z80 arbitration and wait-state behavior in shared bus windows

### Video Display Processor

- [x] VDP registers, VRAM/CRAM/VSRAM, and pattern/tile rendering
- [x] Plane A/B with scrolling, sprites with SAT parsing, and priority handling
- [x] DMA with 68K-to-VDP transfers, fill, and VRAM copy
- [x] Shadow/highlight mode with special sprite palette handling
- [x] Sprite limits with per-line count/dot overflow and x=0 masking
- [x] H32/H40 mode, interlace mode 2, display enable blanking, and VRAM read buffer
- [x] Status register with VInt, sprite overflow/collision, and FIFO flags
- [x] DMA timing
- [x] FIFO emulation
- [ ] More hardware-accurate CRAM-dot, border, and mid-scanline timing behavior
- [ ] More hardware-accurate VDP interrupt/status edge cases and DMA/FIFO corner cases
- [ ] Broader validation against demanding hardware demos and VDP-focused test ROMs

### Audio Subsystem

- [x] Audio timing with master-clock accumulation and rate conversion
- [x] Output pipeline with timestamped event application, stereo mixing, and SDL3 playback
- [x] SN76489 PSG with chip-accurate emulation, reachable from both Z80 and M68K paths
- [x] YM2612 FM synthesis with all 8 algorithms, envelope generator, SSG-EG, LFO, channel 3 special mode, DAC, timers, and die-accurate ROM tables
- [x] Audio filtering with low-pass on YM2612 output and DC-blocking on the final mix
- [ ] Reduce remaining YM2612 mismatches against reference output and hardware edge cases
- [ ] Improve final mix, filtering, and resampling to better match the console output character

### Input and Interaction

- [x] Keyboard and gamepad bindings for two players with hotkeys
- [x] Controller I/O with timed TH behavior and 3/6-button protocol
- [x] SRAM support with persistent `.sav` load/store
- [x] Configurable input mapping via a config file with keyboard, gamepad, and analog threshold settings
- [x] Resizable window and fullscreen toggle
- [x] Startup home screen with recent-ROM history and remembered open-directory state
- [x] Modal save manager for persistent state slots with runtime metadata and delete support
- [x] GIF animation recording support
- [x] WAV audio recording (for debugging)
- [x] BMP screenshot capture
- [x] Save-state previews/screenshots, pause, and save-manager flow
- [ ] More controller I/O edge-case coverage and broader peripheral support

### Compatibility and Tooling

- [x] Separate test targets for unit, frontend, integration, regression, and property suites
- [x] Regression test coverage for CPU, bus, VDP, DMA/FIFO, SRAM, and audio paths
- [x] Boot smoke test with ROM startup progression check
- [x] Test ROM collection in `tests/testroms/`
- [x] Deliberate public and testing facades that keep SDL frontend code out of the core runtime path
- [ ] Reduce remaining scheduler, bus, and VDP timing mismatches exposed by hardware test ROMs and stress demos
- [ ] Debugger with single stepping, breakpoints, and register/memory inspection
- [ ] Expand compatibility regression coverage with broader external ROM and test-ROM suites

### Future Goals

- [ ] Sega CD and 32X subsystem support
- [ ] Browser/WebAssembly build and frontend path
- [ ] Libretro core packaging and integration
