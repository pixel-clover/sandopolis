# Development

This page is aimed at contributors working inside the repository rather than end users running a release build.

## Repository layout

- `src/main.zig`: SDL frontend, event loop, rendering, audio device setup, and runtime hotkeys
- `src/bus/`: memory map, ROM and SRAM handling, Z80 arbitration, VDP coordination, and audio timing coordination
- `src/scheduler/`: frame and master-clock scheduling
- `src/cpu/`: M68000 and Z80 integration glue, including the `jgz80` C bridge
- `src/video/`: VDP timing, rendering, DMA, FIFO, and status behavior
- `src/audio/`: YM2612, PSG, filtering, resampling, and output mixing
- `src/input/`: controller I/O and input mapping
- `src/public/`: deliberate runtime-facing API facade
- `src/testing/`: explicit lower-level testing facade used by integration, regression, and developer tools
- `tests/`: non-unit integration, regression, and property suites

## Timing-sensitive architecture

The main scheduling path is built around master-clock progression.
When changing timing-sensitive behavior, treat these as the core interaction points:

- `Bus.stepMaster()`
- `scheduler/frame_scheduler.runMasterSlice()`
- `Cpu.stepInstruction()`
- `Vdp.progressTransfers()`
- `AudioTiming.consumeMaster()`
- `Z80.setAudioMasterOffset()`

`Bus` is the coordination point for memory, timing, Z80 arbitration, VDP progression, and audio event timing.
If a change crosses subsystem boundaries, it usually belongs there rather than in the SDL frontend.

## Test targets

Run the narrowest useful target while iterating:

```bash
zig build test-unit
zig build test-frontend
zig build test-integration
zig build test-regression
zig build test-property
```

For non-trivial changes, the repository expects both of these before you call the work done:

```bash
zig build test
zig build check
```

## Developer tools

Run the emulator manually:

```bash
zig build run -- <path-to-rom>
```

Compare the YM2612 implementation against the optional Nuked reference:

```bash
git submodule update --init external/Nuked-OPN2
zig build compare-ym -- [scenario]
```

`compare-ym` is a developer-only tool.
The reference core stays out of the default runtime and release build path.

## Documentation workflow

Sandopolis uses two documentation layers:

- Generated Zig API HTML from `src/api.zig`
- MkDocs pages from `docs/`

Useful commands:

```bash
zig build docs --prefix .
make docs
make docs-serve
```

- `zig build docs --prefix .` refreshes `docs/api/`
- `make docs` regenerates the API docs and builds the MkDocs site into `site/`
- `make docs-serve` starts a local MkDocs preview after regenerating the API docs

The `make docs*` targets use `uv` to provide the MkDocs Python environment from `pyproject.toml` and `uv.lock`.

## Contribution expectations

- Keep emulator state instance-bound inside the existing core structs instead of adding global mutable state.
- Keep frontend-specific behavior in `src/main.zig` and core behavior inside `src/`.
- Add tests for emulation changes, especially timing, DMA, VDP, scheduler, controller, and bus-arbitration work.
- Extend `sandopolis.testing` when non-unit tests need deeper access than `Machine` provides.
