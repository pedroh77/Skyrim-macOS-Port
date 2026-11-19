#!/usr/bin/env python3
"""Compare benchmark frame dumps (PSNR / SSIM) against a native reference.

The runner dumps the same three script frames for every configuration.  Frames
are aligned by dump index, not by the absolute frame number: the script counts
frames from the confirmation-dialog sync, so index i is the same point of the
cart ride in every run.

Usage:
  python3 tools/bench/compare_frames.py --results /tmp/skyrim-bench-pilot/results.json \
      --reference native --out /tmp/skyrim-bench-pilot/quality.csv
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from pathlib import Path

import numpy as np
from PIL import Image

WINDOW = 8  # local SSIM window (downscaled luma)


def load_luma(path: Path, downscale: int = 0) -> np.ndarray:
    img = Image.open(path).convert('L')
    if downscale:
        img = img.resize((img.width // downscale, img.height // downscale),
                         Image.Resampling.LANCZOS)
    return np.asarray(img, dtype=np.float64)


def psnr(a: np.ndarray, b: np.ndarray) -> float:
    mse = float(np.mean((a - b) ** 2))
    if mse == 0:
        return float('inf')
    return 10.0 * math.log10((255.0 ** 2) / mse)


def _box_mean(x: np.ndarray, w: int) -> np.ndarray:
    """Mean over every w x w window using an integral image."""
    pad = w // 2
    p = np.pad(x, pad, mode='reflect')
    c = p.cumsum(0).cumsum(1)
    c = np.pad(c, ((1, 0), (1, 0)), mode='constant')
    return (c[w:, w:] - c[:-w, w:] - c[w:, :-w] + c[:-w, :-w]) / (w * w)


def ssim(a: np.ndarray, b: np.ndarray, w: int = WINDOW) -> float:
    """Mean local SSIM on downscaled luma (Gaussian constants for 8-bit)."""
    mu1, mu2 = _box_mean(a, w), _box_mean(b, w)
    s1 = _box_mean(a * a, w) - mu1 * mu1
    s2 = _box_mean(b * b, w) - mu2 * mu2
    s12 = _box_mean(a * b, w) - mu1 * mu2
    c1, c2 = (0.01 * 255.0) ** 2, (0.03 * 255.0) ** 2
    num = (2 * mu1 * mu2 + c1) * (2 * s12 + c2)
    den = (mu1 * mu1 + mu2 * mu2 + c1) * (s1 + s2 + c2)
    return float(np.mean(num / den))


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--results', type=Path, required=True)
    p.add_argument('--reference', default='native',
                   help='config name used as the 100%% native reference')
    p.add_argument('--out', type=Path, help='CSV output (default beside results.json)')
    p.add_argument('--downscale', type=int, default=2,
                   help='downscale factor for the SSIM computation (default 2)')
    p.add_argument('--dump-index', type=int, default=-1,
                   help='compare only this dump index (default: all)')
    args = p.parse_args()

    results = json.loads(args.results.read_text())
    def label(r):
        return r.get('config') or r.get('name') or '?'
    runs = [r for r in results if r.get('dumps')]
    ref = next((r for r in runs if label(r) == args.reference), None)
    if ref is None:
        p.error(f'reference {args.reference!r} not found or has no dumps')
    ref_dumps = ref['dumps']
    ref_imgs = [load_luma(Path(d), args.downscale) for d in ref_dumps]

    out = args.out or args.results.with_name('quality.csv')
    rows = []
    for r in runs:
        if r is ref:
            continue
        for i, path in enumerate(r['dumps']):
            if args.dump_index >= 0 and i != args.dump_index:
                continue
            if i >= len(ref_imgs):
                break
            img = load_luma(Path(path), args.downscale)
            if img.shape != ref_imgs[i].shape:
                print(f'skip {path}: shape {img.shape} != {ref_imgs[i].shape}')
                continue
            rows.append({
                'config': label(r),
                'scale': r['scale'],
                'upscaler': r['upscaler'],
                'aa': r['aa'],
                'frame_index': i,
                'psnr_db': round(psnr(ref_imgs[i], img), 3),
                'ssim': round(ssim(ref_imgs[i], img), 5),
            })

    with out.open('w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else
                           ['config', 'scale', 'upscaler', 'aa', 'frame_index',
                            'psnr_db', 'ssim'])
        w.writeheader()
        w.writerows(rows)

    print(f'reference: {label(ref)} ({len(ref_dumps)} frames)')
    print(f"{'config':<18} {'frames':>6} {'PSNR dB':>8} {'SSIM':>8}")
    groups: dict[str, list[dict]] = {}
    for row in rows:
        groups.setdefault(row['config'], []).append(row)
    for name, group in groups.items():
        print(f"{name:<18} {len(group):>6} "
              f"{statistics.fmean(r['psnr_db'] for r in group):>8.2f} "
              f"{statistics.fmean(r['ssim'] for r in group):>8.4f}")
    print(f'wrote {out}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
