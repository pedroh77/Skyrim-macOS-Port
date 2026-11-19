// Optional Steamworks bridge for Steam builds of The Elder Scrolls V: Skyrim.
// Loads Valve's official ARM64 libsteam_api.dylib via dlopen when present and
// connected to a running Mac Steam client; falls back cleanly to offline mode
// (returning 0 from SteamAPI_Init) if the dylib or Steam client is unavailable.
#include "com.h"
#include "shims.h"
#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

static pthread_mutex_t steam_lock = PTHREAD_MUTEX_INITIALIZER;
static void *steam_lib;
static int steam_active;
static int steam_tried_load;
static int steam_dispatching;

// Real ARM64 pointers from libsteam_api.dylib
static void *real_user;
static void *real_friends;
static void *real_user_stats;
static void *real_apps;
static void *real_utils;

// Guest proxy objects ([vtable ptr], allocated once on guest heap)
static uint32_t proxy_user;
static uint32_t proxy_friends;
static uint32_t proxy_user_stats;
static uint32_t proxy_apps;
static uint32_t proxy_utils;

// Function pointers resolved from libsteam_api.dylib
static bool (*p_SteamAPI_Init)(void);
static void (*p_SteamAPI_Shutdown)(void);
static bool (*p_SteamAPI_IsSteamRunning)(void);
static int32_t (*p_SteamAPI_GetHSteamPipe)(void);
static void (*p_SteamAPI_ManualDispatch_Init)(void);
static void (*p_SteamAPI_ManualDispatch_RunFrame)(int32_t pipe);
typedef struct { int32_t user, id; uint8_t *param; int32_t size; } SteamCallbackMsg;
static bool (*p_SteamAPI_ManualDispatch_GetNextCallback)(int32_t pipe, SteamCallbackMsg *out);
static void (*p_SteamAPI_ManualDispatch_FreeLastCallback)(int32_t pipe);

static void *(*p_SteamUser_v)(void);
static void *(*p_SteamFriends_v)(void);
static void *(*p_SteamUserStats_v)(void);
static void *(*p_SteamApps_v)(void);
static void *(*p_SteamUtils_v)(void);

static bool (*p_ISteamUser_BLoggedOn)(void *self);
static uint32_t (*p_ISteamUtils_GetAppID)(void *self);
static bool (*p_ISteamUserStats_RequestCurrentStats)(void *self);
static bool (*p_ISteamUserStats_GetAchievement)(void *self, const char *name, bool *achieved);
static bool (*p_ISteamUserStats_SetAchievement)(void *self, const char *name);
static bool (*p_ISteamUserStats_ClearAchievement)(void *self, const char *name);
static bool (*p_ISteamUserStats_StoreStats)(void *self);
static bool (*p_ISteamApps_BIsDlcInstalled)(void *self, uint32_t app_id);
static void (*p_ISteamFriends_ActivateGameOverlayToStore)(void *self, uint32_t app_id, int flag);

typedef struct { uint32_t obj; int32_t id; } GuestCallback;
static GuestCallback *cb_list;
static size_t cb_count, cb_cap;

static int is_flag_set(const char *name) {
    const char *v = getenv(name);
    return v && *v && strcmp(v, "0") != 0;
}

static int exe_dir(char *out, size_t n) {
#ifdef __APPLE__
    char raw[PATH_MAX], real[PATH_MAX];
    uint32_t sz = sizeof(raw);
    if (_NSGetExecutablePath(raw, &sz) || !realpath(raw, real)) return -1;
    char *slash = strrchr(real, '/');
    if (!slash) return -1;
    *slash = 0;
    return snprintf(out, n, "%s", real) >= (int)n ? -1 : 0;
#else
    (void)out; (void)n;
    return -1;
#endif
}

static void configure_appid(void) {
    if (getenv("SteamAppId") && *getenv("SteamAppId")) return;
    const char *env_id = getenv("SKYRIM_STEAM_APPID");
    if (!env_id || !*env_id) env_id = getenv("FNV_STEAM_APPID");
    char buf[32] = {0};
    if (env_id && *env_id) {
        snprintf(buf, sizeof(buf), "%s", env_id);
    } else {
        char dir[PATH_MAX], path[PATH_MAX];
        if (!exe_dir(dir, sizeof(dir)) &&
            snprintf(path, sizeof(path), "%s/steam_appid.txt", dir) < (int)sizeof(path)) {
            FILE *f = fopen(path, "rb");
            if (f) {
                size_t k = fread(buf, 1, sizeof(buf) - 1, f);
                fclose(f);
                while (k && (buf[k - 1] == '\n' || buf[k - 1] == '\r' || buf[k - 1] == ' '))
                    buf[--k] = 0;
            }
        }
    }
    if (!buf[0]) snprintf(buf, sizeof(buf), "72850");
    setenv("SteamAppId", buf, 0);
    setenv("SteamGameId", buf, 0);
}

