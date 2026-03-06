#ifndef JGZ80_BRIDGE_H
#define JGZ80_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Jgz80Handle Jgz80Handle;
typedef uint8_t (*Jgz80HostReadFunc)(void* userdata, uint32_t addr);
typedef void (*Jgz80HostWriteFunc)(void* userdata, uint32_t addr, uint8_t val);

Jgz80Handle* jgz80_create(void);
void jgz80_destroy(Jgz80Handle* handle);

void jgz80_reset(Jgz80Handle* handle);
void jgz80_step(Jgz80Handle* handle, uint32_t cycles);
uint32_t jgz80_step_one(Jgz80Handle* handle);

uint8_t jgz80_read_byte(Jgz80Handle* handle, uint16_t addr);
void jgz80_write_byte(Jgz80Handle* handle, uint16_t addr, uint8_t val);
void jgz80_set_host_callbacks(Jgz80Handle* handle, Jgz80HostReadFunc host_read, Jgz80HostWriteFunc host_write, void* userdata);
uint16_t jgz80_get_bank(Jgz80Handle* handle);
uint16_t jgz80_get_pc(Jgz80Handle* handle);
uint8_t jgz80_get_ym_register(Jgz80Handle* handle, uint8_t port, uint8_t reg);
uint8_t jgz80_get_ym_key_mask(Jgz80Handle* handle);
uint8_t jgz80_get_psg_last(Jgz80Handle* handle);
uint16_t jgz80_get_psg_tone(Jgz80Handle* handle, uint8_t channel);
uint8_t jgz80_get_psg_volume(Jgz80Handle* handle, uint8_t channel);
uint8_t jgz80_get_psg_noise(Jgz80Handle* handle);
uint32_t jgz80_take_68k_bus_access_count(Jgz80Handle* handle);

void jgz80_write_bus_req(Jgz80Handle* handle, uint16_t val);
uint16_t jgz80_read_bus_req(Jgz80Handle* handle);
void jgz80_write_reset(Jgz80Handle* handle, uint16_t val);
uint16_t jgz80_read_reset(Jgz80Handle* handle);

#ifdef __cplusplus
}
#endif

#endif
