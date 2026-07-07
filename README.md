# rocm-powerd

rocm-powerd is a lightweight daemon that automatically switches between user-defined ROCm power-management modes based on GPU activity. It keeps AMD GPUs in low-power idle when unused and automatically applies inference-optimized settings during AI workloads.

Features
- Configurable thresholds and timings via TOML
- Small, dependency-free bash implementation; requires `rocm-smi` (ROCm)
- Customizable `ai` and `idle` scripts/commands
- Configurable AI-mode CPU cap, GPU SCLK, and GPU MCLK
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
rocm-smi --setperflevel manual
rocm-smi --setsclk 2
rocm-smi --setmclk 3
```

By default, idle mode runs:

```bash
cpupower frequency-set -u 3000MHz
rocm-smi --resetclocks
rocm-smi --setperflevel auto
rocm-smi --resetprofile
```

These AI-mode values are configurable in `rocm-powerd.toml`:

```toml
[ai_mode]
cpu_max_freq_mhz = 3000
sclk = 2
mclk = 3

[idle_mode]
cpu_max_freq_mhz = 3000
```

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
- Designed for Ubuntu with ROCm 6/7 (uses `rocm-smi` when available)

License
- MIT (see LICENSE)

Tuning results
- On the author's AMD Radeon RX 7900 XTX system, inference tuning reduced GPU/system power during LLM inference at the cost of some throughput. Results will vary depending on hardware, model, and workload.
- Note: applying inference-tuned settings often prevents the GPU from reaching the absolute lowest idle power (sub-50 W). `rocm-powerd` watches power and restores idle settings when the workload subsides.
- Depending on tuning parameters, throughput may decrease in exchange for lower power consumption. On the author's hardware, throughput decreased by roughly 10–15% while reducing inference power.
