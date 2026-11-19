#!/usr/bin/env python3
"""Window-level analysis of benchmark logs, including draw-matched comparisons.

The cart ride moves, so two configurations measured at the same frame count do
not necessarily see the same scene (the frame rate changes how far the cart has
travelled).  Grouping the measured 2 s windows by draw count gives a fairer
comparison: windows with similar draw counts submit similar work, independent
of where the cart happens to be.

Usage:
  python3 tools/bench/analyze_windows.py /tmp/skyrim-bench-pilot
"""
from __future__ import annotations

import argparse
import csv
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_bench import aggregate, parse_log, select_windows  # noqa: E402


def usable(win):
    return [w for w in win if w['intervals'] > 0 and w['draws'] > 0
            and w['compile_ms_total'] <= 0]


def stats(win):
    if not win:
        return {'n': 0}
    return {
        'n': len(win),
        'fps': statistics.fmean(1000.0 / w['interval_ms'] for w in win if w['interval_ms'] > 0),
        'gpu': statistics.fmean(w['gpu_ms'] for w in win if w['gpu_ms'] >= 0),
        'cpu': statistics.fmean(w['main_cpu_ms'] for w in win if w['main_cpu_ms'] >= 0),
        'draws': statistics.fmean(w['draws'] for w in win),
        'thermal': max(w['thermal'] for w in win),
    }


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('results_dir', type=Path)
    p.add_argument('--draws', default='1200-1600', help='draw-count band for matched comparison')
    p.add_argument('--out', type=Path, help='windows.csv path (default beside results)')
    args = p.parse_args()
    lo, hi = (int(x) for x in args.draws.split('-'))

    all_rows, matched_rows = [], []
    for log in sorted(args.results_dir.glob('*/run.log')):
        name = log.parent.name
        parsed = parse_log(log, 20)
        win = usable(select_windows(parsed))
        if not win:
            print(f'{name}: no usable windows')
            continue
        for w in win:
            all_rows.append({'run': name, 'frame': int(w['frame']), 'draws': w['draws'],
                             'fps': 1000.0 / w['interval_ms'] if w['interval_ms'] > 0 else 0,
                             'gpu_ms': w['gpu_ms'], 'cpu_ms': w['main_cpu_ms'],
                             'interval_ms': w['interval_ms'], 'thermal': w['thermal']})
        matched_rows.append({'run': name, **stats([w for w in win if lo <= w['draws'] <= hi])})

    out = args.out or (args.results_dir / 'windows.csv')
    if all_rows:
        with out.open('w', newline='') as f:
            wr = csv.DictWriter(f, fieldnames=list(all_rows[0].keys()))
            wr.writeheader()
            wr.writerows(all_rows)

    print(f"\n{'run':<22} {'all n':>5} {'fps':>6} {'gpu':>6} {'cpu':>6} {'draws':>6} "
          f"| {'band n':>6} {'gpu':>6} {'cpu':>6} {'fps':>6}")
    for row in matched_rows:
        log = args.results_dir / row['run'] / 'run.log'
        parsed = parse_log(log, 20)
        s = stats(usable(select_windows(parsed)))
        if not s['n']:
            continue
        band = row
        print(f"{row['run']:<22} {s['n']:>5} {s['fps']:>6.1f} {s['gpu']:>6.2f} "
              f"{s['cpu']:>6.2f} {s['draws']:>6.0f} "
              f"| {band.get('n', 0):>6} {band.get('gpu', float('nan')):>6.2f} "
              f"{band.get('cpu', float('nan')):>6.2f} {band.get('fps', float('nan')):>6.1f}")
    print(f'wrote {out}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
