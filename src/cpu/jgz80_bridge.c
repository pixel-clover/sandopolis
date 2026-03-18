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
    YM_INTERNAL_MASTER_CYCLES = 42,
    YM_BUSY_CYCLES = 32,
};

struct Jgz80Handle {
    z80 core;
    uint8_t ram[8 * 1024];
    uint16_t bank;
    uint32_t audio_master_offset;
    uint8_t ym_addr[2];
    uint8_t ym_regs[2][256];
    uint8_t ym_key_mask;
    uint32_t ym_offset_cursor;
    uint16_t ym_internal_master_remainder;
    uint8_t ym_cycle;
    uint8_t ym_busy;
    uint8_t ym_busy_cycles_remaining;
    uint8_t ym_last_status_read;
    uint16_t ym_timer_a_cnt;
    uint16_t ym_timer_a_reg;
    uint8_t ym_timer_a_load_lock;
    uint8_t ym_timer_a_load;
    uint8_t ym_timer_a_enable;
    uint8_t ym_timer_a_reset;
    uint8_t ym_timer_a_load_latch;
    uint8_t ym_timer_a_overflow_flag;
    uint8_t ym_timer_a_overflow;
    uint16_t ym_timer_b_cnt;
    uint8_t ym_timer_b_subcnt;
    uint8_t ym_timer_b_reg;
    uint8_t ym_timer_b_load_lock;
    uint8_t ym_timer_b_load;
    uint8_t ym_timer_b_enable;
    uint8_t ym_timer_b_reset;
    uint8_t ym_timer_b_load_latch;
    uint8_t ym_timer_b_overflow_flag;
    uint8_t ym_timer_b_overflow;
    uint32_t audio_event_sequence;
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
    Jgz80HostPeekFunc host_peek;
    Jgz80HostWriteFunc host_write;
    Jgz80M68kBusAccessFunc host_m68k_bus_access;
    void *host_userdata;
    bool bus_req;
    bool bus_ack;
    bool reset_line;
    uint32_t m68k_bus_access_count;
    uint32_t ym_write_overflow_count;
    uint32_t ym_dac_overflow_count;
    uint32_t ym_reset_overflow_count;
    uint32_t psg_command_overflow_count;
    uint16_t instruction_pc;
    uint8_t instruction_fetch_index;
    uint8_t instruction_data_access_index;
    uint8_t instruction_bank_access_index;
    uint8_t instruction_context_valid;
};

static uint8_t peek_mapped_byte_no_side_effects(Jgz80Handle *h, uint16_t addr) {
    const uint16_t zaddr = (uint16_t)(addr & 0xFFFFu);
    if (zaddr < 0x2000u) {
        return h->ram[zaddr & 0x1FFFu];
    }

    if (zaddr == 0x7F11u) {
        return 0xFFu;
    }

    if (zaddr >= 0x7F00u && zaddr <= 0x7FFFu) {
        if (h->host_peek != NULL) {
            return h->host_peek(h->host_userdata, 0xC00000u + (zaddr & 0x1Fu));
        }
        if (h->host_read != NULL) {
            return h->host_read(h->host_userdata, 0xC00000u + (zaddr & 0x1Fu));
        }
        return 0xFFu;
    }

    if (zaddr >= 0x8000u) {
        if (h->host_peek != NULL) {
            const uint32_t m68k_addr = ((uint32_t) h->bank << 15) | (uint32_t)(zaddr & 0x7FFFu);
            return h->host_peek(h->host_userdata, m68k_addr);
        }
        if (h->host_read != NULL) {
            const uint32_t m68k_addr = ((uint32_t) h->bank << 15) | (uint32_t)(zaddr & 0x7FFFu);
            return h->host_read(h->host_userdata, m68k_addr);
        }
        return 0xFFu;
    }

    return 0xFFu;
}

static bool is_host_mapped_z80_address(uint16_t addr) {
    const uint16_t zaddr = (uint16_t)(addr & 0xFFFFu);
    return ((zaddr >= 0x7F00u && zaddr <= 0x7FFFu && zaddr != 0x7F11u) || zaddr >= 0x8000u);
}

static bool is_index_prefix(uint8_t opcode) {
    return opcode == 0xDDu || opcode == 0xFDu;
}

static uint8_t indexed_instruction_opcode(Jgz80Handle *h) {
    return peek_mapped_byte_no_side_effects(h, (uint16_t)(h->instruction_pc + 1u));
}

static bool indexed_instruction_is_cb_prefixed(Jgz80Handle *h) {
    return indexed_instruction_opcode(h) == 0xCBu;
}

static uint8_t indexed_cb_instruction_opcode(Jgz80Handle *h) {
    return peek_mapped_byte_no_side_effects(h, (uint16_t)(h->instruction_pc + 3u));
}

static uint8_t cb_instruction_opcode(Jgz80Handle *h) {
    return peek_mapped_byte_no_side_effects(h, (uint16_t)(h->instruction_pc + 1u));
}

static bool condition_code_true(Jgz80Handle *h, uint8_t cc) {
    const uint8_t f = (uint8_t)(h->core.af & 0x00FFu);
    switch (cc & 0x07u) {
        case 0u:
            return (f & 0x40u) == 0u;
        case 1u:
            return (f & 0x40u) != 0u;
        case 2u:
            return (f & 0x01u) == 0u;
        case 3u:
            return (f & 0x01u) != 0u;
        case 4u:
            return (f & 0x04u) == 0u;
        case 5u:
            return (f & 0x04u) != 0u;
        case 6u:
            return (f & 0x80u) == 0u;
        case 7u:
            return (f & 0x80u) != 0u;
        default:
            return false;
    }
}

static uint8_t indexed_instruction_length_bytes(Jgz80Handle *h) {
    if (indexed_instruction_is_cb_prefixed(h)) {
        return 4u;
    }

    const uint8_t opcode = indexed_instruction_opcode(h);
    switch (opcode) {
        case 0x21:
        case 0x22:
        case 0x2A:
        case 0x36:
            return 4u;
        case 0x34:
        case 0x35:
        case 0x46:
        case 0x4E:
        case 0x56:
        case 0x5E:
        case 0x66:
        case 0x6E:
        case 0x70:
        case 0x71:
        case 0x72:
        case 0x73:
        case 0x74:
        case 0x75:
        case 0x77:
        case 0x7E:
        case 0x86:
        case 0x8E:
        case 0x96:
        case 0x9E:
        case 0xA6:
        case 0xAE:
        case 0xB6:
        case 0xBE:
            return 3u;
        default:
            return 2u;
    }
}

