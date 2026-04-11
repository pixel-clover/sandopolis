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
- [x] Coarse-grain 68K/Z80 bus arbitration with wait-state delays for Z80 window access
- [x] Per-access wait cycle tracking for the VDP FIFO and the Z80 window within multi-access instructions
- [x] Sub-instruction Z80 timing advancement during 68K multi-access instructions
- [x] Deferred Z80 burst execution per scheduler slice, matching the per-line model
- [x] Z80 bank-access stall and M68K contention aligned with expected cycle counts
- [x] Dynamic arbitration during VDP DMA with shared bus windows (feature-gated; matches reference's complete-halt model by default, with optional
  per-refresh-slot 68K bus windows via `clock.enable_dma_refresh_windows`)

### Video Display Processor

- [x] VDP registers, VRAM/CRAM/VSRAM, and pattern/tile rendering
- [x] Plane A/B with scrolling (full-screen, per-8-line, per-column), window plane, and priority handling
- [x] Sprites with SAT parsing, 7-layer priority, per-line count/dot overflow, and x=0 masking
- [x] DMA with 68K-to-VDP transfers, fill, VRAM copy, access-slot-accurate timing, and 128K source-window wrapping
- [x] FIFO emulation with 4-entry queue, latency tracking, and write-ahead projection
- [x] Shadow/highlight mode with special sprite palette handling
- [x] H32/H40 mode, interlace mode 2, display enable blanking, and VRAM read buffer
- [x] Status register with VInt, sprite overflow/collision, FIFO flags, and HV counter-latch
- [x] Pre-line sprite overflow detection visible to CPU during scanline execution
- [x] CRAM pixel-granule updates during active display (CRAM dot behavior) with immediate writes bypassing FIFO latency
- [x] HBlank CRAM palette-per-line updates with per-scanline undo/redo rendering (shadow/highlight aware)
- [x] Mid-scanline register change re-scan (backdrop, display enable, palette mode, display mode, plane base, scroll mode, window split)
- [x] Right-edge border rendering and overscan area coloring
- [x] HInt/VInt priority ordering when both are pending on the same line
- [x] Sprite horizontal wrap-around and clip-box edge cases at screen boundaries
- [x] Validation: TiTAN Overdrive 2 golden framebuffer hash after 100 frames
- [x] Validation: `cram_flicker.bin` test ROM produces visible CRAM dot artifacts
- [x] Validation: V counter-jump points and monotonicity (NTSC threshold 0xEA, PAL thresholds 0x102/0x10A)
- [x] Validation: `vctest.bin` golden framebuffer hash after 60 frames

### Audio Subsystem

- [x] Audio timing with master-clock accumulation and rate conversion
- [x] Output pipeline with timestamped event application, cubic hermite resampling, stereo mixing, and SDL3 playback
- [x] Band-limited sample buffer (blip_buf) ported to Zig for use as an alternative resampler
- [x] 3-band parametric equalizer (low/mid/high gain) as an optional post-processing stage
- [x] SN76489 PSG with chip-accurate emulation, stereo panning, reachable from both Z80 and M68K paths
- [x] YM2612 FM synthesis with all 8 algorithms, envelope generator, SSG-EG, LFO, channel 3 special mode, DAC, CSM, timers, and die-accurate ROM
  tables
- [x] Sample-based YM2612 Zig core (`ym2612_sample.zig`) as runtime FM engine, output levels matching reference within 2%
- [x] YM2612 DAC ladder effect modeling with discrete/integrated/enhanced chip types
- [x] SN76489 PSG bipolar output with reference-matched volume table (max 2800, 2 dB steps)
- [x] Audio filtering with board analog LPF (fc ≈ 3585 Hz, coefficient adjusted for 48 kHz output) and blip-buffer DC-blocking
- [x] Debug render modes (YM-only, PSG-only, unfiltered mix)
- [x] Compare YM2612 output against Nuked-OPN2 reference (26 scenarios: tones, pan, DAC, LFO, CSM, SSG-EG, detune, EG, timers, status; all exact
  match)
