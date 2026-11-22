#!/usr/bin/env python3
"""Build a native macOS arm64 .app bundle with Xcode / Command Line Tools."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from state_probes import normalize, instrument
from native_codecs import validate as validate_codecs
from app_icon import compile_icon

ROOT = Path(__file__).resolve().parents[1]
R = ROOT / 'upstream/recomp'
H = R / 'host'
M = ROOT / 'macos'


def run(cmd):
    subprocess.run(cmd, check=True)


def patch_generated_tu(content):
    """Apply narrow correctness guards for vanilla TESV.exe bugs in translated C units."""
    # 1. Vanilla TESIdleForm::~TESIdleForm (0x55df80) iterates children[0..size-1] via
    #    NiTArray::GetAt (0x4885e0) and unconditionally dereferences the returned pointer at
    #    0x55e05f without checking for NULL. Slots removed via g_55d920 leave NULL holes when not
    #    at the array tail (e.g. Update/DLC plugin loads), causing Quit to Desktop to trap at 0.
    # 2. Vanilla BSAudioManager shutdown (0xb9bbe0) sends a quit message and waits forever on the
    #    LibAudioUpdate thread's exit semaphore [eax+0x34] without checking if the thread was ever
    #    started ([eax+0x24] != 0, skipped at 0xb9f16b when bit 5 / bEnableAudio=0 is set), unlike
    #    0xb9a7a0 which explicitly checks [eax+0x24]. Skip waiting on an unstarted thread.
    guards = [
        (
            b'L_55e05f: /* MOV dword ptr [EAX + 0x24],0x0 */\n',
            b'  if(!eax){RT_BRANCH(0x55e05fu);goto L_55e070;}\n',
        ),
        (
            b'L_b9bbec: /* JZ 0x00b9bc44 */\n',
            b'  if(eax&&!LDM(eax+0x24u,4)){RT_BRANCH(0xb9bbecu);goto L_b9bc44;}\n',
        ),
    ]
    patched = False
    for label, guard in guards:
        if label in content:
            content = content.replace(label, label + guard, 1)
            patched = True
    return content, patched


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def find_unicorn(explicit):
    if explicit:
        return explicit
    for candidate in ['/opt/homebrew/opt/unicorn', '/opt/homebrew', '/usr/local/opt/unicorn', '/usr/local']:
        p = Path(candidate)
        if (p / 'include/unicorn/unicorn.h').is_file() and (p / 'lib/libunicorn.a').is_file():
            return p
    return None


def find_ffmpeg():
    """Find FFmpeg headers and dylibs (libavcodec/libswresample/libavutil) for xWMA decoding."""
    for candidate in ['/opt/local', '/opt/homebrew/opt/ffmpeg', '/opt/homebrew', '/usr/local']:
        p = Path(candidate)
        if (p / 'include/libavcodec/avcodec.h').is_file() and (p / 'lib/libavcodec.dylib').is_file():
            return p
    return None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('target', choices=['probe', 'game', 'host-check'])
    p.add_argument('--generated', type=Path, help='full-game emit.py output')
    p.add_argument('--exe', type=Path, help='exact executable used to generate these units')
    p.add_argument('--out', type=Path, default=Path('build'))
    p.add_argument('--app-name', default=None, help='bundle display name without .app')
    p.add_argument('--jobs', type=int, default=min(os.cpu_count() or 2, 8))
    p.add_argument('--cache', type=Path, help='object cache keyed by compiler, SDK, flags, headers and content')
    p.add_argument('--state-probes', default='[]', help='bounded numeric entry/receiver-field diagnostic specification')
    p.add_argument('--codec-prefix', type=Path, help='verified pinned macOS Ogg/Vorbis static libraries')
    p.add_argument('--unicorn-prefix', type=Path, help='optional Unicorn engine prefix for fallback interpreter')
    p.add_argument('--no-unicorn', action='store_true', help='disable Unicorn fallback interpreter')
    p.add_argument('--steam-api-dylib', type=Path, help='optional Valve ARM64 libsteam_api.dylib to bundle in Frameworks/')
    p.add_argument('--steam-appid', default='72850', help='Steam AppID written to steam_appid.txt when bundling libsteam_api.dylib')
    p.add_argument('--no-call-trace', action='store_true', help='omit per-function diagnostic ring writes')
    p.add_argument('--version', default=os.environ.get('GITHUB_RUN_NUMBER', '1'), help='positive numeric app build version')
    args = p.parse_args()

    if not args.version.isdecimal() or not 0 < int(args.version) <= 2147483647:
        p.error('--version must be a positive 32-bit integer')
    probes = normalize(args.state_probes)
    matched_probes = set()
    probe = args.target == 'probe'
    host_check = args.target == 'host-check'
    codec = validate_codecs(args.codec_prefix, 'macos') if args.codec_prefix else None
    if args.target == 'game' and not codec:
        p.error('game requires --codec-prefix for native sound decoding')
    if args.target == 'game' and not (args.exe and args.exe.is_file() and args.generated and
                                      (args.generated / 'table.c').is_file() and
                                      (args.generated / 'stubs.c').is_file() and
                                      any(args.generated.glob('tu_*.c'))):
        p.error('game requires --exe and --generated with full translated C sources')
    if not shutil.which('xcrun'):
        p.exit(1, 'Apple build required: install Xcode Command Line Tools (xcode-select --install).\n')

    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    cc = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--find', 'clang'], text=True).strip()

    unicorn = None if (probe or args.no_unicorn) else find_unicorn(args.unicorn_prefix)
    if unicorn:
        print(f'Unicorn fallback enabled: {unicorn}', flush=True)
    ffmpeg = None if probe else find_ffmpeg()
    if ffmpeg:
        print(f'FFmpeg xWMA decoding enabled: {ffmpeg}', flush=True)

    signature = hashlib.sha256(subprocess.check_output([cc, '--version']) + sdk.encode())
    for header in sorted({hdr for directory in [R, M] for hdr in directory.rglob('*.h')}):
        signature.update(str(header.relative_to(ROOT)).encode() + header.read_bytes())
    config = signature.digest()

    old_manifest = {}
    if args.cache:
        args.cache.mkdir(parents=True, exist_ok=True)
        if (args.cache / 'manifest.json').exists():
            old_manifest = json.loads((args.cache / 'manifest.json').read_text())

    app_name = args.app_name or ('SkyrimProbe' if probe else 'Skyrim')
    exe_name = 'SkyrimProbe' if probe else 'Skyrim'

    sources = [M / 'FNVApp.m', M / 'FNVPad.c', M / 'FNVDisplay.c', H / 'd3d9_metal.m']
    if probe:
        sources += [M / 'FNVProbe.c', M / 'ProbeRuntime.c']
        sources += [H / (s + '.c') for s in ['d3d9', 'dinput', 'com', 'gheap', 'input', 'sm2msl']]
    else:
        sources += [M / 'FNVAudioMixer.c', M / 'FNVNativeMedia.m', M / 'FNVNativeVideo.m']
        sources += [f for f in H.glob('*.c') if f.name not in ('d3d9_null.c', 'fallback.c')]
        if unicorn:
            sources.append(H / 'fallback.c')
        sources += [H / 'dshow.m', R / 'rt_dispatch.c']
        if not host_check:
            sources += [args.generated / 'table.c', args.generated / 'stubs.c']
            sources += sorted(args.generated.glob('tu_*.c'))

    args.out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.out) as temp:
        tmp = Path(temp)
        bundle = tmp / (app_name + '.app')
        contents = bundle / 'Contents'
        macos_dir = contents / 'MacOS'
        resources_dir = contents / 'Resources'
        macos_dir.mkdir(parents=True)
        resources_dir.mkdir(parents=True)

        base = [cc, '-target', 'arm64-apple-macos14.0', '-isysroot', sdk]

        def compile_one(item):
            idx, source = item
            out = tmp / f'{idx}.o'
            content = source.read_bytes()
            matched = set()
            patched = False
            if args.generated and source.parent.resolve() == args.generated.resolve():
                content, patched = patch_generated_tu(content)
                if probes:
                    content, matched = instrument(content, probes)
                    matched_probes.update(matched)
            compiled_source = source
            if patched or matched:
                compiled_source = tmp / ('patched-' + source.name)
                compiled_source.write_bytes(content)
            flags = ['-O1', '-I', str(H), '-I', str(R), '-I', str(M)]
            if codec:
                flags += ['-DFNV_HAVE_VORBIS', '-I', str(codec / 'include')]
            if unicorn and source.name == 'fallback.c':
                flags += ['-I', str(unicorn / 'include')]
            if ffmpeg and source.name == 'xaudio2.c':
                flags += ['-DSKYRIM_HAVE_FFMPEG', '-I', str(ffmpeg / 'include')]
            if source.suffix == '.m':
                flags.append('-fobjc-arc')
            if probe:
                flags.append('-DFNV_PROBE')
            elif not host_check and not args.no_call_trace:
                flags.append('-DRT_CALLTRACE')
            key = hashlib.sha256(config + json.dumps(base + flags).encode() + source.name.encode() + content).hexdigest()
            stored = args.cache / (key + '.o') if args.cache else None
            if stored and stored.exists() and digest(stored) == old_manifest.get(stored.name):
                return str(stored), True
            run(base + flags + ['-c', str(compiled_source), '-o', str(out)])
            if stored:
                os.replace(out, stored)
                out = stored
            return str(out), False

        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            compiled = list(pool.map(compile_one, enumerate(sources)))
        objects = [path for path, _ in compiled]
        if probes and set(probes) != matched_probes:
            raise ValueError('Requested diagnostic entries absent from generated source')
        print(f'macOS objects: {sum(reused for _, reused in compiled)} reused, {sum(not reused for _, reused in compiled)} compiled', flush=True)
        if args.cache:
            (args.cache / 'manifest.json').write_text(json.dumps({Path(path).name: digest(Path(path)) for path in objects}, indent=2))
        if host_check:
            print(f'PASS: compiled {len(objects)} public game-host sources for arm64 macOS; no game inputs')
            return

        frameworks = [
            'Foundation', 'AppKit', 'Metal', 'MetalFX', 'QuartzCore', 'CoreGraphics',
            'AVFoundation', 'CoreVideo', 'CoreMedia', 'ImageIO',
            'UniformTypeIdentifiers', 'GameController',
        ]
        libraries = [str(codec / 'lib' / ('lib' + n + '.a')) for n in ['vorbisfile', 'vorbis', 'ogg']] if codec else []
        if unicorn:
            libraries.append(str(unicorn / 'lib/libunicorn.a'))

        link_flags = ['-Wl,-stack_size,0x4000000']
        if ffmpeg:
            libraries += ['-L' + str(ffmpeg / 'lib'), '-lavcodec', '-lswresample', '-lavutil']
            link_flags.append('-Wl,-rpath,' + str(ffmpeg / 'lib'))
        run(base + objects + libraries + [v for f in frameworks for v in ('-framework', f)] + link_flags + ['-o', str(macos_dir / exe_name)])

        bundle_exe = exe_name
        if codec:
            shutil.copytree(codec / 'licenses', resources_dir / 'Licenses')
        if not probe and args.steam_api_dylib and args.steam_api_dylib.is_file():
            frameworks_dir = contents / 'Frameworks'
            frameworks_dir.mkdir(exist_ok=True)
            shutil.copy2(args.steam_api_dylib, frameworks_dir / 'libsteam_api.dylib')
            (macos_dir / 'steam_appid.txt').write_text(str(args.steam_appid).strip() + '\n')
            launcher_name = 'SkyrimLauncher'
            run(base + ['-O2', '-Wall', '-Wextra', str(M / 'FNVSteamLauncher.c'), '-o', str(macos_dir / launcher_name)])
            bundle_exe = launcher_name

        info = dict(
            CFBundleDevelopmentRegion='en',
            CFBundleExecutable=bundle_exe,
            CFBundleName=app_name,
            CFBundleDisplayName=app_name,
            # unique per-port identity; see docs/GAME-MODE-ICONS.md for the Game Mode
            # icon-cache behavior and the checklist for future ports (e.g. Oblivion)
            CFBundleIdentifier='dev.skyrimmac.' + args.target,
            CFBundlePackageType='APPL',
            CFBundleVersion=args.version,
            CFBundleShortVersionString='0.1',
            CFBundleInfoDictionaryVersion='6.0',
            LSMinimumSystemVersion='14.0',
            LSApplicationCategoryType='public.app-category.games',
            NSHighResolutionCapable=True,
            GCSupportedGameControllers=[{'ProfileName': 'ExtendedGamepad'}],
        )
        if not probe:
            info['FNVExecutableSHA256'] = digest(args.exe)
        info['FNVGuestCallTraceEnabled'] = bool(not probe and not args.no_call_trace)
        info['FNVOptimizationLevel'] = 'O1'
        info.update(compile_icon(tmp, resources_dir))
        try:
            info['FNVBuildSourceCommit'] = subprocess.check_output(
                ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True, stderr=subprocess.DEVNULL
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            pass

        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        (contents / 'PkgInfo').write_text('APPL????')

        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(bundle)], check=True)

        final_app = args.out / (app_name + '.app')
        if final_app.exists():
            shutil.rmtree(final_app)
        shutil.move(str(bundle), str(final_app))
        print(final_app.resolve())


if __name__ == '__main__':
    main()
