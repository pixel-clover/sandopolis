# API Reference

This page documents the public C API in:

- `include/m68k.h`
- `include/loader.h`
- `include/disasm.h`
- `include/rocket68.h`

## Header Usage

Include the umbrella header:

```c
#include "rocket68.h"
```

Or include only what you need:

```c
#include "m68k.h"
#include "loader.h"
#include "disasm.h"
```

## Core Types

### Integer aliases

- `u8`, `u16`, `u32`
- `s8`, `s16`, `s32`

### `M68kSize`

```c
typedef enum { SIZE_BYTE = 1, SIZE_WORD = 2, SIZE_LONG = 4 } M68kSize;
```

### `M68kRegister`

Register union used for `D0-D7` and `A0-A7`.
`w` maps to the low 16 bits of `l`.

### `M68kCpu`

One complete CPU instance with registers, execution state, memory binding, and callbacks.
`d_regs` is aligned to 64 bytes.

### Host memory callback types

- `M68kRead8Callback`
- `M68kRead16Callback`
- `M68kRead32Callback`
- `M68kWrite8Callback`
- `M68kWrite16Callback`
- `M68kWrite32Callback`

## Status Register Flags

- `M68K_SR_C` carry
- `M68K_SR_V` overflow
- `M68K_SR_Z` zero
- `M68K_SR_N` negative
- `M68K_SR_X` extend
- `M68K_SR_S` supervisor mode

## Function Code Constants

- `M68K_FC_USER_DATA`
- `M68K_FC_USER_PROG`
- `M68K_FC_SUPV_DATA`
- `M68K_FC_SUPV_PROG`
- `M68K_FC_INT_ACK`

## Interrupt ACK Constants

- `M68K_INT_ACK_AUTOVECTOR`
- `M68K_INT_ACK_SPURIOUS`

## Lifecycle and State

### `void m68k_init(M68kCpu* cpu, u8* memory, u32 memory_size);`

Initializes all CPU fields and binds a flat memory buffer.
If host memory callbacks are installed later, read/write API calls dispatch through callbacks instead of this flat buffer.

### `void m68k_reset(M68kCpu* cpu);`

Performs reset-state initialization and loads:

- initial SSP from `0x00000000`
- initial PC from `0x00000004`

### `void m68k_set_pc(M68kCpu* cpu, u32 pc);`

Sets PC and triggers `pc_changed` callback if installed.

### `u32 m68k_get_pc(M68kCpu* cpu);`

Returns PC.

### `void m68k_set_sr(M68kCpu* cpu, u16 new_sr);`

Sets SR with masking (`0xA71F`) and performs USP/SSP swap when supervisor state changes.

### `void m68k_set_irq(M68kCpu* cpu, int level);`

Sets pending interrupt level (0-7).

### Register accessors

- `void m68k_set_dr(M68kCpu* cpu, int reg, u32 value);`
- `u32 m68k_get_dr(M68kCpu* cpu, int reg);`
- `void m68k_set_ar(M68kCpu* cpu, int reg, u32 value);`
- `u32 m68k_get_ar(M68kCpu* cpu, int reg);`

Invalid register indexes are ignored on set and return `0` on get.

## Execution API

### `void m68k_step_ex(M68kCpu* cpu, bool check_exceptions);`

Executes one instruction with optional interrupt/trace checks.

### `void m68k_step(M68kCpu* cpu);`

Equivalent to `m68k_step_ex(cpu, true)`.

### `int m68k_execute(M68kCpu* cpu, int cycles);`

Adds `cycles` to the timeslice, runs until `cycles_remaining <= 0`, and returns consumed cycles for this call.

### Timeslice helpers

- `int m68k_cycles_run(M68kCpu* cpu);`
- `int m68k_cycles_remaining(M68kCpu* cpu);`
- `void m68k_modify_timeslice(M68kCpu* cpu, int cycles);`
- `void m68k_end_timeslice(M68kCpu* cpu);`

## Memory API

All memory accesses are big-endian.
Addresses are masked to 24-bit internally before bounds checks.

### Reads

- `u8  m68k_read_8(M68kCpu* cpu, u32 address);`
- `u16 m68k_read_16(M68kCpu* cpu, u32 address);`
- `u32 m68k_read_32(M68kCpu* cpu, u32 address);`

