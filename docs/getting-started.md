# Getting Started

This page covers the shortest path from a clean checkout to a running ROM, plus the default controls and configuration hooks that matter in day-to-day use.

## Prerequisites

- Zig `0.15.2`
- Git
- A working host C toolchain for Zig to use when compiling the bundled C sources

The project pulls SDL3, `zsdl`, `rocket68`, `jgz80`, and the testing dependencies through `build.zig.zon`.
The first build may fetch those source dependencies from the network.

## Build the emulator

```bash
git clone https://github.com/pixel-clover/sandopolis.git
cd sandopolis
zig build -Doptimize=ReleaseFast
```

The default executable is written to `zig-out/bin/sandopolis`.

## Run a ROM

```bash
zig build run -- <path-to-rom>
```

Or run the built binary directly:

```bash
./zig-out/bin/sandopolis <path-to-rom>
```

Supported cartridge image formats currently include `.bin`, `.md`, and `.smd`.

## Save data and recordings

- SRAM-backed cartridges write save data next to the ROM using the same basename with a `.sav` extension.
- GIF capture writes files like `sandopolis_001.gif` in the current working directory.

## Default controls

Player 1 keyboard defaults:

- D-pad: arrow keys
- `A/B/C`: `A`, `S`, `D`
- `X/Y/Z`: `Q`, `W`, `E`
- `Mode`: `Tab`
- `Start`: `Return`

Player 2 keyboard defaults:

- D-pad: `I`, `J`, `K`, `L`
- `A/B/C`: `U`, `O`, `P`
- `X/Y/Z`: `;`, `'`, `/`
- `Mode`: `.`
- `Start`: `Right Shift`

Default hotkeys:

- `Space`: single-step and print a debug dump
- `Backspace`: print a debug dump
- `R`: start or stop GIF recording
- `F11`: toggle fullscreen
- `Escape`: quit

Fixed frontend keys:

- `F1`: toggle the in-window help overlay
- `F2`: pause or resume emulation
- `F3`: open the host file dialog and load a different ROM at runtime
- `F4`: open the in-window keyboard binding editor
- `F6`: save a quick state in the current session
- `F7`: load the saved quick state
- `F8`: save the active persistent state slot for the current ROM
- `F9`: load the active persistent state slot for the current ROM
- `F10`: cycle between the three persistent state slots

The help overlay, pause mode, open-ROM dialog, and keyboard editor freeze emulation until you close or resume them.
The quick-state slot is session-local and restores the full saved machine snapshot, including the ROM that was active when you saved it.
Persistent state slots use `<rom-name>.slot1.state`, `.slot2.state`, and `.slot3.state` when the current ROM came from disk.
If no ROM path is available, they fall back to `sandopolis.slot1.state`, `sandopolis.slot2.state`, and `sandopolis.slot3.state`.

Keyboard editor controls:

- `Up` / `Down`: move between bindings
- `Return`: rebind the selected action or hotkey
- `F12`: clear the selected binding while capture mode is active
- `F5`: save the current bindings to the active input config path
- `F4` or `Escape`: close the editor

## Input configuration

Sandopolis looks for controller bindings in this order:

1. The path referenced by `SANDOPOLIS_INPUT_CONFIG`
2. `sandopolis_input.cfg` in the current working directory

You can start from the bundled sample at [`docs/assets/config/sandopolis_input.example.cfg`](assets/config/sandopolis_input.example.cfg).
The file supports per-player keyboard and gamepad mappings, controller type selection, analog thresholds, and hotkey remapping.

## Generate documentation locally

Use these commands when you want the docs site as well as the generated Zig API HTML:

```bash
make docs
make docs-serve
```

These commands expect `uv` to be available for the MkDocs Python environment.
`make docs` runs `zig build docs --prefix .` and then builds the MkDocs site into `site/`.
