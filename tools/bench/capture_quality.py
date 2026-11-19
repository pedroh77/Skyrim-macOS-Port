#!/usr/bin/env python3
"""Capture aligned static frames for upscaler quality comparisons.

Uses tools/bench/menu_quality.script: syncs to the main menu and the
"Start a new game?" confirmation (a static camera + UI), dumps one frame and
quits.  The resulting images can be compared with compare_frames.py.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_APP = Path('/tmp/skyrim-bench-build/Skyrim.app/Contents/MacOS/Skyrim')
DEFAULT_ROOT = Path(os.path.expanduser(
    '~/Library/Application Support/Steam/steamapps/common/Skyrim'))
DEFAULT_USER = Path('/tmp/skyrim_bench_user')
DEFAULT_SCRIPT = HERE / 'menu_quality.script'
DUMP_RE = re.compile(r'\[metal\] dumped (.+?\.png)')


def parse_config(spec: str) -> dict:
    name, scale, upscaler, aa = spec.split(':')
    if upscaler not in ('bilinear', 'metalfx'):
        raise argparse.ArgumentTypeError(upscaler)
    return {'name': name, 'scale': int(scale), 'upscaler': upscaler, 'aa': int(aa)}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app', type=Path, default=DEFAULT_APP)
    p.add_argument('--root', type=Path, default=DEFAULT_ROOT)
    p.add_argument('--user', type=Path, default=DEFAULT_USER)
    p.add_argument('--script', type=Path, default=DEFAULT_SCRIPT)
    p.add_argument('--out', type=Path, default=Path('/tmp/skyrim-bench-quality'))
    p.add_argument('--config', action='append', dest='configs', type=parse_config)
    p.add_argument('--cooldown', type=float, default=15.0)
    args = p.parse_args()

    args.app = args.app.resolve()
    args.root = args.root.resolve()
    args.user = args.user.resolve()
    args.script = args.script.resolve()
    args.out = args.out.resolve()
    configs = args.configs or [parse_config(s) for s in (
        'native:100:bilinear:0', 'bilinear75:75:bilinear:0',
        'metalfx75:75:metalfx:0', 'metalfx50:50:metalfx:0')]
    args.out.mkdir(parents=True, exist_ok=True)
    results = []
    for i, cfg in enumerate(configs):
        if i:
            time.sleep(args.cooldown)
        run_dir = args.out / cfg['name']
        run_dir.mkdir(parents=True, exist_ok=True)
        log_path = run_dir / 'run.log'
        env = dict(os.environ)
        env.update({
            'FNV_HEADLESS': '1', 'FNV_STDERR': '1',
            'SKYRIM_SKIP_LAUNCHER': '1',
            'SKYRIM_ROOT': str(args.root), 'SKYRIM_USER_DIR': str(args.user),
            'SKYRIM_RENDER_SCALE': str(cfg['scale']),
            'SKYRIM_UPSCALER': cfg['upscaler'],
            'SKYRIM_AA': str(cfg['aa']), 'SKYRIM_MOUSE_ACCEL': '0',
            'FNV_INPUT_SCRIPT': str(args.script),
            'FNV_DUMP_DIR': str(run_dir), 'FNV_QUIT_AFTER': '90',
        })
        print(f"[quality] {cfg['name']}", flush=True)
        with log_path.open('w') as log:
            rc = subprocess.run([str(args.app)], env=env, stdout=log,
                                stderr=subprocess.STDOUT, timeout=180).returncode
        dumps = [m.group(1) for m in
                 (DUMP_RE.search(line) for line in log_path.read_text(errors='replace').splitlines())
                 if m]
        print(f"[quality] {cfg['name']}: rc={rc} dumps={dumps}", flush=True)
        results.append({**cfg, 'rc': rc, 'dumps': dumps})

    (args.out / 'results.json').write_text(json.dumps(results, indent=2))
    missing = [r for r in results if not r['dumps']]
    return 1 if missing else 0


if __name__ == '__main__':
    raise SystemExit(main())
