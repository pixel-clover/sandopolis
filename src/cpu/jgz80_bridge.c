#include "jgz80_bridge.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "z80.h"

enum {
    YM_DAC_BUFFER_CAPACITY = 4096,
    YM_WRITE_BUFFER_CAPACITY = 32768,
    YM_RESET_BUFFER_CAPACITY = 64,
    PSG_COMMAND_BUFFER_CAPACITY = 8192,
};

struct Jgz80Handle {
    z80 core;
    uint8_t ram[8 * 1024];
    uint16_t bank;
    uint32_t audio_master_offset;
    uint8_t ym_addr[2];
    uint8_t ym_regs[2][256];
    uint8_t ym_key_mask;
    Jgz80YmWriteEvent ym_write_events[YM_WRITE_BUFFER_CAPACITY];
    uint16_t ym_write_write_index;
    uint16_t ym_write_read_index;
    uint16_t ym_write_count;
    Jgz80YmDacSampleEvent ym_dac_samples[YM_DAC_BUFFER_CAPACITY];
    uint16_t ym_dac_write_index;
    uint16_t ym_dac_read_index;
    uint16_t ym_dac_count;
    Jgz80YmResetEvent ym_reset_events[YM_RESET_BUFFER_CAPACITY];
    uint16_t ym_reset_write_index;
    uint16_t ym_reset_read_index;
    uint16_t ym_reset_count;
    Jgz80PsgCommandEvent psg_commands[PSG_COMMAND_BUFFER_CAPACITY];
    uint16_t psg_command_write_index;
    uint16_t psg_command_read_index;
    uint16_t psg_command_count;
    uint8_t psg_last;
    uint16_t psg_tone[3];
    uint8_t psg_volume[4];
    uint8_t psg_noise;
    uint8_t psg_latched_channel;
    bool psg_latched_is_volume;
    Jgz80HostReadFunc host_read;
    Jgz80HostWriteFunc host_write;
    void *host_userdata;
    bool bus_req;
    bool bus_ack;
    bool reset_line;
    uint32_t m68k_bus_access_count;
};

static void clear_ym2612_shadow_state(Jgz80Handle *h) {
    memset(h->ym_addr, 0, sizeof(h->ym_addr));
    memset(h->ym_regs, 0, sizeof(h->ym_regs));
    h->ym_key_mask = 0;
}

static void clear_ym2612_event_queues(Jgz80Handle *h) {
    h->ym_write_write_index = 0;
    h->ym_write_read_index = 0;
    h->ym_write_count = 0;
    h->ym_dac_write_index = 0;
    h->ym_dac_read_index = 0;
    h->ym_dac_count = 0;
    h->ym_reset_write_index = 0;
    h->ym_reset_read_index = 0;
    h->ym_reset_count = 0;
}

static void reset_ym2612_state(Jgz80Handle *h) {
    clear_ym2612_shadow_state(h);
    clear_ym2612_event_queues(h);
}

static void push_ym_write_event(Jgz80Handle *h, uint8_t port, uint8_t reg, uint8_t value) {
    if (h->ym_write_count == YM_WRITE_BUFFER_CAPACITY) {
        h->ym_write_read_index = (uint16_t)((h->ym_write_read_index + 1u) % YM_WRITE_BUFFER_CAPACITY);
        --h->ym_write_count;
    }

    h->ym_write_events[h->ym_write_write_index].master_offset = h->audio_master_offset;
    h->ym_write_events[h->ym_write_write_index].port = port;
    h->ym_write_events[h->ym_write_write_index].reg = reg;
    h->ym_write_events[h->ym_write_write_index].value = value;
    h->ym_write_write_index = (uint16_t)((h->ym_write_write_index + 1u) % YM_WRITE_BUFFER_CAPACITY);
    ++h->ym_write_count;
}

static void push_psg_command(Jgz80Handle *h, uint8_t value) {
    if (h->psg_command_count == PSG_COMMAND_BUFFER_CAPACITY) {
        h->psg_command_read_index = (uint16_t)((h->psg_command_read_index + 1u) % PSG_COMMAND_BUFFER_CAPACITY);
        --h->psg_command_count;
    }

    h->psg_commands[h->psg_command_write_index].master_offset = h->audio_master_offset;
    h->psg_commands[h->psg_command_write_index].value = value;
    h->psg_command_write_index = (uint16_t)((h->psg_command_write_index + 1u) % PSG_COMMAND_BUFFER_CAPACITY);
    ++h->psg_command_count;
}

