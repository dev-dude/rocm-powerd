# Benchmarks

Measurements from the author's machine, taken in November 2026 while tuning
rocm-powerd. Numbers will differ on other hardware, models and workloads.

## Test machine

| Part | Details |
|---|---|
| CPU | Intel Core i9-13900KF |
| GPU | AMD Radeon RX 7900 XTX (24 GB, gfx1100) |
| RAM | ~94 GB DDR4 |
| Board | ASRock B760M Pro-A/D4, BIOS 9.02 |
| OS | Ubuntu 24.04.5, kernel 6.17.0-35 |
| GPU stack | amdgpu-dkms 30.30.1 + ROCm 7.2.1, then 30.30.4 + ROCm 7.2.4 |
| LLM | [Strata](https://github.com/Niko1221/Strata) serving Qwen3.8-Flash-Next IQ2_XS (~68 GB, so most experts live in system RAM and the CPU does part of the work) |

rocm-powerd settings during the tests, unless a table says otherwise: AI mode
`sclk_level = 2`, `mclk_level = 1`; idle mode `sclk_level = 1`, `mclk_level = 1`.

## AI-mode CPU power cap

Workload: an LLM batch job of 1,000 items, 50 items per request with short JSON
answers, one request at a time. AI mode was active for the whole run. GPU power is the average of `power1_average` sampled once a second.
The wall readings are from a plug-in meter that also powers a few other devices
(roughly 30 W), read by eye, so treat them as approximate.

| AI mode `cpu_pl1_watts` / `cpu_pl2_watts` | Time | Items/s | GPU avg / peak | Wall meter peak |
|---|---|---|---|---|
| 95 / 125 | 124.8 s | 8.0 | 130 / 139 W | ~380 W |
| **65 / 65** | **122.2 s** | **8.2** | 131 / 140 W | **~313 W** |
| 45 / 45 | 122.9 s | 8.1 | 136 / 149 W | ~309 W |

- 65/65 W cut the wall peak by about 70 W with no slowdown. The low point between
  peaks stayed around 280 W at every cap.
- 45/45 W saved only ~4 W more. The GPU, not the CPU, sets the speed for this job,
  and a tighter cap only slows any other CPU work done while the model runs.
- The draw cycles with each request (roughly 3 s high, 2 s low); the peak is what the
  CPU cap trims.

Clocks observed during these runs (AI mode): GPU core ~2,525 MHz, VRAM 456 MHz
(`mclk_level = 1` of 0-3, max 1,249 MHz), fabric clock 1,000 MHz (max 2,301 MHz),
GPU 120-180 W. The VRAM level is a deliberate power choice; it was not varied here.

## Idle power

GPU `power1_average` with the model loaded and idle, at idle-mode levels sclk 1 / mclk 1:

| Setup | GPU idle |
|---|---|
| amdgpu 30.30.1, idle levels restored from a snapshot taken while the model was loading (mclk 3) | ~50 W |
| amdgpu 30.30.1, fixed idle levels (`[idle_mode] sclk_level/mclk_level = 1`) | 31-34 W |
| amdgpu 30.30.4, fixed idle levels | **27 W** (60 s average) |

The first row is the reason for the `[idle_mode]` clock settings: without them idle
mode restores whatever levels were saved on the first switch into AI mode.

CPU package power at idle (`turbostat --show idle,power`, 15 s), after enabling
**Package C State Support** (Disabled → Auto) and **C6DRAM** in the BIOS:

| | Package power | Package C-state residency |
|---|---|---|
| Before | 3.8 W | 0% in every package state |
| After | **2.46 W** | PC2 37.7%, PC3 31.5%, PC6-PC10 0% |

Deeper package states stay at 0%, most likely because the onboard RTL8125 NIC runs
with ASPM disabled by its driver (on purpose; leave it on a server).

## LLM throughput under AI mode

Medians of 3 runs, thinking off, temperature 0: a 450-token answer, a 4.6k-token
prompt, a short single JSON request, and a 50-item JSON batch. AI mode CPU cap
95/125 W for all of these.

| Setup | Output tok/s | Prompt tok/s (4.6k tokens) | Single JSON request | 50-item batch |
|---|---|---|---|---|
| Strata 0.2.8, MTP drafter, ROCm 7.2.1 | 51.5 | 1,217 | 1.61 s | 8.5 s |
| Strata 0.2.14, MTP drafter, ROCm 7.2.1 | 51.6 | 1,433 | 1.47 s | 8.2 s |
| Strata 0.2.14, DFlash2 drafter, ROCm 7.2.1 | 54.4 | 1,430 | 1.37 s | 6.8 s |
| Strata 0.2.14, DFlash2, amdgpu 30.30.4 / ROCm 7.2.4, run 1 | 53.5 | 1,421 | 1.40 s | 6.9 s |
| Strata 0.2.14, DFlash2, amdgpu 30.30.4 / ROCm 7.2.4, run 2 | 50.8 | 1,434 | 1.38 s | 6.9 s |

The driver and ROCm update did not change throughput (within run-to-run noise); its
gain was the lower idle power above.

## Reproducing

Run the same job under each setting: change the AI-mode cap in
`/etc/rocm-powerd/rocm-powerd.toml`, `sudo systemctl restart rocm-powerd`, and check
`journalctl -u rocm-powerd` for the `Applying AI mode: ... pl1=...` line to confirm
the cap took effect. Sample GPU power from the amdgpu hwmon `power1_average` file
and CPU package power with `sudo turbostat --show idle,power`.
