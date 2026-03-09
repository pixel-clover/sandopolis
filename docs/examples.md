# Examples

These examples focus on common host-integration patterns.
All snippets use only public headers.

## 1. Run a Small Program from Reset Vectors

This example initializes RAM, writes reset vectors, and runs until `STOP`.

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rocket68.h"

int main(void) {
    const u32 mem_size = 1024 * 1024;
    u8* ram = calloc(mem_size, 1);
    if (!ram) return 1;

    M68kCpu cpu;
    m68k_init(&cpu, ram, mem_size);

    /* Reset vectors */
    m68k_write_32(&cpu, 0x00000000, 0x0000FF00); /* SSP */
    m68k_write_32(&cpu, 0x00000004, 0x00000100); /* PC  */

    /* Program: NOP; STOP #$2700 */
    m68k_write_16(&cpu, 0x00000100, 0x4E71);
    m68k_write_16(&cpu, 0x00000102, 0x4E72);
    m68k_write_16(&cpu, 0x00000104, 0x2700);

    m68k_reset(&cpu);

    while (!cpu.stopped) {
        m68k_execute(&cpu, 32);
    }

    printf("Stopped at PC=0x%08X\n", m68k_get_pc(&cpu));

    free(ram);
    return 0;
}
```

## 2. Start from Host-Controlled State

Use this when your platform sets CPU state directly instead of using vector table boot.

```c
M68kCpu cpu;
m68k_init(&cpu, ram, mem_size);

m68k_set_ar(&cpu, 7, 0x0000FF00); /* A7/SP */
m68k_set_sr(&cpu, 0x2700);         /* Supervisor mode */
m68k_set_pc(&cpu, 0x00001000);

for (int i = 0; i < 100 && !cpu.stopped; i++) {
    m68k_step(&cpu);
}
```

## 3. Interrupt Handling with `int_ack`

`m68k_set_irq` sets a pending level (0-7). The core checks interrupts on step boundaries.

```c
#include "rocket68.h"

static int my_int_ack(M68kCpu* cpu, int level) {
    (void)cpu;
    (void)level;

    /* Return autovector (level 3 -> vector 27). */
    return M68K_INT_ACK_AUTOVECTOR;
}

void setup_interrupt_demo(M68kCpu* cpu) {
    m68k_set_int_ack_callback(cpu, my_int_ack);

    /* Raise level-3 interrupt. */
    m68k_set_irq(cpu, 3);

    /* Run some time; interrupt will be taken if mask allows it. */
    m68k_execute(cpu, 128);
}
```

## 4. Model Wait States with `wait_bus`

`wait_bus` is called on memory reads, memory writes, and instruction fetches.

```c
#include "rocket68.h"

static void wait_bus(M68kCpu* cpu, u32 address, M68kSize size) {
    (void)address;
    (void)size;

    /* Add 2 extra cycles for each bus access. */
    cpu->cycles_remaining -= 2;
}

void attach_wait_states(M68kCpu* cpu) {
    m68k_set_wait_bus_callback(cpu, wait_bus);
}
```

## 5. Track Access Context with `fc_callback`

Function-code callback reports whether access is user/supervisor and data/program.

```c
#include <stdio.h>
#include "rocket68.h"

static void fc_trace(M68kCpu* cpu, unsigned int fc) {
    (void)cpu;

    const char* name = "UNKNOWN";
    if (fc == M68K_FC_USER_DATA) name = "USER_DATA";
    else if (fc == M68K_FC_USER_PROG) name = "USER_PROG";
    else if (fc == M68K_FC_SUPV_DATA) name = "SUPV_DATA";
    else if (fc == M68K_FC_SUPV_PROG) name = "SUPV_PROG";

    printf("FC: %s (%u)\n", name, fc);
}

void attach_fc_trace(M68kCpu* cpu) {
    m68k_set_fc_callback(cpu, fc_trace);
}
```

## 6. Use a Host Bus with Memory Callbacks

Use this when you need mapped IO/peripherals instead of a flat RAM array.

```c
#include "rocket68.h"

typedef struct {
    u8 ram[64 * 1024];
    u8 io_reg;
} HostBus;

