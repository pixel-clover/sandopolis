## Project roadmap

This document outlines the features implemented in Sandopolis emulator and the future goals for the project.

> [!IMPORTANT]
> This roadmap is a work in progress and is subject to change.

### Core system

- [x] Project scaffolding, SDL3 integration, and memory bus structure
- [x] ROM loading with `.bin`, `.md`, and `.smd` deinterleave support
- [x] M68000 CPU via rocket68 with bus callbacks
- [x] Z80 CPU via jgz80 C bridge with host callbacks
- [x] Frame scheduler with per-line HINT/HBlank/VBlank event handling
- [x] Z80 bus control with BUSREQ/RESET and 68K window gating
- [ ] Complete memory mapping with remaining mirror/open-bus edge behavior
- [ ] Accurate bus arbitration; per-access Z80/68K contention is modeled but full cycle-accurate mid-instruction arbitration is incomplete

### Video display processor

- [x] VDP registers, VRAM/CRAM/VSRAM, and pattern/tile rendering
- [x] Plane A/B with scrolling, sprites with SAT parsing, and priority handling
- [x] DMA with 68K-to-VDP transfers, fill, and VRAM copy
- [x] Shadow/highlight mode with special sprite palette handling
- [x] Sprite limits with per-line count/dot overflow and x=0 masking
- [x] H32/H40 mode, interlace mode 2, display enable blanking, and VRAM read buffer
- [x] Status register with VInt, sprite overflow/collision, and FIFO flags
- [ ] DMA timing; startup delay, CPU halting, and replay delay are modeled but cycle-accurate stall behavior is incomplete
- [ ] FIFO emulation; queueing with access-slot timing and wait accounting are implemented but per-access timing is incomplete
- [ ] VDP accuracy; HV/status timing is mode-aware but remaining hardware quirks and exact port timing are incomplete

### Audio subsystem

- [x] Audio timing with master-clock accumulation and rate conversion
- [x] Output pipeline with timestamped event application, stereo mixing, and SDL3 playback
- [x] SN76489 PSG with chip-accurate emulation, reachable from both Z80 and M68K paths
- [x] YM2612 FM synthesis with all 8 algorithms, envelope generator, SSG-EG, LFO, channel 3 special mode, DAC, timers, and die-accurate ROM tables
- [x] Audio filtering with low-pass on YM2612 output and DC-blocking on the final mix
- [ ] YM2612 accuracy; remaining edge-case phase/rate/timer behavior is incomplete
- [ ] Audio fidelity; per-channel panning differences and analog output stage modeling

### Input and interaction

- [x] Keyboard and gamepad bindings for two players with hotkeys
- [x] Controller I/O with timed TH behavior and 3/6-button protocol
- [x] SRAM support with persistent `.sav` load/store
- [x] Configurable input mapping via config file with keyboard, gamepad, and analog threshold settings
- [x] Resizable window and fullscreen toggle
- [x] GIF animation recording support
- [ ] Input management polish; UI, profiles, and device management are incomplete
- [ ] Controller I/O edge cases and broader device coverage

### Compatibility and tooling

- [x] Separate test targets for unit, frontend, integration, regression, and property suites
- [x] Regression test coverage for CPU, bus, VDP, DMA/FIFO, SRAM, and audio paths
- [x] Boot smoke test with ROM startup progression check
- [x] Test ROM collection in `tests/testroms/`
- [ ] Timing accuracy; slice-based scheduling still needs cycle-interleaved bus timing
- [ ] Debugger: register views and disassembler are done; memory editor and VDP viewer are not
- [ ] Compatibility test suite against broad external test ROM suites

### Future goals

- [ ] Sega CD / 32X (long term)
- [ ] WebAssembly build
- [ ] Libretro core
