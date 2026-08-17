#!/usr/bin/env bash
# rocm-powerd: Idle mode helper
# Restore automatic GPU power management and default CPU frequencies.

set -euo pipefail

LOG_TAG="rocm-powerd-idle"
log() { logger -t "$LOG_TAG" "$*" || echo "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=power-control.sh
source "$SCRIPT_DIR/power-control.sh"

IDLE_CPU_MAX_FREQ_MHZ="${IDLE_CPU_MAX_FREQ_MHZ:-${CPU_MAX_FREQ_MHZ:-}}"
if [[ -z "$IDLE_CPU_MAX_FREQ_MHZ" && -n "${CPU_MAX_FREQ_KHZ:-}" ]]; then
    IDLE_CPU_MAX_FREQ_MHZ=$((CPU_MAX_FREQ_KHZ / 1000))
fi
IDLE_CPU_MAX_FREQ_MHZ="${IDLE_CPU_MAX_FREQ_MHZ:-3000}"

log "Restoring idle mode: cpu_max=${IDLE_CPU_MAX_FREQ_MHZ}MHz"

cpupower frequency-set -u "${IDLE_CPU_MAX_FREQ_MHZ}MHz"
restore_saved_power_limits

ORIGINAL_SCLK=""
ORIGINAL_MCLK=""
ORIGINAL_PERF=""
ORIGINAL_SCLK=$(saved_state_value sclk || true)
ORIGINAL_MCLK=$(saved_state_value mclk || true)
ORIGINAL_PERF=$(saved_state_value perf || true)

if [[ -n "$ORIGINAL_SCLK" || -n "$ORIGINAL_MCLK" ]]; then
    rocm-smi --resetclocks
    rocm-smi --setperflevel manual
    [[ -n "$ORIGINAL_SCLK" ]] && rocm-smi --setsclk "$ORIGINAL_SCLK"
    [[ -n "$ORIGINAL_MCLK" ]] && rocm-smi --setmclk "$ORIGINAL_MCLK"
    rocm-smi --setperflevel "${ORIGINAL_PERF:-auto}"
else
    rocm-smi --resetclocks
    rocm-smi --setperflevel auto
    rocm-smi --resetprofile
fi
mark_state_idle

log "Idle mode restored"
