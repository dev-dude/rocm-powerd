# rocm-powerd

rocm-powerd is a lightweight daemon that automatically switches between user-defined ROCm power-management modes based on GPU activity. It keeps AMD GPUs in low-power idle when unused and automatically applies inference-optimized settings during AI workloads.

Features
- Configurable thresholds and timings via TOML
- Small, dependency-free bash implementation; requires `rocm-smi` (ROCm)
- Customizable `ai` and `idle` scripts/commands
- Systemd service and install/uninstall scripts

Quick start
1. Review and edit `/etc/rocm-powerd/rocm-powerd.toml` (copied from `rocm-powerd.toml.example` on install).
2. Customize `ai` and `idle` scripts or change the commands in config.
3. Install:

```bash
sudo ./install.sh
```

4. Service is enabled and started as `rocm-powerd` (systemd unit `rocm-powerd.service`).

CLI
- `--status` print a single status line
- `--once` run a single check and apply
- `--daemon` run continuously (default)
- `--config PATH` point to alternate config file

Compatibility
- Designed for Ubuntu with ROCm 6/7 (uses `rocm-smi` when available)

License
- MIT (see LICENSE)

Tuning results
- On the author's AMD Radeon RX 7900 XTX system, inference tuning reduced GPU/system power during LLM inference at the cost of some throughput. Results will vary depending on hardware, model, and workload.
- Note: applying inference-tuned settings often prevents the GPU from reaching the absolute lowest idle power (sub-50 W). `rocm-powerd` watches power and restores idle settings when the workload subsides.
- Depending on tuning parameters, throughput may decrease in exchange for lower power consumption. On the author's hardware, throughput decreased by roughly 10–15% while reducing inference power.
