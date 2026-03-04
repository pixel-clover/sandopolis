#include "jgz80_bridge.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "z80.h"

struct Jgz80Handle {
    z80 core;
    uint8_t ram[8 * 1024];
    bool bus_req;
    bool bus_ack;
    bool reset_line;
};

static uint8_t bridge_read_byte(void* userdata, uint16_t addr) {
    Jgz80Handle* h = (Jgz80Handle*)userdata;
    return h->ram[addr & 0x1FFFu];
}

static void bridge_write_byte(void* userdata, uint16_t addr, uint8_t val) {
    Jgz80Handle* h = (Jgz80Handle*)userdata;
    h->ram[addr & 0x1FFFu] = val;
}

static uint8_t bridge_port_in(z80* z, uint16_t port) {
    (void)z;
    (void)port;
    return 0xFFu;
}

static void bridge_port_out(z80* z, uint16_t port, uint8_t val) {
    (void)z;
    (void)port;
    (void)val;
}

static void bind_callbacks(Jgz80Handle* h) {
    h->core.userdata = h;
    h->core.read_byte = bridge_read_byte;
    h->core.write_byte = bridge_write_byte;
    h->core.port_in = bridge_port_in;
    h->core.port_out = bridge_port_out;
}

Jgz80Handle* jgz80_create(void) {
    Jgz80Handle* h = (Jgz80Handle*)calloc(1, sizeof(Jgz80Handle));
    if (!h) return NULL;

    z80_init(&h->core);
    bind_callbacks(h);
    memset(h->ram, 0, sizeof(h->ram));
    return h;
}

void jgz80_destroy(Jgz80Handle* handle) {
    free(handle);
}

void jgz80_reset(Jgz80Handle* handle) {
    if (!handle) return;
    bind_callbacks(handle);
    handle->bus_req = false;
    handle->bus_ack = false;
    handle->reset_line = false;
    memset(handle->ram, 0, sizeof(handle->ram));
    z80_reset(&handle->core);
}

void jgz80_step(Jgz80Handle* handle, uint32_t cycles) {
    if (!handle) return;
    bind_callbacks(handle);
    if (handle->bus_req || handle->reset_line) return;
    (void)z80_step_n(&handle->core, cycles);
}

uint8_t jgz80_read_byte(Jgz80Handle* handle, uint16_t addr) {
    if (!handle) return 0;
    return handle->ram[addr & 0x1FFFu];
}

void jgz80_write_byte(Jgz80Handle* handle, uint16_t addr, uint8_t val) {
    if (!handle) return;
    handle->ram[addr & 0x1FFFu] = val;
}

void jgz80_write_bus_req(Jgz80Handle* handle, uint16_t val) {
    if (!handle) return;
    if ((val & 0x100u) != 0u) {
        handle->bus_req = false;
        handle->bus_ack = false;
    } else {
        handle->bus_req = true;
        handle->bus_ack = true;
    }
}

uint16_t jgz80_read_bus_req(Jgz80Handle* handle) {
    if (!handle) return 0x0100u;
    return handle->bus_req ? 0x0000u : 0x0100u;
}

void jgz80_write_reset(Jgz80Handle* handle, uint16_t val) {
    if (!handle) return;
    bind_callbacks(handle);
    if (val == 0u) {
        handle->reset_line = true;
        z80_reset(&handle->core);
        memset(handle->ram, 0, sizeof(handle->ram));
    } else {
        handle->reset_line = false;
    }
}
