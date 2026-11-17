# FEX — Building and Testing (a7xx)

Building FEX (`build-manual.md`, `make-fex-tool.sh`), packaging it into a
Proton tool (`fex-in-proton-manual.md`), per-game configs (`fex-pergame-config.md`),
and A/B testing of FEX profiles: isolating the impact of FEX (above all Multiblock)
on FPS drops in games. The main stack of Turnip patches lives in
`../turnip-a7xx-dx12/` and is not rebuilt between FEX runs: only the FEX profile changes.

> The SpaceMarine (55150) crash investigation via Proton 11/FEX lives in a separate
> repo: `../spacemarine-proton-fix/`.

## Table of contents

- [Hypothesis](#hypothesis)
- [FEX profiles](#fex-profiles)
- [Methodology](#methodology)
- [Measurements](#measurements)
- [RE4 results (2026-10-02, driver patched, DX12)](#re4-results-2026-10-02-driver-patched-dx12)
- [Status](#status)

## Hypothesis

RE4 (DX12, vkd3d → Turnip, 13 fps in stock and patched, memory-limited) — the drops
may be in FEX exactly. WNO — OpenGL, runs through `kgsl_dri`, Turnip is not involved;
FEX can also be the limiter in WNO, but the Turnip patches do not work there.

## FEX profiles (`/usr/share/armada/fex-profiles.json`)

| profile | TSOEnabled | Multiblock | X87ReducedPrecision | VectorTSO | MemcpySetTSO | HalfBarrierTSO |
|---|---|---|---|---|---|---|
| `default` | 1 | **1** | 1 | 0 | 0 | 1 |
| `fast` | 0 | **1** | 1 | 0 | 0 | 0 |
| `compatible` | 1 | **0** | 0 | 1 | 1 | 1 |

A/B design: `default` vs `fast` (TSO and HalfBarrier) — isolates the TSO stack;
`default` vs `compatible` — isolates Multiblock itself.

This is an **Armada OS convention**, not upstream FEX: FEX has no automatic
"game → profile" database; per-game config is set via `AppConfig/<exe>.json` or
`AppConfig/Steam_<appid>_<exe>.json` files, or `FEX_APP_CONFIG`. Details —
[`fex-pergame-config.md`](fex-pergame-config.md) (there too: what Proton has, and why
"one game on fast, another on compatible" is normal).

## Methodology

1. RE4: `../turnip-a7xx-dx12/scripts/run-game.sh patched <sec>` (DX12, vkd3d → Turnip).
2. WNO: `../turnip-a7xx-dx12/scripts/run-wtno.sh` (OpenGL, Turnip is not involved).
3. Power profile `performance` — via `/usr/libexec/armada/armada-game-launch`
   (the wrapper accepts only `COMMAND [ARGS...]`; the profile is set separately,
   `scaling_governor` is rw for `root:wheel` — changeable without sudo).
4. MangoHud CSV → `results/<game>/` (do not keep them in
   `/tmp/opencode/mangologs` — that does not survive a reboot). Layout:
   `results/re4/` — RE4 runs, `results/wno/` — WNO runs, `results/fex-cfg.log` —
   the generated profile configs (common to all games).
5. One run per configuration, minimum ~2 min of a stable section; on diverging
   p95/min — repeat the run.
6. Do not run the build and the game at the same time. Kill leftover wine by pid.

## Measurements

- mean / median / min / max fps
- frametime: median / p95 / max
- RAM / swap (in game: ~7 GiB RAM + up to 4 GiB zram)
- MangoHud CSV contains, per 100 ms interval: gpu_load (kgsl ioctl, GPU-busy
  time share), cpu_load, ram/swap, gpu_core_clock.

## RE4 results (2026-10-02, driver patched, DX12)

FEX profile A/B (`results/re4/fps-fex-{default,fast,compatible}.csv`, 180 s each):

| profile | Multiblock | TSO | fps med | fps p5 | ft med | ft p95 |
|---|---|---|---|---|---|---|
| default | 1 | 1 | 15.3 | 14.6 | 65.2 | 68.3 |
| fast | 1 | 0 | 15.6 | 15.1 | 64.2 | 66.2 |
| compatible | 0 | 1 | 15.6 | 15.2 | 64.2 | 65.8 |

All three within noise → **the FEX profile (Multiblock/TSO) does not affect RE4 FPS**.

Where the frames go (`scripts/bn-sampler.py` + `scripts/align-correlate.py`,
`default` run, data in `results/re4/bn-default.csv`):

- **Steady state (80% of samples, ft 45–150 ms): gpu_load = 98% at the max
  frequency of 680 MHz** (devfreq `simple_ondemand`, ceiling 680). PSI
  memory/io ≈ 0, disk 0 MB/s, swap stable (~4 GiB), system CPU ~26%.
  **The 64.6 ms frame is GPU-limited** — consistent with §13 of the main repo
  (FPS does not depend on the driver: the patches reduce bandwidth, but the
  GPU is not bandwidth-limited).
- **Stalls ≥200 ms — only in the first ~6 s after the first frame** (level
  load): USB exFAT streaming up to 43 MB/s, psi_mem up to 51%, swap fills
  2.6→4.1 GiB. In the following ~145 s of gameplay there were no stalls at all.
- "Fast" frames <34 ms (menu/light scenes): gpu 43%, cpu 54% — the limiter
  shifts to the CPU there (streaming/decompression/FEX).

Practical consequences:

1. The game is on USB exFAT (`/dev/sdg`); 202 GiB free on the internal btrfs —
   moving RE4 to UFS would cut level load times and streaming stalls.
2. **Steady state is GPU-bound (98%, 680 MHz). Optimizing from the driver side
   is unlikely to matter.** Rationale:
   - §13 of the main repo: stock vs patched turnip — identical FPS (13–15).
     The patches affect bandwidth/UBWC, but in GPU-bound mode the gain is zero.
   - Steady-state PSI memory/io ≈ 0, disk 0 MB/s — not bandwidth-bound, not
     I/O-bound.
   - GPU 98% busy at max freq — the bottleneck is shader/fill rate, not command
     submission (the CPU does not starve the GPU).
   - Turnip has no perf-queries (no accessible hardware GPU counters on a7xx),
     so pinpoint optimization of "which exact stage" is impossible without
     guesswork. Any micro-optimizations in the translator that we have already
     tested (UBWC/compat/pipeline patches) gave no effect on this workload.
   - **Shader/fill load cannot be radically accelerated from the driver side.**
     The driver translates D3D12→Vulkan→IR3, it does not rewrite the game's
     shaders. The load can be reduced **only via RE4's graphics settings**
     (resolution, shadows, AO, post-effects, AA) — they cut polygon density,
     overdraw, fragment load. No significant gain is expected from the driver side.
3. FEX profiles do not need to be touched.

Limitation: `top_threads` in bn-sampler is empty — the search for `re4.exe` by
cmdline does not fire (the proton/arm64ec process cmdline does not contain
`re4.exe`); thread-level data requires a search via `/proc/<pid>/maps`
(libarm64ecfex) + a repeat run.

## Status

- [x] A/B RE4: `default` vs `fast` — within noise
- [x] A/B RE4: `default` vs `compatible` (isolating Multiblock) — within noise
- [x] Conclusion: Multiblock/TSO do not affect RE4's drops; the limiter is the
      GPU (98%, max freq)
- [ ] WNO: baseline run captured under FEX `default`
- [ ] (optional) thread-level data: fix the process lookup, repeat the run