static void push_ym_dac_sample(Jgz80Handle *h, uint8_t value) {
    if (h->ym_dac_count == YM_DAC_BUFFER_CAPACITY) {
        h->ym_dac_read_index = (uint16_t)((h->ym_dac_read_index + 1u) % YM_DAC_BUFFER_CAPACITY);
        --h->ym_dac_count;
    }

    h->ym_dac_samples[h->ym_dac_write_index].master_offset = h->audio_master_offset;
    h->ym_dac_samples[h->ym_dac_write_index].value = value;
    h->ym_dac_write_index = (uint16_t)((h->ym_dac_write_index + 1u) % YM_DAC_BUFFER_CAPACITY);
    ++h->ym_dac_count;
}

static void push_ym_reset_event(Jgz80Handle *h) {
    if (h->ym_reset_count == YM_RESET_BUFFER_CAPACITY) {
        h->ym_reset_read_index = (uint16_t)((h->ym_reset_read_index + 1u) % YM_RESET_BUFFER_CAPACITY);
        --h->ym_reset_count;
    }

    h->ym_reset_events[h->ym_reset_write_index].master_offset = h->audio_master_offset;
    h->ym_reset_write_index = (uint16_t)((h->ym_reset_write_index + 1u) % YM_RESET_BUFFER_CAPACITY);
    ++h->ym_reset_count;
}

static uint8_t mapped_read_byte(Jgz80Handle *h, uint16_t addr) {
    const uint16_t zaddr = (uint16_t)(addr & 0xFFFFu);
    if (zaddr < 0x2000u) {
        return h->ram[zaddr & 0x1FFFu];
    }

    if (zaddr >= 0x4000u && zaddr < 0x6000u) {
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
            const uint32_t m68k_addr = ((uint32_t) h->bank << 15) | (uint32_t)(zaddr & 0x7FFFu);
            ++h->m68k_bus_access_count;
            return h->host_read(h->host_userdata, m68k_addr);
        }
        return 0xFFu;
    }

    return 0xFFu;
}

static void mapped_write_byte(Jgz80Handle *h, uint16_t addr, uint8_t val) {
    const uint16_t zaddr = (uint16_t)(addr & 0xFFFFu);
    if (zaddr < 0x2000u) {
        h->ram[zaddr & 0x1FFFu] = val;
        return;
    }

    if (zaddr >= 0x4000u && zaddr < 0x6000u) {
        const uint8_t port_index = (uint8_t)((zaddr >> 1) & 1u);
        const bool is_data = (zaddr & 1u) != 0u;
        if (!is_data) {
            h->ym_addr[port_index] = val;
        } else {
            const uint8_t reg = h->ym_addr[port_index];
            h->ym_regs[port_index][reg] = val;
            if (port_index == 0u && reg == 0x2Au) {
                push_ym_dac_sample(h, val);
            } else {
                push_ym_write_event(h, port_index, reg, val);
            }
            if (port_index == 0u && reg == 0x28u) {
                uint8_t channel = val & 0x03u;
                if (channel != 3u) {
                    if ((val & 0x04u) != 0u) {
                        channel = (uint8_t)(channel + 3u);
                    }
                    if ((val & 0xF0u) != 0u) {
                        h->ym_key_mask |= (uint8_t)(1u << channel);
                    } else {
                        h->ym_key_mask &= (uint8_t) ~(1u << channel);
                    }
                }
            }
        }
        return;
    }

    if (zaddr == 0x7F11u) {
        push_psg_command(h, val);
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
            const uint32_t m68k_addr = ((uint32_t) h->bank << 15) | (uint32_t)(zaddr & 0x7FFFu);
            ++h->m68k_bus_access_count;
            h->host_write(h->host_userdata, m68k_addr, val);
        }
        return;
    }
}

static uint8_t bridge_read_byte(void *userdata, uint16_t addr) {
    Jgz80Handle *h = (Jgz80Handle *) userdata;
    return mapped_read_byte(h, addr);
}

static void bridge_write_byte(void *userdata, uint16_t addr, uint8_t val) {
    Jgz80Handle *h = (Jgz80Handle *) userdata;
    mapped_write_byte(h, addr, val);
}

static uint8_t bridge_port_in(z80 *z, uint16_t port) {
    (void) z;
    (void) port;
    return 0xFFu;
}

static void bridge_port_out(z80 *z, uint16_t port, uint8_t val) {
    (void) z;
    (void) port;
    (void) val;
}

static void bind_callbacks(Jgz80Handle *h) {
    h->core.userdata = h;
    h->core.read_byte = bridge_read_byte;
    h->core.write_byte = bridge_write_byte;
    h->core.port_in = bridge_port_in;
    h->core.port_out = bridge_port_out;
}