static uint8_t instruction_length_bytes(Jgz80Handle *h, uint8_t opcode) {
    if (is_index_prefix(opcode)) {
        return indexed_instruction_length_bytes(h);
    }

    switch (opcode) {
        case 0x06:
        case 0x0E:
        case 0x10:
        case 0x16:
        case 0x18:
        case 0x1E:
        case 0x20:
        case 0x26:
        case 0x28:
        case 0x2E:
        case 0x30:
        case 0x36:
        case 0x38:
        case 0x3E:
        case 0xC6:
        case 0xCB:
        case 0xCE:
        case 0xD3:
        case 0xD6:
        case 0xDB:
        case 0xDE:
        case 0xE6:
        case 0xEE:
        case 0xF6:
        case 0xFE:
            return 2u;
        case 0x01:
        case 0x11:
        case 0x21:
        case 0x22:
        case 0x2A:
        case 0x31:
        case 0x32:
        case 0x3A:
        case 0xC2:
        case 0xC3:
        case 0xC4:
        case 0xCA:
        case 0xCC:
        case 0xCD:
        case 0xD2:
        case 0xD4:
        case 0xDA:
        case 0xDC:
        case 0xE2:
        case 0xE4:
        case 0xEA:
        case 0xEC:
        case 0xF2:
        case 0xF4:
        case 0xFA:
        case 0xFC:
            return 3u;
        case 0xED: {
            const uint8_t ext = peek_mapped_byte_no_side_effects(h, (uint16_t)(h->instruction_pc + 1u));
            switch (ext) {
                case 0x43:
                case 0x4B:
                case 0x53:
                case 0x5B:
                case 0x63:
                case 0x6B:
                case 0x73:
                case 0x7B:
                    return 4u;
                default:
                    return 2u;
            }
        }
        default:
            return 1u;
    }
}

static uint32_t instruction_fetch_start_z80_cycles(Jgz80Handle *h, uint8_t byte_index) {
    const uint8_t opcode = peek_mapped_byte_no_side_effects(h, h->instruction_pc);
    if (byte_index == 0u) return 0u;

    if (is_index_prefix(opcode)) {
        switch (byte_index) {
            case 1u:
                return 4u;
            case 2u:
                return 8u;
            case 3u:
                return 11u;
            default:
                return 0u;
        }
    }

    if (opcode == 0xED) {
        switch (byte_index) {
            case 1u:
                return 4u;
            case 2u:
                return 8u;
            case 3u:
                return 11u;
            default:
                return 0u;
        }
    }

    switch (byte_index) {
        case 1u:
            return 4u;
        case 2u:
            return 7u;
        default:
            return 0u;
    }
}

static uint32_t instruction_data_access_start_z80_cycles(Jgz80Handle *h, uint8_t access_index) {
    const uint8_t opcode = peek_mapped_byte_no_side_effects(h, h->instruction_pc);
    if (is_index_prefix(opcode)) {
        if (indexed_instruction_is_cb_prefixed(h)) {
            const uint8_t cb_opcode = indexed_cb_instruction_opcode(h);
            if ((cb_opcode & 0xC0u) == 0x40u) {
                return access_index == 0u ? 15u : 0u;
            }

            if (access_index == 0u) return 15u;
            if (access_index == 1u) return 19u;
            return 0u;
        }

        const uint8_t ext = indexed_instruction_opcode(h);
        switch (ext) {
            case 0xE3:
                if (access_index == 0u) return 8u;
                if (access_index == 1u) return 11u;
                if (access_index == 2u) return 15u;
                if (access_index == 3u) return 18u;
                return 0u;
            case 0xE1:
                if (access_index == 0u) return 8u;
                if (access_index == 1u) return 11u;
                return 0u;
            case 0xE5:
                if (access_index == 0u) return 9u;
                if (access_index == 1u) return 12u;
                return 0u;
            case 0x46:
            case 0x4E:
            case 0x56:
            case 0x5E:
            case 0x66:
            case 0x6E:
            case 0x70:
            case 0x71:
            case 0x72:
            case 0x73:
            case 0x74:
            case 0x75:
            case 0x77:
            case 0x7E:
            case 0x86:
            case 0x8E:
            case 0x96:
            case 0x9E:
            case 0xA6:
            case 0xAE:
            case 0xB6:
            case 0xBE:
                return access_index == 0u ? 15u : 0u;
            case 0x34:
            case 0x35:
                if (access_index == 0u) return 15u;
                if (access_index == 1u) return 19u;
                return 0u;
            case 0x36:
                return access_index == 0u ? 15u : 0u;
            case 0x22:
            case 0x2A:
                if (access_index == 0u) return 14u;
                if (access_index == 1u) return 17u;
                return 0u;
            default:
                return 0u;
        }
    }

    switch (opcode) {
        case 0xE3:
            if (access_index == 0u) return 4u;
            if (access_index == 1u) return 7u;
            if (access_index == 2u) return 11u;
            if (access_index == 3u) return 14u;
            return 0u;
        case 0xC0:
        case 0xC8:
        case 0xD0:
        case 0xD8:
        case 0xE0:
        case 0xE8:
        case 0xF0:
        case 0xF8:
            if (!condition_code_true(h, (uint8_t)((opcode >> 3) & 0x07u))) return 0u;
            if (access_index == 0u) return 5u;
            if (access_index == 1u) return 8u;
            return 0u;
        case 0xC1:
        case 0xD1:
        case 0xE1:
        case 0xF1:
        case 0xC9:
            if (access_index == 0u) return 4u;
            if (access_index == 1u) return 7u;
            return 0u;
        case 0xC5:
        case 0xD5:
        case 0xE5:
        case 0xF5:
        case 0xC7:
        case 0xCF:
        case 0xD7:
        case 0xDF:
        case 0xE7:
        case 0xEF:
        case 0xF7:
        case 0xFF:
            if (access_index == 0u) return 5u;
            if (access_index == 1u) return 8u;
            return 0u;
        case 0x02:
        case 0x0A:
        case 0x12:
        case 0x1A:
        case 0x46:
        case 0x4E:
        case 0x56:
        case 0x5E:
        case 0x66:
        case 0x6E:
        case 0x70:
        case 0x71:
        case 0x72:
        case 0x73:
        case 0x74:
        case 0x75:
        case 0x77:
        case 0x7E:
        case 0x86:
        case 0x8E:
        case 0x96:
        case 0x9E:
        case 0xA6:
        case 0xAE:
        case 0xB6:
        case 0xBE:
            return access_index == 0u ? 4u : 0u;
        case 0x34:
        case 0x35:
            if (access_index == 0u) return 4u;
            if (access_index == 1u) return 8u;
            return 0u;
        case 0x36:
            return access_index == 0u ? 7u : 0u;
        case 0x22:
        case 0x2A:
            if (access_index == 0u) return 10u;
            if (access_index == 1u) return 13u;
            return 0u;
        case 0x32:
        case 0x3A:
            return access_index == 0u ? 10u : 0u;
        case 0xC4:
        case 0xCC:
        case 0xD4:
        case 0xDC:
        case 0xE4:
        case 0xEC:
        case 0xF4:
        case 0xFC:
            if (!condition_code_true(h, (uint8_t)((opcode >> 3) & 0x07u))) return 0u;
            if (access_index == 0u) return 11u;
            if (access_index == 1u) return 14u;
            return 0u;
        case 0xCD:
            if (access_index == 0u) return 11u;
            if (access_index == 1u) return 14u;
            return 0u;
        case 0xCB: {
            const uint8_t cb_opcode = cb_instruction_opcode(h);
            if ((cb_opcode & 0x07u) != 0x06u) return 0u;
            if ((cb_opcode & 0xC0u) == 0x40u) {
                return access_index == 0u ? 8u : 0u;
            }

            if (access_index == 0u) return 8u;
            if (access_index == 1u) return 12u;
            return 0u;
        }
        case 0xED: {
            const uint8_t ext = peek_mapped_byte_no_side_effects(h, (uint16_t)(h->instruction_pc + 1u));
            switch (ext) {
                case 0x43:
                case 0x4B:
                case 0x53:
                case 0x5B:
                case 0x63:
                case 0x6B:
                case 0x73:
                case 0x7B:
                    if (access_index == 0u) return 14u;
                    if (access_index == 1u) return 17u;
                    return 0u;
                case 0x45:
                case 0x4D:
                    if (access_index == 0u) return 8u;
                    if (access_index == 1u) return 11u;
                    return 0u;
                case 0x67:
                case 0x6F:
                    if (access_index == 0u) return 8u;
                    if (access_index == 1u) return 11u;
                    return 0u;
                case 0xA0:
                case 0xA8:
                case 0xB0:
                case 0xB8:
                    if (access_index == 0u) return 8u;
                    if (ext == 0xA0 || ext == 0xA8 || ext == 0xB0 || ext == 0xB8) {
                        return access_index == 1u ? 11u : 0u;
                    }
                    return 0u;
                case 0xA1:
                case 0xA9:
                case 0xB1:
                case 0xB9:
                    return access_index == 0u ? 8u : 0u;
                case 0xA2:
                case 0xAA:
                case 0xB2:
                case 0xBA:
                    return access_index == 0u ? 12u : 0u;
                case 0xA3:
                case 0xAB:
                case 0xB3:
                case 0xBB:
                    return access_index == 0u ? 4u : 0u;
                default:
                    return 0u;
            }
        }
        default:
            return 0u;
    }
}

