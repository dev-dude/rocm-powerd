#!/usr/bin/env bash
# Shared power-limit discovery, validation, and state helpers for rocm-powerd.

ROCM_POWERD_SYSFS_ROOT="${ROCM_POWERD_SYSFS_ROOT:-/sys}"
ROCM_POWERD_STATE_DIR="${ROCM_POWERD_STATE_DIR:-/run/rocm-powerd}"

is_positive_number() {
    [[ ${1:-} =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v value="$1" 'BEGIN { exit !(value > 0) }'
}

watts_to_microwatts() {
    awk -v watts="$1" 'BEGIN { printf "%.0f\n", watts * 1000000 }'
}

clamp_to_sysfs_bounds() {
    local requested="$1" value="$1" min_file="${2:-}" max_file="${3:-}" bound

    if [[ -n "$min_file" && -r "$min_file" ]]; then
        bound=$(<"$min_file")
        if [[ $bound =~ ^[0-9]+$ ]] && (( value < bound )); then
            value=$bound
        fi
    fi
    if [[ -n "$max_file" && -r "$max_file" ]]; then
        bound=$(<"$max_file")
        if [[ $bound =~ ^[0-9]+$ ]] && (( value > bound )); then
            value=$bound
        fi
    fi

    if (( value != requested )); then
        log "Clamped ${requested}uW to ${value}uW using limits for ${min_file:-$max_file}"
    fi
    printf '%s\n' "$value"
}

write_if_changed() {
    local path="$1" value="$2" current
    current=$(<"$path")
    if [[ "$current" == "$value" ]]; then
        return 0
    fi
    printf '%s\n' "$value" >"$path"
}

find_rapl_constraint_files() {
    local zone base constraint
    shopt -s nullglob
    for zone in "$ROCM_POWERD_SYSFS_ROOT"/class/powercap/intel-rapl:*; do
        [[ -d "$zone" ]] || continue
        base=${zone##*/}
        [[ $base =~ ^intel-rapl:[0-9]+$ ]] || continue
        for constraint in 0 1; do
            [[ -f "$zone/constraint_${constraint}_power_limit_uw" ]] &&
                printf '%s\n' "$zone/constraint_${constraint}_power_limit_uw"
        done
    done
    shopt -u nullglob
}

find_amd_gpu_power_caps() {
    local name_file hwmon_dir
    shopt -s nullglob
    for name_file in "$ROCM_POWERD_SYSFS_ROOT"/class/hwmon/hwmon*/name; do
        [[ -r "$name_file" ]] || continue
        [[ "$(<"$name_file")" == "amdgpu" ]] || continue
        hwmon_dir=${name_file%/name}
        [[ -f "$hwmon_dir/power1_cap" ]] && printf '%s\n' "$hwmon_dir/power1_cap"
    done
    shopt -u nullglob
}

find_amd_gpu_device_file() {
    local filename="$1" name_file hwmon_dir
    shopt -s nullglob
    for name_file in "$ROCM_POWERD_SYSFS_ROOT"/class/hwmon/hwmon*/name; do
        [[ -r "$name_file" ]] || continue
        [[ "$(<"$name_file")" == "amdgpu" ]] || continue
        hwmon_dir=${name_file%/name}
        if [[ -r "$hwmon_dir/device/$filename" ]]; then
            printf '%s\n' "$hwmon_dir/device/$filename"
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

selected_clock_level() {
    local clock_file="$1" line
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*([0-9]+):.*\* ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <"$clock_file"
    return 1
}

clamp_clock_level() {
    local requested="$1" clock_file="$2" line min="" max="" level
    [[ $requested =~ ^[0-9]+$ ]] || return 1

    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*([0-9]+): ]]; then
            level=${BASH_REMATCH[1]}
            [[ -z "$min" || $level -lt $min ]] && min=$level
            [[ -z "$max" || $level -gt $max ]] && max=$level
        fi
    done <"$clock_file"

    if [[ -n "$min" && $requested -lt $min ]]; then
        printf '%s\n' "$min"
    elif [[ -n "$max" && $requested -gt $max ]]; then
        printf '%s\n' "$max"
    else
        printf '%s\n' "$requested"
    fi
}

capture_original_state() {
    local state_file="$ROCM_POWERD_STATE_DIR/original-state" path value
    local active_file="$ROCM_POWERD_STATE_DIR/ai-active"
    local sclk_file mclk_file perf_file

    [[ -f "$state_file" && -f "$active_file" ]] && return 0
    mkdir -p "$ROCM_POWERD_STATE_DIR"

    {
        while IFS= read -r path; do
            [[ -r "$path" ]] || continue
            value=$(<"$path")
            [[ $value =~ ^[0-9]+$ ]] && printf 'cpu\t%s\t%s\n' "$path" "$value"
        done < <(find_rapl_constraint_files)

        while IFS= read -r path; do
            [[ -r "$path" ]] || continue
            value=$(<"$path")
            [[ $value =~ ^[0-9]+$ ]] && printf 'gpu\t%s\t%s\n' "$path" "$value"
        done < <(find_amd_gpu_power_caps)

        if sclk_file=$(find_amd_gpu_device_file pp_dpm_sclk) && value=$(selected_clock_level "$sclk_file"); then
            printf 'sclk\t%s\n' "$value"
        fi
        if mclk_file=$(find_amd_gpu_device_file pp_dpm_mclk) && value=$(selected_clock_level "$mclk_file"); then
            printf 'mclk\t%s\n' "$value"
        fi
        if perf_file=$(find_amd_gpu_device_file power_dpm_force_performance_level); then
            value=$(<"$perf_file")
            [[ -n "$value" ]] && printf 'perf\t%s\n' "$value"
        fi
    } >"$state_file.tmp"
    mv "$state_file.tmp" "$state_file"
    : >"$active_file"
}

apply_cpu_power_limits() {
    local pl1_watts="$1" pl2_watts="$2" path base index requested value
    is_positive_number "$pl1_watts" || { log "Invalid cpu_pl1_watts: $pl1_watts"; return 1; }
    is_positive_number "$pl2_watts" || { log "Invalid cpu_pl2_watts: $pl2_watts"; return 1; }

    while IFS= read -r path; do
        base=${path%_power_limit_uw}
        index=${base##*_}
        if [[ $index == 0 ]]; then
            requested=$(watts_to_microwatts "$pl1_watts")
        else
            requested=$(watts_to_microwatts "$pl2_watts")
        fi
        value=$(clamp_to_sysfs_bounds "$requested" "${base}_min_power_uw" "${base}_max_power_uw")
        write_if_changed "$path" "$value"
    done < <(find_rapl_constraint_files)
}

apply_gpu_power_cap() {
    local watts="$1" path base requested value found=0
    is_positive_number "$watts" || { log "Invalid gpu_power_cap_watts: $watts"; return 1; }
    requested=$(watts_to_microwatts "$watts")

    while IFS= read -r path; do
        found=1
        base=${path%_cap}
        value=$(clamp_to_sysfs_bounds "$requested" "${base}_cap_min" "${base}_cap_max")
        write_if_changed "$path" "$value"
    done < <(find_amd_gpu_power_caps)

    if (( ! found )); then
        log "No AMD GPU hwmon power1_cap found; GPU power cap was not changed"
    fi
}

restore_saved_power_limits() {
    local state_file="$ROCM_POWERD_STATE_DIR/original-state" kind path value
    [[ -r "$state_file" ]] || return 0
    while IFS=$'\t' read -r kind path value; do
        case "$kind" in
            cpu|gpu)
                [[ -f "$path" && $value =~ ^[0-9]+$ ]] && write_if_changed "$path" "$value"
                ;;
        esac
    done <"$state_file"
}

saved_state_value() {
    local wanted="$1" state_file="$ROCM_POWERD_STATE_DIR/original-state" kind value
    [[ -r "$state_file" ]] || return 1
    while IFS=$'\t' read -r kind value _; do
        if [[ "$kind" == "$wanted" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done <"$state_file"
    return 1
}

mark_state_idle() {
    local active_file="$ROCM_POWERD_STATE_DIR/ai-active"
    if [[ -e "$active_file" ]]; then
        rm -f -- "$active_file"
    fi
}
