#!/usr/bin/env bash
# rocm-powerd: AI mode helper
# Apply AI mode performance tuning.

set -euo pipefail

LOG_TAG="rocm-powerd-ai"
log() { logger -t "$LOG_TAG" "$*" || echo "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=power-control.sh
source "$SCRIPT_DIR/power-control.sh"

AI_CPU_MAX_FREQ_MHZ="${AI_CPU_MAX_FREQ_MHZ:-${CPU_MAX_FREQ_MHZ:-}}"
if [[ -z "$AI_CPU_MAX_FREQ_MHZ" && -n "${CPU_MAX_FREQ_KHZ:-}" ]]; then
    AI_CPU_MAX_FREQ_MHZ=$((CPU_MAX_FREQ_KHZ / 1000))
fi
AI_CPU_MAX_FREQ_MHZ="${AI_CPU_MAX_FREQ_MHZ:-3000}"
AI_CPU_PL1_WATTS="${AI_CPU_PL1_WATTS:-65}"
AI_CPU_PL2_WATTS="${AI_CPU_PL2_WATTS:-90}"
AI_GPU_POWER_CAP_WATTS="${AI_GPU_POWER_CAP_WATTS:-294}"
AI_SCLK_LEVEL="${AI_SCLK_LEVEL:-${AI_SCLK:-2}}"
AI_MCLK_LEVEL="${AI_MCLK_LEVEL:-${AI_MCLK:-1}}"

is_positive_number "$AI_CPU_PL1_WATTS" || { log "Invalid cpu_pl1_watts: $AI_CPU_PL1_WATTS"; exit 1; }
is_positive_number "$AI_CPU_PL2_WATTS" || { log "Invalid cpu_pl2_watts: $AI_CPU_PL2_WATTS"; exit 1; }
is_positive_number "$AI_GPU_POWER_CAP_WATTS" || { log "Invalid gpu_power_cap_watts: $AI_GPU_POWER_CAP_WATTS"; exit 1; }

SCLK_FILE=""
MCLK_FILE=""
if file=$(find_amd_gpu_device_file pp_dpm_sclk); then
    SCLK_FILE="$file"
    AI_SCLK_LEVEL=$(clamp_clock_level "$AI_SCLK_LEVEL" "$SCLK_FILE") || {
        log "Invalid sclk_level: $AI_SCLK_LEVEL"
        exit 1
    }
elif [[ ! $AI_SCLK_LEVEL =~ ^[0-9]+$ ]]; then
    log "Invalid sclk_level: $AI_SCLK_LEVEL"
    exit 1
fi
if file=$(find_amd_gpu_device_file pp_dpm_mclk); then
    MCLK_FILE="$file"
    AI_MCLK_LEVEL=$(clamp_clock_level "$AI_MCLK_LEVEL" "$MCLK_FILE") || {
        log "Invalid mclk_level: $AI_MCLK_LEVEL"
        exit 1
    }
elif [[ ! $AI_MCLK_LEVEL =~ ^[0-9]+$ ]]; then
    log "Invalid mclk_level: $AI_MCLK_LEVEL"
    exit 1
fi

log "Applying AI mode: cpu_max=${AI_CPU_MAX_FREQ_MHZ}MHz pl1=${AI_CPU_PL1_WATTS}W pl2=${AI_CPU_PL2_WATTS}W gpu_cap=${AI_GPU_POWER_CAP_WATTS}W sclk=${AI_SCLK_LEVEL} mclk=${AI_MCLK_LEVEL}"

capture_original_state
cpupower frequency-set -u "${AI_CPU_MAX_FREQ_MHZ}MHz"
apply_cpu_power_limits "$AI_CPU_PL1_WATTS" "$AI_CPU_PL2_WATTS"
apply_gpu_power_cap "$AI_GPU_POWER_CAP_WATTS"
rocm-smi --setperflevel manual
rocm-smi --setsclk "$AI_SCLK_LEVEL"
rocm-smi --setmclk "$AI_MCLK_LEVEL"

log "AI mode applied"
