#include "FNVDisplay.h"

// Configured on the main thread before the guest starts. Uses native desktop resolution
// (or scaled internal render resolution with MetalFX/bilinear upscale to output resolution).
static unsigned width = 1280, height = 720, client_width = 1280, client_height = 720;
static unsigned output_width = 0, output_height = 0;
static int display_refresh_hz = 60;
static int graphics_upscaler = 1; // 0 = Bilinear, 1 = MetalFX Spatial
static int graphics_aa = 0;       // 0 = Off, 1 = SMAA, 2 = FXAA

void fnv_display_configure_scaled(unsigned native_w, unsigned native_h, unsigned scale_pct) {
    if (!native_w || !native_h) return;
    unsigned ow = (native_w / 2u) * 2u;
    unsigned oh = (native_h / 2u) * 2u;
    if (ow < 640u) ow = 640u;
    if (oh < 480u) oh = 480u;
    output_width = ow;
    output_height = oh;

    if (scale_pct == 0u) scale_pct = 100u;
    if (scale_pct < 50u) scale_pct = 50u;
    if (scale_pct > 100u) scale_pct = 100u;

    unsigned rw = ((ow * scale_pct / 100u) / 2u) * 2u;
    unsigned rh = ((oh * scale_pct / 100u) / 2u) * 2u;
    if (rw < 640u) rw = 640u;
    if (rh < 480u) rh = 480u;
    if (rw > ow) rw = ow;
    if (rh > oh) rh = oh;

    width = client_width = rw;
    height = client_height = rh;
}

void fnv_display_configure(unsigned nw, unsigned nh) {
    fnv_display_configure_scaled(nw, nh, 100u);
}

unsigned fnv_display_width(void) { return width; }
unsigned fnv_display_height(void) { return height; }
unsigned fnv_output_width(void) { return output_width; }
unsigned fnv_output_height(void) { return output_height; }

void fnv_display_client(unsigned w, unsigned h) {
    if (w && h) {
        client_width = w;
        client_height = h;
    }
}

unsigned fnv_client_width(void) { return client_width; }
unsigned fnv_client_height(void) { return client_height; }

void fnv_display_set_refresh(int hz) { if (hz > 0) display_refresh_hz = hz; }
int fnv_display_refresh(void) { return display_refresh_hz; }

void fnv_graphics_configure(int upscaler, int aa) {
    graphics_upscaler = upscaler;
    graphics_aa = aa;
}
int fnv_graphics_upscaler(void) { return graphics_upscaler; }
int fnv_graphics_aa(void) { return graphics_aa; }

// Keep the established guest adapter identity stable. Startup compares it with
// sD3DDevice before deciding whether to tear down workers and invoke the launcher.
const char *fnv_display_adapter_description(void) { return "NVIDIA GeForce GTX 580"; }