static int load_steam_dylib(void) {
    if (steam_tried_load) return steam_lib != NULL;
    steam_tried_load = 1;

    if (is_flag_set("SKYRIM_STEAM_DISABLE") || is_flag_set("FNV_STEAM_DISABLE")) return 0;
    if (is_flag_set("FNV_HEADLESS") && !is_flag_set("SKYRIM_STEAM_FORCE")) return 0;

    char cand[PATH_MAX];
    const char *env_path = getenv("SKYRIM_STEAM_API_DYLIB");
    if (!env_path || !*env_path) env_path = getenv("FNV_STEAM_API_DYLIB");
    if (env_path && *env_path) {
        steam_lib = dlopen(env_path, RTLD_NOW | RTLD_LOCAL);
    }
    if (!steam_lib) {
        char dir[PATH_MAX];
        if (!exe_dir(dir, sizeof(dir))) {
            if (snprintf(cand, sizeof(cand), "%s/../Frameworks/libsteam_api.dylib", dir) < (int)sizeof(cand))
                steam_lib = dlopen(cand, RTLD_NOW | RTLD_LOCAL);
            if (!steam_lib && snprintf(cand, sizeof(cand), "%s/libsteam_api.dylib", dir) < (int)sizeof(cand))
                steam_lib = dlopen(cand, RTLD_NOW | RTLD_LOCAL);
        }
    }
    if (!steam_lib) return 0;

#define SYM(var, name) do { *(void **)(&var) = dlsym(steam_lib, name); if (!(var)) goto missing; } while (0)
    SYM(p_SteamAPI_Init, "SteamAPI_Init");
    SYM(p_SteamAPI_Shutdown, "SteamAPI_Shutdown");
    SYM(p_SteamAPI_IsSteamRunning, "SteamAPI_IsSteamRunning");
    SYM(p_SteamAPI_GetHSteamPipe, "SteamAPI_GetHSteamPipe");
    SYM(p_SteamAPI_ManualDispatch_Init, "SteamAPI_ManualDispatch_Init");
    SYM(p_SteamAPI_ManualDispatch_RunFrame, "SteamAPI_ManualDispatch_RunFrame");
    SYM(p_SteamAPI_ManualDispatch_GetNextCallback, "SteamAPI_ManualDispatch_GetNextCallback");
    SYM(p_SteamAPI_ManualDispatch_FreeLastCallback, "SteamAPI_ManualDispatch_FreeLastCallback");
    SYM(p_SteamUser_v, "SteamAPI_SteamUser_v021");
    SYM(p_SteamFriends_v, "SteamAPI_SteamFriends_v017");
    SYM(p_SteamUserStats_v, "SteamAPI_SteamUserStats_v012");
    SYM(p_SteamApps_v, "SteamAPI_SteamApps_v008");
    SYM(p_SteamUtils_v, "SteamAPI_SteamUtils_v010");
    SYM(p_ISteamUser_BLoggedOn, "SteamAPI_ISteamUser_BLoggedOn");
    SYM(p_ISteamUtils_GetAppID, "SteamAPI_ISteamUtils_GetAppID");
    SYM(p_ISteamUserStats_RequestCurrentStats, "SteamAPI_ISteamUserStats_RequestCurrentStats");
    SYM(p_ISteamUserStats_GetAchievement, "SteamAPI_ISteamUserStats_GetAchievement");
    SYM(p_ISteamUserStats_SetAchievement, "SteamAPI_ISteamUserStats_SetAchievement");
    SYM(p_ISteamUserStats_ClearAchievement, "SteamAPI_ISteamUserStats_ClearAchievement");
    SYM(p_ISteamUserStats_StoreStats, "SteamAPI_ISteamUserStats_StoreStats");
    SYM(p_ISteamApps_BIsDlcInstalled, "SteamAPI_ISteamApps_BIsDlcInstalled");
    SYM(p_ISteamFriends_ActivateGameOverlayToStore, "SteamAPI_ISteamFriends_ActivateGameOverlayToStore");
#undef SYM
    return 1;

missing:
    fprintf(stderr, "[steam] libsteam_api.dylib is missing expected symbols; running offline\n");
    dlclose(steam_lib);
    steam_lib = NULL;
    return 0;
}

