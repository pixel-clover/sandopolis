#include "jgz80_bridge.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "z80.h"

struct Jgz80Handle {
    z80 core;
    uint8_t ram[8 * 1024];
    uint16_t bank;
    uint8_t ym_addr[2];
    uint8_t ym_regs[2][256];
    uint8_t ym_key_mask;
    uint8_t psg_last;
    uint16_t psg_tone[3];
    uint8_t psg_volume[4];
    uint8_t psg_noise;
    uint8_t psg_latched_channel;
    bool psg_latched_is_volume;
    Jgz80HostReadFunc host_read;
    Jgz80HostWriteFunc host_write;
    void* host_userdata;
    bool bus_req;
    bool bus_ack;
    bool reset_line;
};

static uint8_t mapped_read_byte(Jgz80Handle* h, uint16_t addr) {
    const uint16_t zaddr = (uint16_t)(addr & 0xFFFFu);
    if (zaddr < 0x2000u) {
        return h->ram[zaddr & 0x1FFFu];
    }

    if (zaddr >= 0x4000u && zaddr <= 0x4003u) {
        return 0u;
    }

    if (zaddr == 0x7F11u) {
        return 0xFFu;
    }

    if (zaddr >= 0x7F00u && zaddr <= 0x7FFFu) {
        if (h->host_read != NULL) {
            return h->host_read(h->host_userdata, 0xC00000u + (zaddr & 0x1Fu));
        }
        return 0xFFu;
    }

    if (zaddr >= 0x8000u) {
        if (h->host_read != NULL) {
            const uint32_t m68k_addr = ((uint32_t)h->bank << 15) | (uint32_t)(zaddr & 0x7FFFu);
            return h->host_read(h->host_userdata, m68k_addr);
        }
        return 0xFFu;
    }

    return 0xFFu;
}

static void mapped_write_byte(Jgz80Handle* h, uint16_t addr, uint8_t val) {
    const uint16_t zaddr = (uint16_t)(addr & 0xFFFFu);
    if (zaddr < 0x2000u) {
        h->ram[zaddr & 0x1FFFu] = val;
        return;
    }

    if (zaddr >= 0x4000u && zaddr <= 0x4003u) {
        const uint8_t port_index = (uint8_t)((zaddr >> 1) & 1u);
        const bool is_data = (zaddr & 1u) != 0u;
        if (!is_data) {
            h->ym_addr[port_index] = val;
        } else {
            const uint8_t reg = h->ym_addr[port_index];
            h->ym_regs[port_index][reg] = val;
            if (port_index == 0u && reg == 0x28u) {
                uint8_t channel = val & 0x03u;
                if (channel != 3u) {
                    if ((val & 0x04u) != 0u) {
                        channel = (uint8_t)(channel + 3u);
                    }
                    if ((val & 0xF0u) != 0u) {
                        h->ym_key_mask |= (uint8_t)(1u << channel);
                    } else {
                        h->ym_key_mask &= (uint8_t)~(1u << channel);
                    }
                }
            }
        }
        return;
    }

    if (zaddr == 0x7F11u) {
        h->psg_last = val;
        if ((val & 0x80u) != 0u) {
            const uint8_t channel = (val >> 5) & 0x03u;
            const bool is_volume = (val & 0x10u) != 0u;
            h->psg_latched_channel = channel;
            h->psg_latched_is_volume = is_volume;

            if (is_volume) {
                h->psg_volume[channel] = val & 0x0Fu;
            } else if (channel < 3) {
                h->psg_tone[channel] &= 0x3F0u;
                h->psg_tone[channel] |= val & 0x0Fu;
            } else {
                h->psg_noise = val & 0x07u;
            }
        } else {
            const uint8_t channel = h->psg_latched_channel & 0x03u;
            if (h->psg_latched_is_volume) {
                h->psg_volume[channel] = val & 0x0Fu;
            } else if (channel < 3) {
                h->psg_tone[channel] &= 0x00Fu;
                h->psg_tone[channel] |= (uint16_t)(val & 0x3Fu) << 4;
            } else {
                h->psg_noise = val & 0x07u;
            }
        }
        return;
    }

    if (zaddr >= 0x6000u && zaddr < 0x6100u) {
        h->bank >>= 1;
        h->bank |= (val & 1u) != 0u ? 0x100u : 0u;
        return;
    }

    if (zaddr >= 0x7F00u && zaddr <= 0x7FFFu) {
        if (h->host_write != NULL) {
            h->host_write(h->host_userdata, 0xC00000u + (zaddr & 0x1Fu), val);
        }
        return;
    }

    if (zaddr >= 0x8000u) {
        if (h->host_write != NULL) {
            const uint32_t m68k_addr = ((uint32_t)h->bank << 15) | (uint32_t)(zaddr & 0x7FFFu);
            h->host_write(h->host_userdata, m68k_addr, val);
        }
        return;
    }
}

