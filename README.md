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

Sandopolis is a Sega Genesis/Mega Drive emulator writen in Zig (and C).
It includes the main Genesis subsystems, including the Motorola 68000 CPU as the main CPU, VDP (Video Display Processor),
Z80 as helper CPU for sound processing, and controller/I/O path.

### Features

- Implemented in Zig and C and fully portable to any platform, including WASM builds
- Accurate Sega Genesis/Mega Drive emulation with good compatibility
- Very configurable input and rendering settings
- Debugging features including single stepping and register dumps
- Has a permissive license that allows commercial use

See [ROADMAP.md](ROADMAP.md) for the list of implemented and planned features.

> [!IMPORTANT]
> This project is still in early development, so bugs and breaking changes are expected.
> Please use the [issues page](https://github.com/pixel-clover/sandopolis/issues) to report bugs or request features.

---

### Quickstart

#### Building

```bash
BUILD_TYPE=ReleaseFast make build
```

#### Running

```bash
# Run with a ROM file
./zig-out/bin/sandopolis path/to/rom.bin

# Example with Sonic & Knuckles
./zig-out/bin/sandopolis roms/sn.smd

# Or use the convenience target
BUILD_TYPE=ReleaseFast make run ARGS="roms/sn.smd"
```

#### Controls

Controls are configurable via `sandopolis_input.cfg` or `SANDOPOLIS_INPUT_CONFIG`.
Controller type is also configurable per player with `controller.p1` / `controller.p2` set to `three_button` or `six_button`.
Configurable gamepad bindings can also use `guide`, `left_stick`, `right_stick`, `misc1`, `left_trigger`, and `right_trigger`.
Analog thresholds are configurable with `analog.gamepad_axis`, `analog.joystick_axis`, and `analog.trigger`.
The bindings below are the defaults.

##### Keyboard (Player 1)

- Arrow Keys: D-Pad
- A/S/D: Buttons A/B/C
- Q/W/E: Buttons X/Y/Z
- Tab: Mode
- Enter: Start

##### Keyboard (Player 2)

- I/J/K/L: D-Pad
- U/O/P: Buttons A/B/C
- Semicolon/Apostrophe/Slash: Buttons X/Y/Z
- .: Mode
- Right Shift: Start

##### Keyboard Hotkeys

- Space: Single step and dump the updated debug state
- Backspace: Dump CPU/Z80/VDP registers and the current 68K instruction
- Escape: Exit

##### Gamepad

- D-Pad / Left Stick: D-Pad
- South (A): Button A
- East (B): Button B
- West (X): Button X
- North (Y): Button Y
- Right Shoulder: Button C
- Left Shoulder: Button Z
- Back: Mode
- Start: Start

The first two SDL gamepads are assigned to player 1 and player 2.

##### Raw SDL Joystick Fallback

If SDL sees a controller as a joystick but not a gamepad, Sandopolis now assigns the first two non-gamepad joysticks to any remaining free player slots.

- Axis 0 / Axis 1: D-Pad
- Hat 0: D-Pad
- Button 0/1/2/3: South/East/West/North
- Button 4/5: Left Shoulder/Right Shoulder
- Button 6/7: Back/Start

Those fallback joystick inputs are translated through the existing gamepad bindings, so action remaps in `sandopolis_input.cfg` still apply.

---

### Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to make a contribution.

### License

This project is licensed under the MIT License (see [LICENSE](LICENSE)).

### Acknowledgements

* The logo is from [SVG Repo](https://www.svgrepo.com/svg/519365/sonic-runners) with some modifications.
* This project uses the following projects:
    * [Minish](https://github.com/CogitatorTech/minish) framework for property-based testing
    * [Rocket 68](https://github.com/habedi/rocket68) for the main CPU emulation
    * [jgz80](https://github.com/carmiker/jgz80) for the Z80 chip emulation
    * [SDL3](https://www.libsdl.org/) for the rendering and input
