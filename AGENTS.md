# AGENTS.md

Sandopolis is a Sega emulator written in Zig and C.
It supports Genesis, Sega CD, Master System, Game Gear, and SG-1000.
Prioritize emulation correctness and compatibility, then clear timing, maintainable subsystem boundaries, and performance.

## Architecture

- Keep emulator state on the instance that owns it. Avoid new mutable globals. Keep changes focused and comment only on non-obvious hardware behavior
  or timing.
- Keep SDL code in `src/main.zig` and `src/frontend/`, and Sega CD emulation in `src/scd/`. Desktop, WebAssembly, and Libretro frontends drive the
  core through `SystemMachine`. Add missing operations to the facade. Reserve `asGenesis()` for Genesis-only features.
- Expose public operations through `src/api.zig` and the `Machine` facade in `src/public/`. Keep raw coordination types such as `Bus`, `Cpu`, `Vdp`,
  and `Z80` internal.
- Keep direct use of `std.Io`, `std.fs`, and `std.process` in `src/platform.zig`. Use its wrappers for files, directories, clocks, environment
  variables, arguments, and sleep.
- `Bus` coordinates memory, Z80 arbitration, video, and audio timing. `scheduler/frame_scheduler.runMasterSlice()` drives frame execution. Timing
  changes must account for `Bus.stepMaster()`, `Cpu.stepInstruction()`, `Vdp.progressTransfers()`, and audio timestamps from
  `AudioTiming.consumeMaster()` and `Z80.setAudioMasterOffset()`.
- The jgz80 C bridge owns YM/PSG event queues and register shadows. Both PSG write paths (Z80 address `0x7F11` and M68K VDP port `0xC00011`) must
  enqueue timestamped events through the bridge. Keep `src/audio/events.zig`, `jgz80_bridge.h`, and the layout assertions in `src/cpu/z80.zig` in
  sync.

## Dependencies and Assets

- Use source dependencies in `build.zig.zon`. The desktop build uses the Zig-native SDL3 build from `castholm/SDL` and the bindings in
  `external/zsdl3/`. Keep platform-specific binaries out of the build graph.
- Preserve MIT-license boundaries. Treat external emulator repositories and AGPL code as references unless their licenses have been explicitly
  reviewed. The optional LGPL `external/Nuked-OPN2` submodule belongs only to the `compare-ym` developer tool.
- `make web` generates `web/fonts/`, `web/img/`, and `web/sandopolis.wasm`. Edit the source overlays in `docs/assets/overlays/`. Treat `tmp/` as
  optional scratch space.

## Testing and Validation

Read the affected module and nearby tests first. For behavior changes, write a regression or unit test, verify that it fails for the expected reason,
then make the smallest fix and refactor with the test passing. Run the narrowest relevant suite while iterating. Finish with `zig build check` and
`zig build test`. See the [test commands](tests/README.md).

- Keep unit tests in the module they exercise and move them with the code. Non-unit suites use the public API. Extend `sandopolis.testing` when they
  need lower-level control.
- Use `tests/integration_tests.zig` for public API and cross-module behavior, `tests/regression_tests.zig` for bug reproductions, timing regressions,
  and ROM-backed checks, and `tests/property_tests.zig` for invariants and randomized coverage.
- Use deterministic inputs, minimal setup, and assertions on observable behavior. Cover changes to timing, DMA, VDP, scheduling, controllers, and bus
  arbitration explicitly.
- Prefer the [community test ROMs](tests/testroms/README.md) for hardware regressions. Local files in `roms/` support manual testing and optional
  regressions. Keep the suite runnable when those files are absent.

| Change                           | Additional validation            |
|----------------------------------|----------------------------------|
| Frontend helpers or UI state     | `zig build test-frontend`        |
| Manual desktop behavior          | `zig build run -- <path-to-rom>` |
| Core or WebAssembly code         | `zig build wasm`                 |
| Browser frontend                 | `make web-serve`                 |
| API documentation or docs build  | `zig build docs --prefix .`      |
| Makefile or contributor workflow | `make test` and `make docs`      |

## Emulator Investigation

Use `-Doptimize=safe` for routine emulator and audio investigations, `fast` for long gameplay or throughput measurements, and `debug` for stepping,
assertions, or narrow traces.

For YM2612 synthesis changes, run `zig build compare-ym -- [scenario]` when the Nuked submodule is available. For cross-emulator FM differences, first
compare register streams with `zig build trace-ym-writes -- ...`. If the raw core matches but ROM audio diverges, inspect Z80 write order with
`zig build trace-z80-audio-ops -- ...` before changing synthesis.

## Writing and Documentation

- Use English for code, comments, docs, and tests. Use Oxford commas, plain descriptions, and noun phrases for checklist items. Avoid em dashes.
- Use title case for Markdown headings. Lowercase minor words such as “and,” “for,” and “the” unless they start the heading.
- Update `README.md` for user workflow changes, `ROADMAP.md` for progress changes, and `src/api.zig` for public API documentation. Correct stale
  guidance alongside related changes.

## Code Review

Report only P0 defects (incorrect emulation, severe regressions, or broken builds or tests) and P1 defects (likely timing bugs, incorrect subsystem
coupling, or missing validation for risky changes).
Give the severity, file and line, issue, impact, and smallest fix for each finding.