static u8 bus_read8(M68kCpu* cpu, u32 addr) {
    HostBus* bus = (HostBus*)cpu->memory; /* host-owned pointer convention */
    addr &= 0x00FFFFFF;

    if (addr == 0x00A10001) return bus->io_reg;  /* simple MMIO read */
    if (addr < sizeof(bus->ram)) return bus->ram[addr];
    return 0xFF;
}

static void bus_write8(M68kCpu* cpu, u32 addr, u8 value) {
    HostBus* bus = (HostBus*)cpu->memory;
    addr &= 0x00FFFFFF;

    if (addr == 0x00A10001) {
        bus->io_reg = value;  /* simple MMIO write */
        return;
    }
    if (addr < sizeof(bus->ram)) {
        bus->ram[addr] = value;
    }
}

/* Width wrappers can use your own bus logic directly. */
static u16 bus_read16(M68kCpu* cpu, u32 addr) {
    return (u16)((bus_read8(cpu, addr) << 8) | bus_read8(cpu, addr + 1));
}

static u32 bus_read32(M68kCpu* cpu, u32 addr) {
    return ((u32)bus_read16(cpu, addr) << 16) | bus_read16(cpu, addr + 2);
}

static void bus_write16(M68kCpu* cpu, u32 addr, u16 value) {
    bus_write8(cpu, addr, (u8)(value >> 8));
    bus_write8(cpu, addr + 1, (u8)value);
}

static void bus_write32(M68kCpu* cpu, u32 addr, u32 value) {
    bus_write16(cpu, addr, (u16)(value >> 16));
    bus_write16(cpu, addr + 2, (u16)value);
}

void attach_bus(M68kCpu* cpu, HostBus* bus) {
    /* memory/memory_size can be repurposed for host state when callbacks are installed */
    m68k_init(cpu, (u8*)bus, sizeof(*bus));

    m68k_set_read8_callback(cpu, bus_read8);
    m68k_set_read16_callback(cpu, bus_read16);
    m68k_set_read32_callback(cpu, bus_read32);
    m68k_set_write8_callback(cpu, bus_write8);
    m68k_set_write16_callback(cpu, bus_write16);
    m68k_set_write32_callback(cpu, bus_write32);
}
```

Note:

- When a callback for a given width is installed, Rocket68 dispatches through that callback for that width.
- Pass `NULL` to any `m68k_set_*_callback` setter to fall back to flat-memory behavior for that width.

## 7. Save and Restore CPU Context

Use this for save states or rewind.

```c
#include <stdlib.h>
#include <string.h>
#include "rocket68.h"

void save_and_restore(M68kCpu* cpu) {
    const unsigned int ctx_size = m68k_context_size();
    void* blob = malloc(ctx_size);
    if (!blob) return;

    m68k_get_context(cpu, blob);

    /* Run forward a bit. */
    m68k_execute(cpu, 256);

    /* Restore prior state. */
    m68k_set_context(cpu, blob);

    free(blob);
}
```

Note:

- `m68k_set_context` preserves the destination CPU's memory binding and installed callbacks.
- Save-state data should be reused with the same Rocket68 build/config.

## 8. Load Programs from S-Record or Binary

```c
#include "rocket68.h"

bool load_program(M68kCpu* cpu) {
    if (!m68k_load_srec(cpu, "firmware.srec")) {
        return false; /* File open failed. */
    }

    if (!m68k_load_bin(cpu, "overlay.bin", 0x00020000)) {
        return false; /* File open failed. */
    }

    return true;
}
```

Notes:

- For loader edge-case behavior (malformed records, checksum policy, entry-point handling), see [API Reference](api-reference.md) and [Compatibility Notes](compatibility.md).

## 9. Disassemble Memory for Debug Output

```c
#include <stdio.h>
#include "rocket68.h"

void dump_disasm(M68kCpu* cpu, u32 pc, int count) {
    for (int i = 0; i < count; i++) {
        char text[128];
        int used = m68k_disasm(cpu, pc, text, (int)sizeof(text));

        printf("%08X: %s\n", pc, text);

        if (used <= 0) {
            break;
        }
        pc += (u32)used;
    }
}
```

For disassembly return semantics, see [API Reference](api-reference.md).