// ---- Guest __thiscall proxy methods (ECX = this, callee pops stack args) ------------------------
static void steam_unimplemented(CPU *c) {
    fprintf(stderr, "[steam] unimplemented interface method called (ECX=%#x, EIP~%#x)\n",
            REG(c, R_ECX), (uint32_t)LD(c->r + 644, 4));
    rt_trap(c, TRAP_IMPORT, 0);
}

static void m_ISteamUser_BLoggedOn(CPU *c) {
    uint32_t ok = (real_user && p_ISteamUser_BLoggedOn(real_user)) ? 1u : 0u;
    RET(c, ok, 0);
}

static void m_ISteamUtils_GetAppID(CPU *c) {
    uint32_t id = real_utils ? p_ISteamUtils_GetAppID(real_utils) : 0u;
    RET(c, id, 0);
}

static void m_ISteamUserStats_RequestCurrentStats(CPU *c) {
    uint32_t ok = (real_user_stats && p_ISteamUserStats_RequestCurrentStats(real_user_stats)) ? 1u : 0u;
    fprintf(stderr, "[steam] RequestCurrentStats() -> %u\n", ok);
    RET(c, ok, 0);
}

static void m_ISteamUserStats_GetAchievement(CPU *c) {
    const char *name = GSTR(ARG(c, 0));
    uint32_t out_ptr = ARG(c, 1);
    bool achieved = false;
    uint32_t ok = (real_user_stats && name &&
                   p_ISteamUserStats_GetAchievement(real_user_stats, name, &achieved)) ? 1u : 0u;
    if (out_ptr) MEM[out_ptr] = achieved ? 1u : 0u;
    RET(c, ok, 2);
}

static void m_ISteamUserStats_SetAchievement(CPU *c) {
    const char *name = GSTR(ARG(c, 0));
    uint32_t ok = (real_user_stats && name && p_ISteamUserStats_SetAchievement(real_user_stats, name)) ? 1u : 0u;
    fprintf(stderr, "[steam] SetAchievement(\"%s\") -> %u\n", name ? name : "", ok);
    RET(c, ok, 1);
}

static void m_ISteamUserStats_ClearAchievement(CPU *c) {
    const char *name = GSTR(ARG(c, 0));
    uint32_t ok = (real_user_stats && name && p_ISteamUserStats_ClearAchievement(real_user_stats, name)) ? 1u : 0u;
    fprintf(stderr, "[steam] ClearAchievement(\"%s\") -> %u\n", name ? name : "", ok);
    RET(c, ok, 1);
}

static void m_ISteamUserStats_StoreStats(CPU *c) {
    uint32_t ok = (real_user_stats && p_ISteamUserStats_StoreStats(real_user_stats)) ? 1u : 0u;
    fprintf(stderr, "[steam] StoreStats() -> %u\n", ok);
    RET(c, ok, 0);
}

static void m_ISteamApps_BIsDlcInstalled(CPU *c) {
    uint32_t app_id = ARG(c, 0);
    uint32_t ok = (real_apps && p_ISteamApps_BIsDlcInstalled(real_apps, app_id)) ? 1u : 0u;
    RET(c, ok, 1);
}

static void m_ISteamFriends_ActivateGameOverlayToStore(CPU *c) {
    uint32_t app_id = ARG(c, 0);
    if (real_friends) p_ISteamFriends_ActivateGameOverlayToStore(real_friends, app_id, 0);
    RET(c, 0, 1);
}

typedef struct { int slot; const char *name; ShimFn fn; } SteamSlot;
static uint32_t make_proxy(const char *iface, const SteamSlot *slots, int n_slots, int total_slots) {
    uint32_t vt = gmalloc(4u * (uint32_t)total_slots);
    uint32_t fallback = host_thunk(iface, steam_unimplemented);
    for (int i = 0; i < total_slots; i++) P32(vt + 4u * (uint32_t)i, fallback);
    for (int i = 0; i < n_slots; i++) {
        char nm[96];
        snprintf(nm, sizeof(nm), "%s::%s", iface, slots[i].name);
        P32(vt + 4u * (uint32_t)slots[i].slot, host_thunk(nm, slots[i].fn));
    }
    uint32_t obj = gmalloc(4);
    P32(obj, vt);
    return obj;
}