static uint8_t bridge_read_byte(void* userdata, uint16_t addr) {
    Jgz80Handle* h = (Jgz80Handle*)userdata;
    return mapped_read_byte(h, addr);
}

static void bridge_write_byte(void* userdata, uint16_t addr, uint8_t val) {
    Jgz80Handle* h = (Jgz80Handle*)userdata;
    mapped_write_byte(h, addr, val);
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
    h->bank = 0;
    memset(h->ym_addr, 0, sizeof(h->ym_addr));
    memset(h->ym_regs, 0, sizeof(h->ym_regs));
    h->ym_key_mask = 0;
    h->psg_last = 0;
    memset(h->psg_tone, 0, sizeof(h->psg_tone));
    memset(h->psg_volume, 0x0F, sizeof(h->psg_volume));
    h->psg_noise = 0;
    h->psg_latched_channel = 0;
    h->psg_latched_is_volume = false;
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
    handle->bank = 0;
    memset(handle->ym_addr, 0, sizeof(handle->ym_addr));
    memset(handle->ym_regs, 0, sizeof(handle->ym_regs));
    handle->ym_key_mask = 0;
    handle->psg_last = 0;
    memset(handle->psg_tone, 0, sizeof(handle->psg_tone));
    memset(handle->psg_volume, 0x0F, sizeof(handle->psg_volume));
    handle->psg_noise = 0;
    handle->psg_latched_channel = 0;
    handle->psg_latched_is_volume = false;
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
    return mapped_read_byte(handle, addr);
}

void jgz80_write_byte(Jgz80Handle* handle, uint16_t addr, uint8_t val) {
    if (!handle) return;
    mapped_write_byte(handle, addr, val);
}

void jgz80_set_host_callbacks(Jgz80Handle* handle, Jgz80HostReadFunc host_read, Jgz80HostWriteFunc host_write, void* userdata) {
    if (!handle) return;
    handle->host_read = host_read;
    handle->host_write = host_write;
    handle->host_userdata = userdata;
}

uint16_t jgz80_get_bank(Jgz80Handle* handle) {
    if (!handle) return 0u;
    return handle->bank;
}

uint8_t jgz80_get_ym_register(Jgz80Handle* handle, uint8_t port, uint8_t reg) {
    if (!handle || (port & ~1u) != 0u) return 0u;
    return handle->ym_regs[port][reg];
}

uint8_t jgz80_get_ym_key_mask(Jgz80Handle* handle) {
    if (!handle) return 0u;
    return handle->ym_key_mask & 0x3Fu;
}

uint8_t jgz80_get_psg_last(Jgz80Handle* handle) {
    if (!handle) return 0u;
    return handle->psg_last;
}

uint16_t jgz80_get_psg_tone(Jgz80Handle* handle, uint8_t channel) {
    if (!handle || channel >= 3u) return 0u;
    return handle->psg_tone[channel] & 0x03FFu;
}

uint8_t jgz80_get_psg_volume(Jgz80Handle* handle, uint8_t channel) {
    if (!handle || channel >= 4u) return 0x0Fu;
    return handle->psg_volume[channel] & 0x0Fu;
}

uint8_t jgz80_get_psg_noise(Jgz80Handle* handle) {
    if (!handle) return 0u;
    return handle->psg_noise & 0x07u;
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