static uint32_t instruction_bank_access_start_z80_cycles(Jgz80Handle *h, uint8_t access_index) {
    if (h->instruction_context_valid == 0u) return 0u;

    const uint8_t opcode = peek_mapped_byte_no_side_effects(h, h->instruction_pc);
    const uint8_t length = instruction_length_bytes(h, opcode);
    uint8_t host_fetch_count = 0u;

    for (uint8_t byte_index = 0u; byte_index < length; ++byte_index) {
        if (!is_host_mapped_z80_address((uint16_t)(h->instruction_pc + byte_index))) continue;
        if (host_fetch_count == access_index) {
            return instruction_fetch_start_z80_cycles(h, byte_index);
        }
        ++host_fetch_count;
    }

    return instruction_data_access_start_z80_cycles(h, (uint8_t)(access_index - host_fetch_count));
}

static uint32_t current_instruction_pre_access_master_cycles(Jgz80Handle *h) {
    const uint8_t access_index = h->instruction_bank_access_index;
    const uint32_t access_start = instruction_bank_access_start_z80_cycles(h, access_index);
    if (access_start == 0u) return 0u;

    const uint32_t previous_start = access_index == 0u
        ? 0u
        : instruction_bank_access_start_z80_cycles(h, (uint8_t)(access_index - 1u));
    if (access_start <= previous_start) return 0u;
    return (access_start - previous_start) * 15u;
}

static uint32_t instruction_access_master_offset(Jgz80Handle *h, uint16_t addr, bool is_write) {
    if (h->instruction_context_valid == 0u) return h->audio_master_offset;

    if (!is_write) {
        const uint8_t opcode = peek_mapped_byte_no_side_effects(h, h->instruction_pc);
        const uint8_t length = instruction_length_bytes(h, opcode);
        if (h->instruction_fetch_index < length) {
            const uint16_t fetch_delta = (uint16_t)(addr - h->instruction_pc);
            if (fetch_delta < length) {
                const uint32_t access_start =
                    instruction_fetch_start_z80_cycles(h, h->instruction_fetch_index);
                ++h->instruction_fetch_index;
                return h->audio_master_offset + access_start * 15u;
            }
        }
    }

    const uint32_t access_start =
        instruction_data_access_start_z80_cycles(h, h->instruction_data_access_index);
    ++h->instruction_data_access_index;
    return h->audio_master_offset + access_start * 15u;
}

static void notify_contended_host_access(Jgz80Handle *h) {
    if (h->host_m68k_bus_access != NULL) {
        h->host_m68k_bus_access(h->host_userdata, current_instruction_pre_access_master_cycles(h));
    }
    ++h->instruction_bank_access_index;
    ++h->m68k_bus_access_count;
}

static void clear_ym2612_shadow_state(Jgz80Handle *h) {
    memset(h->ym_addr, 0, sizeof(h->ym_addr));
    memset(h->ym_regs, 0, sizeof(h->ym_regs));
    h->ym_key_mask = 0;
}

static void clear_ym2612_runtime_state(Jgz80Handle *h) {
    h->ym_offset_cursor = h->audio_master_offset;
    h->ym_internal_master_remainder = 0;
    h->ym_cycle = 0;
    h->ym_busy = 0;
    h->ym_busy_cycles_remaining = 0;
    h->ym_last_status_read = 0;
    h->ym_timer_a_cnt = 0;
    h->ym_timer_a_reg = 0;
    h->ym_timer_a_load_lock = 0;
    h->ym_timer_a_load = 0;
    h->ym_timer_a_enable = 0;
    h->ym_timer_a_reset = 0;
    h->ym_timer_a_load_latch = 0;
    h->ym_timer_a_overflow_flag = 0;
    h->ym_timer_a_overflow = 0;
    h->ym_timer_b_cnt = 0;
    h->ym_timer_b_subcnt = 0;
    h->ym_timer_b_reg = 0;
    h->ym_timer_b_load_lock = 0;
    h->ym_timer_b_load = 0;
    h->ym_timer_b_enable = 0;
    h->ym_timer_b_reset = 0;
    h->ym_timer_b_load_latch = 0;
    h->ym_timer_b_overflow_flag = 0;
    h->ym_timer_b_overflow = 0;
}

