// Native Steam launcher wrapper bundled as CFBundleExecutable for Steam builds.
// Starts the Mac Steam client silently if installed and not already running,
// waits until the Steam global user IPC is ready, configures SteamAppId /
// SteamGameId / SteamOverlayGameId and DYLD_INSERT_LIBRARIES for Valve's
// gameoverlayrenderer.dylib, then execv's Skyrim.
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int is_flag_set(const char *name) {
    const char *v = getenv(name);
    return v && *v && strcmp(v, "0") != 0;
}

static int run_quiet(const char *path, char *const argv[]) {
    posix_spawn_file_actions_t fa;
    if (posix_spawn_file_actions_init(&fa) != 0) return -1;
    posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (rc != 0) return -1;
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) return -1;
    return (WIFEXITED(st) && WEXITSTATUS(st) == 0) ? 0 : 1;
}

static int is_proc_running(const char *name) {
    char *const argv[] = {"pgrep", "-qx", (char *)name, NULL};
    return run_quiet("/usr/bin/pgrep", argv) == 0;
}

static int steam_is_installed(const char *home) {
    if (access("/Applications/Steam.app", F_OK) == 0) return 1;
    if (!home) return 0;
    char p[PATH_MAX];
    if (snprintf(p, sizeof(p), "%s/Applications/Steam.app", home) < (int)sizeof(p) &&
        access(p, F_OK) == 0) return 1;
    if (snprintf(p, sizeof(p),
                 "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx",
                 home) < (int)sizeof(p) && access(p, F_OK) == 0) return 1;
    return 0;
}

static void read_appid(const char *dir, char *out, size_t n) {
    const char *env = getenv("SteamAppId");
    if (!env || !*env) env = getenv("SKYRIM_STEAM_APPID");
    if (!env || !*env) env = getenv("FNV_STEAM_APPID");
    if (env && *env) {
        snprintf(out, n, "%s", env);
        return;
    }
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/steam_appid.txt", dir) < (int)sizeof(path)) {
        FILE *f = fopen(path, "rb");
        if (f) {
            size_t k = fread(out, 1, n - 1, f);
            fclose(f);
            out[k] = 0;
            while (k && (out[k - 1] == '\n' || out[k - 1] == '\r' || out[k - 1] == ' '))
                out[--k] = 0;
            if (out[0]) return;
        }
    }
    snprintf(out, n, "72850");
}

static void wait_for_steam_user(const char *dir, const char *home, int just_started) {
    void *sc_lib = NULL;
    void *sa_lib = NULL;

    if (home) {
        char sc_path[PATH_MAX];
        if (snprintf(sc_path, sizeof(sc_path),
                     "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib",
                     home) < (int)sizeof(sc_path)) {
            sc_lib = dlopen(sc_path, RTLD_NOW | RTLD_LOCAL);
        }
    }

    char sa_path[PATH_MAX];
    if (snprintf(sa_path, sizeof(sa_path), "%s/../Frameworks/libsteam_api.dylib", dir) < (int)sizeof(sa_path)) {
        sa_lib = dlopen(sa_path, RTLD_NOW | RTLD_LOCAL);
    }
    if (!sa_lib && snprintf(sa_path, sizeof(sa_path), "%s/libsteam_api.dylib", dir) < (int)sizeof(sa_path)) {
        sa_lib = dlopen(sa_path, RTLD_NOW | RTLD_LOCAL);
    }

    void *(*create_iface)(const char *, int *) = NULL;
    int32_t (*create_pipe)(void *) = NULL;
    int32_t (*connect_user)(void *, int32_t) = NULL;
    void (*release_user)(void *, int32_t, int32_t) = NULL;
    bool (*release_pipe)(void *, int32_t) = NULL;

    if (sc_lib) *(void **)(&create_iface) = dlsym(sc_lib, "CreateInterface");
    if (sa_lib) {
        *(void **)(&create_pipe) = dlsym(sa_lib, "SteamAPI_ISteamClient_CreateSteamPipe");
        *(void **)(&connect_user) = dlsym(sa_lib, "SteamAPI_ISteamClient_ConnectToGlobalUser");
        *(void **)(&release_user) = dlsym(sa_lib, "SteamAPI_ISteamClient_ReleaseUser");
        *(void **)(&release_pipe) = dlsym(sa_lib, "SteamAPI_ISteamClient_BReleaseSteamPipe");
    }

    void *client = NULL;
    if (create_iface) {
        client = create_iface("SteamClient020", NULL);
        if (!client) client = create_iface("SteamClient017", NULL);
    }

    int ready = 0;
    if (client && create_pipe && connect_user && release_user && release_pipe) {
        for (int i = 0; i < 60; i++) {
            if (!is_proc_running("steam_osx")) break;
            int32_t pipe = create_pipe(client);
            if (pipe != 0) {
                int32_t user = connect_user(client, pipe);
                if (user != 0) {
                    release_user(client, pipe, user);
                    release_pipe(client, pipe);
                    ready = 1;
                    break;
                }
                release_pipe(client, pipe);
            }
            usleep(500000);
        }
    } else if (just_started) {
        usleep(6000000);
    }

    if (sa_lib) dlclose(sa_lib);
    if (sc_lib) dlclose(sc_lib);

    if (just_started && ready) {
        usleep(500000);
    }
}

