#!/usr/bin/env bash
# rocm-powerd: AI mode helper
# Apply AI mode performance tuning.

set -euo pipefail

LOG_TAG="rocm-powerd-ai"
log() { logger -t "$LOG_TAG" "$*" || echo "$*" >&2; }

AI_CPU_MAX_FREQ_MHZ="${AI_CPU_MAX_FREQ_MHZ:-${CPU_MAX_FREQ_MHZ:-}}"
if [[ -z "$AI_CPU_MAX_FREQ_MHZ" && -n "${CPU_MAX_FREQ_KHZ:-}" ]]; then
    AI_CPU_MAX_FREQ_MHZ=$((CPU_MAX_FREQ_KHZ / 1000))
fi
AI_CPU_MAX_FREQ_MHZ="${AI_CPU_MAX_FREQ_MHZ:-3000}"
AI_SCLK="${AI_SCLK:-2}"
AI_MCLK="${AI_MCLK:-3}"

log "Applying AI mode: cpu_max=${AI_CPU_MAX_FREQ_MHZ}MHz sclk=${AI_SCLK} mclk=${AI_MCLK}"

cpupower frequency-set -u "${AI_CPU_MAX_FREQ_MHZ}MHz"
rocm-smi --setperflevel manual
rocm-smi --setsclk "$AI_SCLK"
rocm-smi --setmclk "$AI_MCLK"

log "AI mode applied"