static void clear_ym2612_event_queues(Jgz80Handle *h) {
    h->ym_write_write_index = 0;
    h->ym_write_read_index = 0;
    h->ym_write_count = 0;
    h->ym_write_overflow_count = 0;
    h->ym_dac_write_index = 0;
    h->ym_dac_read_index = 0;
    h->ym_dac_count = 0;
    h->ym_dac_overflow_count = 0;
    h->ym_reset_write_index = 0;
    h->ym_reset_read_index = 0;
    h->ym_reset_count = 0;
    h->ym_reset_overflow_count = 0;
}

static void clear_psg_command_queue(Jgz80Handle *h) {
    h->psg_command_write_index = 0;
    h->psg_command_read_index = 0;
    h->psg_command_count = 0;
    h->psg_command_overflow_count = 0;
}

static void reset_ym2612_state(Jgz80Handle *h) {
    clear_ym2612_shadow_state(h);
    clear_ym2612_runtime_state(h);
    clear_ym2612_event_queues(h);
}

static uint32_t next_audio_event_sequence(Jgz80Handle *h) {
    uint32_t sequence = h->audio_event_sequence;
    h->audio_event_sequence += 1u;
    return sequence;
}

static void push_ym_write_event(Jgz80Handle *h, uint8_t port, uint8_t reg, uint8_t value) {
    if (h->ym_write_count == YM_WRITE_BUFFER_CAPACITY) {
        h->ym_write_read_index = (uint16_t)((h->ym_write_read_index + 1u) % YM_WRITE_BUFFER_CAPACITY);
        --h->ym_write_count;
        ++h->ym_write_overflow_count;
    }

    h->ym_write_events[h->ym_write_write_index].master_offset = h->audio_master_offset;
    h->ym_write_events[h->ym_write_write_index].sequence = next_audio_event_sequence(h);
    h->ym_write_events[h->ym_write_write_index].port = port;
    h->ym_write_events[h->ym_write_write_index].reg = reg;
    h->ym_write_events[h->ym_write_write_index].value = value;
    h->ym_write_write_index = (uint16_t)((h->ym_write_write_index + 1u) % YM_WRITE_BUFFER_CAPACITY);
    ++h->ym_write_count;
}

static void push_ym_write_event_at(Jgz80Handle *h, uint32_t master_offset, uint8_t port, uint8_t reg, uint8_t value) {
    if (h->ym_write_count == YM_WRITE_BUFFER_CAPACITY) {
        h->ym_write_read_index = (uint16_t)((h->ym_write_read_index + 1u) % YM_WRITE_BUFFER_CAPACITY);
        --h->ym_write_count;
        ++h->ym_write_overflow_count;
    }

    h->ym_write_events[h->ym_write_write_index].master_offset = master_offset;
    h->ym_write_events[h->ym_write_write_index].sequence = next_audio_event_sequence(h);
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
        ++h->psg_command_overflow_count;
    }

    h->psg_commands[h->psg_command_write_index].master_offset = h->audio_master_offset;
    h->psg_commands[h->psg_command_write_index].value = value;
    h->psg_command_write_index = (uint16_t)((h->psg_command_write_index + 1u) % PSG_COMMAND_BUFFER_CAPACITY);
    ++h->psg_command_count;
}

static void push_psg_command_at(Jgz80Handle *h, uint32_t master_offset, uint8_t value) {
    if (h->psg_command_count == PSG_COMMAND_BUFFER_CAPACITY) {
        h->psg_command_read_index = (uint16_t)((h->psg_command_read_index + 1u) % PSG_COMMAND_BUFFER_CAPACITY);
        --h->psg_command_count;
        ++h->psg_command_overflow_count;
    }

    h->psg_commands[h->psg_command_write_index].master_offset = master_offset;
    h->psg_commands[h->psg_command_write_index].value = value;
    h->psg_command_write_index = (uint16_t)((h->psg_command_write_index + 1u) % PSG_COMMAND_BUFFER_CAPACITY);
    ++h->psg_command_count;
}

static void push_ym_dac_sample(Jgz80Handle *h, uint8_t value) {
    if (h->ym_dac_count == YM_DAC_BUFFER_CAPACITY) {
        h->ym_dac_read_index = (uint16_t)((h->ym_dac_read_index + 1u) % YM_DAC_BUFFER_CAPACITY);
        --h->ym_dac_count;
        ++h->ym_dac_overflow_count;
    }

    h->ym_dac_samples[h->ym_dac_write_index].master_offset = h->audio_master_offset;
    h->ym_dac_samples[h->ym_dac_write_index].sequence = next_audio_event_sequence(h);
    h->ym_dac_samples[h->ym_dac_write_index].value = value;
    h->ym_dac_write_index = (uint16_t)((h->ym_dac_write_index + 1u) % YM_DAC_BUFFER_CAPACITY);
    ++h->ym_dac_count;
}

static void push_ym_dac_sample_at(Jgz80Handle *h, uint32_t master_offset, uint8_t value) {
    if (h->ym_dac_count == YM_DAC_BUFFER_CAPACITY) {
        h->ym_dac_read_index = (uint16_t)((h->ym_dac_read_index + 1u) % YM_DAC_BUFFER_CAPACITY);
        --h->ym_dac_count;
        ++h->ym_dac_overflow_count;
    }

    h->ym_dac_samples[h->ym_dac_write_index].master_offset = master_offset;
    h->ym_dac_samples[h->ym_dac_write_index].sequence = next_audio_event_sequence(h);
    h->ym_dac_samples[h->ym_dac_write_index].value = value;
    h->ym_dac_write_index = (uint16_t)((h->ym_dac_write_index + 1u) % YM_DAC_BUFFER_CAPACITY);
    ++h->ym_dac_count;
}

static void push_ym_reset_event(Jgz80Handle *h) {
    if (h->ym_reset_count == YM_RESET_BUFFER_CAPACITY) {
        h->ym_reset_read_index = (uint16_t)((h->ym_reset_read_index + 1u) % YM_RESET_BUFFER_CAPACITY);
        --h->ym_reset_count;
        ++h->ym_reset_overflow_count;
    }

    h->ym_reset_events[h->ym_reset_write_index].master_offset = h->audio_master_offset;
    h->ym_reset_events[h->ym_reset_write_index].sequence = next_audio_event_sequence(h);
    h->ym_reset_write_index = (uint16_t)((h->ym_reset_write_index + 1u) % YM_RESET_BUFFER_CAPACITY);
    ++h->ym_reset_count;
}