### Writes

- `void m68k_write_8(M68kCpu* cpu, u32 address, u8 value);`
- `void m68k_write_16(M68kCpu* cpu, u32 address, u16 value);`
- `void m68k_write_32(M68kCpu* cpu, u32 address, u32 value);`

Behavior notes:

- If a host memory callback is installed for the requested width, it is called first.
- When callbacks are used, default flat-buffer address/alignment/bus-error checks for that access are bypassed and are expected to be handled by the host.
- Word/long accesses on odd addresses trigger address error handling.
- Out-of-range accesses trigger bus error handling.

## Callback API

All callbacks are per-instance.

### `void m68k_set_wait_bus_callback(M68kCpu* cpu, M68kWaitBusCallback callback);`

Called before each memory/fetch bus access.

### `void m68k_set_int_ack_callback(M68kCpu* cpu, M68kIntAckCallback callback);`

Called when an interrupt is acknowledged.
Return vector number, `M68K_INT_ACK_AUTOVECTOR`, or `M68K_INT_ACK_SPURIOUS`.

### `void m68k_set_fc_callback(M68kCpu* cpu, M68kFcCallback callback);`

Called before bus/program accesses with the active FC value.

### `void m68k_set_instr_hook_callback(M68kCpu* cpu, M68kInstrHookCallback callback);`

Called before each instruction decode/execute (not during STOP-idle cycles).

### `void m68k_set_pc_changed_callback(M68kCpu* cpu, M68kPcChangedCallback callback);`

Called when PC changes through `m68k_set_pc`.

### `void m68k_set_reset_callback(M68kCpu* cpu, M68kResetCallback callback);`

Called by execution of the `RESET` instruction.
This is separate from `m68k_reset()`.

### `void m68k_set_tas_callback(M68kCpu* cpu, M68kTasCallback callback);`

Called by `TAS`; non-zero return allows write-back, zero blocks write-back.

### `void m68k_set_illg_callback(M68kCpu* cpu, M68kIllgCallback callback);`

Registers an illegal-opcode callback pointer.
Current core decode path does not invoke this callback yet.

### Host memory callbacks

- `void m68k_set_read8_callback(M68kCpu* cpu, M68kRead8Callback callback);`
- `void m68k_set_read16_callback(M68kCpu* cpu, M68kRead16Callback callback);`
- `void m68k_set_read32_callback(M68kCpu* cpu, M68kRead32Callback callback);`
- `void m68k_set_write8_callback(M68kCpu* cpu, M68kWrite8Callback callback);`
- `void m68k_set_write16_callback(M68kCpu* cpu, M68kWrite16Callback callback);`
- `void m68k_set_write32_callback(M68kCpu* cpu, M68kWrite32Callback callback);`

Use these to route memory access to a host bus implementation (for mapped IO/peripherals or custom memory models).
Pass `NULL` to disable a callback and fall back to default flat-memory behavior for that access width.

## Context Save/Restore

### `unsigned int m68k_context_size(void);`

Returns context blob size in bytes.

### `void m68k_get_context(M68kCpu* cpu, void* dst);`

Copies CPU context into `dst` (`m68k_context_size()` bytes).

### `void m68k_set_context(M68kCpu* cpu, const void* src);`

Restores context from `src`, while preserving destination-instance runtime bindings:

- memory pointer and memory size
- internal fault trap storage
- installed callbacks

## Loader API (`loader.h`)

### `bool m68k_load_srec(M68kCpu* cpu, const char* filename);`

Loads Motorola S-record data into memory.
Returns `false` only when the file cannot be opened.
Malformed records are reported to `stderr` and skipped.
Entry-point records (`S7/S8/S9`) set `cpu->pc` directly.

### `bool m68k_load_bin(M68kCpu* cpu, const char* filename, u32 address);`

Loads raw binary bytes into memory starting at `address`.
Returns `false` only when the file cannot be opened.

## Disassembler API (`disasm.h`)

### `int m68k_disasm(M68kCpu* cpu, u32 pc, char* buffer, int buf_size);`

Disassembles one instruction at `pc` into `buffer`.
Returns number of bytes consumed by that instruction.

## Version

### `ROCKET68_VERSION_STR`

Semantic version string in `include/rocket68.h`.
