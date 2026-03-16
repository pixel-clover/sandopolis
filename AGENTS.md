# AGENTS.md

This file provides guidance to coding agents collaborating on this repository.

## Mission

Sandopolis is a Sega Genesis / Mega Drive emulator written in Zig (and C).
Priorities, in order:

1. Correct emulation behavior and compatibility.
2. Clear timing and subsystem interactions.
3. Maintainable boundaries between frontend and core emulation logic.
4. Performance, but only after correctness is covered by tests.

## Core Rules

- Use English for code, comments, docs, and tests.
- Prefer small, focused changes over broad rewrites.
- Ensure the project is modular and components are decoupled with clean APIs and interfaces.
- Keep emulator state instance-bound inside the existing structs (`Bus`, `Vdp`, `Io`, `Z80`, `Cpu`, and `AudioOutput`).
- Avoid introducing a new global mutable state.
- Keep SDL/frontend logic in `src/main.zig` and `src/frontend/`; keep core emulation logic in `src/`.
- Keep SDL3 portable in the build graph: use the Zig-native SDL3 build (`castholm/SDL`) plus `zsdl` bindings, and do not hard-code platform binary
  artifacts such as `lib/libSDL3.so` in `build.zig`.
- Add comments only when they clarify non-obvious hardware behavior or timing.

Quick examples:

- Good: add a VDP timing helper inside `src/video/vdp.zig` with module-local tests.
- Good: add a regression ROM boot assertion in `tests/regression_tests.zig`.
- Bad: move emulator core behavior into `src/main.zig`.
- Bad: add a new debug-only behavior path without tests.

## Repository Layout

- `src/main.zig`: SDL frontend, event loop, rendering, audio device setup.
- `src/api.zig`: API/doc entrypoint used for generated documentation.
- `src/public/`: deliberate public API facade type (`Machine`) exposed from `src/api.zig`.
- `src/testing/`: explicit testing facade used by non-unit suites that need lower-level control than `Machine` alone exposes.
- `src/testing_root.zig`: root module used for internal testing facades that need broader access than `src/testing/` alone.
- `src/bus/`: cartridge loading/persistence, memory map, open-bus behavior, Z80 arbitration, and VDP/audio timing coordination.
- `src/scheduler/`: frame/master-clock scheduling.
- `src/cpu/`: 68K/Z80 wrappers, runtime hooks, CPU-facing memory interface, and the local jgz80 bridge C code.
- `src/audio/`: YM2612 FM synthesizer, SN76489 PSG emulation, rate conversion, DC-blocking filters, and the output mixing pipeline.
- `src/input/`: controller I/O and configurable input mapping.
- `src/recording/`: GIF animation recording with LZW compression and crash-safe output, WAV audio recording, and BMP screenshot capture.
- `src/video/`: VDP and video timing/rendering logic.
- `src/frontend/`: SDL frontend helpers including config, UI state, save manager, menu, dialog, toast, and performance overlay logic.
- `src/unit_test_root.zig`: internal test root that aggregates module-local unit tests for `zig build test-unit`.
- `src/`: remaining core emulator modules (`machine.zig`, `cli.zig`, `performance_profile.zig`, `rom_metadata.zig`, `state_file.zig`, etc.).
- `tests/`: non-unit suites only:
    - `integration_tests.zig`
    - `regression_tests.zig`
    - `property_tests.zig`
- `tests/testroms/`: local (public-domain and community) ROMs for testing and hardware verification; see `tests/testroms/README.md`.
- `roms/`: local ROMs for manual testing only; this directory may be absent.
- `tools/`: developer-only utilities that are not part of the shipped emulator runtime.
- `external/`: optional checked-out third-party source trees used for developer tooling or reference comparison, not default runtime dependencies.
- `tmp/`: scratch/reference material only; do not treat it as the Sandopolis source, and it may be missing.
- `build.zig.zon`: source dependencies only. Avoid adding checked-in platform binary packages when an upstream source dependency is available.

## Testing Layout Rules

- Unit tests belong in the Zig module they exercise.
- `zig build test-unit` collects module-local unit tests through `src/unit_test_root.zig`.
- Integration, regression, and property-based tests belong in `tests/`.
- Non-unit tests should use the public API from `src/api.zig`. If they need lower-level control than `Machine` exposes, add or extend the explicit
  `sandopolis.testing` facade instead of re-exporting raw core structs.