static void reset_psg_shadow_state(Jgz80Handle *h) {
    h->psg_last = 0;
    memset(h->psg_tone, 0, sizeof(h->psg_tone));
    memset(h->psg_volume, 0, sizeof(h->psg_volume));
    h->psg_noise = 0;
    /* Integrated Mega Drive PSG powers on with tone channel 2 attenuation latched. */
    h->psg_latched_channel = 1;
    h->psg_latched_is_volume = true;
}

static void ym_do_timer_a(Jgz80Handle *h) {
    uint8_t load = h->ym_timer_a_overflow;
    if (h->ym_cycle == 2u) {
        load |= (uint8_t)(h->ym_timer_a_load_lock == 0u && h->ym_timer_a_load != 0u);
        h->ym_timer_a_load_lock = h->ym_timer_a_load;
    }

    uint16_t time = h->ym_timer_a_load_latch != 0u ? h->ym_timer_a_reg : h->ym_timer_a_cnt;
    h->ym_timer_a_load_latch = load;

    if (h->ym_cycle == 1u && h->ym_timer_a_load_lock != 0u) {
        time = (uint16_t)(time + 1u);
    }

    if (h->ym_timer_a_reset != 0u) {
        h->ym_timer_a_reset = 0u;
        h->ym_timer_a_overflow_flag = 0u;
    } else {
        h->ym_timer_a_overflow_flag |= (uint8_t)(h->ym_timer_a_overflow & h->ym_timer_a_enable);
    }

    h->ym_timer_a_overflow = (uint8_t)(time >> 10);
    h->ym_timer_a_cnt = (uint16_t)(time & 0x03FFu);
}

static void ym_do_timer_b(Jgz80Handle *h) {
    uint8_t load = h->ym_timer_b_overflow;
    if (h->ym_cycle == 2u) {
        load |= (uint8_t)(h->ym_timer_b_load_lock == 0u && h->ym_timer_b_load != 0u);
        h->ym_timer_b_load_lock = h->ym_timer_b_load;
    }

    uint16_t time = h->ym_timer_b_load_latch != 0u ? h->ym_timer_b_reg : h->ym_timer_b_cnt;
    h->ym_timer_b_load_latch = load;

    if (h->ym_cycle == 1u) {
        h->ym_timer_b_subcnt = (uint8_t)(h->ym_timer_b_subcnt + 1u);
    }
    if (h->ym_timer_b_subcnt == 0x10u && h->ym_timer_b_load_lock != 0u) {
        time = (uint16_t)(time + 1u);
    }
    h->ym_timer_b_subcnt &= 0x0Fu;

    if (h->ym_timer_b_reset != 0u) {
        h->ym_timer_b_reset = 0u;
        h->ym_timer_b_overflow_flag = 0u;
    } else {
        h->ym_timer_b_overflow_flag |= (uint8_t)(h->ym_timer_b_overflow & h->ym_timer_b_enable);
    }

    h->ym_timer_b_overflow = (uint8_t)(time >> 8);
    h->ym_timer_b_cnt = (uint16_t)(time & 0x00FFu);
}

static void advance_ym_internal_cycle(Jgz80Handle *h) {
    h->ym_busy = (uint8_t)(h->ym_busy_cycles_remaining != 0u);
    if (h->ym_busy_cycles_remaining != 0u) {
        --h->ym_busy_cycles_remaining;
    }

    ym_do_timer_a(h);
    ym_do_timer_b(h);
    h->ym_cycle = (uint8_t)((h->ym_cycle + 1u) % 24u);
}

static void advance_ym_master(Jgz80Handle *h, uint32_t master_cycles) {
    uint32_t remaining = master_cycles;
    while (remaining != 0u) {
        const uint32_t until_boundary = h->ym_internal_master_remainder == 0u
                                            ? YM_INTERNAL_MASTER_CYCLES
                                            : (uint32_t)(YM_INTERNAL_MASTER_CYCLES - h->ym_internal_master_remainder);

        if (remaining < until_boundary) {
            h->ym_internal_master_remainder =
                    (uint16_t)(h->ym_internal_master_remainder + remaining);
            return;
        }

        remaining -= until_boundary;
        h->ym_internal_master_remainder = 0u;
        advance_ym_internal_cycle(h);
    }
}

static void advance_ym_to_master_offset(Jgz80Handle *h, uint32_t master_offset) {
    if (master_offset < h->ym_offset_cursor) {
        h->ym_offset_cursor = master_offset;
        return;
    }

    advance_ym_master(h, master_offset - h->ym_offset_cursor);
    h->ym_offset_cursor = master_offset;
}

static uint8_t ym_status(Jgz80Handle *h) {
    return (uint8_t)(
        ((h->ym_busy != 0u) ? 0x80u : 0u) |
        ((h->ym_timer_b_overflow_flag & 0x01u) << 1) |
        (h->ym_timer_a_overflow_flag & 0x01u)
    );
}

static void apply_ym_data_write_runtime_state(Jgz80Handle *h, uint8_t port, uint8_t reg, uint8_t value) {
    h->ym_busy_cycles_remaining = YM_BUSY_CYCLES;

    if (port != 0u) return;

    switch (reg) {
        case 0x24:
            h->ym_timer_a_reg &= 0x0003u;
            h->ym_timer_a_reg |= (uint16_t) value << 2;
            break;
        case 0x25:
            h->ym_timer_a_reg &= 0x03FCu;
            h->ym_timer_a_reg |= value & 0x03u;
            break;
        case 0x26:
            h->ym_timer_b_reg = value;
            break;
        case 0x27:
            h->ym_timer_a_load = value & 0x01u;
            h->ym_timer_a_enable = (value >> 2) & 0x01u;
            h->ym_timer_a_reset = (value >> 4) & 0x01u;
            h->ym_timer_b_load = (value >> 1) & 0x01u;
            h->ym_timer_b_enable = (value >> 3) & 0x01u;
            h->ym_timer_b_reset = (value >> 5) & 0x01u;
            break;
        default:
            break;
    }
}