Jgz80Handle *jgz80_create(void) {
    Jgz80Handle *h = (Jgz80Handle *) calloc(1, sizeof(Jgz80Handle));
    if (!h) return NULL;

    z80_init(&h->core);
    bind_callbacks(h);
    memset(h->ram, 0, sizeof(h->ram));
    h->bank = 0;
    h->audio_master_offset = 0;
    reset_ym2612_state(h);
    h->psg_last = 0;
    memset(h->psg_tone, 0, sizeof(h->psg_tone));
    memset(h->psg_volume, 0x0F, sizeof(h->psg_volume));
    h->psg_noise = 0;
    h->psg_latched_channel = 0;
    h->psg_latched_is_volume = false;
    h->m68k_bus_access_count = 0;
    return h;
}

void jgz80_destroy(Jgz80Handle *handle) {
    free(handle);
}

void jgz80_reset(Jgz80Handle *handle) {
    if (!handle) return;
    bind_callbacks(handle);
    handle->bus_req = false;
    handle->bus_ack = false;
    handle->reset_line = false;
    memset(handle->ram, 0, sizeof(handle->ram));
    handle->bank = 0;
    handle->audio_master_offset = 0;
    reset_ym2612_state(handle);
    handle->psg_last = 0;
    memset(handle->psg_tone, 0, sizeof(handle->psg_tone));
    memset(handle->psg_volume, 0x0F, sizeof(handle->psg_volume));
    handle->psg_noise = 0;
    handle->psg_latched_channel = 0;
    handle->psg_latched_is_volume = false;
    handle->m68k_bus_access_count = 0;
    z80_reset(&handle->core);
}

void jgz80_step(Jgz80Handle *handle, uint32_t cycles) {
    if (!handle) return;
    bind_callbacks(handle);
    if (handle->bus_req || handle->reset_line) return;
    (void) z80_step_n(&handle->core, cycles);
}

uint32_t jgz80_step_one(Jgz80Handle *handle) {
    if (!handle) return 0;
    bind_callbacks(handle);
    if (handle->bus_req || handle->reset_line) return 0;
    return z80_step(&handle->core);
}

uint8_t jgz80_read_byte(Jgz80Handle *handle, uint16_t addr) {
    if (!handle) return 0;
    return mapped_read_byte(handle, addr);
}

void jgz80_write_byte(Jgz80Handle *handle, uint16_t addr, uint8_t val) {
    if (!handle) return;
    mapped_write_byte(handle, addr, val);
}

void jgz80_set_host_callbacks(Jgz80Handle *handle, Jgz80HostReadFunc host_read, Jgz80HostWriteFunc host_write,
                              void *userdata) {
    if (!handle) return;
    handle->host_read = host_read;
    handle->host_write = host_write;
    handle->host_userdata = userdata;
}

uint16_t jgz80_get_bank(Jgz80Handle *handle) {
    if (!handle) return 0u;
    return handle->bank;
}

uint16_t jgz80_get_pc(Jgz80Handle *handle) {
    if (!handle) return 0u;
    return handle->core.pc;
}

Jgz80RegisterDump jgz80_get_register_dump(Jgz80Handle *handle) {
    Jgz80RegisterDump dump;
    memset(&dump, 0, sizeof(dump));
    if (!handle) return dump;

    dump.pc = handle->core.pc;
    dump.sp = handle->core.sp;
    dump.ix = handle->core.ix;
    dump.iy = handle->core.iy;
    dump.af = handle->core.af;
    dump.bc = handle->core.bc;
    dump.de = handle->core.de;
    dump.hl = handle->core.hl;
    dump.af_alt = handle->core.a_f_;
    dump.bc_alt = handle->core.b_c_;
    dump.de_alt = handle->core.d_e_;
    dump.hl_alt = handle->core.h_l_;
    dump.ir = (uint16_t)(((uint16_t) handle->core.i << 8) | handle->core.r);
    dump.wz = handle->core.mem_ptr;
    dump.interrupt_mode = handle->core.interrupt_mode;
    dump.irq_data = handle->core.irq_data;
    dump.iff1 = handle->core.iff1 ? 1u : 0u;
    dump.iff2 = handle->core.iff2 ? 1u : 0u;
    dump.halted = handle->core.halted ? 1u : 0u;
    return dump;
}

uint8_t jgz80_get_ym_register(Jgz80Handle *handle, uint8_t port, uint8_t reg) {
    if (!handle || (port & ~1u) != 0u) return 0u;
    return handle->ym_regs[port][reg];
}

uint8_t jgz80_get_ym_key_mask(Jgz80Handle *handle) {
    if (!handle) return 0u;
    return handle->ym_key_mask & 0x3Fu;
}

uint16_t jgz80_take_ym_writes(Jgz80Handle *handle, Jgz80YmWriteEvent *dest, uint16_t max_events) {
    uint16_t copied = 0u;

    if (!handle || !dest || max_events == 0u) return 0u;

    while (copied < max_events && handle->ym_write_count != 0u) {
        dest[copied] = handle->ym_write_events[handle->ym_write_read_index];
        ++copied;
        handle->ym_write_read_index = (uint16_t)((handle->ym_write_read_index + 1u) % YM_WRITE_BUFFER_CAPACITY);
        --handle->ym_write_count;
    }

    return copied;
}

