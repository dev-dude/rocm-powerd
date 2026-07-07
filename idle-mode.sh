#!/usr/bin/env bash
# rocm-powerd: Idle mode helper
# Restore automatic GPU power management and default CPU frequencies.

set -e

LOG_TAG="rocm-powerd-idle"
log() { logger -t "$LOG_TAG" "$*" || echo "$*" >&2; }

log "Applying idle mode"

cpupower frequency-set -u 3000MHz || log "cpupower failed"
rocm-smi --resetclocks >/dev/null 2>&1 || log "rocm-smi resetclocks failed"
rocm-smi --setperflevel auto >/dev/null 2>&1 || log "rocm-smi setperflevel failed"
rocm-smi --resetprofile >/dev/null 2>&1 || log "rocm-smi resetprofile failed"

log "Idle mode applied"