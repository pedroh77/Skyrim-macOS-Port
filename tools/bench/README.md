# Render-scale / MetalFX benchmark

A reproducible way to answer: *does MetalFX at scale N actually help, and how
much?*  It compares the same fixed window of real gameplay across
`SKYRIM_RENDER_SCALE` and `SKYRIM_UPSCALER` settings while holding every other
variable constant.

## Scenario

The benchmark uses the **new-game intro cart ride**.  It is deterministic,
needs no save and exercises real guest logic plus the full Metal path
(~1000–2000 draws/frame).  The input script:

1. waits for the main menu to be stable (`waitsteady 120 9`),
2. presses Enter twice (New Game → confirmation → Yes),
3. lets the intro cinematic play,
4. measures **script frames 2400–4200** (30 s at the 60 Hz pace) in the cart,
5. dumps three aligned frames after the window for PSNR/SSIM,
6. quits cleanly.

Frame numbers after a `waitsteady` are relative to the sync moment, so the
measured window does not depend on startup time.

## Metrics

Each `[perf]` line covers roughly 2 s.  The useful fields:

| Metric | Meaning |
| --- | --- |
| `interval_ms` → `fps` | Wall time between presents, i.e. the frame rate the player sees. |
| `main_cpu_ms` | CPU time of the game/present thread. This is the CPU ceiling: if it is above the frame interval, the scene is CPU-bound. |
| `gpu_ms` | Average GPU execution time of completed present command buffers (Metal timestamps). |
| `present_ms`, `drawable_wait_ms`, `inflight_wait_ms` | Where the frame went if it is not GPU- or CPU-bound. |
| `max_interval_ms` | Worst frame in the 2 s window (hitches). |
| `draws` | Draw calls per frame; identifies the scene. |
| `compile_ms_total` | Shader/pipeline compilation in the window; those windows are excluded. |
| `thermal`, `low_power` | Processor state; record it, do not hide it. |

**Interpretation:** MetalFX reduces `gpu_ms`.  It cannot reduce `main_cpu_ms`.
If `main_cpu_ms` is the larger term, the scene is CPU-bound and MetalFX's frame
rate gain is capped by the CPU.  That is exactly what the cart ride shows, so
also compare the **GPU-only** numbers at matched internal resolution
(75 % bilinear vs 75 % MetalFX): the delta is the upscaler's own cost.

## Running

Build the host once (the normal build is fine; the benchmark needs the
`waitsteady` input-script command):

```sh
python3 tools/build.py game \
  --generated ~/Library/Caches/skyrim-macos/translate-<sha>/generated \
  --exe "$SKYRIM_ROOT/TESV.exe" \
  --codec-prefix ~/Library/Caches/skyrim-macos/codecs/prefix \
  --cache ~/Library/Caches/skyrim-macos/objects-<sha> \
  --out /tmp/skyrim-bench-build --app-name Skyrim
```

Pilot (4 configs, one run each, ~15 min on a fanless M1 Air):

```sh
python3 tools/bench/run_bench.py \
  --config native:100:bilinear:0 \
  --config bilinear75:75:bilinear:0 \
  --config metalfx75:75:metalfx:0 \
  --config metalfx50:50:metalfx:0 \
  --cooldown 75 --out /tmp/skyrim-bench-pilot
```

Full sweep (2 repeats, interleaved, 90 s cooldown):

```sh
python3 tools/bench/run_bench.py --repeats 2 --cooldown 90 \
  --out /tmp/skyrim-bench-full
```

Quality (compare the three dumped frames with the 100 % reference):

```sh
~/.dsh/.../python3 tools/bench/compare_frames.py \
  --results /tmp/skyrim-bench-pilot/results.json \
  --reference native --out /tmp/skyrim-bench-pilot/quality.csv
```

`run_bench.py` writes `results.json`, `summary.csv` and one directory per run
with `run.log` and the dumped PNGs.

## Controls and confounds

- **Mouse acceleration is pinned** (`SKYRIM_MOUSE_ACCEL=0`).  It changes input
  feel, not render cost; pinning it removes the confound the user noticed.
- **Vsync/60 Hz pace stays on** for gameplay runs.  `FNV_NOVSYNC=1` is for GPU
  microbenchmarks only: without the 60 Hz pace Skyrim's Havok/physics timing
  changes.
- **Headless** (`FNV_HEADLESS=1`) avoids window focus, fullscreen transitions
  and compositor differences.  The GPU work is the same; presentation is not
  captured, so read `gpu_ms`, not only `fps`, for the upscaler comparison.
