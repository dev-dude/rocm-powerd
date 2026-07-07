#!/usr/bin/env bash
# rocm-powerd: GPU power based auto-mode daemon
# Improved, configurable, and packaged for open-sourcing.

set -euo pipefail

PROG_NAME="rocm-powerd"
LOG_TAG="rocm-powerd"

usage() {
    cat <<EOF
Usage: $0 [--config PATH] [--daemon|--once|--status]

Options:
    --config PATH   Path to TOML config (default: search /etc and ~/.config)
    --daemon        Run as a long-running daemon (default)
    --once          Run a single check and apply appropriate mode
    --status        Print current GPU power and mode (no changes)
    -h, --help      Show this help
EOF
}

log() { logger -t "$LOG_TAG" "$*" || echo "$*" >&2; }
err() { log "ERROR: $*"; }

# TOML reader: find a key under a section. Simple and works for basic values.
toml_get() {
    local section="$1" key="$2" default="$3" file="$4"
    awk -v section="[$section]" -v key="$key" -v default="$default" '
        BEGIN{found=0}
        $0 ~ /^\s*\[/ {found = ($0==section)}
        found && $0 ~ "^\s*"key"\s*=\s*" { 
            line=$0; gsub(/^[^=]*=\s*/,"",line); gsub(/\s*#.*/,"",line); gsub(/"/,"",line); gsub(/\r/,"",line); gsub("\"","",line); print line; exit
        }
        END{ if (NR && !found) print default }
    ' "$file" | sed -n '1p'
}

# Determine configuration file path
find_config() {
    local candidates=("/etc/rocm-powerd/rocm-powerd.toml" "$HOME/.config/rocm-powerd/rocm-powerd.toml" "./rocm-powerd.toml")
    if [[ -n "${CONFIG:-}" && -f "$CONFIG" ]]; then
        echo "$CONFIG"
        return
    fi
    for c in "${candidates[@]}"; do
        if [[ -f "$c" ]]; then
            echo "$c"; return
        fi
    done
    # not found
    return 1
}

# Get GPU power (watts). Tries rocm-smi first, falls back to sysfs hwmon.
get_gpu_power() {
    local out max=0
    if command -v rocm-smi >/dev/null 2>&1; then
        out=$(rocm-smi --showpower 2>/dev/null || true)
        # parse power values and normalize mW to W
        while IFS= read -r line; do
            if [[ $line =~ ([0-9]+(\.[0-9]+)?)\s*([mM]?W)? ]]; then
                val=${BASH_REMATCH[1]}
                unit=${BASH_REMATCH[3]:-}
                val=${val%.*}
                if [[ -z "$unit" || ${unit,,} == "w" ]]; then
                    if (( val > 10000 )); then
                        # likely raw milliwatts reported without proper unit normalization
                        val=$(( val / 1000 ))
                    fi
                fi
                if [[ ${unit,,} == "mw" ]]; then
                    val=$(( val / 1000 ))
                fi
                (( val > max )) && max=$val
            fi
        done <<<"$out"
        if (( max > 0 )); then
            echo "$max"; return 0
        fi
    fi
    # fallback: try hwmon power input
    for p in /sys/class/hwmon/hwmon*/power1_input /sys/class/hwmon/hwmon*/power1_average; do
        if [[ -r $p ]]; then
            val=$(cat "$p" 2>/dev/null || true)
            if [[ $val =~ ^[0-9]+$ ]]; then
                # some sensors report mW
                if (( val > 10000 )); then
                    val=$((val/1000))
                fi
                (( val > max )) && max=$val
            fi
        fi
    done
    echo "$((max>0?max:0))"
}

apply_cmd() {
    local cmd="$1"
    if [[ -z "$cmd" ]]; then
        log "No command configured for this mode"
        return 0
    fi
    log "Executing: $cmd"
    # Run in a subshell to avoid altering daemon environment
    bash -c "$cmd" >/dev/null 2>&1 || log "Command failed: $cmd"
}

MODE="idle"

# defaults
BUSY_WATTS=120
IDLE_WATTS=80
IDLE_DURATION_SEC=300
POLL_INTERVAL=3
BUSY_TRIGGER_COUNT=1
IDLE_TRIGGER_COUNT=0
AI_CMD="./ai-mode.sh"
IDLE_CMD="./idle-mode.sh"

# CLI parsing
MODE_FLAG="daemon"
CONFIG=""
while [[ ${1:-} != "" ]]; do
    case "$1" in
        --config) CONFIG="$2"; shift 2;;
        --once) MODE_FLAG=once; shift;;
        --daemon) MODE_FLAG=daemon; shift;;
        --status) MODE_FLAG=status; shift;;
        -h|--help) usage; exit 0;;
        *) echo "Unknown arg: $1"; usage; exit 2;;
    esac
