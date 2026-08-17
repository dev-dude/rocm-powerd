#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}

assert_contains() {
    local needle="$1" file="$2"
    grep -F -- "$needle" "$file" >/dev/null || fail "'$needle' not found in $file"
}

make_fixture() {
    FIXTURE="$TEST_TMP/fixture-$1"
    SYSFS="$FIXTURE/sys"
    STATE="$FIXTURE/state"
    MOCK_BIN="$FIXTURE/bin"
    COMMAND_LOG="$FIXTURE/commands.log"
    mkdir -p "$SYSFS/class/powercap/intel-rapl:0"
    mkdir -p "$SYSFS/class/hwmon/hwmon7/device"
    mkdir -p "$SYSFS/class/hwmon/hwmon2"
    mkdir -p "$MOCK_BIN"

    printf '%s\n' 55000000 >"$SYSFS/class/powercap/intel-rapl:0/constraint_0_power_limit_uw"
    printf '%s\n' 45000000 >"$SYSFS/class/powercap/intel-rapl:0/constraint_0_min_power_uw"
    printf '%s\n' 80000000 >"$SYSFS/class/powercap/intel-rapl:0/constraint_0_max_power_uw"
    printf '%s\n' 85000000 >"$SYSFS/class/powercap/intel-rapl:0/constraint_1_power_limit_uw"
    printf '%s\n' 60000000 >"$SYSFS/class/powercap/intel-rapl:0/constraint_1_min_power_uw"
    printf '%s\n' 100000000 >"$SYSFS/class/powercap/intel-rapl:0/constraint_1_max_power_uw"

    printf '%s\n' k10temp >"$SYSFS/class/hwmon/hwmon2/name"
    printf '%s\n' amdgpu >"$SYSFS/class/hwmon/hwmon7/name"
    printf '%s\n' 280000000 >"$SYSFS/class/hwmon/hwmon7/power1_cap"
    printf '%s\n' 100000000 >"$SYSFS/class/hwmon/hwmon7/power1_cap_min"
    printf '%s\n' 300000000 >"$SYSFS/class/hwmon/hwmon7/power1_cap_max"
    printf '0: 500Mhz\n1: 1500Mhz *\n2: 2400Mhz\n' >"$SYSFS/class/hwmon/hwmon7/device/pp_dpm_sclk"
    printf '0: 96Mhz *\n1: 1250Mhz\n' >"$SYSFS/class/hwmon/hwmon7/device/pp_dpm_mclk"
    printf '%s\n' auto >"$SYSFS/class/hwmon/hwmon7/device/power_dpm_force_performance_level"

    cat >"$MOCK_BIN/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat >"$MOCK_BIN/cpupower" <<'EOF'
#!/usr/bin/env bash
printf 'cpupower %s\n' "$*" >>"$COMMAND_LOG"
EOF
    cat >"$MOCK_BIN/rocm-smi" <<'EOF'
#!/usr/bin/env bash
if [[ $# -eq 0 && -n "${MOCK_GPU_POWER_W:-}" ]]; then
    printf '0 card0 %sW\n' "$MOCK_GPU_POWER_W"
    exit 0
fi
printf 'rocm-smi %s\n' "$*" >>"$COMMAND_LOG"
EOF
    chmod +x "$MOCK_BIN/logger" "$MOCK_BIN/cpupower" "$MOCK_BIN/rocm-smi"
    : >"$COMMAND_LOG"
}

run_ai() {
    env PATH="$MOCK_BIN:$PATH" COMMAND_LOG="$COMMAND_LOG" \
        ROCM_POWERD_SYSFS_ROOT="$SYSFS" ROCM_POWERD_STATE_DIR="$STATE" \
        "$@" bash "$REPO_DIR/ai-mode.sh"
}

run_idle() {
    env PATH="$MOCK_BIN:$PATH" COMMAND_LOG="$COMMAND_LOG" \
        ROCM_POWERD_SYSFS_ROOT="$SYSFS" ROCM_POWERD_STATE_DIR="$STATE" \
        "$@" bash "$REPO_DIR/idle-mode.sh"
}

test_defaults_and_restore() {
    make_fixture defaults
    run_ai

    assert_eq 65000000 "$(<"$SYSFS/class/powercap/intel-rapl:0/constraint_0_power_limit_uw")" "default PL1"
    assert_eq 90000000 "$(<"$SYSFS/class/powercap/intel-rapl:0/constraint_1_power_limit_uw")" "default PL2"
    assert_eq 294000000 "$(<"$SYSFS/class/hwmon/hwmon7/power1_cap")" "default GPU cap"
    assert_contains $'cpu\t' "$STATE/original-state"
    assert_contains $'gpu\t' "$STATE/original-state"
    assert_contains 'rocm-smi --setsclk 2' "$COMMAND_LOG"
    assert_contains 'rocm-smi --setmclk 1' "$COMMAND_LOG"

    run_idle
    assert_eq 55000000 "$(<"$SYSFS/class/powercap/intel-rapl:0/constraint_0_power_limit_uw")" "restored PL1"
    assert_eq 85000000 "$(<"$SYSFS/class/powercap/intel-rapl:0/constraint_1_power_limit_uw")" "restored PL2"
    assert_eq 280000000 "$(<"$SYSFS/class/hwmon/hwmon7/power1_cap")" "restored GPU cap"
    [[ -e "$STATE/original-state" ]] || fail "idle mode did not retain its idempotent restore baseline"
    [[ ! -e "$STATE/ai-active" ]] || fail "idle mode left the AI-active marker in place"
    assert_contains 'rocm-smi --setsclk 1' "$COMMAND_LOG"
    assert_contains 'rocm-smi --setmclk 0' "$COMMAND_LOG"
    assert_contains 'rocm-smi --setperflevel auto' "$COMMAND_LOG"

    printf '%s\n' 70000000 >"$SYSFS/class/powercap/intel-rapl:0/constraint_0_power_limit_uw"
    run_idle
    assert_eq 55000000 "$(<"$SYSFS/class/powercap/intel-rapl:0/constraint_0_power_limit_uw")" "repeated idle restore"

    printf '%s\n' 60000000 >"$SYSFS/class/powercap/intel-rapl:0/constraint_0_power_limit_uw"
    run_ai
    assert_contains $'cpu\t'"$SYSFS/class/powercap/intel-rapl:0/constraint_0_power_limit_uw"$'\t60000000' \
        "$STATE/original-state"
}

test_clamping_and_idempotent_snapshot() {
    make_fixture clamp
    run_ai AI_CPU_PL1_WATTS=30 AI_CPU_PL2_WATTS=150 AI_GPU_POWER_CAP_WATTS=500 \
        AI_SCLK_LEVEL=9 AI_MCLK_LEVEL=9
    cp "$STATE/original-state" "$FIXTURE/first-state"

    assert_eq 45000000 "$(<"$SYSFS/class/powercap/intel-rapl:0/constraint_0_power_limit_uw")" "clamped PL1"
    assert_eq 100000000 "$(<"$SYSFS/class/powercap/intel-rapl:0/constraint_1_power_limit_uw")" "clamped PL2"
    assert_eq 300000000 "$(<"$SYSFS/class/hwmon/hwmon7/power1_cap")" "clamped GPU cap"
    assert_contains 'rocm-smi --setsclk 2' "$COMMAND_LOG"
    assert_contains 'rocm-smi --setmclk 1' "$COMMAND_LOG"

    run_ai AI_CPU_PL1_WATTS=30 AI_CPU_PL2_WATTS=150 AI_GPU_POWER_CAP_WATTS=500 \
        AI_SCLK_LEVEL=9 AI_MCLK_LEVEL=9
    cmp -s "$FIXTURE/first-state" "$STATE/original-state" || fail "repeated AI mode replaced the original snapshot"
}

test_daemon_exports_new_config_keys() {
    make_fixture config
    ENV_LOG="$FIXTURE/environment.log"
    CONFIG_FILE="$FIXTURE/rocm-powerd.toml"
    CAPTURE_ENV="$FIXTURE/capture-env.sh"

    cat >"$CAPTURE_ENV" <<'EOF'
#!/usr/bin/env bash
printf '%s %s %s %s %s\n' "$AI_CPU_PL1_WATTS" "$AI_CPU_PL2_WATTS" \
    "$AI_GPU_POWER_CAP_WATTS" "$AI_SCLK_LEVEL" "$AI_MCLK_LEVEL" >"$ENV_LOG"
EOF
    chmod +x "$CAPTURE_ENV"
    cat >"$CONFIG_FILE" <<EOF
[powermanager]
busy_watt = 1
idle_watt = 0
idle_duration_sec = 30
poll_interval = 3
busy_trigger_count = 1

[scripts]
ai = "$CAPTURE_ENV"
idle = ""

[ai_mode]
cpu_pl1_watts = 61
cpu_pl2_watts = 87
gpu_power_cap_watts = 275
sclk_level = 1
mclk_level = 0
EOF

    env PATH="$MOCK_BIN:$PATH" COMMAND_LOG="$COMMAND_LOG" ENV_LOG="$ENV_LOG" \
        MOCK_GPU_POWER_W=10 bash "$REPO_DIR/gpu-auto-mode.sh" --once --config "$CONFIG_FILE"
    assert_eq '61 87 275 1 0' "$(<"$ENV_LOG")" "daemon config exports"
}

test_invalid_limits_fail_before_mutation() {
    make_fixture invalid
    if run_ai AI_CPU_PL1_WATTS=not-a-number; then
        fail "invalid power limit was accepted"
    fi
    [[ ! -e "$STATE/original-state" ]] || fail "invalid input captured state before validation"
    [[ ! -s "$COMMAND_LOG" ]] || fail "invalid input ran tuning commands before validation"
}

test_defaults_and_restore
test_clamping_and_idempotent_snapshot
test_daemon_exports_new_config_keys
test_invalid_limits_fail_before_mutation
echo "All rocm-powerd tests passed"
