# Game Mode icon behavior on macOS

This note records why the macOS **Game Mode** notice can keep showing a stale
app icon after the bundle icon changes, and the bundle-identity rules that
avoid it. It was originally written for the Fallout 3 / New Vegas port and is
kept here because Skyrim and future ports (next: Oblivion) share the same
packaging layer.

- **Observed on:** macOS 27.2.1 (build 26B131), Apple Silicon, 2026-11-22.
- **Confirmed in:** Fallout 3 (`dev.f3mac.fallout3`); the port author verified
  the Game Mode icon after the fix. Skyrim already uses a unique identifier
  (`dev.skyrimmac.<target>`) and registers the installed bundle with
  `lsregister -f`.
- **Credit:** the per-`CFBundleIdentifier` cache behavior was surfaced by
  **FineWine**; this note records the reproduction and the reusable fix.

## TL;DR

- Game Mode keeps its **own icon cache**, keyed by the app's bundle identity
  (`CFBundleIdentifier`), not by the `.icns` file path or its modification
  time.
- Two games sharing one identifier (the old shared `dev.f3mac.game`) can make
  Game Mode show the other game's icon, even after replacing `AppIcon.icns`,
  touching the `.app`, and re-registering it with LaunchServices.
- Give every game/target a **unique bundle identifier from the first build**.
  When replacing an icon on an existing id, bump `CFBundleVersion`, rebuild
  and reinstall. Changing the id is the guaranteed cache refresh; the version
  bump is an additional cache-buster.
- Finder, Dock, and Get Info can show the new icon while Game Mode still shows
  the old one. Verify in Game Mode itself, not only in Finder.

## What Game Mode displays

Game Mode is entered for apps whose bundle is a game
(`LSApplicationCategoryType = public.app-category.games`). When the game
starts, macOS shows the Game Mode notice/HUD using the app's icon. That icon is
resolved from the bundle identity that macOS registered, not from the bytes of
the current `AppIcon.icns` each time.

This is distinct from the Finder/Dock icon path:

| Surface | What it keys on | Typically updates with |
| --- | --- | --- |
| Finder / Dock / Get Info | Bundle path + icon file, refreshed through LaunchServices | Replacing the icon, `lsregister -f`, restarting Finder/Dock |
| Game Mode notice/HUD | Per-app bundle identity cache (observed key: bundle identifier) | Changing the bundle identifier, or a new identity/version that invalidates the old cache |

The practical consequence: replacing `AppIcon.icns` can make Finder show the
new artwork while Game Mode keeps the previous game's icon. That mismatch is
the confusing part.

## Reproduction in the Fallout 3 port (cross-port reference)

The original Fallout 3 build used the shared identity `dev.f3mac.game`. That
same identity had been registered by an earlier FNV build, so when Fallout 3
received its own icon Game Mode still resolved the notice to the stale New
Vegas ranger artwork.

The following did **not** fix it on its own:

- replacing `Contents/Resources/AppIcon.icns`;
- `touch`-ing the `.app`;
- rebuilding/reinstalling while keeping the same bundle identifier;
- refreshing LaunchServices with `lsregister -f`.

What did fix it:

1. a dedicated bundle identifier for Fallout 3: `dev.f3mac.fallout3`;
2. `CFBundleVersion = 2` on the installed app (one-time cache-buster for the
   old identity);
3. a LaunchServices refresh after reinstalling.

The user then confirmed the Game Mode icon was correct. Later rebuilds went
back to `CFBundleVersion = 1` and the icon stayed correct, because the
identifier is now unique. That is the important nuance: **the unique id is the
durable fix; the version bump was only needed to invalidate the old shared-id
cache once.**

Current Fallout 3 bundle for reference:

```text
CFBundleIdentifier   dev.f3mac.fallout3
CFBundleVersion      1
CFBundleIconFile     AppIcon
LSApplicationCategoryType  public.app-category.games
```

Skyrim's current packaging for comparison:

```text
CFBundleIdentifier   dev.skyrimmac.<target>
CFBundleVersion      tools/build.py --version (default 1)
CFBundleIconFile     AppIcon
LSApplicationCategoryType  public.app-category.games
```

Skyrim is already on the safe path: unique identifier from the first build and
`lsregister -f` after installation. The checklist below is what a future
Oblivion port should copy before its first build.

## Correct bundle configuration

Every port/target must have its own identity:

