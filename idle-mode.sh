#!/usr/bin/env bash
# rocm-powerd: Idle mode helper
# Restore automatic GPU power management and default CPU frequencies.

set -euo pipefail

LOG_TAG="rocm-powerd-idle"
log() { logger -t "$LOG_TAG" "$*" || echo "$*" >&2; }

log "Restoring CPU frequency governor and max frequency"
if command -v cpupower >/dev/null 2>&1; then
	cpupower frequency-set -g ondemand >/dev/null 2>&1 || log "cpupower set governor failed"
	cpupower frequency-set -u max >/dev/null 2>&1 || log "cpupower reset max failed"
else
	for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
		if [[ -w "$cpu/cpufreq/scaling_max_freq" ]]; then
			# Attempt to set to '0' (kernel chooses) or a conservative high value
			echo 0 > "$cpu/cpufreq/scaling_max_freq" || log "write failed to $cpu"
		fi
	done
fi

if command -v rocm-smi >/dev/null 2>&1; then
	log "Restoring ROCm automatic clocks and perflevel"
	rocm-smi --resetclocks >/dev/null 2>&1 || log "rocm-smi resetclocks failed"
	rocm-smi --setperflevel auto >/dev/null 2>&1 || log "rocm-smi setperflevel failed"
	rocm-smi --resetprofile >/dev/null 2>&1 || log "rocm-smi resetprofile failed"
fi

log "Idle mode restored"