# The Elder Scrolls V: Skyrim (32-bit LE) for macOS (Apple Silicon)

A native Apple Silicon (`arm64`) macOS port of **The Elder Scrolls V: Skyrim** (32-bit DirectX 9 "Oldrim", build `1.9.32.0.8`) using **x86-to-C/ARM64 static recompilation** and direct **Direct3D 9 → Apple Metal** translation, packaged as a standalone `Skyrim.app` bundle with no Wine, CrossOver, Rosetta 2, or virtual machines required.

> **Status:** Active porting effort adapted from the Fallout: New Vegas macOS static recompiler architecture.

---

## Requirements & Supported Executable

* **Apple Silicon Mac (`arm64`)** running **macOS 14 (Sonoma)** or later.
* **Xcode Command Line Tools** (`xcode-select --install`) and **Homebrew**.
* **Your own PC copy of *The Elder Scrolls V: Skyrim* (32-bit LE, patch 1.9.32.0.8):**
  * Steam ships `TESV.exe` with SteamStub v2.1 DRM (`.bind` section). Because the static recompiler translates unencrypted x86 machine code ahead of time, `quick-install.sh` checks `TESV.exe` and, when SteamStub DRM is detected, automatically installs `mono` (via Homebrew if missing), downloads and SHA-256-verifies the official [Steamless](https://github.com/atom0s/Steamless) CLI release (`v3.1.0.5`), backs up the original file to `TESV.exe.og`, and strips the DRM with no interactive prompt (no DRM-free retail Oldrim release exists).
  * **Original Steam `TESV.exe` (SteamStub v2.1 DRM):**
    * SHA-256: `69362f77bc56bf17570a33106d020b6c67fd8f32a294b82f8b687b9cf71efc72`
  * **Supported unpacked `TESV.exe` hashes (both reuse `symbols/skyrim/` without re-running Ghidra auto-analysis):**
    * **Steamless CLI (`v3.1.0.5` + Mono):** `d97eb0cc0ceef0923d2234d42b382c0d033853356528b271bc043542b1f5e605`
    * **Steamless GUI:** `124306c7ea4aa8c655e8d9b7b093ea30afa579e40ac0c56dee579a978f87899f`

> **Dev note — why Steamless CLI and Steamless GUI produce different unpacked SHA-256s (and why symbols do not need regenerating):**
> Byte-for-byte comparison between the Steamless CLI unpacked executable (`d97eb0cc...`) and the Steamless GUI unpacked executable (`124306c7...`) shows **only 4 bytes differ** across the entire 17,462,064-byte file (`0x27d`, `0x2a4`, `0x2a5`, `0x2cd`), corresponding to trailing characters in the 8-byte PE section-header name strings (`.data`/`.tls`/`.rsrc` null-padded by CLI vs `.dataa`/`.tlsaa`/`.rsrca` left by the GUI unpacker). All 6 PE section payloads (`.text`, `.rdata`, `.data`, `.tls`, `.rsrc`, `.reloc`), section virtual addresses/sizes, and the entry point (`0xb568a1`) are bit-for-bit identical, and `ApplyMetadataAndDump.java` produces a byte-for-byte identical 78,497-function P-code dump (`d5998638c887e0576791d0fd8cc6b70d913248d01238e124c3b77661073b676b`). `quick-install.sh` therefore accepts both hashes directly for `symbols/skyrim/`.

---

## Quick Install

```sh
./quick-install.sh "/path/to/Skyrim"
```

To also wrap the app in a drag-to-Applications `.dmg`:

```sh
./quick-install.sh --dmg "/path/to/Skyrim"
```

The finished app is installed at `~/Applications/Skyrim.app`.

To build a standalone app without the Steam launcher, Overlay hook or
`libsteam_api.dylib` (offline mode):

```sh
./quick-install.sh --no-steam "/path/to/Skyrim"
```

* User data (`Skyrim.ini`, `SkyrimPrefs.ini`, saves, and `LocalAppData/Skyrim/plugins.txt`) is stored in `~/Library/Application Support/Skyrim/UserDocuments`.
* Logs are written to `~/Library/Logs/Skyrim/skyrim.log`.
* Translation and object caches are stored in `~/Library/Caches/skyrim-macos/`.

---

## Steam integration, Overlay & achievements

Skyrim is a Steam-only PC release, so the default build bundles the Steam
bridge:

* `quick-install.sh` downloads Valve's official **ARM64/universal
  `libsteam_api.dylib`** from Steamworks.NET 20.1.0 (SHA-256 verified), caches
  it under `~/Library/Caches/skyrim-macos/steamworks/20.1.0/`, and passes it to
  `tools/build.py --steam-api-dylib ... --steam-appid 72850`.
* The built bundle contains `Contents/Frameworks/libsteam_api.dylib`,
  `Contents/MacOS/steam_appid.txt` (`72850`) and a `SkyrimLauncher` executable.
  `SkyrimLauncher` is the bundle's `CFBundleExecutable`.
* On launch, `SkyrimLauncher` starts the Mac Steam client silently (`-silent`)
  if needed, waits for the Steam global user IPC/login, sets `SteamAppId`,
  `SteamGameId` and `SteamOverlayGameId`, injects Valve's
  `gameoverlayrenderer.dylib` for the Metal Steam Overlay (`Shift+Tab` and
  achievement notifications), then `execv`s the `Skyrim` shim binary.
* `upstream/recomp/host/shims_steam.c` bridges the `steam_api.dll` imports used
  by `TESV.exe` (`SteamAPI_Init`, `SteamAPI_RunCallbacks`,
  `SteamAPI_RegisterCallback`, `SteamAPI_UnregisterCallback`,
  `SteamUserStats`), including achievement get/set/clear and store-stats
  proxies, with a clean offline fallback when the dylib or Steam client is
  unavailable.
* Runtime overrides: `SKYRIM_STEAM_DISABLE=1` disables the Steam bridge;
  `SKYRIM_STEAM_NO_OVERLAY=1` starts Steam without injecting the Overlay.
  Build-time: `--no-steam` omits all of the above.

> The Steam client must be installed and logged in. The app is ad-hoc signed;
> launching it does not require Steam to own the Windows `TESV.exe` — the
> translation uses your own unpacked copy, while Steam provides the Overlay,
> status and achievements.

---

## Anti-aliasing, render scale & display

The launcher (`SkyrimSkipLauncher`/Options window) exposes:

* **Upscaler:** `MetalFX Spatial` or `Bilinear`.
* **Anti-Aliasing:** `Off`, `SMAA (Post-Process)` or `FXAA (Fast,
  Post-Process)` (FXAA is applied at the internal render resolution before the
  MetalFX/bilinear upscale).
* **Render Scale:** 50–100 % (internal resolution; the output is the physical
  panel).
* **Shadow Quality / Fullscreen / Mouse acceleration** options.

Environment overrides for automation and troubleshooting:

* `SKYRIM_RENDER_SCALE=50..100`
* `SKYRIM_UPSCALER=metalfx|bilinear`
* `SKYRIM_AA=off|smaa|fxaa`
* `SKYRIM_SHADOWS=keep|low|medium|high`
* `SKYRIM_MOUSE_ACCEL=0|1`
* `SKYRIM_OUTPUT_WIDTH`/`SKYRIM_OUTPUT_HEIGHT` — force the output resolution
  instead of the detected physical panel.
* `SKYRIM_SKIP_LAUNCHER=1` — bypass the Options window.

The app detects the **physical panel pixel size** (for example 2560×1600 on a
MacBook Air M1) even when macOS is using a scaled HiDPI desktop mode, and
renders/upscales to that output instead of the scaled backing resolution. This
avoids paying for 2880×1800 when the panel is 2560×1600. If detection is not
desired, set the output overrides above.

---

## Manual Build & Tests

```sh
# Compile host-only check (no game files required)
python3 tools/build.py host-check

# Build standalone Metal/input probe app
python3 tools/build.py probe --out build/probe-test

# Run native host/media test suite
bash tests/run.sh
```

---

## Credits

* **[Fallout-NV-MacOS](https://github.com/thetheoryofR/Fallout-NV-MacOS)** (by **thetheoryofR**) — Original x86→C/ARM64 static recompiler, D3D9→Metal renderer, Win32/COM host, and Unicorn fallback (MIT license in `upstream/LICENSE`).
* **[FNV-iOS-Shim](https://github.com/arjuk95-dot/FNV-iOS-Shim)** (by **arjuk95-dot**) — Native audio mixer (`AVAudioEngine`), Ogg/Vorbis bridge, `AVFoundation` video, DirectShow pull-source, and heap/texture/sync fixes.
* **[macIV](https://github.com/tanmayisdumb/macIV)** — App bundle packaging and `quick-install.sh` UX inspiration.
