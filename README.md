# The Elder Scrolls V: Skyrim (32-bit LE) for macOS (Apple Silicon)

A native Apple Silicon (`arm64`) macOS port of **The Elder Scrolls V: Skyrim** (32-bit DirectX 9 "Oldrim", build `1.9.32.0.8`) using **x86-to-C/ARM64 static recompilation** and direct **Direct3D 9 → Apple Metal** translation, packaged as a standalone `Skyrim.app` bundle with no Wine, CrossOver, Rosetta 2, or virtual machines required.

> **Status:** Active porting effort adapted from the Fallout: New Vegas macOS static recompiler architecture.

## Quick Start

**What you need upfront:**
1. An **Apple Silicon Mac** (M1 or newer) running **macOS 14 (Sonoma)** or later.
2. **Apple Command Line Tools** (`xcode-select --install`) and **[Homebrew](https://brew.sh/)** — `quick-install.sh` automatically installs every other build tool it needs (`ghidra`, `unicorn`, `cmake`, `ffmpeg`, and `mono` for SteamStub DRM) and none of them are required to play once `Skyrim.app` is built (see [Notes on Cleanup](#notes-on-cleanup)).
3. **Your own Steam PC copy** of original 32-bit *Skyrim* (AppID `72850`, patch `1.9.32.0.8` — not Special/Anniversary Edition), downloaded via `steamcmd` (see [Obtaining the Windows Game Files on macOS](#obtaining-the-windows-game-files-on-macos)).

**Build & install:**

```sh
./quick-install.sh
```

The finished app is placed in `~/Applications/Skyrim.app`.

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

## Obtaining the Windows Game Files on macOS

Because original 32-bit *Skyrim* ("Oldrim", AppID `72850`) is a Windows-only release on Steam (unlisted from Steam search, though still purchasable via direct link at `https://store.steampowered.com/app/72850/`), you can fetch the game files directly on your Mac using any of the methods below. All output paths shown here are auto-detected by `quick-install.sh`.

> **Important:** Only the original 32-bit *Skyrim* (AppID `72850`, patch `1.9.32.0.8`) is supported — **not** *Skyrim Special Edition* or *Anniversary Edition*.

### Method A — `steamcmd` (recommended)

```sh
brew install --cask steamcmd
steamcmd +@sSteamCmdForcePlatformType windows +login <YOUR_STEAM_USERNAME> +app_update 72850 validate +quit
```

*This single command downloads the game along with all DLCs/expansions owned by your Steam account (Dawnguard, Hearthfire, Dragonborn, and the High Resolution Texture Pack, if owned) directly into `~/Library/Application Support/Steam/steamapps/common/Skyrim` (or `~/Steam/steamapps/common/Skyrim`), both of which `quick-install.sh` auto-detects. Pass `+force_install_dir "$HOME/Downloads/Skyrim"` before `+login` if you prefer a separate folder.*

### Method B — `DepotDownloader`

```sh
brew tap steamre/tools
brew install depotdownloader
depotdownloader -app 72850 -os windows -username <YOUR_STEAM_USERNAME> \
  -dir "$HOME/Downloads/Skyrim"
```

*If you omit `-dir`, DepotDownloader places files under `./depots/72850/<manifest>/` (`~/depots/72850/` and `~/Downloads/depots/72850/` are also auto-detected).*

### Method C — Steam Client Console

1. Open the hidden Console tab in the desktop Steam client:
   ```sh
   open "steam://open/console"
   ```
2. Download the base Windows depots (plus any DLC depots you own — check Depot IDs on SteamDB if needed):
   ```text
   download_depot 72850 72851
   download_depot 72850 72852
   download_depot 72850 72853
   ```
3. Steam saves each depot separately under:
   `~/Library/Application Support/Steam/steamapps/content/app_72850/depot_*/`
   Merge the contents of those `depot_*` folders into `~/Downloads/Skyrim/` so `TESV.exe` and `Data/` sit together in one folder.

---

## Quick Install

```sh
# Auto-detect game files (Steam, SteamCMD, DepotDownloader, Downloads, Games)
./quick-install.sh

# Or pass an explicit path
./quick-install.sh "/path/to/Skyrim"
```

Optional flags:

```sh
# Also wrap the app in a drag-to-Applications .dmg
./quick-install.sh --dmg

# Build standalone offline without Steam launcher, Overlay hook, or libsteam_api.dylib
./quick-install.sh --no-steam

# Keep ~/Library/Caches/skyrim-macos after a successful build (for faster incremental rebuilds)
./quick-install.sh --keep-cache
```

The finished app is installed at `~/Applications/Skyrim.app`.

* The bundle uses a dedicated identifier (`dev.skyrimmac.<target>`) and the installer registers it with LaunchServices (`lsregister -f`). macOS Game Mode caches its notice icon by bundle identifier; see [docs/GAME-MODE-ICONS.md](docs/GAME-MODE-ICONS.md) for the observed behavior and the checklist for future ports (e.g. Oblivion).

* User data (`Skyrim.ini`, `SkyrimPrefs.ini`, saves, and `LocalAppData/Skyrim/plugins.txt`) is stored in `~/Library/Application Support/Skyrim/UserDocuments`.
* Logs are written to `~/Library/Logs/Skyrim/skyrim.log`.

> **Note on disk usage & automatic cleanup:** to avoid duplicating roughly 9–12 GB of game data, `quick-install.sh` **moves** the playable game files into `~/Applications/Skyrim.app` (`Contents/Resources/GameData/`), **deletes leftover Windows-only files** from the source folder (Steam `steamapps/common/Skyrim` or DepotDownloader folders), removes Steam's `appmanifest_72850.acf` so Steam does not keep an uninstallable ghost entry in your Mac library (Steam achievements, Overlay, playtime, and "Playing" status do not depend on the `.acf` file), and **deletes the build/translation cache (`~/Library/Caches/skyrim-macos`) automatically** once the app is built and signed (pass `--keep-cache` or set `SKYRIM_KEEP_CACHE=1` to keep it for faster rebuilds). Existing `.app` bundles are never deleted when rebuilding from them.

---

## Notes on Cleanup

**None of the build tools are needed to play the game once `Skyrim.app` is built.** `libunicorn.a` is statically linked into the app binary, `.bik` cutscenes are already converted to `.mp4`, and Ghidra only runs during translation.

`quick-install.sh` cleans up leftover source files and `~/Library/Caches/skyrim-macos` automatically upon success (unless `--keep-cache` is passed), and intentionally does **not** uninstall global software from your Mac. At the end of a run, it prints the exact list of any Homebrew packages it installed together with a ready-to-copy `brew uninstall` command.

If you installed build tools only for this port and want to remove them later:

1. **Homebrew packages used for building/downloading** (or run the exact `brew uninstall ...` command printed at the end of `quick-install.sh`; edit this list to omit anything you want to keep):
   ```sh
   for p in ghidra unicorn cmake ffmpeg mono depotdownloader steamcmd; do brew list "$p" &>/dev/null && brew uninstall "$p"; done && brew cleanup
   ```
   Optional: if you added the DepotDownloader tap:
   ```sh
   brew untap steamre/tools 2>/dev/null
   ```

2. **Build & translation cache** (already removed automatically unless you passed `--keep-cache` or an earlier run stopped mid-way):
   ```sh
   rm -rf ~/Library/Caches/skyrim-macos
   ```

3. **Homebrew & Apple Command Line Tools (optional — only if you installed them solely for this port):**
   * Uninstall Homebrew using the [official Homebrew uninstall script](https://github.com/homebrew/install#uninstall-homebrew).
   * Uninstall Apple Command Line Tools:
     ```sh
     sudo rm -rf /Library/Developer/CommandLineTools
     ```

**Keep these files to continue playing:**
* `~/Applications/Skyrim.app` (the game itself).
* `~/Library/Application Support/Skyrim/` (saves and `.ini` settings).

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
