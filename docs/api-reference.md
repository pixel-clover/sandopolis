# Public API

The deliberate public Zig API is defined in [`src/api.zig`](https://github.com/pixel-clover/sandopolis/blob/main/src/api.zig).
It is intentionally small: Sandopolis exports a stable facade for runtime use and testing, while internal coordination types remain private.

## Generated API HTML

The generated Zig API docs live at [`docs/api/index.html`](api/index.html).
They are produced by:

```bash
zig build docs --prefix .
```

`make docs` includes those generated files in the final MkDocs site under `site/api/`.

## Top-level exports

The public module currently re-exports:

- `clock`: timing constants and conversion helpers used by tests and host code
- `PendingAudioFrames`: the audio frame accounting type from the timing pipeline
- `Machine`: the main high-level emulator facade
- `testing`: the explicit lower-level testing facade

## `Machine`

`Machine` is the smallest public surface for loading a ROM and advancing emulation.
Its responsibilities are intentionally narrow:

- initialize from a ROM path
- reset the system
- run a master-clock slice
- flush persistent save data
- expose a minimal CPU state view
- emit a debug dump when needed

Minimal usage looks like this:

```zig
const std = @import("std");
const sandopolis = @import("sandopolis_src");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var machine = try sandopolis.Machine.init(allocator, "path/to/game.bin");
    defer machine.deinit(allocator);

    machine.reset();
    machine.runMasterSlice(sandopolis.clock.m68kCyclesToMaster(4));
}
```

## `testing`

The `sandopolis.testing` namespace exists for integration tests, regression tests, and developer tools that need more control than `Machine` exposes.
Current entry points include:

- `Emulator` for bus-level reads and writes, frame stepping, ROM-backed setup, VDP access, SRAM checks, and audio inspection
- `Vdp` for focused VDP timing and transfer tests
- `AudioTiming` for audio frame accumulation tests
- `ControllerIo` plus `Button` and `ControllerType` for controller protocol tests
- `Ym2612Synth` and `YmWriteEvent` for low-level YM tooling

Use this facade instead of re-exporting internal structs like `Bus`, `Cpu`, `Vdp`, or `Z80` from the core.

## Source of truth

Use this page for the high-level map of what is public.
Use the generated Zig API HTML for full signatures, fields, and doc comments.