static void init_proxies(void) {
    if (proxy_user) return;
    static const SteamSlot user_slots[] = {{1, "BLoggedOn", m_ISteamUser_BLoggedOn}};
    static const SteamSlot utils_slots[] = {{9, "GetAppID", m_ISteamUtils_GetAppID}};
    static const SteamSlot stats_slots[] = {
        {0, "RequestCurrentStats", m_ISteamUserStats_RequestCurrentStats},
        {6, "GetAchievement", m_ISteamUserStats_GetAchievement},
        {7, "SetAchievement", m_ISteamUserStats_SetAchievement},
        {8, "ClearAchievement", m_ISteamUserStats_ClearAchievement},
        {10, "StoreStats", m_ISteamUserStats_StoreStats},
    };
    static const SteamSlot apps_slots[] = {{7, "BIsDlcInstalled", m_ISteamApps_BIsDlcInstalled}};
    static const SteamSlot friends_slots[] = {{22, "ActivateGameOverlayToStore", m_ISteamFriends_ActivateGameOverlayToStore}};

    proxy_user = make_proxy("ISteamUser", user_slots, 1, 24);
    proxy_utils = make_proxy("ISteamUtils", utils_slots, 1, 24);
    proxy_user_stats = make_proxy("ISteamUserStats", stats_slots, 5, 24);
    proxy_apps = make_proxy("ISteamApps", apps_slots, 1, 24);
    proxy_friends = make_proxy("ISteamFriends", friends_slots, 1, 32);
}

// ---- Callbacks ---------------------------------------------------------------------------------
static void deliver_callback(CPU *c, uint32_t obj, int32_t id, const void *data, int32_t size) {
    uint32_t vt = G32(obj);
    // MSVC places Run(void*, bool, SteamAPICall_t) [ret 0x10] at vtable[0] and the 1-arg
    // Run(void *pvParam) [ret 0x4] at vtable[1] for CCallback<T, P, false> in TESV.exe.
    uint32_t run_fn = G32(vt + 4);
    if (!run_fn) run_fn = G32(vt);
    if (!run_fn) return;

    if (id == 331 && size >= 1 && data) {
        fprintf(stderr, "[steam] GameOverlayActivated(active=%u)\n", ((const uint8_t *)data)[0]);
    }

    // UserStatsReceived_t (1101): macOS pack(4) is 20 bytes (m_nGameID@0, m_eResult@8,
    // m_steamIDUser@12); Win32 MSVC pack(8) is 24 bytes (m_steamIDUser@16).
    uint32_t alloc_sz = (uint32_t)(size > 0 ? size : 1) + 16u;
    uint32_t buf = gmalloc(alloc_sz);
    memset(MEM + buf, 0, alloc_sz);
    if (id == 1101 && size == 20 && data) {
        memcpy(MEM + buf, data, 12);
        memcpy(MEM + buf + 16, (const uint8_t *)data + 12, 8);
    } else if (size > 0 && data) {
        memcpy(MEM + buf, data, (size_t)size);
    }

    uint32_t esp = REG(c, R_ESP);
    uint32_t ecx = REG(c, R_ECX);
    uint32_t eax = REG(c, R_EAX);
    uint32_t edx = REG(c, R_EDX);
    uint32_t sp = esp - 64;
    P32(sp, HOST_EXIT_THUNK);
    P32(sp + 4, buf);
    SETREG(c, R_ESP, sp);
    SETREG(c, R_ECX, obj);
    rt_call(c, run_fn);   // CCallbackBase::Run(void *pvParam): __thiscall, callee pops arg
    SETREG(c, R_ESP, esp);
    SETREG(c, R_ECX, ecx);
    SETREG(c, R_EAX, eax);
    SETREG(c, R_EDX, edx);
    gfree(buf);
}

static void dispatch_callbacks(CPU *c, int32_t id, const void *data, int32_t size) {
    pthread_mutex_lock(&steam_lock);
    size_t n = 0;
    uint32_t *targets = cb_count ? malloc(cb_count * sizeof(*targets)) : NULL;
    for (size_t i = 0; targets && i < cb_count; i++) {
        if (cb_list[i].id == id) targets[n++] = cb_list[i].obj;
    }
    pthread_mutex_unlock(&steam_lock);

    for (size_t t = 0; t < n; t++) {
        pthread_mutex_lock(&steam_lock);
        int alive = 0;
        for (size_t i = 0; i < cb_count && !alive; i++) {
            alive = (cb_list[i].obj == targets[t] && cb_list[i].id == id);
        }
        pthread_mutex_unlock(&steam_lock);
        if (alive) deliver_callback(c, targets[t], id, data, size);
    }
    free(targets);
}

