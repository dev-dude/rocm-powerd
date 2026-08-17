# rocm-powerd

rocm-powerd is a lightweight daemon that automatically switches between user-defined ROCm power-management modes based on GPU activity. It keeps AMD GPUs in low-power idle when unused and automatically applies inference-optimized settings during AI workloads.

Features
- Configurable thresholds and timings via TOML
- Small, dependency-free bash implementation; requires `rocm-smi` (ROCm)
- Customizable `ai` and `idle` scripts/commands
- Configurable AI-mode CPU frequency cap, Intel RAPL PL1/PL2, AMD GPU power cap,
  GPU SCLK, and GPU MCLK
- Systemd service and install/uninstall scripts

Quick start
1. Review and edit `/etc/rocm-powerd/rocm-powerd.toml` (copied from `rocm-powerd.toml.example` on install).
2. Customize thresholds and mode tuning in the config.
3. Install:

```bash
sudo ./install.sh
```

4. Service is enabled and started as `rocm-powerd` (systemd unit `rocm-powerd.service`).

After changing the repository scripts, reinstall them:

```bash
sudo ./install.sh
sudo systemctl restart rocm-powerd
```

After changing only `/etc/rocm-powerd/rocm-powerd.toml`, restart the service:

```bash
sudo systemctl restart rocm-powerd
```

CLI
- `--status` print a single status line
- `--once` run a single check and apply
- `--daemon` run continuously (default)
- `--config PATH` point to alternate config file

Modes
By default, AI mode runs:

```bash
cpupower frequency-set -u 3000MHz
# Intel RAPL PL1/PL2 are set to 65W/90W through sysfs
# AMD GPU power1_cap is set to 294W through its discovered hwmon node
rocm-smi --setperflevel manual
rocm-smi --setsclk 2
rocm-smi --setmclk 1
```

By default, idle mode runs:

```bash
cpupower frequency-set -u 3000MHz
# Restore the CPU/GPU limits, clocks, and performance level captured before AI mode
```

These AI-mode values are configurable in `rocm-powerd.toml`:

```toml
[ai_mode]
cpu_max_freq_mhz = 3000
cpu_pl1_watts = 65
cpu_pl2_watts = 90
gpu_power_cap_watts = 294
sclk_level = 2
mclk_level = 1

[idle_mode]
cpu_max_freq_mhz = 3000
```

On the first transition into AI mode, rocm-powerd records the current Intel RAPL
limits, AMD GPU `power1_cap`, selected SCLK/MCLK states, and GPU performance
level under `/run/rocm-powerd`. Repeated AI-mode calls retain that original
snapshot. When idle mode runs, it restores and retains the snapshot so repeated
idle calls have the same result; the next AI session captures a fresh baseline.
If no snapshot is available, idle mode falls back to ROCm's reset-clock and
automatic-performance behavior.

RAPL package constraints are discovered under `/sys/class/powercap`, while the
GPU cap is found by locating an `amdgpu` node under `/sys/class/hwmon`; hwmon
numbering is not assumed. Requested power values are clamped to any min/max
files exposed by sysfs. Clock levels are also clamped to the range advertised
by `pp_dpm_sclk` and `pp_dpm_mclk` when those files are available.

The legacy `sclk` and `mclk` AI-mode keys remain accepted, but new
configurations should use `sclk_level` and `mclk_level`.

You can also replace the helper scripts entirely:

```toml
[scripts]
ai = "/usr/local/bin/ai-mode.sh"
idle = "/usr/local/bin/idle-mode.sh"
```

Troubleshooting
Check service health and recent logs:

```bash
sudo systemctl status rocm-powerd
journalctl -u rocm-powerd -n 50 --no-pager
```

Compatibility
- Designed for Ubuntu with ROCm 6/7, `rocm-smi`, `cpupower`, Intel RAPL sysfs,
  and AMDGPU hwmon power-cap support

Tests

Run the shell regression suite on Linux:

```bash
bash tests/run-tests.sh
```

License
- MIT (see LICENSE)

Tuning results
- On the author's AMD Radeon RX 7900 XTX system, inference tuning reduced GPU/system power during LLM inference at the cost of some throughput. Results will vary depending on hardware, model, and workload.
- Note: applying inference-tuned settings often prevents the GPU from reaching the absolute lowest idle power (sub-50 W). `rocm-powerd` watches power and restores idle settings when the workload subsides.
- Depending on tuning parameters, throughput may decrease in exchange for lower power consumption. On the author's hardware, throughput decreased by roughly 10–15% while reducing inference power.