- [x] ROM-backed YM2612 synthesis golden hash from FM Test ROM (120-frame capture, Ym2612Synth replay)
- [x] ROM-backed YM2612 register stream comparison for a few titles (Sonic & Knuckles, Streets of Rage, and Warsong; 300-frame golden hashes)
- [x] CSM mode synthesis validation against Nuked-OPN2 (4 scenarios: basic, rapid retriggering, param change, and all algorithms)
- [x] Active rendering path switch from cubic hermite resampling to blip-buffer band-limited synthesis
- [x] PSG/FM gain balance validated via end-to-end audio pipeline golden hash (120-frame FM Test ROM)

### Input and Interaction

- [x] Keyboard and gamepad bindings for two players with hotkeys
- [x] Controller I/O with timed TH behavior and 3/6-button protocol
- [x] SRAM support with persistent `.sav` load/store, write-protect register, and I2C EEPROM (24Cxx series)
- [x] TMSS (Trademark Security System) register gating VDP access
- [x] Configurable input mapping via a config file with keyboard, gamepad, and analog threshold settings
- [x] Resizable window and fullscreen toggle
- [x] Startup home screen with recent-ROM history and remembered open-directory state
- [x] Modal save manager for persistent state slots with runtime metadata and delete support
- [x] GIF animation recording, WAV audio recording, and BMP screenshot capture
- [x] Save-state previews/screenshots and pause the flow
- [x] EA 4-Way Play multitap adapter (4-player support)
- [x] Sega Mouse peripheral support with 8-nibble TH-toggle protocol
- [x] 6-button controller TH counter reset timing edge cases (pull-up transition counting, mid-identification timeout)

### Compatibility and Tooling

- [x] Separate test targets for unit, frontend, integration, regression, and property suites
- [x] Regression test coverage for CPU, bus, VDP, DMA/FIFO, SRAM, and audio paths
- [x] Boot smoke test with ROM startup progression check
- [x] Test ROM collection in `tests/testroms/`
- [x] Deliberate public and testing facades that keep SDL frontend code out of the core runtime path
- [x] Debugger: M68K single stepping with F10, register display (D0-D7, A0-A7, PC, SR flags)
- [x] Debugger: memory hex dump viewer with page navigation
- [x] Debugger: VDP state viewer (24 registers, mode/scanline/flags, DMA status)
- [x] Debugger: instruction-level breakpoints with toggle (B), run-to-breakpoint (G), and visual markers
- [x] Debugger: tile and palette visualizer (CRAM palette grid and VRAM tile pattern viewer with palette 0)
- [x] Regression coverage for all community test ROMs (vctest, CRAM flicker, memtest, shadow/highlight, TEST1536, Overdrive 2, Multitap IO,
  DisableRegTestROM)
- [x] ROM header checksum validation and product code extraction
- [x] Game database lookup for extended metadata (26 titles by product code)
- [ ] Regression suite expansion with Ings VDP tests
- [x] Shadow/highlight priority fix: high-priority background and window tiles promote pixels from shadow to normal brightness
- [x] Street Fighter II Special Champion Edition graphics corruption (lazy SSF mapper activation on bank register write)
- [ ] Ultimate Mortal Kombat Trilogy romhack loading failure on desktop (works on web)
- [x] Color cycling artifacts during screen transitions (root cause: VBlank status flag bug on last scanline; fixed alongside Zabu crash)

### Future Goals