static void ensure_steam_running(const char *dir, const char *home) {
    int already = is_proc_running("steam_osx");
    if (!already) {
        if (!steam_is_installed(home)) return;

        char *const argv[] = {"open", "-ga", "Steam", "--args", "-silent", NULL};
        if (run_quiet("/usr/bin/open", argv) != 0) return;

        for (int i = 0; i < 40; i++) {
            if (is_proc_running("steam_osx")) break;
            usleep(500000);
        }
        if (!is_proc_running("steam_osx")) return;

        for (int i = 0; i < 40; i++) {
            if (is_proc_running("ipcserver")) break;
            usleep(250000);
        }
    }

    if (is_proc_running("steam_osx")) {
        wait_for_steam_user(dir, home, !already);
    }
}

static void maybe_inject_overlay(const char *home) {
    if (!home || is_flag_set("SKYRIM_STEAM_NO_OVERLAY") || is_flag_set("FNV_STEAM_NO_OVERLAY")) return;
    char overlay[PATH_MAX];
    if (snprintf(overlay, sizeof(overlay),
                 "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/gameoverlayrenderer.dylib",
                 home) >= (int)sizeof(overlay)) return;
    if (access(overlay, R_OK) != 0) return;

    const char *existing = getenv("DYLD_INSERT_LIBRARIES");
    if (existing && *existing) {
        if (strstr(existing, "gameoverlayrenderer.dylib")) return;
        size_t need = strlen(overlay) + 1 + strlen(existing) + 1;
        char *joined = malloc(need);
        if (!joined) return;
        snprintf(joined, need, "%s:%s", overlay, existing);
        setenv("DYLD_INSERT_LIBRARIES", joined, 1);
        free(joined);
    } else {
        setenv("DYLD_INSERT_LIBRARIES", overlay, 1);
    }
}

int main(int argc, char **argv) {
    char raw[PATH_MAX], real[PATH_MAX];
    uint32_t sz = sizeof(raw);
    if (_NSGetExecutablePath(raw, &sz) != 0 || !realpath(raw, real)) {
        perror("_NSGetExecutablePath");
        return 127;
    }
    char *slash = strrchr(real, '/');
    if (!slash) return 127;
    *slash = 0;

    char target[PATH_MAX];
    if (snprintf(target, sizeof(target), "%s/Skyrim", real) >= (int)sizeof(target)) {
        fprintf(stderr, "Skyrim path too long\n");
        return 127;
    }

    if (!is_flag_set("SKYRIM_STEAM_DISABLE") && !is_flag_set("FNV_STEAM_DISABLE") && !is_flag_set("FNV_HEADLESS")) {
        const char *home = getenv("HOME");
        ensure_steam_running(real, home);
        if (is_proc_running("steam_osx")) {
            char appid[32];
            read_appid(real, appid, sizeof(appid));
            setenv("SteamAppId", appid, 0);
            setenv("SteamGameId", appid, 0);
            setenv("SteamOverlayGameId", appid, 0);
            maybe_inject_overlay(home);
        }
    }

    char **new_argv = calloc((size_t)argc + 1, sizeof(char *));
    if (!new_argv) return 127;
    new_argv[0] = target;
    for (int i = 1; i < argc; i++) new_argv[i] = argv[i];
    execv(target, new_argv);
    perror("execv");
    free(new_argv);
    return 127;
}
