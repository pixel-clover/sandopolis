# Compatibility

Sandopolis already boots and runs a growing set of games and test ROMs, but it is still an in-progress emulator.
This page summarizes the practical state of the codebase rather than promising full hardware parity.

## Implemented well enough to build on

- ROM loading with `.bin`, `.md`, and `.smd` deinterleaving.
- M68000 and Z80 execution with shared-bus coordination.
- Frame scheduling around HBlank, HINT, VBlank, and Z80 interaction.
- VDP background and sprite rendering, DMA modes, FIFO timing, sprite overflow and collision flags, display blanking, H32 and H40 modes, and interlace mode 2.
- YM2612 synthesis, SN76489 PSG, timestamped audio event capture, and final audio mixing.
- Controller I/O with three-button and six-button protocols, keyboard and gamepad mapping, SRAM persistence, fullscreen, and GIF capture.

## Areas still under active accuracy work

- Per-access 68K and Z80 bus arbitration accuracy.
- VDP edge cases and cycle-exact behavior.
- YM2612 fidelity and broader audio validation.
- Input edge cases and wider controller compatibility.
- Broad game compatibility beyond the current targeted regression set.

## Test coverage today

The project includes:

- Module-local unit tests collected by `zig build test-unit`
- Frontend helper tests in `zig build test-frontend`
- Public API and cross-module integration coverage in `zig build test-integration`
- Regression coverage for scheduler, DMA, FIFO, SRAM, audio, VDP, and ROM-backed startup cases in `zig build test-regression`
- Property-based coverage in `zig build test-property`

Several regression tests use public-domain and community ROMs from [`tests/testroms/`](https://github.com/pixel-clover/sandopolis/tree/main/tests/testroms).

## Scope limits

- Sandopolis is a Genesis and Mega Drive emulator only. Sega CD and 32X support are future goals, not current features.
- `external/Nuked-OPN2` is only used by the optional `compare-ym` developer tool and is not part of the default runtime or release build.
- The public API intentionally exposes a small facade. Internal coordination types like `Bus`, `Cpu`, `Vdp`, and `Z80` stay internal unless a stable facade is added first.

## Tracking progress

For the current checklist of implemented and planned work, see [ROADMAP.md](https://github.com/pixel-clover/sandopolis/blob/main/ROADMAP.md).