- `tests/integration_tests.zig` is for stable public-API and cross-module wiring coverage that is not tied to a specific bug history.
- `tests/regression_tests.zig` is for bug reproductions, timing regressions, and ROM-backed behavior checks.
- `tests/property_tests.zig` is for invariant-style and randomized coverage.
- ROM-dependent tests belong in `tests/regression_tests.zig`.
- `tests/testroms/` contains community test ROMs for hardware verification. Use these for targeted regression tests against known hardware behavior.
  `roms/` is for local game ROMs used in manual testing only.
- If you move code across modules, move or rewrite the unit tests with it.

## Architecture Constraints

- `Bus` is the central coordination point for memory, timing, Z80 arbitration, VDP progression, and audio timing.
- `scheduler/frame_scheduler.runMasterSlice()` is the authoritative scheduler path for frame execution.
- Timing-sensitive changes must respect the interaction between:
    - `Bus.stepMaster()`
    - `scheduler/frame_scheduler.runMasterSlice()`
    - `Cpu.stepInstruction()`
    - `Vdp.progressTransfers()`
    - `AudioTiming.consumeMaster()` and `Z80.setAudioMasterOffset()` (audio event timestamps)
- The jgz80 C bridge (`src/cpu/jgz80_bridge.c`) owns the YM/PSG event ring buffers and register shadows. Audio event flow crosses a Zig/C boundary —
  changes to audio event capture or draining must account for both sides.
- The PSG is reachable from both the Z80 (address `0x7F11`) and the M68K (VDP port `0xC00011`). Both paths must push timestamped events through the
  Z80 bridge.
- Keep frontend concerns separate from emulation concerns.
- Preserve MIT-license boundaries. Treat external emulator repos and AGPL code as references unless licensing has been reviewed explicitly.
- `external/Nuked-OPN2` is an optional LGPL developer-reference dependency. Keep it isolated to the `compare-ym` tool and never make it part of the
  default `sandopolis`, `check`, `test`, or release build paths.

## Workflow

Before coding:

1. Identify whether this is a timing, API, frontend, or docs change.
2. Read the touched module and existing nearby tests.

Implement and test:

1. Make the smallest change that solves the problem.
2. Add or update tests in the correct location (module-local `test` blocks for unit behavior, `tests/` for integration/regression/property coverage).
3. Run the narrowest relevant test target while iterating (`zig build test-unit`, `zig build test-integration`, etc.).
4. Run `zig build check` and `zig build test`.
5. Update docs (`README.md`, `ROADMAP.md`, `src/api.zig` exports) if behavior or workflow changed.

Additional validation when relevant:

- `zig build test-frontend` when touching frontend helper functions or UI state logic.
- `zig build docs --prefix .` for docs/API/build-doc changes.
- `make test` / `make docs` when touching the Makefile or contributor workflow.
- `zig build run -- <path-to-rom>` for frontend/manual runtime checks.
- `zig build compare-ym -- [scenario]` when touching YM2612 synthesis and the Nuked submodule is available.

## Testing Expectations

- No emulation behavior change is complete without tests.
- Timing, DMA, VDP, scheduler, controller, and bus arbitration changes need explicit coverage.
- Prefer targeted assertions over broad snapshot-style tests unless the behavior is naturally end-to-end.
- Keep tests deterministic and avoid hidden dependencies on local state beyond explicitly referenced ROMs.
- Initialize only the state you need, drive the relevant API directly, and assert on observable behavior.
- When uncertain about emulator correctness, add or refine tests first.

## Documentation Expectations

- Public-facing API docs are generated from `src/api.zig`. Keep it focused on deliberate public surfaces — do not re-export raw internal coordination
  types like `Bus`, `Cpu`, `Vdp`, or `Z80`; add facade/view types instead.
- User workflow changes should update `README.md`.
- Progress/completeness changes should update `ROADMAP.md`.
- If you detect stale docs while changing related code, fix them in the same patch.

## Review Guidelines (P0/P1 Focus)

Review output should be concise and only include critical issues.

- `P0`: must-fix defects (incorrect emulation behavior, severe regression, broken build/test workflow).
- `P1`: high-priority defects (likely timing bug, incorrect subsystem coupling, missing validation for risky change).

Use this review format:

1. `Severity` (`P0`/`P1`)
2. `File:line`
3. `Issue`
4. `Why it matters`
5. `Minimal fix direction`

Do not include style-only feedback or broad praise.
