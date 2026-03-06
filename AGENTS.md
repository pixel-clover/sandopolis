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
- Add comments only when they clarify non-obvious hardware behavior or timing.

Quick examples:

- Good: add a VDP timing helper inside `src/vdp.zig` with module-local tests.
- Good: add a regression ROM boot assertion in `tests/regression_tests.zig`.
- Bad: move emulator core behavior into `src/main.zig`.
- Bad: add a new debug-only behavior path without tests.

## Repository Layout

- `src/main.zig`: SDL frontend, event loop, rendering, audio device setup.
- `src/api.zig`: API/doc entrypoint used for generated documentation.
- `src/unit_tests.zig`: aggregate unit-test root that imports inline module tests.
- `src/`: core emulator modules (`memory.zig`, `vdp.zig`, `io.zig`, `z80.zig`, `audio_*`, etc.).
- `src/c/`: C bridge code for external CPU cores.
- `src/cpu/`: 68K wrapper and CPU entrypoint.
- `tests/`: non-unit suites only:
  - `integration_tests.zig`
  - `regression_tests.zig`
  - `property_tests.zig`
- `roms/`: local ROMs for manual testing; not part of the distributable build.
- `tmp/`: scratch/reference repos; do not treat them as a Sandopolis source.

## Testing Layout Rules

- Unit tests belong in the Zig module they exercise.
- Integration, regression, and property-based tests belong in `tests/`.
- ROM-dependent tests belong in `tests/regression_tests.zig`.
- If you move code across modules, move or rewrite the unit tests with it.

## Architecture Constraints

- `Bus` is the central coordination point for memory, timing, Z80 arbitration, VDP progression, and audio timing.
- `frame_scheduler.runMasterSlice()` is the authoritative scheduler path for frame execution.
- Timing-sensitive changes must respect the interaction between:
  - `Bus.stepMaster()`
  - `frame_scheduler.runMasterSlice()`
  - `Cpu.stepInstruction()`
  - `Vdp.progressTransfers()`
- Keep frontend concerns separate from emulation concerns.
- Preserve MIT-license boundaries. Treat external emulator repos and AGPL code as references unless licensing has been reviewed explicitly.

## Required Validation

Run these checks for any non-trivial change:

1. `zig build check`
2. `zig build test`

Also run these when relevant:

1. `zig build docs --prefix .` for docs/API/build-doc changes
2. `make test` when touching the Makefile or contributor workflow
3. `make docs` when touching docs generation paths
4. `zig build run -- roms/sn.smd` or `make run ARGS="roms/sn.smd"` for frontend/manual runtime checks

## First Contribution Flow

Use this sequence for a new change:

1. Read the touched module and existing nearby tests.
2. Implement the smallest change that solves the problem.
3. Add or update tests in the correct location:
   - module-local `test` blocks for unit behavior
   - `tests/` for integration/regression/property coverage
4. Run `zig build test`.
5. Run `zig build check`.
6. Update docs (`README.md`, `ROADMAP.md`, `src/api.zig`-visible exports) if behavior or workflow changed.

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
