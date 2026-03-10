# Sandopolis

Sandopolis is a Sega Genesis/Mega Drive emulator written in Zig and C.
The project prioritizes correctness and subsystem timing first, then maintainable boundaries between the frontend and core emulation code, and only then raw performance.

## Current scope

- M68000 execution through the `rocket68` core and Z80 execution through the `jgz80` bridge.
- VDP rendering with scrolling planes, sprites, DMA, FIFO timing, shadow and highlight, H32 and H40 modes, and interlace mode 2.
- YM2612 and SN76489 audio routed through timestamped event capture and a shared output pipeline.
- Keyboard and gamepad input for two players, a runtime keyboard editor, quick save/load states, three persistent state slots, configurable bindings, fullscreen toggle, GIF recording, and SRAM persistence.
- Unit, frontend, integration, regression, and property-based tests.

## Read this site by task

- [Getting Started](getting-started.md) covers building, running ROMs, default controls, and input configuration.
- [Development](development.md) covers repository layout, timing-sensitive architecture, tests, and tooling.
- [Public API](api-reference.md) summarizes the exported Zig facade and points to generated API HTML.
- [Compatibility](compatibility.md) tracks what works well today and what still needs accuracy work.

## Quickstart

```bash
git clone https://github.com/pixel-clover/sandopolis.git
cd sandopolis
zig build -Doptimize=ReleaseFast
./zig-out/bin/sandopolis <path-to-rom>
```

Sandopolis accepts `.bin`, `.md`, and `.smd` ROM images.
The SDL3 runtime is built from source through Zig dependencies, so you do not need to install a separate system SDL3 package just to build the emulator.

## Project status

Sandopolis is still under active development.
Compatibility is improving, but timing accuracy, VDP edge cases, and YM2612 fidelity are still active work areas.
For a checklist-style view of implemented and planned work, see [ROADMAP.md](https://github.com/pixel-clover/sandopolis/blob/main/ROADMAP.md).

## Documentation outputs

There are two documentation outputs in this repository:

- This MkDocs site for contributor and user-facing guidance.
- Generated Zig API HTML under [`docs/api/`](api/index.html), built from [`src/api.zig`](https://github.com/pixel-clover/sandopolis/blob/main/src/api.zig).
