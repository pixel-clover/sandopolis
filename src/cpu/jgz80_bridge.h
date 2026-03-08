#ifndef JGZ80_BRIDGE_H
#define JGZ80_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Jgz80Handle Jgz80Handle;

typedef struct Jgz80YmWriteEvent {
    uint32_t master_offset;
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
    uint8_t value;
} Jgz80YmDacSampleEvent;

typedef struct Jgz80YmResetEvent {
    uint32_t master_offset;
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

typedef uint8_t (*Jgz80HostReadFunc)(void *userdata, uint32_t addr);

typedef void (*Jgz80HostWriteFunc)(void *userdata, uint32_t addr, uint8_t val);

Jgz80Handle *jgz80_create(void);

void jgz80_destroy(Jgz80Handle *handle);

void jgz80_reset(Jgz80Handle *handle);

void jgz80_step(Jgz80Handle *handle, uint32_t cycles);

uint32_t jgz80_step_one(Jgz80Handle *handle);

uint8_t jgz80_read_byte(Jgz80Handle *handle, uint16_t addr);

void jgz80_write_byte(Jgz80Handle *handle, uint16_t addr, uint8_t val);

void jgz80_set_host_callbacks(Jgz80Handle *handle, Jgz80HostReadFunc host_read, Jgz80HostWriteFunc host_write,
                              void *userdata);

uint16_t jgz80_get_bank(Jgz80Handle *handle);

uint16_t jgz80_get_pc(Jgz80Handle *handle);

Jgz80RegisterDump jgz80_get_register_dump(Jgz80Handle *handle);

uint8_t jgz80_get_ym_register(Jgz80Handle *handle, uint8_t port, uint8_t reg);

uint8_t jgz80_get_ym_key_mask(Jgz80Handle *handle);

uint16_t jgz80_take_ym_writes(Jgz80Handle *handle, Jgz80YmWriteEvent *dest, uint16_t max_events);

uint16_t jgz80_take_ym_dac_samples(Jgz80Handle *handle, Jgz80YmDacSampleEvent *dest, uint16_t max_samples);

uint16_t jgz80_take_ym_resets(Jgz80Handle *handle, Jgz80YmResetEvent *dest, uint16_t max_events);

uint16_t jgz80_take_psg_commands(Jgz80Handle *handle, Jgz80PsgCommandEvent *dest, uint16_t max_commands);

uint8_t jgz80_get_psg_last(Jgz80Handle *handle);

uint16_t jgz80_get_psg_tone(Jgz80Handle *handle, uint8_t channel);

uint8_t jgz80_get_psg_volume(Jgz80Handle *handle, uint8_t channel);

uint8_t jgz80_get_psg_noise(Jgz80Handle *handle);

uint32_t jgz80_take_68k_bus_access_count(Jgz80Handle *handle);

void jgz80_set_audio_master_offset(Jgz80Handle *handle, uint32_t master_offset);

void jgz80_assert_irq(Jgz80Handle *handle, uint8_t data);

void jgz80_clear_irq(Jgz80Handle *handle);

void jgz80_write_bus_req(Jgz80Handle *handle, uint16_t val);

uint16_t jgz80_read_bus_req(Jgz80Handle *handle);

void jgz80_write_reset(Jgz80Handle *handle, uint16_t val);

uint16_t jgz80_read_reset(Jgz80Handle *handle);

#ifdef __cplusplus
}
#endif

#endif
