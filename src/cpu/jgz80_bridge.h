#ifndef JGZ80_BRIDGE_H
#define JGZ80_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Jgz80Handle Jgz80Handle;

typedef struct Jgz80YmWriteEvent {
    uint32_t master_offset;
    uint32_t sequence;
    uint8_t port;
    uint8_t reg;
    uint8_t value;
} Jgz80YmWriteEvent;

typedef struct Jgz80PsgCommandEvent {
    uint32_t master_offset;
    uint8_t value;
} Jgz80PsgCommandEvent;

typedef struct Jgz80YmDacSampleEvent {
    uint32_t master_offset;
    uint32_t sequence;
    uint8_t value;
} Jgz80YmDacSampleEvent;

typedef struct Jgz80YmResetEvent {
    uint32_t master_offset;
    uint32_t sequence;
} Jgz80YmResetEvent;

typedef struct Jgz80RegisterDump {
    uint16_t pc;
    uint16_t sp;
    uint16_t ix;
    uint16_t iy;
    uint16_t af;
    uint16_t bc;
    uint16_t de;
    uint16_t hl;
    uint16_t af_alt;
    uint16_t bc_alt;
    uint16_t de_alt;
    uint16_t hl_alt;
    uint16_t ir;
    uint16_t wz;
    uint8_t interrupt_mode;
    uint8_t irq_data;
    uint8_t iff1;
    uint8_t iff2;
    uint8_t halted;
} Jgz80RegisterDump;

typedef struct Jgz80State {
    uint16_t pc;
    uint16_t sp;
    uint16_t ix;
    uint16_t iy;
    uint16_t mem_ptr;
    uint16_t af;
    uint16_t bc;
    uint16_t de;
    uint16_t hl;
    uint16_t af_alt;
    uint16_t bc_alt;
    uint16_t de_alt;
    uint16_t hl_alt;
    uint8_t i;
    uint8_t r;
    uint8_t iff_delay;
    uint8_t interrupt_mode;
    uint8_t irq_data;
    uint8_t irq_pending;
    uint8_t nmi_pending;
    uint8_t iff1;
    uint8_t iff2;
    uint8_t halted;
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
    Jgz80YmWriteEvent ym_write_events[32768];
    uint16_t ym_write_write_index;
    uint16_t ym_write_read_index;
    uint16_t ym_write_count;
    Jgz80YmDacSampleEvent ym_dac_samples[4096];
    uint16_t ym_dac_write_index;
    uint16_t ym_dac_read_index;
    uint16_t ym_dac_count;
    Jgz80YmResetEvent ym_reset_events[64];
    uint16_t ym_reset_write_index;
    uint16_t ym_reset_read_index;
    uint16_t ym_reset_count;
    Jgz80PsgCommandEvent psg_commands[8192];
    uint16_t psg_command_write_index;
    uint16_t psg_command_read_index;
    uint16_t psg_command_count;
    uint8_t psg_last;
    uint16_t psg_tone[3];
    uint8_t psg_volume[4];
    uint8_t psg_noise;
    uint8_t psg_latched_channel;
    uint8_t psg_latched_is_volume;
    uint8_t bus_req;
    uint8_t bus_ack;
    uint8_t reset_line;
    uint32_t m68k_bus_access_count;
} Jgz80State;

typedef uint8_t (*Jgz80HostReadFunc)(void *userdata, uint32_t addr);

typedef uint8_t (*Jgz80HostPeekFunc)(void *userdata, uint32_t addr);

typedef void (*Jgz80HostWriteFunc)(void *userdata, uint32_t addr, uint8_t val);

typedef void (*Jgz80M68kBusAccessFunc)(void *userdata, uint32_t pre_access_master_cycles);

Jgz80Handle *jgz80_create(void);

Jgz80Handle *jgz80_clone(const Jgz80Handle *handle);

void jgz80_capture_state(const Jgz80Handle *handle, Jgz80State *state);

void jgz80_restore_state(Jgz80Handle *handle, const Jgz80State *state);

void jgz80_destroy(Jgz80Handle *handle);

void jgz80_reset(Jgz80Handle *handle);

void jgz80_soft_reset(Jgz80Handle *handle);

void jgz80_step(Jgz80Handle *handle, uint32_t cycles);

uint32_t jgz80_step_one(Jgz80Handle *handle);

uint8_t jgz80_read_byte(Jgz80Handle *handle, uint16_t addr);

void jgz80_write_byte(Jgz80Handle *handle, uint16_t addr, uint8_t val);

void jgz80_set_host_callbacks(
    Jgz80Handle *handle,
    Jgz80HostReadFunc host_read,
    Jgz80HostPeekFunc host_peek,
    Jgz80HostWriteFunc host_write,
    Jgz80M68kBusAccessFunc host_m68k_bus_access,
    void *userdata
);

uint16_t jgz80_get_bank(Jgz80Handle *handle);

uint16_t jgz80_get_pc(Jgz80Handle *handle);

Jgz80RegisterDump jgz80_get_register_dump(Jgz80Handle *handle);

uint8_t jgz80_get_ym_register(Jgz80Handle *handle, uint8_t port, uint8_t reg);

uint8_t jgz80_get_ym_key_mask(Jgz80Handle *handle);

uint16_t jgz80_peek_ym_write_count(const Jgz80Handle *handle);

uint16_t jgz80_peek_ym_dac_count(const Jgz80Handle *handle);

uint16_t jgz80_peek_psg_command_count(const Jgz80Handle *handle);

uint16_t jgz80_take_ym_writes(Jgz80Handle *handle, Jgz80YmWriteEvent *dest, uint16_t max_events);

uint16_t jgz80_take_ym_dac_samples(Jgz80Handle *handle, Jgz80YmDacSampleEvent *dest, uint16_t max_samples);

uint16_t jgz80_take_ym_resets(Jgz80Handle *handle, Jgz80YmResetEvent *dest, uint16_t max_events);

uint16_t jgz80_take_psg_commands(Jgz80Handle *handle, Jgz80PsgCommandEvent *dest, uint16_t max_commands);

uint8_t jgz80_get_psg_last(Jgz80Handle *handle);

uint16_t jgz80_get_psg_tone(Jgz80Handle *handle, uint8_t channel);

uint8_t jgz80_get_psg_volume(Jgz80Handle *handle, uint8_t channel);

uint8_t jgz80_get_psg_noise(Jgz80Handle *handle);

uint32_t jgz80_take_68k_bus_access_count(Jgz80Handle *handle);

uint32_t jgz80_take_overflow_counts(Jgz80Handle * handle, uint32_t * ym_write, uint32_t * ym_dac, uint32_t * ym_reset,
                                    uint32_t * psg_command);

void jgz80_set_audio_master_offset(Jgz80Handle *handle, uint32_t master_offset);

void jgz80_assert_irq(Jgz80Handle *handle, uint8_t data);

void jgz80_clear_irq(Jgz80Handle *handle);

void jgz80_write_bus_req(Jgz80Handle *handle, uint16_t val);

uint16_t jgz80_read_bus_req(Jgz80Handle *handle);

uint8_t jgz80_bus_req_asserted(Jgz80Handle *handle);

void jgz80_write_reset(Jgz80Handle *handle, uint16_t val);

uint16_t jgz80_read_reset(Jgz80Handle *handle);

uint8_t jgz80_reset_line_asserted(Jgz80Handle *handle);

void jgz80_set_reset_line_asserted(Jgz80Handle *handle, uint8_t asserted);

#ifdef __cplusplus
}
#endif

#endif
