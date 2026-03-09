# Getting Started

This page shows the smallest path from source files to a running 68000 program.

## 1. Build and Link

### Option A: Compile core sources directly

```bash
gcc -std=c11 -O3 -Iinclude src/m68k/*.c your_app.c -o your_app
```

### Option B: Build library with Make

```bash
BUILD_TYPE=release make static
# Produces lib/librocket68.a
```

Then link your app:

```bash
gcc -std=c11 -O2 -Iinclude your_app.c lib/librocket68.a -o your_app
```

## 2. Minimal Runnable Program

This example:

1. Creates CPU + RAM
2. Writes reset vectors (`SSP` at `0x00000000`, `PC` at `0x00000004`)
3. Writes a tiny program (`NOP`, then `STOP #$2700`)
4. Runs until STOP

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "m68k.h"

int main(void) {
    const u32 mem_size = 1024 * 1024;
    u8* ram = calloc(mem_size, 1);
    if (!ram) return 1;

    M68kCpu cpu;
    m68k_init(&cpu, ram, mem_size);

    /* Reset vectors */
    m68k_write_32(&cpu, 0x00000000, 0x0000FF00); /* initial SSP */
    m68k_write_32(&cpu, 0x00000004, 0x00000100); /* initial PC  */

    /* Program at 0x100: NOP; STOP #$2700 */
    m68k_write_16(&cpu, 0x00000100, 0x4E71);
    m68k_write_16(&cpu, 0x00000102, 0x4E72);
    m68k_write_16(&cpu, 0x00000104, 0x2700);

    m68k_reset(&cpu);

    int total_cycles = 0;
    while (!cpu.stopped) {
        total_cycles += m68k_execute(&cpu, 32);
    }

    printf("Stopped. cycles=%d pc=0x%08X\n", total_cycles, cpu.pc);

    free(ram);
    return 0;
}
```

## 3. Running Without Reset Vectors

You can also set state directly:

```c
m68k_set_ar(&cpu, 7, 0x0000FF00); /* A7/SP */
m68k_set_sr(&cpu, 0x2700);         /* supervisor mode */
m68k_set_pc(&cpu, 0x00000100);
```

Use this pattern when your host controls boot flow explicitly.

## 4. Basic Execution Model

- `m68k_step(&cpu)` executes one instruction (with interrupt/trace checks).
- `m68k_execute(&cpu, cycles)` runs until the timeslice is exhausted.
- `m68k_cycles_run(&cpu)` and `m68k_cycles_remaining(&cpu)` report timeslice accounting.
- `m68k_end_timeslice(&cpu)` forces the current timeslice to finish.

## 5. Callback Wiring (Optional)

```c
static void wait_bus(M68kCpu* cpu, u32 address, M68kSize size) {
    (void)address;
    (void)size;
    /* Add 2 wait-state cycles for each access */
    cpu->cycles_remaining -= 2;
}

static int int_ack(M68kCpu* cpu, int level) {
    (void)cpu;
    (void)level;
    return M68K_INT_ACK_AUTOVECTOR;
}

m68k_set_wait_bus_callback(&cpu, wait_bus);
m68k_set_int_ack_callback(&cpu, int_ack);
```

For mapped-memory or MMIO host integration, see the host bus callback example in [Examples](examples.md#6-use-a-host-bus-with-memory-callbacks).

## 6. Useful Notes

- Memory accesses are checked against `cpu.memory_size`; out-of-range accesses trigger bus error handling.
- Internally, addresses are masked to 24-bit before validation.
- `M68kCpu` state is instance-local, so multiple CPU instances can run independently.
