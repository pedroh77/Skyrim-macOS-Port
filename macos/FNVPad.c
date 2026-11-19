#include "FNVPad.h"
#include <pthread.h>
#include <string.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static FNVPadState physical;
static int connected;

void fnv_pad_physical_state(const FNVPadState *state, int is_connected) {
    pthread_mutex_lock(&lock);
    connected = !!is_connected;
    if (connected && state) {
        if (memcmp((const char *)state + 4, (const char *)&physical + 4, sizeof(FNVPadState) - 4) != 0) {
            uint32_t next_pkt = physical.packet + 1;
            physical = *state;
            physical.packet = next_pkt;
        }
    } else {
        uint32_t next_pkt = physical.packet + 1;
        memset(&physical, 0, sizeof physical);
        physical.packet = next_pkt;
    }
    pthread_mutex_unlock(&lock);
}

int fnv_pad_connected(void) {
    pthread_mutex_lock(&lock);
    int c = connected;
    pthread_mutex_unlock(&lock);
    return c;
}

int fnv_analog_enabled(void) {
    return fnv_pad_connected();
}

void fnv_pad_snapshot(FNVPadState *state) {
    pthread_mutex_lock(&lock);
    *state = physical;
    pthread_mutex_unlock(&lock);
}

void fnv_pad_reset(void) {
    pthread_mutex_lock(&lock);
    uint32_t next_pkt = physical.packet + 1;
    memset(&physical, 0, sizeof physical);
    physical.packet = next_pkt;
    pthread_mutex_unlock(&lock);
}
