# Compatibility Notes

This page lists current compatibility notes and scope limits based on the current codebase.

## CPU Model Scope

- The core exposes one execution profile through `M68kCpu`.
- There is no public API to select CPU model variants (for example 68010/68020 mode switches).
- Some later-family instructions exist (`MOVEC`, `MOVES`, `RTD`, `BKPT`), but model behavior is not fully parameterized.

## Address Space and Memory Model

- All memory accesses are against one flat memory buffer (`cpu->memory`, `cpu->memory_size`).
- Addresses are masked to 24-bit (`address & 0x00FFFFFF`) before bounds checks.
- There is no per-access memory read/write callback API for custom bus mapping; integration is currently done by sharing a memory buffer plus optional timing callbacks.

## Callback Behavior Notes

- `fc_callback` is emitted for memory reads/writes and instruction fetches.
- `M68K_FC_INT_ACK` is defined, but the current interrupt acknowledge path does not emit FC callback events with this code.
- `pc_changed_callback` is triggered when PC is changed through `m68k_set_pc`.
- Direct PC writes (for example in `m68k_reset`, `m68k_fetch`, and S-record entry-point load) do not call `pc_changed_callback`.
- `reset_callback` is tied to execution of the `RESET` instruction, not to `m68k_reset()`.
- `illg_callback` can be installed, but the current decode/exception path does not call it.

## Control Registers and Exception Base

- `VBR`, `SFC`, and `DFC` fields exist and are accessible through `MOVEC`.
- Exception vector fetch currently uses `vector * 4` from base address zero.
- `VBR` is not currently applied as an exception vector base in `m68k_exception`.
- `SFC`/`DFC` values are stored but not used to drive bus access behavior.

## Context Save/Restore Format

- `m68k_get_context` / `m68k_set_context` copy raw `M68kCpu` struct bytes.
- The blob format should be treated as build-dependent (compiler/ABI/version sensitive), not a stable cross-version interchange format.
- `m68k_set_context` preserves destination instance memory binding and installed callbacks.

## Loader and Disassembler Notes

- `m68k_load_srec` and `m68k_load_bin` return `false` only when file open fails.
- `m68k_load_srec` reports malformed lines and continues parsing.
- S-record checksum validity is not explicitly validated.
- S-record entry records (`S7/S8/S9`) set `cpu->pc` directly.
- `m68k_disasm` returns instruction bytes consumed; unsupported decode cases may still produce `???` output text.

## JSON Compatibility Harness

- The JSON compatibility runner (`tests/test_json.c`) has a relaxed default for exception-path state checks.
- Strict exception-path checking is available with `ROCKET68_JSON_STRICT=1`.
- This behavior is test-harness policy, not a runtime core API toggle.
