#ifndef JGZ80_BRIDGE_H
#define JGZ80_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Jgz80Handle Jgz80Handle;

Jgz80Handle* jgz80_create(void);
void jgz80_destroy(Jgz80Handle* handle);

void jgz80_reset(Jgz80Handle* handle);
void jgz80_step(Jgz80Handle* handle, uint32_t cycles);

uint8_t jgz80_read_byte(Jgz80Handle* handle, uint16_t addr);
void jgz80_write_byte(Jgz80Handle* handle, uint16_t addr, uint8_t val);

void jgz80_write_bus_req(Jgz80Handle* handle, uint16_t val);
uint16_t jgz80_read_bus_req(Jgz80Handle* handle);
void jgz80_write_reset(Jgz80Handle* handle, uint16_t val);

#ifdef __cplusplus
}
#endif

#endif
