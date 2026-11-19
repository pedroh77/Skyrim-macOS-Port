#pragma once
#include <stdint.h>

typedef struct {
    uint32_t packet;
    uint16_t buttons;
    uint8_t left_trigger, right_trigger;
    int16_t lx, ly, rx, ry;
} FNVPadState;

void fnv_pad_physical_state(const FNVPadState *state, int connected);
int fnv_pad_connected(void);
int fnv_analog_enabled(void);
void fnv_pad_snapshot(FNVPadState *state);
void fnv_pad_reset(void);
