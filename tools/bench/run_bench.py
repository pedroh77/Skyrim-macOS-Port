#!/usr/bin/env python3
"""Run the Skyrim intro-cart benchmark across render-scale / upscaler configs.

The game is driven headlessly by FNV_INPUT_SCRIPT (tools/bench/cart_intro.script)
so no window focus or physical input is involved.  Each run writes a log; the
[metal] frame / [perf] lines are parsed and reduced to one row per 2 s window,
one row per run and one summary row per configuration.

The measured window is the cart ride, i.e. real guest + Metal work rather than a
menu or a movie.  Frames that compile shaders are excluded.  The mouse
acceleration setting is pinned so it cannot confound the render comparison.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import random
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_APP = Path('/tmp/skyrim-bench-build/Skyrim.app/Contents/MacOS/Skyrim')
DEFAULT_ROOT = Path(os.path.expanduser(
    '~/Library/Application Support/Steam/steamapps/common/Skyrim'))
DEFAULT_USER = Path('/tmp/skyrim_bench_user')
DEFAULT_SCRIPT = HERE / 'cart_intro.script'

# Script frames after the second waitsteady (the confirmation dialog sync).
SYNC_SCRIPT_FRAME = 20
MEASURE_START = 2400
MEASURE_END = 4200

DEFAULT_CONFIGS = [
    'native:100:bilinear:0',
    'bilinear75:75:bilinear:0',
    'metalfx75:75:metalfx:0',
    'metalfx50:50:metalfx:0',
]

FRAME_RE = re.compile(r'\[metal\] frame (\d+): ([\d.]+) fps, (\d+) draws/frame')
PERF_RES = {
    'intervals': r'intervals=(\d+)',
    'interval_ms': r'interval_ms=([\d.-]+)',
    'max_interval_ms': r'max_interval_ms=([\d.-]+)',
    'main_cpu_ms': r'main_cpu_ms=([\d.-]+)',
    'cpu_intervals': r'cpu_intervals=(\d+)',
    'cpu_rejected': r'cpu_rejected=(\d+)',
    'present_ms': r'present_ms=([\d.-]+)',
    'drawable_wait_ms': r'drawable_wait_ms=([\d.-]+)',
    'inflight_wait_ms': r'inflight_wait_ms=([\d.-]+)',
    'gpu_ms': r'gpu_ms=([\d.-]+)',
    'gpu_completed': r'gpu_completed=(\d+)',
    'gpu_unknown': r'gpu_unknown=(\d+)',
    'compile_ms_total': r'compile_ms_total=([\d.-]+)',
    'upload_peak_kib': r'upload_peak_kib=(\d+)',
    'footprint_mib': r'footprint_mib=([\d.-]+)',
    'thermal': r'thermal=(\d+)',
    'low_power': r'low_power=(\d+)',
}
WAITSTEADY_RE = re.compile(r'\[input\] waitsteady \d+ frames at \d+ draws, frame (\d+)')
DUMP_RE = re.compile(r'\[metal\] dumped (.+frame_\d+\.png) \((\d+)x(\d+)\)')


def parse_config(spec: str) -> dict:
    parts = spec.split(':')
    if len(parts) != 4:
        raise argparse.ArgumentTypeError(f'config must be name:scale:upscaler:aa, got {spec!r}')
    name, scale, upscaler, aa = parts
    if upscaler not in ('bilinear', 'metalfx'):
        raise argparse.ArgumentTypeError(f'upscaler must be bilinear|metalfx, got {upscaler!r}')
    return {'name': name, 'scale': int(scale), 'upscaler': upscaler, 'aa': int(aa)}


def parse_log(path: Path, sync_script_frame: int) -> dict:
    """Return sync frame, parsed perf windows and dumped frame paths."""
    syncs, windows, dumps = [], [], []
    current = None
    for line in path.read_text(errors='replace').splitlines():
        m = WAITSTEADY_RE.search(line)
        if m:
            syncs.append(int(m.group(1)))
        m = FRAME_RE.search(line)
        if m:
            current = {'frame': int(m.group(1)), 'draws': float(m.group(3))}
            continue
        m = DUMP_RE.search(line)
        if m:
            dumps.append(m.group(1))
            continue
        if '[perf]' not in line or current is None:
            continue
        row = dict(current)
        ok = True
        for key, pattern in PERF_RES.items():
            m = re.search(pattern, line)
            if not m:
                ok = False
                break
            row[key] = float(m.group(1))
        if ok:
            windows.append(row)

    out = {'sync_frames': syncs, 'windows': windows, 'dumps': dumps,
           'measure_start': None, 'measure_end': None}
    if len(syncs) >= 2:
        sync = syncs[1]  # confirmation dialog
        out['sync_frame'] = sync
        out['measure_start'] = sync + (MEASURE_START - sync_script_frame)
        out['measure_end'] = sync + (MEASURE_END - sync_script_frame)
    return out


def aggregate(windows: list[dict]) -> dict:
    usable = [w for w in windows
              if w['intervals'] > 0 and w['draws'] > 0
              and w['compile_ms_total'] <= 0]
    excluded_compile = len([w for w in windows if w['compile_ms_total'] > 0])
    if not usable:
        return {'n_windows': 0, 'excluded_compile': excluded_compile}
    fps = [1000.0 / w['interval_ms'] for w in usable if w['interval_ms'] > 0]

    def mean(key):
        vals = [w[key] for w in usable if w[key] >= 0]
        return statistics.fmean(vals) if vals else float('nan')

    def median(key):
        vals = [w[key] for w in usable if w[key] >= 0]
        return statistics.median(vals) if vals else float('nan')

    return {
        'n_windows': len(usable),
        'excluded_compile': excluded_compile,
        'fps_mean': statistics.fmean(fps) if fps else float('nan'),
        'fps_median': statistics.median(fps) if fps else float('nan'),
        'gpu_ms_mean': mean('gpu_ms'),
        'gpu_ms_median': median('gpu_ms'),
        'cpu_ms_mean': mean('main_cpu_ms'),
        'cpu_ms_median': median('main_cpu_ms'),
        'present_ms_mean': mean('present_ms'),
        'drawable_wait_ms_mean': mean('drawable_wait_ms'),
        'inflight_wait_ms_mean': mean('inflight_wait_ms'),
        'max_interval_ms_mean': mean('max_interval_ms'),
        'max_interval_ms_max': max(w['max_interval_ms'] for w in usable),
        'draws_mean': mean('draws'),
        'compile_ms_total': sum(w['compile_ms_total'] for w in windows),
        'gpu_unknown_total': sum(w['gpu_unknown'] for w in windows),
        'thermal_max': max(w['thermal'] for w in windows),
        'low_power_max': max(w['low_power'] for w in windows),
        'footprint_mib_mean': mean('footprint_mib'),
        'upload_peak_kib_max': max(w['upload_peak_kib'] for w in windows),
    }


def select_windows(parsed: dict) -> list[dict]:
    if parsed.get('measure_start') is None:
        return []
    lo, hi = parsed['measure_start'], parsed['measure_end']
    return [w for w in parsed['windows'] if lo <= w['frame'] <= hi]


def run_one(cfg: dict, repeat: int, args, out_dir: Path) -> dict:
    tag = f"{cfg['name']}_r{repeat}"
    run_dir = out_dir / tag
    run_dir.mkdir(parents=True, exist_ok=True)
    log_path = run_dir / 'run.log'
    env = dict(os.environ)
    env.update({
        'FNV_HEADLESS': '1',
        'FNV_STDERR': '1',
        'SKYRIM_SKIP_LAUNCHER': '1',
        'SKYRIM_ROOT': str(args.root),
        'SKYRIM_USER_DIR': str(args.user),
        'SKYRIM_RENDER_SCALE': str(cfg['scale']),
        'SKYRIM_UPSCALER': cfg['upscaler'],
        'SKYRIM_AA': str(cfg['aa']),
        'SKYRIM_MOUSE_ACCEL': '0',
        'FNV_INPUT_SCRIPT': str(args.script),
        'FNV_DUMP_DIR': str(run_dir),
        'FNV_QUIT_AFTER': str(args.quit_after),
    })
    if args.novsync:
        env['FNV_NOVSYNC'] = '1'
    cmd = [str(args.app)]
    print(f"[bench] {tag}: scale={cfg['scale']} upscaler={cfg['upscaler']} aa={cfg['aa']}"
          f" novsync={bool(args.novsync)}", flush=True)
    t0 = time.time()
    with log_path.open('w') as log:
        try:
            rc = subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT,
                                timeout=args.timeout).returncode
        except subprocess.TimeoutExpired:
            rc = 'timeout'
    wall = time.time() - t0

    parsed = parse_log(log_path, SYNC_SCRIPT_FRAME)
    if parsed.get('sync_frame') is not None:
        sync = parsed['sync_frame']
        lo = sync + (args.window_start - SYNC_SCRIPT_FRAME)
        hi = sync + (args.window_end - SYNC_SCRIPT_FRAME)
    else:
        lo = hi = None
    window = [w for w in parsed['windows'] if lo is not None and lo <= w['frame'] <= hi]
    agg = aggregate(window)
    result = {
        'config': cfg['name'], 'scale': cfg['scale'], 'upscaler': cfg['upscaler'],
        'aa': cfg['aa'], 'repeat': repeat, 'rc': rc, 'wall_s': round(wall, 1),
        'sync_frames': parsed['sync_frames'], 'measure_start': lo,
        'measure_end': hi, 'dumps': parsed['dumps'],
        **agg,
    }
    if agg.get('n_windows', 0) == 0:
        print(f"[bench] {tag}: FAILED (rc={rc}) see {log_path}", flush=True)
    else:
        print(f"[bench] {tag}: {agg['n_windows']} windows, "
              f"fps={agg['fps_mean']:.1f}, gpu={agg['gpu_ms_mean']:.2f} ms, "
              f"cpu={agg['cpu_ms_mean']:.2f} ms, thermal={agg['thermal_max']}", flush=True)
    return result


def summarize(results: list[dict]) -> list[dict]:
    groups: dict[str, list[dict]] = {}
    for r in results:
        if r.get('n_windows', 0) > 0:
            groups.setdefault(r['config'], []).append(r)
    rows = []
    for name, runs in groups.items():
        cfg = runs[0]
        row = {'config': name, 'scale': cfg['scale'], 'upscaler': cfg['upscaler'],
               'aa': cfg['aa'], 'runs': len(runs)}
        for key in ('fps_mean', 'gpu_ms_mean', 'cpu_ms_mean', 'present_ms_mean',
                    'max_interval_ms_mean', 'draws_mean', 'thermal_max'):
            vals = [r[key] for r in runs if isinstance(r.get(key), (int, float))]
            row[key] = statistics.fmean(vals) if vals else float('nan')
            row[key + '_stdev'] = statistics.stdev(vals) if len(vals) > 1 else 0.0
        rows.append(row)
    rows.sort(key=lambda r: (r['scale'], r['upscaler'], r['config']))
    return rows


def print_summary(rows: list[dict]) -> None:
    print('\nconfig            scale upscaler  runs   fps    gpu_ms  cpu_ms  present  max_int  thermal')
    for r in rows:
        print(f"{r['config']:<17} {r['scale']:>4}% {r['upscaler']:<9} {r['runs']:>4} "
              f"{r['fps_mean']:>6.1f} {r['gpu_ms_mean']:>8.2f} {r['cpu_ms_mean']:>6.2f} "
              f"{r['present_ms_mean']:>7.2f} {r['max_interval_ms_mean']:>7.2f} {r['thermal_max']:>7.0f}")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--app', type=Path, default=DEFAULT_APP)
    p.add_argument('--root', type=Path, default=DEFAULT_ROOT)
    p.add_argument('--user', type=Path, default=DEFAULT_USER)
    p.add_argument('--script', type=Path, default=DEFAULT_SCRIPT)
    p.add_argument('--out', type=Path, default=Path('/tmp/skyrim-bench'))
    p.add_argument('--config', action='append', dest='configs', type=parse_config,
                   default=None, help='name:scale:upscaler:aa (repeatable)')
    p.add_argument('--repeats', type=int, default=1)
    p.add_argument('--cooldown', type=float, default=20.0, help='seconds between runs')
    p.add_argument('--novsync', action='store_true', help='allow uncapped frames (GPU cost only)')
    p.add_argument('--quit-after', type=float, default=300.0, help='FNV_QUIT_AFTER safety net')
    p.add_argument('--window-start', type=int, default=MEASURE_START,
                   help='measurement start in script frames after the second sync')
    p.add_argument('--window-end', type=int, default=MEASURE_END,
                   help='measurement end in script frames after the second sync')
    p.add_argument('--timeout', type=float, default=360.0, help='hard subprocess timeout')
    p.add_argument('--seed', type=int, default=1)
    p.add_argument('--keep-order', action='store_true')
    args = p.parse_args()

    args.app = args.app.resolve()
    args.root = args.root.resolve()
    args.user = args.user.resolve()
    args.script = args.script.resolve()
    args.out = args.out.resolve()
    if not args.app.is_file():
        p.error(f'app executable not found: {args.app}')
    if not args.script.is_file():
        p.error(f'input script not found: {args.script}')
    args.out.mkdir(parents=True, exist_ok=True)
    args.user.mkdir(parents=True, exist_ok=True)

    configs = args.configs or [parse_config(s) for s in DEFAULT_CONFIGS]
    jobs = [(c, r) for r in range(1, args.repeats + 1) for c in configs]
    if not args.keep_order:
        random.Random(args.seed).shuffle(jobs)

    results = []
    for i, (cfg, repeat) in enumerate(jobs):
        if i:
            time.sleep(args.cooldown)
        results.append(run_one(cfg, repeat, args, args.out))

    (args.out / 'results.json').write_text(json.dumps(results, indent=2))
    rows = summarize(results)
    if rows:
        with (args.out / 'summary.csv').open('w', newline='') as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
    print_summary(rows)
    failures = [r for r in results if r.get('n_windows', 0) == 0]
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
