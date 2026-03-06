<div align="center">
  <picture>
    <img alt="Sandopolis Logo" src="logo.svg" height="25%" width="25%">
  </picture>
<br>

<h2>Sandopolis</h2>

[![Tests](https://img.shields.io/github/actions/workflow/status/pixel-clover/sandopolis/tests.yml?label=tests&style=flat&labelColor=282c34&logo=github)](https://github.com/pixel-clover/sandopolis/actions/workflows/tests.yml)
[![License](https://img.shields.io/badge/license-MIT-007ec6?label=license&style=flat&labelColor=282c34&logo=open-source-initiative)](https://github.com/pixel-clover/sandopolis/blob/main/LICENSE)
[![Docs](https://img.shields.io/badge/docs-read-blue?style=flat&labelColor=282c34&logo=read-the-docs)](https://pixel-clover.github.io/sandopolis/)
[![Zig Version](https://img.shields.io/badge/Zig-0.15.2-orange?logo=zig&labelColor=282c34)](https://ziglang.org/download/)
[![Release](https://img.shields.io/github/release/pixel-clover/sandopolis.svg?label=release&style=flat&labelColor=282c34&logo=github)](https://github.com/pixel-clover/sandopolis/releases/latest)

A Sega Genesis/Mega Drive emulator written in Zig

</div>

---

## Overview

Sandopolis is a Sega Genesis/Mega Drive emulator built from the ground up in Zig. It implements the main Genesis subsystems, including the Motorola 68000 CPU, VDP (Video Display Processor), Z80 sound processor, and controller/I/O path. Core video, DMA, audio, and input flows are running today, while cycle-accurate timing, hardware edge cases, and chip-accurate audio are still in progress.

## Features

- Motorola 68000 CPU emulation via [rocket68](https://github.com/habedi/rocket68)
- VDP implementation with support for:
  - Tile rendering (Plane A, Plane B, Sprites)
  - VRAM, CRAM, and VSRAM access
  - Hardware scrolling
  - DMA transfer modes and VDP-managed transfer progression
- Z80 core integration via [jgz80](https://github.com/carmiker/jgz80)
- Controller input support (keyboard and gamepad)
- SMD ROM format deinterleaving
- Real-time rendering with SDL3

## Quick Start

### Building

```bash
make build
```

### Running

```bash
# Run with a ROM file
./zig-out/bin/sandopolis path/to/rom.bin

# Run test emulator (no GUI)
./zig-out/bin/test_emu path/to/rom.bin

# Example with Sonic & Knuckles
./zig-out/bin/sandopolis roms/sn.smd
```

### Controls

#### Keyboard
- Arrow Keys: D-Pad
- A/S/D: Buttons A/B/C
- Enter: Start
- Space: Single step (debug mode)
- Escape: Exit

#### Gamepad
- D-Pad: D-Pad
- South (A): Button A
- East (B): Button B
- Right Shoulder: Button C
- Start: Start

## Project Structure

```
sandopolis/
├── src/
│   ├── main.zig           # Main emulator loop and SDL integration
│   ├── memory.zig         # Memory bus and address decoding
│   ├── vdp.zig            # Video Display Processor
│   ├── io.zig             # Input/Output controller
│   ├── z80.zig            # Z80 wrapper (jgz80 bridge)
│   └── cpu/
│       ├── cpu.zig            # CPU entrypoint
│       └── rocket68_cpu.zig   # Rocket68-backed M68K wrapper
├── src/c/                 # C bridges (jgz80)
├── external/              # Git submodules (rocket68, jgz80)
├── roms/                  # Place your Genesis ROMs here
├── test_emu.zig          # Standalone test runner
└── build.zig             # Build configuration
```

## Building

### Prerequisites

- Zig 0.15.2 or later
- SDL3 (bundled for Linux in dependencies)
- Make (optional, for convenience commands)

### Build Commands

```bash
# Build the project
make build

# Build and run with a ROM
make run -- roms/your-game.smd
```

---

### Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to make a contribution.

### License

This project is licensed under the MIT License (see [LICENSE](LICENSE)).

### Acknowledgements

* The logo is from [SVG Repo](https://www.svgrepo.com/svg/519365/sonic-runners) with some modifications.
* This project uses the [Minish](https://github.com/CogitatorTech/minish) framework for property-based testing and
  the [Ordered](https://github.com/CogitatorTech/minish) Zig library.
