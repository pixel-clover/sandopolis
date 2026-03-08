# AGENTS.md

This file provides guidance to coding agents collaborating on this repository.

## Mission

Sandopolis is a Sega Genesis / Mega Drive emulator written in Zig.
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
- Keep SDL/frontend logic in `src/main.zig`; keep core emulation logic in `src/`.
- Keep SDL3 portable in the build graph: use the Zig-native SDL3 build (`castholm/SDL`) plus `zsdl` bindings, and do not hard-code platform binary artifacts such as `lib/libSDL3.so` in `build.zig`.
- Add comments only when they clarify non-obvious hardware behavior or timing.

Quick examples:

- Good: add a VDP timing helper inside `src/video/vdp.zig` with module-local tests.
- Good: add a regression ROM boot assertion in `tests/regression_tests.zig`.
- Bad: move emulator core behavior into `src/main.zig`.
- Bad: add a new debug-only behavior path without tests.

## Repository Layout

- `src/main.zig`: SDL frontend, event loop, rendering, audio device setup.
- `src/api.zig`: API/doc entrypoint used for generated documentation.
- `src/public/`: deliberate public API facade types exposed from `src/api.zig`.
- `src/testing/`: explicit testing facade used by non-unit suites that need lower-level control than `Machine` alone exposes.
- `src/bus/`: cartridge loading/persistence, memory map, open-bus behavior, Z80 arbitration, and VDP/audio timing coordination.
- `src/scheduler/`: frame/master-clock scheduling.
- `src/cpu/`: 68K/Z80 wrappers, runtime hooks, CPU-facing memory interface, and the local jgz80 bridge C code.
- `src/audio/`: YM2612 FM synthesizer, SN76489 PSG emulation, rate conversion, DC-blocking filters, and the output mixing pipeline.
- `src/input/`: controller I/O and configurable input mapping.
- `src/recording/`: GIF animation recording with LZW compression and crash-safe output.
- `src/video/`: VDP and video timing/rendering logic.
- `src/unit_test_root.zig`: internal test root that aggregates module-local unit tests for `zig build test-unit`.
- `src/`: remaining core emulator modules (`machine.zig`, etc.).
- `tests/`: non-unit suites only:
  - `integration_tests.zig`
  - `regression_tests.zig`
  - `property_tests.zig`
- `tests/testroms/`: local (public-domain and community) ROMs for testing and hardware verification; see `tests/testroms/README.md`.
- `roms/`: local ROMs for manual testing only; this directory may be absent.
- `tmp/`: scratch/reference material only; do not treat it as Sandopolis source, and it may be absent.
- `build.zig.zon`: source dependencies only. Avoid adding checked-in platform binary packages when an upstream source dependency is available.

## Testing Layout Rules

- Unit tests belong in the Zig module they exercise.
- `zig build test-unit` collects module-local unit tests through `src/unit_test_root.zig`.
- Integration, regression, and property-based tests belong in `tests/`.
- Non-unit tests should use the public API from `src/api.zig`. If they need lower-level control than `Machine` exposes, add or extend the explicit `sandopolis.testing` facade instead of re-exporting raw core structs.
- `tests/integration_tests.zig` is for stable public-API and cross-module wiring coverage that is not tied to a specific bug history.
- `tests/regression_tests.zig` is for bug reproductions, timing regressions, and ROM-backed behavior checks.
- `tests/property_tests.zig` is for invariant-style and randomized coverage.
- ROM-dependent tests belong in `tests/regression_tests.zig`.
- `tests/testroms/` contains community test ROMs for hardware verification. Use these for targeted regression tests against known hardware behavior. `roms/` is for local game ROMs used in manual testing only.
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
- The jgz80 C bridge (`src/cpu/jgz80_bridge.c`) owns the YM/PSG event ring buffers and register shadows. Audio event flow crosses a Zig/C boundary — changes to audio event capture or draining must account for both sides.
- The PSG is reachable from both the Z80 (address `0x7F11`) and the M68K (VDP port `0xC00011`). Both paths must push timestamped events through the Z80 bridge.
- Keep frontend concerns separate from emulation concerns.
- Preserve MIT-license boundaries. Treat external emulator repos and AGPL code as references unless licensing has been reviewed explicitly.

## Required Validation

Run these checks for any non-trivial change:

1. `zig build check`
2. `zig build test`

Also run these when relevant:

1. `zig build test-unit` when touching module-local tests, unit-test build wiring, or test-only module behavior during iteration
2. `zig build docs --prefix .` for docs/API/build-doc changes
3. `make test` when touching the Makefile or contributor workflow
4. `make docs` when touching docs generation paths
5. `zig build run -- <path-to-rom>` or `make run ARGS="<path-to-rom>"` for frontend/manual runtime checks

## First Contribution Flow

Use this sequence for a new change:

1. Read the touched module and existing nearby tests.
2. Implement the smallest change that solves the problem.
3. Add or update tests in the correct location:
   - module-local `test` blocks for unit behavior
   - `tests/` for integration/regression/property coverage
4. Run the narrowest relevant test target while iterating (`zig build test-unit`, `zig build test-integration`, etc.).
5. Run `zig build test`.
6. Run `zig build check`.
7. Update docs (`README.md`, `ROADMAP.md`, and `src/api.zig` exports) if behavior or workflow changed.

## Testing Expectations

- No emulation behavior change is complete without tests.
- Timing, DMA, VDP, scheduler, controller, and bus arbitration changes need explicit coverage.
- Prefer targeted assertions over broad snapshot-style tests unless the behavior is naturally end-to-end.
- Keep tests deterministic and avoid hidden dependencies on local state beyond explicitly referenced ROMs.

Minimal unit-test checklist:

1. Initialize only the state you need.
2. Drive the relevant API directly.
3. Assert on observable behavior, not incidental implementation detail.
4. Keep helper setup local to the module unless multiple suites truly share it.

## Documentation Expectations

- Public-facing API docs are generated from `src/api.zig`.
- Keep `src/api.zig` focused on deliberate public surfaces. Do not re-export raw internal coordination types like `Bus`, `Cpu`, `Vdp`, or `Z80`; add facade/view types instead.
- If a type should show up in generated docs, re-export it from `src/api.zig`.
- User workflow changes should update `README.md`.
- Progress/completeness wording should update `ROADMAP.md` when it materially changes.

## Change Design Checklist

Before coding:

1. Is this a timing change, an API change, a frontend change, or a workflow/docs change?
2. Which existing tests should fail before the change?
3. Does the change belong in a core module or only in the frontend?

Before submitting:

1. Did you put tests in the correct place?
2. Did `zig build test` pass?
3. Did you update docs/workflow files if needed?
4. Did you avoid introducing a new global mutable state or frontend/core coupling?

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

## Practical Notes for Agents

- Follow existing module boundaries unless there is a strong reason to change them.
- Prefer adapting the current scheduler/timing model over introducing parallel experimental paths.
- If you detect stale docs or workflow targets while changing related code, fix them in the same patch if the scope stays coherent.
- When uncertain about emulator correctness, add or refine tests first.