- [x] Browser/WebAssembly build with Canvas rendering, keyboard input, and Web Audio playback (`zig build wasm`, `web/`)
- [x] Browser save states with IndexedDB persistence and in-memory quick save/load
- [x] Browser settings panel with audio mode, PSG volume, 3-band equalizer, controller type, aspect ratio, and CRT screen effect
- [x] Browser gamepad support with standard and raw mapping fallback (2 players)
- [x] Browser performance HUD, about panel, and Genesis/Zig-themed UI with light/dark modes
- [x] Docker image for Sandopolis Web (`Dockerfile`, published to GHCR)
- [x] Libretro core packaging (`zig build libretro`, shared library with all 25 API functions)
- [x] Browser keyboard remapping UI with localStorage persistence and duplicate-swap
- [x] Browser integer scaling mode (whole-pixel multiples)
- [x] Desktop integer scaling and pixel-perfect aspect ratio correction (nearest-neighbor texture filtering)
- [x] Tooltip help text on web controls and context-sensitive hint line in desktop settings
- [ ] Browser CRT shader option
- [ ] NTSC composite video filter (Blargg's or equivalent)
- [ ] Game Gear LCD ghosting emulation
- [ ] Anti-dither shader
- [x] SG-1000 subsystem support (TMS9918A VDP Modes 0-3, 1KB RAM bus, TMS sprite rendering)
- [ ] Sega CD subsystem support
- [ ] 32X subsystem support
- [ ] Sega Pico subsystem support
- [ ] Cheat code support (Game Genie and Action Replay)
- [ ] Lock-on cartridge emulation (like Sonic & Knuckles)
- [ ] Rewind functionality (per-frame state history)
- [ ] CPU overclocking options

### Input Peripherals

- [ ] Light guns (Sega Light Phaser, Menacer, and Konami Justifiers)
- [ ] Sega Paddle Control
- [ ] Sega Sports Pad
- [ ] XE-1AP analog controller
- [ ] Sega Activator

### Sega Master System Support

- [x] Z80 bridge SMS mode: host-routed memory, I/O port callbacks, NMI assertion (`jgz80_bridge.c`)
- [x] SMS VDP Mode 4: 16KB VRAM, 32-byte CRAM, 11 registers, background, and sprite rendering
- [x] SMS bus with Sega mapper (3 page registers, cartridge RAM banking)
- [x] SMS I/O port dispatch with partial address decoding (VDP, PSG, controllers)
- [x] SMS controller input (2 buttons per player, pause via NMI)
- [x] SMS cartridge detection ("TMR SEGA" header) and system auto-detection (`system.zig`)
- [x] SMS machine coordinator with Z80-only frame loop (228 cycles per scanline, 262/313 lines)
- [x] PSG-only audio pipeline reusing the existing SN76489 implementation
- [x] SystemMachine tagged union abstracting Genesis and SMS for the SDL frontend
- [x] WASM layer SMS support with system auto-detection and button mapping
- [x] Web and desktop file dialogs accept `.sms` extension
- [x] VDP sprite collision flag and overflow detection
- [x] Sprite pattern base address fix (bit 2 of register 6 selects 0x0000/0x2000)
- [x] SMS-specific keyboard and gamepad input binding in the SDL frontend
- [x] VDP rendering accuracy: horizontal scroll, vertical scroll wrapping, scroll lock columns
- [x] Extended display modes (224-line and 240-line) with mode detection
- [x] I/O control register (port 0x3F) TH pin direction/level reflected in port 0xDD reads (region/nationality detection)
- [x] VDP rendering accuracy: fine scroll sub-tile edge cases
- [x] Game-specific: Disney's Aladdin black screen fix via immediate Z80 IRQ de-assertion on VDP status read (prevents spurious interrupt re-trigger
  from stale level-triggered assertion)
- [x] Game Gear support: 12-bit CRAM (two-byte sequential writes), 160x144 viewport, START button via port 0x00, PSG stereo via port 0x06, system
  auto-detection from cartridge region codes
- [x] SMS quick save states (in-memory capture and restore of Z80, VDP, bus, and audio state)
- [x] SMS persistent save states (file-based serialization with source path, Z80, VDP, bus, and audio state)
- [ ] Korean mapper variants (MSX, Nemesis, and Janggun)
- [ ] Codemasters mapper
- [ ] BIOS/boot ROM support
- [ ] FM sound unit (YM2413) for Japanese SMS and Mark III
- [ ] Per-game compatibility database for mapper and setting detection
