#!/usr/bin/env bash
# rocm-powerd: Idle mode helper
# Restore automatic GPU power management and default CPU frequencies.

set -euo pipefail

LOG_TAG="rocm-powerd-idle"
log() { logger -t "$LOG_TAG" "$*" || echo "$*" >&2; }

IDLE_CPU_MAX_FREQ_MHZ="${IDLE_CPU_MAX_FREQ_MHZ:-${CPU_MAX_FREQ_MHZ:-}}"
if [[ -z "$IDLE_CPU_MAX_FREQ_MHZ" && -n "${CPU_MAX_FREQ_KHZ:-}" ]]; then
    IDLE_CPU_MAX_FREQ_MHZ=$((CPU_MAX_FREQ_KHZ / 1000))
fi
IDLE_CPU_MAX_FREQ_MHZ="${IDLE_CPU_MAX_FREQ_MHZ:-3000}"

log "Restoring idle mode: cpu_max=${IDLE_CPU_MAX_FREQ_MHZ}MHz"

cpupower frequency-set -u "${IDLE_CPU_MAX_FREQ_MHZ}MHz"
rocm-smi --resetclocks
rocm-smi --setperflevel auto
rocm-smi --resetprofile

log "Idle mode restored"