| Game | Identifier | Icon asset |
| --- | --- | --- |
| Fallout 3 | `dev.f3mac.fallout3` | `macos/Assets/AppIcon-Fallout3.png` |
| Fallout: New Vegas | `dev.fnvmac.<target>` | `macos/Assets/AppIcon.png` |
| Skyrim (this repo) | `dev.skyrimmac.<target>` | `macos/Assets/AppIcon.png` |
| Oblivion (future) | `dev.oblivionmac.<target>` (or `dev.f3mac.oblivion`) | `AppIcon-Oblivion.png` |

Also set:

- `CFBundleName` / `CFBundleDisplayName` / `CFBundleExecutable` uniquely per
  game (avoid two bundles that present themselves with the same name);
- `LSApplicationCategoryType = public.app-category.games`, otherwise Game Mode
  may not engage at all;
- `CFBundleIconFile = AppIcon`, with a real `AppIcon.icns` generated by
  `tools/app_icon.py` (sips + iconutil, source PNG >= 1024x1024, sRGB);
- an integer `CFBundleVersion`; `tools/build.py --version N` sets it (default
  `1`, or `GITHUB_RUN_NUMBER` in CI). Bump it when the icon or bundle identity
  changes.

Never reuse `dev.f3mac.game` (or any other generic id) across different games.
If two ports have already shared an id, give one of them a new id; that is the
reliable way to clear the Game Mode cache.

## Remediation checklist

1. **Change the bundle identifier** if the app ever shared an id with another
   game, or if the Game Mode icon is stale and the id has history. This alone
   is the guaranteed refresh.
2. If keeping the id, **bump `CFBundleVersion`** and rebuild.
3. **Rebuild/reinstall the bundle from scratch** (`rm -rf` the destination
   `.app` first, then install); do not just edit the icon inside the existing
   bundle.
4. **Re-register LaunchServices** for the new bundle:

   ```sh
   LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
   "$LSREG" -u "/Applications/MyGame.app"   # optional: drop the old record
   "$LSREG" -f "/Applications/MyGame.app"   # register the new bundle
   ```

5. Launch the game from the installed path and check the Game Mode notice.
6. Only if it is still stale: log out/in or reboot (Game Mode and icon-cache
   daemons can hold the old record), or reset LaunchServices (below).

### Last-resort LaunchServices reset

Use this only when the targeted `-u`/`-f` did not help. It resets registrations
for all apps and may require a logout/reboot:

```sh
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREG" -kill -r -domain local -domain system -domain user
killall Finder
```

`lsregister -delete` also exists, but it deletes the database and explicitly
requires a reboot; prefer the targeted commands first.

## Verification

```sh
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
APP="/Applications/MyGame.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$APP/Contents/Info.plist"

"$LSREG" -dump 2>/dev/null | grep -i -A2 'dev\.oblivionmac\.'
```

Then launch the game, enter Game Mode, and inspect the notice/HUD icon. Do not
treat Finder's icon or Get Info as proof that Game Mode is fixed.

## Oblivion port checklist

- [ ] Choose a unique id before the first build, e.g.
  `dev.oblivionmac.<target>` or `dev.f3mac.oblivion`. Never `dev.f3mac.game`.
- [ ] Put `AppIcon-Oblivion.png` (>= 1024x1024, square, sRGB) in
  `macos/Assets/`; let `tools/app_icon.py` produce `AppIcon.icns`.
- [ ] Set `CFBundleIconFile = AppIcon` and
  `LSApplicationCategoryType = public.app-category.games`.
- [ ] Set unique `CFBundleName`, `CFBundleDisplayName`, and
  `CFBundleExecutable` for Oblivion.
- [ ] Start `CFBundleVersion` at 1; bump it for every icon/bundle-identity
  change.
- [ ] Rebuild and install to a stable path (e.g. `~/Applications/Oblivion.app`);
  remove the previous bundle, then register with `lsregister -f`.
- [ ] If the Game Mode icon is ever stale, change the id first; bump the
  version/re-register second; log out/in only as a last resort.

## References

- Commit `7b73e31` — “Give the Fallout 3 bundle a dedicated identifier”
  (the fix and the original observation).
- `tools/build.py` — bundle id selection and `CFBundleVersion` handling.
- `tools/app_icon.py` — `.icns` generation (`sips` + `iconutil`).
- `quick-install.sh` — installs the bundle and refreshes LaunchServices with
  `lsregister -f`.
- `README.md` — quick-install and packaging notes.
- Fallout 3/New Vegas commit `7b73e31` — the original fix and observation
  (in `pedroh77/Fallout3-NewVegas-macOS-Port`).
- FineWine — source of the per-bundle-identifier Game Mode icon cache insight.