uint16_t jgz80_take_ym_dac_samples(Jgz80Handle *handle, Jgz80YmDacSampleEvent *dest, uint16_t max_samples) {
    uint16_t copied = 0u;

    if (!handle || !dest || max_samples == 0u) return 0u;

    while (copied < max_samples && handle->ym_dac_count != 0u) {
        dest[copied] = handle->ym_dac_samples[handle->ym_dac_read_index];
        ++copied;
        handle->ym_dac_read_index = (uint16_t)((handle->ym_dac_read_index + 1u) % YM_DAC_BUFFER_CAPACITY);
        --handle->ym_dac_count;
    }

    return copied;
}

uint16_t jgz80_take_ym_resets(Jgz80Handle *handle, Jgz80YmResetEvent *dest, uint16_t max_events) {
    uint16_t copied = 0u;

    if (!handle || !dest || max_events == 0u) return 0u;

    while (copied < max_events && handle->ym_reset_count != 0u) {
        dest[copied] = handle->ym_reset_events[handle->ym_reset_read_index];
        ++copied;
        handle->ym_reset_read_index = (uint16_t)((handle->ym_reset_read_index + 1u) % YM_RESET_BUFFER_CAPACITY);
        --handle->ym_reset_count;
    }

    return copied;
}

uint16_t jgz80_take_psg_commands(Jgz80Handle *handle, Jgz80PsgCommandEvent *dest, uint16_t max_commands) {
    uint16_t copied = 0u;

    if (!handle || !dest || max_commands == 0u) return 0u;

    while (copied < max_commands && handle->psg_command_count != 0u) {
        dest[copied] = handle->psg_commands[handle->psg_command_read_index];
        ++copied;
        handle->psg_command_read_index = (
            uint16_t)((handle->psg_command_read_index + 1u) % PSG_COMMAND_BUFFER_CAPACITY);
        --handle->psg_command_count;
    }

    return copied;
}

uint8_t jgz80_get_psg_last(Jgz80Handle *handle) {
    if (!handle) return 0u;
    return handle->psg_last;
}

uint16_t jgz80_get_psg_tone(Jgz80Handle *handle, uint8_t channel) {
    if (!handle || channel >= 3u) return 0u;
    return handle->psg_tone[channel] & 0x03FFu;
}

uint8_t jgz80_get_psg_volume(Jgz80Handle *handle, uint8_t channel) {
    if (!handle || channel >= 4u) return 0x0Fu;
    return handle->psg_volume[channel] & 0x0Fu;
}

uint8_t jgz80_get_psg_noise(Jgz80Handle *handle) {
    if (!handle) return 0u;
    return handle->psg_noise & 0x07u;
}

uint32_t jgz80_take_68k_bus_access_count(Jgz80Handle *handle) {
    if (!handle) return 0u;
    const uint32_t count = handle->m68k_bus_access_count;
    handle->m68k_bus_access_count = 0;
    return count;
}

void jgz80_set_audio_master_offset(Jgz80Handle *handle, uint32_t master_offset) {
    if (!handle) return;
    handle->audio_master_offset = master_offset;
}

void jgz80_assert_irq(Jgz80Handle *handle, uint8_t data) {
    if (!handle) return;
    z80_assert_irq(&handle->core, data);
}

void jgz80_clear_irq(Jgz80Handle *handle) {
    if (!handle) return;
    z80_clr_irq(&handle->core);
}

void jgz80_write_bus_req(Jgz80Handle *handle, uint16_t val) {
    if (!handle) return;
    handle->bus_req = (val & 0x100u) != 0u;
    handle->bus_ack = handle->bus_req && !handle->reset_line;
}

uint16_t jgz80_read_bus_req(Jgz80Handle *handle) {
    if (!handle) return 0x0100u;
    return handle->bus_ack ? 0x0000u : 0x0100u;
}

uint16_t jgz80_read_reset(Jgz80Handle *handle) {
    if (!handle) return 0x0100u;
    return handle->reset_line ? 0x0000u : 0x0100u;
}

void jgz80_write_reset(Jgz80Handle *handle, uint16_t val) {
    if (!handle) return;
    bind_callbacks(handle);
    if (val == 0u) {
        if (!handle->reset_line) {
            clear_ym2612_shadow_state(handle);
            push_ym_reset_event(handle);
        }
        handle->reset_line = true;
        handle->bus_ack = false;
        z80_reset(&handle->core);
    } else {
        handle->reset_line = false;
        handle->bus_ack = handle->bus_req;
    }
}
