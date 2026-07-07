#!/usr/bin/env bash
# rocm-powerd: AI mode helper
# This script should apply performance tuning for inference workloads.
# It's intentionally simple and intended to be customized by users.

set -euo pipefail

LOG_TAG="rocm-powerd-ai"
log() { logger -t "$LOG_TAG" "$*" || echo "$*" >&2; }

# Example: cap CPU max frequency to a conservative value for inference
# Users can replace or extend this script to suit their hardware and needs.

CPU_MAX_FREQ_KHZ="${CPU_MAX_FREQ_KHZ:-2400000}"

log "Applying AI mode: capping CPU max frequency to ${CPU_MAX_FREQ_KHZ} kHz"
if command -v cpupower >/dev/null 2>&1; then
	cpupower frequency-set -u "${CPU_MAX_FREQ_KHZ}kHz" || log "cpupower failed"
else
	for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
		if [[ -w "$cpu/cpufreq/scaling_max_freq" ]]; then
			echo "$CPU_MAX_FREQ_KHZ" > "$cpu/cpufreq/scaling_max_freq" || log "write failed to $cpu"
		fi
	done
fi

# Example ROCm manual clocks: users can set specific clocks via rocm-smi
if command -v rocm-smi >/dev/null 2>&1; then
	log "Applying ROCm manual clocks (example)"
	# This is intentionally conservative; users should customize.
	rocm-smi --setsclk 5 >/dev/null 2>&1 || log "rocm-smi setsclk failed"
fi

log "AI mode applied"