done

CFG_PATH=""
if cfg=$(find_config); then
    CFG_PATH="$cfg"
    log "Using config: $CFG_PATH"
else
    log "No config found; using built-in defaults"
fi

if [[ -n "$CFG_PATH" ]]; then
    BUSY_WATTS=$(toml_get powermanager busy_watt "$BUSY_WATTS" "$CFG_PATH" )
    IDLE_WATTS=$(toml_get powermanager idle_watt "$IDLE_WATTS" "$CFG_PATH" )
    IDLE_DURATION_SEC=$(toml_get powermanager idle_duration_sec "$IDLE_DURATION_SEC" "$CFG_PATH" )
    POLL_INTERVAL=$(toml_get powermanager poll_interval "$POLL_INTERVAL" "$CFG_PATH" )
    BUSY_TRIGGER_COUNT=$(toml_get powermanager busy_trigger_count "$BUSY_TRIGGER_COUNT" "$CFG_PATH" )
    AI_CMD=$(toml_get scripts ai "${AI_CMD}" "$CFG_PATH" )
    IDLE_CMD=$(toml_get scripts idle "${IDLE_CMD}" "$CFG_PATH" )
fi

# compute trigger count for idle based on duration
if [[ -n "$IDLE_DURATION_SEC" && -n "$POLL_INTERVAL" ]]; then
    IDLE_TRIGGER_COUNT=$(( IDLE_DURATION_SEC / POLL_INTERVAL ))
fi

busy_count=0
idle_count=0

# Export tuning values to helper scripts (they inherit environment)
if [[ -n "$CFG_PATH" ]]; then
  CPU_MAX_FREQ_KHZ=$(toml_get tuning cpu_max_freq_khz "" "$CFG_PATH" )
  if [[ -n "$CPU_MAX_FREQ_KHZ" && "$CPU_MAX_FREQ_KHZ" != "" ]]; then
    export CPU_MAX_FREQ_KHZ
    log "Exported CPU_MAX_FREQ_KHZ=${CPU_MAX_FREQ_KHZ}"
  fi
fi

do_check_and_apply() {
    local power
    power=$(get_gpu_power)
    power=${power:-0}
    if (( power >= BUSY_WATTS )); then
        busy_count=$((busy_count+1)); idle_count=0
    elif (( power <= IDLE_WATTS )); then
        idle_count=$((idle_count+1)); busy_count=0
    else
        busy_count=0; idle_count=0
    fi

    log "mode=$MODE power=${power}W busy=${busy_count} idle=${idle_count}"

    if [[ "$MODE" == "idle" && $busy_count -ge $BUSY_TRIGGER_COUNT ]]; then
        log ">>> switching to AI mode"
        apply_cmd "$AI_CMD"
        MODE="ai"
        busy_count=0; idle_count=0
    fi

    if [[ "$MODE" == "ai" && $idle_count -ge $IDLE_TRIGGER_COUNT ]]; then
        log ">>> switching to IDLE mode"
        apply_cmd "$IDLE_CMD"
        MODE="idle"
        busy_count=0; idle_count=0
    fi
}

if [[ "$MODE_FLAG" == "status" ]]; then
    power=$(get_gpu_power)
    echo "power=${power}W mode=${MODE}"
    exit 0
fi

if [[ "$MODE_FLAG" == "once" ]]; then
    do_check_and_apply
    exit 0
fi

log "Starting daemon (poll interval ${POLL_INTERVAL}s)"
# ensure initial idle mode applied to start
apply_cmd "$IDLE_CMD"

while true; do
    do_check_and_apply
    sleep "$POLL_INTERVAL"
done
