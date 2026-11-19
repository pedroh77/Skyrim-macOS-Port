#!/usr/bin/env python3
"""Draw a compact GPU/CPU/FPS chart from a benchmark summary.csv."""
from __future__ import annotations

import argparse
import csv
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

BG = (250, 250, 250)
FG = (30, 30, 30)
GRID = (220, 220, 220)
GPU = (52, 120, 210)
CPU = (230, 145, 40)
FPS = (60, 160, 90)


def font(size: int):
    for path in ('/System/Library/Fonts/Helvetica.ttc',
                 '/System/Library/Fonts/Supplemental/Arial.ttf'):
        try:
            return ImageFont.truetype(path, size, index=0)
        except OSError:
            pass
    return ImageFont.load_default(size=size)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--summary', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()

    rows = list(csv.DictReader(args.summary.open()))
    if not rows:
        p.error('empty summary')
    rows.sort(key=lambda r: (int(r['scale']), r['upscaler'], r['config']))
    names = [r['config'] for r in rows]
    gpu = [float(r['gpu_ms_mean']) for r in rows]
    cpu = [float(r['cpu_ms_mean']) for r in rows]
    fps = [float(r['fps_mean']) for r in rows]

    W, H = 1400, 900
    img = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(img)
    f_title, f_lab, f_val, f_note = font(30), font(18), font(16), font(15)
    d.text((40, 24), 'Skyrim macOS — intro cart ride (1800-frame window, headless)', font=f_title, fill=FG)
    d.text((40, 62), 'GPU and CPU are independent: when CPU > GPU the scene is CPU-bound and '
                     'MetalFX cannot raise the frame rate further.  Bilinear 75% was measured before the headless parity fix.', font=f_note, fill=(90, 90, 90))

    left, right = 100, W - 40
    top, mid, bottom = 110, 500, 830
    n = len(names)
    slot = (right - left) / n

    def panel(y0, y1, values1, values2, label, colors, vmax):
        d.line([(left, y1), (right, y1)], fill=FG, width=2)
        d.line([(left, y0), (left, y1)], fill=FG, width=2)
        for k in range(6):
            v = vmax * k / 5
            y = y1 - (y1 - y0) * k / 5
            d.line([(left, y), (right, y)], fill=GRID, width=1)
            d.text((left - 12, y - 8), f'{v:.1f}', font=f_lab, fill=(80, 80, 80), anchor='ra')
        d.text((left - 70, (y0 + y1) / 2), label, font=f_lab, fill=FG, anchor='mm')
        bw = min(46, slot / 3.2)
        for i, a in enumerate(values1):
            b = values2[i] if values2 is not None else None
            cx = left + slot * (i + 0.5)
            series = [(a, colors[0])] if values2 is None else [(a, colors[0]), (b, colors[1])]
            for j, (v, col) in enumerate(series):
                x = cx + (j - 0.5) * (bw + 8)
                y = y1 - (y1 - y0) * min(v, vmax) / vmax
                d.rectangle([x - bw / 2, y, x + bw / 2, y1], fill=col)
                d.text((x, y - 6), f'{v:.1f}', font=f_val, fill=FG, anchor='mb')
        for i, name in enumerate(names):
            d.text((left + slot * (i + 0.5), y1 + 12), name, font=f_lab, fill=FG, anchor='ma')

    vmax1 = max(gpu + cpu) * 1.25
    panel(top, mid, gpu, cpu, 'ms', (GPU, CPU), vmax1)
    d.rectangle([left, top - 2, left + 18, top + 14], fill=GPU)
    d.text((left + 24, top), 'GPU ms', font=f_val, fill=FG)
    d.rectangle([left + 120, top - 2, left + 138, top + 14], fill=CPU)
    d.text((left + 144, top), 'CPU ms (game/present thread)', font=f_val, fill=FG)

    vmax2 = max(fps) * 1.3
    panel(mid + 40, bottom, fps, None, 'fps', (FPS,), vmax2)
    d.rectangle([left, mid + 38, left + 18, mid + 54], fill=FPS)
    d.text((left + 24, mid + 38), 'fps (1000 / interval_ms)', font=f_val, fill=FG)
    d.text((40, H - 36), 'Source: tools/bench/run_bench.py · interleaved, cooled, one 1800-frame cart-ride window per run',
           font=f_note, fill=(110, 110, 110))

    img.save(args.out)
    print(f'wrote {args.out}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
