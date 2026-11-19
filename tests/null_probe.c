#include <assert.h>
#include <stdio.h>
#include "FNVPad.h"
#include "input.h"
#include "d3d9_backend.h"

static int clears;

void d3d_backend_clear(D3DState *s, uint32_t n, uint32_t rects, uint32_t flags, uint32_t color, float z, uint32_t stencil) {
    (void)n; (void)rects; (void)z; (void)stencil;
    assert(s->width == 960 && s->height == 540 && flags == 1);
    assert(color == 0xff564d70u);
    ++clears;
}

int fnv_probe(unsigned);

int main(void) {
    assert(!fnv_analog_enabled());
    input_key(0x11, 1);
    uint8_t keys[256];
    input_keyboard_state(keys);
    assert(keys[0x11]);
    input_key(0x11, 0);
    input_keyboard_state(keys);
    assert(!keys[0x11]);

    FNVPadState pad = {0};
    pad.lx = 8192;
    pad.ly = 16384;
    fnv_pad_physical_state(&pad, 1);
    assert(fnv_analog_enabled());
    input_mouse_move(6, -3);
    int rc = fnv_probe(3);
    assert(rc == 0 && clears == 3);
    puts("PASS: dynamic guest map, D3D COM device/clear/present, keyboard/mouse/gamepad poll");
    return rc;
}