static uint8_t mapped_read_byte(Jgz80Handle *h, uint16_t addr) {
    const uint16_t zaddr = (uint16_t)(addr & 0xFFFFu);
    const uint32_t access_master_offset = instruction_access_master_offset(h, zaddr, false);
    if (zaddr < 0x2000u) {
        return h->ram[zaddr & 0x1FFFu];
    }

    if (zaddr >= 0x4000u && zaddr < 0x6000u) {
        advance_ym_to_master_offset(h, access_master_offset);
        h->ym_last_status_read = ym_status(h);
        return h->ym_last_status_read;
    }

    if (zaddr == 0x7F11u) {
        return 0xFFu;
    }

    if (zaddr >= 0x7F00u && zaddr <= 0x7FFFu) {
        if (h->host_read != NULL) {
            notify_contended_host_access(h);
            return h->host_read(h->host_userdata, 0xC00000u + (zaddr & 0x1Fu));
        }
        return 0xFFu;
    }

    if (zaddr >= 0x8000u) {
        if (h->host_read != NULL) {
            const uint32_t m68k_addr = ((uint32_t) h->bank << 15) | (uint32_t)(zaddr & 0x7FFFu);
            notify_contended_host_access(h);
            return h->host_read(h->host_userdata, m68k_addr);
        }
        return 0xFFu;
    }

    return 0xFFu;
}