// ---- steam_api.dll imports (cdecl) -------------------------------------------------------------
SHIM(SteamAPI_Init) {
    pthread_mutex_lock(&steam_lock);
    if (!steam_active && load_steam_dylib()) {
        configure_appid();
        if (p_SteamAPI_Init()) {
            p_SteamAPI_ManualDispatch_Init();
            real_user = p_SteamUser_v();
            real_friends = p_SteamFriends_v();
            real_user_stats = p_SteamUserStats_v();
            real_apps = p_SteamApps_v();
            real_utils = p_SteamUtils_v();
            if (real_user_stats) p_ISteamUserStats_RequestCurrentStats(real_user_stats);
            init_proxies();
            steam_active = 1;
            uint32_t appid = real_utils ? p_ISteamUtils_GetAppID(real_utils) : 0;
            fprintf(stderr, "[steam] SteamAPI_Init -> true (AppID=%u)\n", appid);
        } else {
            fprintf(stderr, "[steam] SteamAPI_Init -> false (Steam client unavailable; running offline)\n");
        }
    } else if (!steam_active) {
        fprintf(stderr, "[host] SteamAPI_Init -> false (offline)\n");
    }
    uint32_t ok = steam_active ? 1u : 0u;
    pthread_mutex_unlock(&steam_lock);
    RET(c, ok, 0);
}

SHIM(SteamAPI_IsSteamRunning) {
    uint32_t running = (steam_active && p_SteamAPI_IsSteamRunning && p_SteamAPI_IsSteamRunning()) ? 1u : 0u;
    RET(c, running, 0);
}

SHIM(SteamAPI_Shutdown) {
    pthread_mutex_lock(&steam_lock);
    if (steam_active && p_SteamAPI_Shutdown) {
        p_SteamAPI_Shutdown();
        steam_active = 0;
        fprintf(stderr, "[steam] SteamAPI_Shutdown\n");
    }
    pthread_mutex_unlock(&steam_lock);
    RET(c, 0, 0);
}

SHIM(SteamAPI_RunCallbacks) {
    if (steam_active && !steam_dispatching) {
        int32_t pipe = p_SteamAPI_GetHSteamPipe();
        if (pipe) {
            steam_dispatching = 1;
            p_SteamAPI_ManualDispatch_RunFrame(pipe);
            SteamCallbackMsg msg;
            while (p_SteamAPI_ManualDispatch_GetNextCallback(pipe, &msg)) {
                dispatch_callbacks(c, msg.id, msg.param, msg.size);
                p_SteamAPI_ManualDispatch_FreeLastCallback(pipe);
            }
            steam_dispatching = 0;
        }
    }
    RET(c, 0, 0);
}

SHIM(SteamAPI_RegisterCallback) {
    uint32_t obj = ARG(c, 0);
    int32_t id = (int32_t)ARG(c, 1);
    if (obj) {
        MEM[obj + 4] |= 0x01u;
        P32(obj + 8, (uint32_t)id);
        pthread_mutex_lock(&steam_lock);
        int found = 0;
        for (size_t i = 0; i < cb_count; i++) {
            if (cb_list[i].obj == obj) { cb_list[i].id = id; found = 1; break; }
        }
        if (!found) {
            if (cb_count == cb_cap) {
                cb_cap = cb_cap ? cb_cap * 2 : 8;
                cb_list = realloc(cb_list, cb_cap * sizeof(*cb_list));
            }
            if (cb_list) cb_list[cb_count++] = (GuestCallback){obj, id};
        }
        pthread_mutex_unlock(&steam_lock);
    }
    RET(c, 0, 0);   // cdecl: caller pops
}

SHIM(SteamAPI_UnregisterCallback) {
    uint32_t obj = ARG(c, 0);
    if (obj) {
        MEM[obj + 4] &= (uint8_t)~0x01u;
        pthread_mutex_lock(&steam_lock);
        for (size_t i = 0; i < cb_count; i++) {
            if (cb_list[i].obj == obj) { cb_list[i] = cb_list[--cb_count]; break; }
        }
        pthread_mutex_unlock(&steam_lock);
    }
    RET(c, 0, 0);   // cdecl: caller pops
}

SHIM(SteamUser) { RET(c, steam_active ? proxy_user : 0u, 0); }
SHIM(SteamFriends) { RET(c, steam_active ? proxy_friends : 0u, 0); }
SHIM(SteamUserStats) { RET(c, steam_active ? proxy_user_stats : 0u, 0); }
SHIM(SteamApps) { RET(c, steam_active ? proxy_apps : 0u, 0); }
SHIM(SteamUtils) { RET(c, steam_active ? proxy_utils : 0u, 0); }

SHIM_TABLE(steam_shims,
    E(SteamAPI_Init) E(SteamAPI_IsSteamRunning) E(SteamAPI_Shutdown) E(SteamAPI_RunCallbacks)
    E(SteamAPI_RegisterCallback) E(SteamAPI_UnregisterCallback)
    E(SteamUser) E(SteamFriends) E(SteamUserStats) E(SteamApps) E(SteamUtils))