- **Shader compilation:** windows with `compile_ms_total > 0` are excluded.
  The first cart section still compiles a few pipelines; it is outside the
  measured window.
- **Thermal drift:** the MacBook Air is fanless.  Interleave configurations,
  cool down between runs, repeat, use the median, and discard or flag runs with
  a worse `thermal` state.  A 30 s window measured immediately after a hot run
  is not comparable to a cold run.
- **Dumps are outside the window** (frames 4300–4500) so the synchronous
  readback cannot pollute the timing.
- **Scene identity:** check `draws` in the measured window; if one run has a
  very different draw profile, the sync landed elsewhere and the run is invalid.

## What this can and cannot prove

It proves the relative cost of MetalFX/bilinear and render scale **in this
cart-ride scene** on this machine.  It does not prove performance in towns,
interiors or combat.  Once a save exists, the same harness can add
`load <save>`/`coc <cell>` scripts for those scenes; the metric definitions and
controls stay identical.

## Static GPU microbenchmark (dialog)

The cart ride is CPU-heavy and its camera moves, so it is a poor place to
isolate the upscaler.  The `dialog.script` stops on the "Start a new game?"
confirmation (static camera, 37–40 draws) and measures a fixed window there:

```sh
python3 tools/bench/run_bench.py --script "$PWD/tools/bench/dialog.script" \
  --window-start 150 --window-end 550 --cooldown 10 \
  --config native:100:bilinear:0 \
  --config bilinear50:50:bilinear:0 --config metalfx50:50:metalfx:0 \
  --config bilinear75:75:bilinear:0 --config metalfx75:75:metalfx:0 \
  --out /tmp/skyrim-bench-dialog
```

Because the scene is small, `fps` is capped at 60; read `gpu_ms`, not fps.
In headless mode the bilinear path now performs the same output-resolution
linear blit a window performs, so both upscalers pay for the final pass.

## Quality pass

`capture_quality.py` stops on the same static confirmation, dumps one frame per
configuration and quits; `compare_frames.py` computes PSNR/SSIM against the
native 100 % frame.  Use `--dump-index 0` for the single static frame.

```sh
python3 tools/bench/capture_quality.py --out /tmp/skyrim-bench-quality
python3 tools/bench/compare_frames.py \
  --results /tmp/skyrim-bench-quality/results.json \
  --reference native --dump-index 0
```

## Pilot observations (2026-11-18, MacBookAir10,1, M1, headless)

One run per configuration, 1800-frame cart window, `SKYRIM_MOUSE_ACCEL=0`:

| config | scale | upscaler | GPU ms | CPU ms | fps |
| --- | --- | --- | ---: | ---: | ---: |
| native | 100 | bilinear | 18.0 | 24.3 | 34.3 |
| bilinear75 | 75 | bilinear | 11.2 | 17.5 | 48.9 |
| metalfx75 | 75 | MetalFX | 13.8 | 21.2 | 40.3 |
| metalfx50 | 50 | MetalFX | 10.0 | 16.8 | 50.9 |

Static dialog, post-parity build (GPU-bound, fps capped at 60):

| config | GPU ms |
| --- | ---: |
| native 100 | 8.25 |
| bilinear75 | 5.84 |
| metalfx75 | 8.79 |
| bilinear50 | 3.34 |
| metalfx50 | 7.06 |

Dialog text crop vs native 100 % (same static frame):

| config | PSNR dB | SSIM |
| --- | ---: | ---: |
| bilinear75 | 19.36 | 0.585 |
| metalfx75 | 19.18 | 0.723 |
| metalfx50 | 19.00 | 0.740 |

Interpretation:

- MetalFX is **not a speed-up at a matched render scale**.  It costs
  ~2–3 ms of GPU at 2880×1800 output; at 75 % it can be slower than native 100 %
  in a GPU-light scene.
- The frame-rate gain the player perceives from "MetalFX" comes mostly from
  lowering the render scale (100 % → 75 %), not from the upscaler.
- MetalFX buys real edge/text quality over bilinear at the same scale
  (SSIM 0.72 vs 0.59 on the text crop), at the cost above.
- 50 % MetalFX is a reasonable balance: its GPU cost is near 75 % bilinear and
  its text quality is higher, with a similar cart frame rate.
- The cart ride is also CPU-bound (`main_cpu_ms` 17–24 ms); below ~75 % the
  frame-rate gain flattens because the CPU, not the GPU, is the limit.
- These are single-run pilot numbers with scene/thermal caveats.  Use the full
  sweep (`--repeats 2 --cooldown 90`) and the draw-matched
  `analyze_windows.py` before making a buying decision.