static void mapped_write_byte(Jgz80Handle *h, uint16_t addr, uint8_t val) {
    const uint16_t zaddr = (uint16_t)(addr & 0xFFFFu);
    const uint32_t access_master_offset = instruction_access_master_offset(h, zaddr, true);
    if (zaddr < 0x2000u) {
        h->ram[zaddr & 0x1FFFu] = val;
        return;
    }

    if (zaddr >= 0x4000u && zaddr < 0x6000u) {
        advance_ym_to_master_offset(h, access_master_offset);
        const uint8_t port_index = (uint8_t)((zaddr >> 1) & 1u);
        const bool is_data = (zaddr & 1u) != 0u;
        if (!is_data) {
            h->ym_addr[port_index] = val;
        } else {
            const uint8_t reg = h->ym_addr[port_index];
            h->ym_regs[port_index][reg] = val;
            apply_ym_data_write_runtime_state(h, port_index, reg, val);
            if (port_index == 0u && reg == 0x2Au) {
                push_ym_dac_sample_at(h, access_master_offset, val);
            } else {
                push_ym_write_event_at(h, access_master_offset, port_index, reg, val);
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
        push_psg_command_at(h, access_master_offset, val);
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
            notify_contended_host_access(h);
            h->host_write(h->host_userdata, 0xC00000u + (zaddr & 0x1Fu), val);
        }
        return;
    }

    if (zaddr >= 0x8000u) {
        if (h->host_write != NULL) {
            const uint32_t m68k_addr = ((uint32_t) h->bank << 15) | (uint32_t)(zaddr & 0x7FFFu);
            notify_contended_host_access(h);
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
    h->audio_event_sequence = 0;
    reset_ym2612_state(h);
    reset_psg_shadow_state(h);
    h->m68k_bus_access_count = 0;
    return h;
}

Jgz80Handle *jgz80_clone(const Jgz80Handle *handle) {
    if (!handle) return NULL;

    Jgz80Handle *copy = (Jgz80Handle *) calloc(1, sizeof(Jgz80Handle));
    if (!copy) return NULL;

    memcpy(copy, handle, sizeof(Jgz80Handle));
    bind_callbacks(copy);
    return copy;
}

void jgz80_capture_state(const Jgz80Handle *handle, Jgz80State *state) {
    if (!state) return;
    memset(state, 0, sizeof(*state));
    if (!handle) return;

    state->pc = handle->core.pc;
    state->sp = handle->core.sp;
    state->ix = handle->core.ix;
    state->iy = handle->core.iy;
    state->mem_ptr = handle->core.mem_ptr;
    state->af = handle->core.af;
    state->bc = handle->core.bc;
    state->de = handle->core.de;
    state->hl = handle->core.hl;
    state->af_alt = handle->core.a_f_;
    state->bc_alt = handle->core.b_c_;
    state->de_alt = handle->core.d_e_;
    state->hl_alt = handle->core.h_l_;
    state->i = handle->core.i;
    state->r = handle->core.r;
    state->iff_delay = handle->core.iff_delay;
    state->interrupt_mode = handle->core.interrupt_mode;
    state->irq_data = handle->core.irq_data;
    state->irq_pending = handle->core.irq_pending;
    state->nmi_pending = handle->core.nmi_pending;
    state->iff1 = handle->core.iff1 ? 1u : 0u;
    state->iff2 = handle->core.iff2 ? 1u : 0u;
    state->halted = handle->core.halted ? 1u : 0u;

    memcpy(state->ram, handle->ram, sizeof(state->ram));
    state->bank = handle->bank;
    state->audio_master_offset = handle->audio_master_offset;
    memcpy(state->ym_addr, handle->ym_addr, sizeof(state->ym_addr));
    memcpy(state->ym_regs, handle->ym_regs, sizeof(state->ym_regs));
    state->ym_key_mask = handle->ym_key_mask;
    state->ym_offset_cursor = handle->ym_offset_cursor;
    state->ym_internal_master_remainder = handle->ym_internal_master_remainder;
    state->ym_cycle = handle->ym_cycle;
    state->ym_busy = handle->ym_busy;
    state->ym_busy_cycles_remaining = handle->ym_busy_cycles_remaining;
    state->ym_last_status_read = handle->ym_last_status_read;
    state->ym_timer_a_cnt = handle->ym_timer_a_cnt;
    state->ym_timer_a_reg = handle->ym_timer_a_reg;
    state->ym_timer_a_load_lock = handle->ym_timer_a_load_lock;
    state->ym_timer_a_load = handle->ym_timer_a_load;
    state->ym_timer_a_enable = handle->ym_timer_a_enable;
    state->ym_timer_a_reset = handle->ym_timer_a_reset;
    state->ym_timer_a_load_latch = handle->ym_timer_a_load_latch;
    state->ym_timer_a_overflow_flag = handle->ym_timer_a_overflow_flag;
    state->ym_timer_a_overflow = handle->ym_timer_a_overflow;
    state->ym_timer_b_cnt = handle->ym_timer_b_cnt;
    state->ym_timer_b_subcnt = handle->ym_timer_b_subcnt;
    state->ym_timer_b_reg = handle->ym_timer_b_reg;
    state->ym_timer_b_load_lock = handle->ym_timer_b_load_lock;
    state->ym_timer_b_load = handle->ym_timer_b_load;
    state->ym_timer_b_enable = handle->ym_timer_b_enable;
    state->ym_timer_b_reset = handle->ym_timer_b_reset;
    state->ym_timer_b_load_latch = handle->ym_timer_b_load_latch;
    state->ym_timer_b_overflow_flag = handle->ym_timer_b_overflow_flag;
    state->ym_timer_b_overflow = handle->ym_timer_b_overflow;
    state->audio_event_sequence = handle->audio_event_sequence;
    memcpy(state->ym_write_events, handle->ym_write_events, sizeof(state->ym_write_events));
    state->ym_write_write_index = handle->ym_write_write_index;
    state->ym_write_read_index = handle->ym_write_read_index;
    state->ym_write_count = handle->ym_write_count;
    memcpy(state->ym_dac_samples, handle->ym_dac_samples, sizeof(state->ym_dac_samples));
    state->ym_dac_write_index = handle->ym_dac_write_index;
    state->ym_dac_read_index = handle->ym_dac_read_index;
    state->ym_dac_count = handle->ym_dac_count;
    memcpy(state->ym_reset_events, handle->ym_reset_events, sizeof(state->ym_reset_events));
    state->ym_reset_write_index = handle->ym_reset_write_index;
    state->ym_reset_read_index = handle->ym_reset_read_index;
    state->ym_reset_count = handle->ym_reset_count;
    memcpy(state->psg_commands, handle->psg_commands, sizeof(state->psg_commands));
    state->psg_command_write_index = handle->psg_command_write_index;
    state->psg_command_read_index = handle->psg_command_read_index;
    state->psg_command_count = handle->psg_command_count;
    state->psg_last = handle->psg_last;
    memcpy(state->psg_tone, handle->psg_tone, sizeof(state->psg_tone));
    memcpy(state->psg_volume, handle->psg_volume, sizeof(state->psg_volume));
    state->psg_noise = handle->psg_noise;
    state->psg_latched_channel = handle->psg_latched_channel;
    state->psg_latched_is_volume = handle->psg_latched_is_volume ? 1u : 0u;
    state->bus_req = handle->bus_req ? 1u : 0u;
    state->bus_ack = handle->bus_ack ? 1u : 0u;
    state->reset_line = handle->reset_line ? 1u : 0u;
    state->m68k_bus_access_count = handle->m68k_bus_access_count;
}

void jgz80_restore_state(Jgz80Handle *handle, const Jgz80State *state) {
    if (!handle || !state) return;

    handle->core.pc = state->pc;
    handle->core.sp = state->sp;
    handle->core.ix = state->ix;
    handle->core.iy = state->iy;
    handle->core.mem_ptr = state->mem_ptr;
    handle->core.af = state->af;
    handle->core.bc = state->bc;
    handle->core.de = state->de;
    handle->core.hl = state->hl;
    handle->core.a_f_ = state->af_alt;
    handle->core.b_c_ = state->bc_alt;
    handle->core.d_e_ = state->de_alt;
    handle->core.h_l_ = state->hl_alt;
    handle->core.i = state->i;
    handle->core.r = state->r;
    handle->core.iff_delay = state->iff_delay;
    handle->core.interrupt_mode = state->interrupt_mode;
    handle->core.irq_data = state->irq_data;
    handle->core.irq_pending = state->irq_pending;
    handle->core.nmi_pending = state->nmi_pending;
    handle->core.iff1 = state->iff1 != 0u;
    handle->core.iff2 = state->iff2 != 0u;
    handle->core.halted = state->halted != 0u;
    bind_callbacks(handle);

    memcpy(handle->ram, state->ram, sizeof(handle->ram));
    handle->bank = state->bank;
    handle->audio_master_offset = state->audio_master_offset;
    memcpy(handle->ym_addr, state->ym_addr, sizeof(handle->ym_addr));
    memcpy(handle->ym_regs, state->ym_regs, sizeof(handle->ym_regs));
    handle->ym_key_mask = state->ym_key_mask;
    handle->ym_offset_cursor = state->ym_offset_cursor;
    handle->ym_internal_master_remainder = state->ym_internal_master_remainder;
    handle->ym_cycle = state->ym_cycle;
    handle->ym_busy = state->ym_busy;
    handle->ym_busy_cycles_remaining = state->ym_busy_cycles_remaining;
    handle->ym_last_status_read = state->ym_last_status_read;
    handle->ym_timer_a_cnt = state->ym_timer_a_cnt;
    handle->ym_timer_a_reg = state->ym_timer_a_reg;
    handle->ym_timer_a_load_lock = state->ym_timer_a_load_lock;
    handle->ym_timer_a_load = state->ym_timer_a_load;
    handle->ym_timer_a_enable = state->ym_timer_a_enable;
    handle->ym_timer_a_reset = state->ym_timer_a_reset;
    handle->ym_timer_a_load_latch = state->ym_timer_a_load_latch;
    handle->ym_timer_a_overflow_flag = state->ym_timer_a_overflow_flag;
    handle->ym_timer_a_overflow = state->ym_timer_a_overflow;
    handle->ym_timer_b_cnt = state->ym_timer_b_cnt;
    handle->ym_timer_b_subcnt = state->ym_timer_b_subcnt;
    handle->ym_timer_b_reg = state->ym_timer_b_reg;
    handle->ym_timer_b_load_lock = state->ym_timer_b_load_lock;
    handle->ym_timer_b_load = state->ym_timer_b_load;
    handle->ym_timer_b_enable = state->ym_timer_b_enable;
    handle->ym_timer_b_reset = state->ym_timer_b_reset;
    handle->ym_timer_b_load_latch = state->ym_timer_b_load_latch;
    handle->ym_timer_b_overflow_flag = state->ym_timer_b_overflow_flag;
    handle->ym_timer_b_overflow = state->ym_timer_b_overflow;
    handle->audio_event_sequence = state->audio_event_sequence;
    memcpy(handle->ym_write_events, state->ym_write_events, sizeof(handle->ym_write_events));
    handle->ym_write_write_index = state->ym_write_write_index;
    handle->ym_write_read_index = state->ym_write_read_index;
    handle->ym_write_count = state->ym_write_count;
    memcpy(handle->ym_dac_samples, state->ym_dac_samples, sizeof(handle->ym_dac_samples));
    handle->ym_dac_write_index = state->ym_dac_write_index;
    handle->ym_dac_read_index = state->ym_dac_read_index;
    handle->ym_dac_count = state->ym_dac_count;
    memcpy(handle->ym_reset_events, state->ym_reset_events, sizeof(handle->ym_reset_events));
    handle->ym_reset_write_index = state->ym_reset_write_index;
    handle->ym_reset_read_index = state->ym_reset_read_index;
    handle->ym_reset_count = state->ym_reset_count;
    memcpy(handle->psg_commands, state->psg_commands, sizeof(handle->psg_commands));
    handle->psg_command_write_index = state->psg_command_write_index;
    handle->psg_command_read_index = state->psg_command_read_index;
    handle->psg_command_count = state->psg_command_count;
    handle->psg_last = state->psg_last;
    memcpy(handle->psg_tone, state->psg_tone, sizeof(handle->psg_tone));
    memcpy(handle->psg_volume, state->psg_volume, sizeof(handle->psg_volume));
    handle->psg_noise = state->psg_noise;
    handle->psg_latched_channel = state->psg_latched_channel;
    handle->psg_latched_is_volume = state->psg_latched_is_volume != 0u;
    handle->bus_req = state->bus_req != 0u;
    handle->bus_ack = state->bus_ack != 0u;
    handle->reset_line = state->reset_line != 0u;
    handle->m68k_bus_access_count = state->m68k_bus_access_count;
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
    handle->audio_event_sequence = 0;
    reset_ym2612_state(handle);
    clear_psg_command_queue(handle);
    reset_psg_shadow_state(handle);
    handle->m68k_bus_access_count = 0;
    z80_reset(&handle->core);
}

void jgz80_soft_reset(Jgz80Handle *handle) {
    if (!handle) return;
    bind_callbacks(handle);
    handle->bus_req = false;
    handle->bus_ack = false;
    handle->reset_line = false;
    handle->bank = 0;
    handle->m68k_bus_access_count = 0;
    clear_ym2612_shadow_state(handle);
    clear_ym2612_runtime_state(handle);
    push_ym_reset_event(handle);
    z80_reset(&handle->core);
}

void jgz80_step(Jgz80Handle *handle, uint32_t cycles) {
    if (!handle) return;
    bind_callbacks(handle);
    if (handle->bus_req || handle->reset_line) return;
    (void) z80_step_n(&handle->core, cycles);
    advance_ym_master(handle, cycles * 15u);
}

uint32_t jgz80_step_one(Jgz80Handle *handle) {
    if (!handle) return 0;
    bind_callbacks(handle);
    if (handle->bus_req || handle->reset_line) return 0;
    const uint32_t instruction_start_master_offset = handle->audio_master_offset;
    handle->instruction_pc = handle->core.pc;
    handle->instruction_fetch_index = 0u;
    handle->instruction_data_access_index = 0u;
    handle->instruction_bank_access_index = 0u;
    handle->instruction_context_valid = 1u;
    const uint32_t cycles = z80_step(&handle->core);
    handle->instruction_context_valid = 0u;
    advance_ym_to_master_offset(handle, instruction_start_master_offset + cycles * 15u);
    return cycles;
}

uint8_t jgz80_read_byte(Jgz80Handle *handle, uint16_t addr) {
    if (!handle) return 0;
    return mapped_read_byte(handle, addr);
}

void jgz80_write_byte(Jgz80Handle *handle, uint16_t addr, uint8_t val) {
    if (!handle) return;
    mapped_write_byte(handle, addr, val);
}

void jgz80_set_host_callbacks(
    Jgz80Handle *handle,
    Jgz80HostReadFunc host_read,
    Jgz80HostPeekFunc host_peek,
    Jgz80HostWriteFunc host_write,
    Jgz80M68kBusAccessFunc host_m68k_bus_access,
    void *userdata
) {
    if (!handle) return;
    handle->host_read = host_read;
    handle->host_peek = host_peek;
    handle->host_write = host_write;
    handle->host_m68k_bus_access = host_m68k_bus_access;
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

uint16_t jgz80_peek_ym_write_count(const Jgz80Handle *handle) {
    if (!handle) return 0u;
    return handle->ym_write_count;
}

uint16_t jgz80_peek_ym_dac_count(const Jgz80Handle *handle) {
    if (!handle) return 0u;
    return handle->ym_dac_count;
}

uint16_t jgz80_peek_psg_command_count(const Jgz80Handle *handle) {
    if (!handle) return 0u;
    return handle->psg_command_count;
}

uint32_t jgz80_take_overflow_counts(Jgz80Handle *handle, uint32_t *ym_write, uint32_t *ym_dac, uint32_t *ym_reset, uint32_t *psg_command) {
    if (!handle) return 0u;
    uint32_t total = handle->ym_write_overflow_count + handle->ym_dac_overflow_count
                   + handle->ym_reset_overflow_count + handle->psg_command_overflow_count;
    if (ym_write) *ym_write = handle->ym_write_overflow_count;
    if (ym_dac) *ym_dac = handle->ym_dac_overflow_count;
    if (ym_reset) *ym_reset = handle->ym_reset_overflow_count;
    if (psg_command) *psg_command = handle->psg_command_overflow_count;
    handle->ym_write_overflow_count = 0;
    handle->ym_dac_overflow_count = 0;
    handle->ym_reset_overflow_count = 0;
    handle->psg_command_overflow_count = 0;
    return total;
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
    if (master_offset < handle->ym_offset_cursor) {
        handle->ym_offset_cursor = master_offset;
    } else {
        advance_ym_master(handle, master_offset - handle->ym_offset_cursor);
        handle->ym_offset_cursor = master_offset;
    }
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

uint8_t jgz80_bus_req_asserted(Jgz80Handle *handle) {
    if (!handle) return 0u;
    return handle->bus_req ? 1u : 0u;
}

uint16_t jgz80_read_reset(Jgz80Handle *handle) {
    if (!handle) return 0x0100u;
    return handle->reset_line ? 0x0000u : 0x0100u;
}

uint8_t jgz80_reset_line_asserted(Jgz80Handle *handle) {
    if (!handle) return 0u;
    return handle->reset_line ? 1u : 0u;
}

void jgz80_set_reset_line_asserted(Jgz80Handle *handle, uint8_t asserted) {
    if (!handle) return;
    handle->reset_line = asserted != 0u;
    handle->bus_ack = handle->bus_req && !handle->reset_line;
}

void jgz80_write_reset(Jgz80Handle *handle, uint16_t val) {
    if (!handle) return;
    bind_callbacks(handle);
    if ((val & 0x100u) == 0u) {
        if (!handle->reset_line) {
            clear_ym2612_shadow_state(handle);
            clear_ym2612_runtime_state(handle);
            push_ym_reset_event(handle);
            handle->reset_line = true;
            handle->bus_ack = false;
        }
    } else {
        if (handle->reset_line) {
            clear_ym2612_shadow_state(handle);
            clear_ym2612_runtime_state(handle);
            push_ym_reset_event(handle);
            z80_reset(&handle->core);
        }
        handle->reset_line = false;
        handle->bus_ack = handle->bus_req;
    }
}
