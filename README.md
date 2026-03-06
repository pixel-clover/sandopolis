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

Sandopolis is a Sega Genesis/Mega Drive emulator writen in Zig (and C).
It includes the main Genesis subsystems, including the Motorola 68000 CPU, VDP (Video Display Processor), Z80 sound processor,
and controller/I/O path.

## Features

- Motorola 68000 CPU emulation via [rocket68](https://github.com/habedi/rocket68)
- VDP implementation with support for:
  - Tile rendering (Plane A, Plane B, and Sprites)
  - VRAM, CRAM, and VSRAM access
  - Hardware scrolling
  - DMA transfer modes and VDP-managed transfer progression
- Z80 core integration via [jgz80](https://github.com/carmiker/jgz80)
- Controller input support (keyboard and gamepad)
- SMD ROM format deinterleaving
- Real-time rendering with SDL3

See [ROADMAP.md](ROADMAP.md) for the list of implemented and planned features.

> [!IMPORTANT]
> This project is still in early development, so bugs and breaking changes are expected.
> Please use the [issues page](https://github.com/pixel-clover/sandopolis/issues) to report bugs or request features.

---

## Quickstart

### Building

```bash
BUILD_TYPE=ReleaseFast make build
```

### Running

```bash
# Run with a ROM file
./zig-out/bin/sandopolis path/to/rom.bin

# Example with Sonic & Knuckles
./zig-out/bin/sandopolis roms/sn.smd

# Or use the convenience target
BUILD_TYPE=ReleaseFast make run ARGS="roms/sn.smd"
```

### Controls

Controls are configurable via `sandopolis_input.cfg` or `SANDOPOLIS_INPUT_CONFIG`.
The bindings below are the defaults.

#### Keyboard (Player 1)
- Arrow Keys: D-Pad
- A/S/D: Buttons A/B/C
- Q/W/E: Buttons X/Y/Z
- Tab: Mode
- Enter: Start

#### Keyboard (Player 2)
- I/J/K/L: D-Pad
- U/O/P: Buttons A/B/C
- Semicolon/Apostrophe/Slash: Buttons X/Y/Z
- .: Mode
- Right Shift: Start

#### Keyboard Hotkeys
- Space: Single step (debug mode)
- Escape: Exit

#### Gamepad
- D-Pad: D-Pad
- South (A): Button A
- East (B): Button B
- West (X): Button X
- North (Y): Button Y
- Right Shoulder: Button C
- Left Shoulder: Button Z
- Back: Mode
- Start: Start

The first two SDL gamepads are assigned to player 1 and player 2.

---

### Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to make a contribution.

### License

This project is licensed under the MIT License (see [LICENSE](LICENSE)).

### Acknowledgements

* The logo is from [SVG Repo](https://www.svgrepo.com/svg/519365/sonic-runners) with some modifications.
* This project uses the [Minish](https://github.com/CogitatorTech/minish) framework for property-based testing and
  the [Ordered](https://github.com/CogitatorTech/minish) Zig library.
