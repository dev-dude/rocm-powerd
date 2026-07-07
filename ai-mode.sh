#!/usr/bin/env bash
# rocm-powerd: AI mode helper
# Apply AI mode performance tuning.

set -e

LOG_TAG="rocm-powerd-ai"
log() { logger -t "$LOG_TAG" "$*" || echo "$*" >&2; }

log "Applying AI mode"

cpupower frequency-set -u 3000MHz || log "cpupower failed"
rocm-smi --setperflevel manual >/dev/null 2>&1 || log "rocm-smi setperflevel failed"
rocm-smi --setsclk 2 >/dev/null 2>&1 || log "rocm-smi setsclk failed"
rocm-smi --setmclk 3 >/dev/null 2>&1 || log "rocm-smi setmclk failed"

log "AI mode applied"