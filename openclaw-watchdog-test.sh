#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHDOG="$SCRIPT_DIR/openclaw-watchdog.sh"

TEST_TMP=""
TESTS_RUN=0
TESTS_FAILED=0

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf 'PASS %s\n' "$1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL %s: %s\n' "$1" "$2"
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "missing '$needle'"
    fi
}

setup() {
    TEST_TMP="$(mktemp -d /tmp/openclaw-watchdog-test.XXXXXX)"
    export HOME="$TEST_TMP/home"
    mkdir -p "$HOME/Library/LaunchAgents"
    export OPENCLAW_WATCHDOG_TESTING=1
    export OPENCLAW_WATCHDOG_LOG_DIR="$TEST_TMP/logs"
    export OPENCLAW_BIN="$TEST_TMP/bin/openclaw"
    export OPENCLAW_GATEWAY_PLIST="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
    export OPENCLAW_LAUNCHD_DOMAIN="gui/999"
    export STARTUP_WAIT=2
    export STARTUP_POLL=1
    export CONTROL_TIMEOUT=1
    export RETRY_DELAY=0
    export MAX_RETRIES=1
    mkdir -p "$(dirname "$OPENCLAW_BIN")"
    mkdir -p "$OPENCLAW_WATCHDOG_LOG_DIR"
}

teardown() {
    rm -rf "$TEST_TMP"
    unset HOME OPENCLAW_WATCHDOG_TESTING OPENCLAW_WATCHDOG_LOG_DIR OPENCLAW_BIN
    unset OPENCLAW_GATEWAY_PLIST OPENCLAW_LAUNCHD_DOMAIN STARTUP_WAIT STARTUP_POLL
    unset CONTROL_TIMEOUT RETRY_DELAY MAX_RETRIES
}

source_watchdog() {
    # shellcheck disable=SC1090
    source "$WATCHDOG"
}

write_mock_openclaw() {
    local body="$1"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$OPENCLAW_BIN"
    chmod +x "$OPENCLAW_BIN"
}

test_restart_falls_back_to_start_and_launchctl_when_service_missing() {
    echo "[test] restart fallback uses start and launchctl when restart cannot work"
    setup
    source_watchdog

    local calls=""
    log() { :; }
    wait_for_health() { return 0; }
    check_launchctl() { return 1; }
    is_healthy() { return 1; }
    : > "$OPENCLAW_GATEWAY_PLIST"
    run_control_cmd() {
        calls+="$*"$'\n'
        case "$1" in
            "openclaw gateway restart"|"openclaw gateway start")
                return 1
                ;;
            *)
                return 0
                ;;
        esac
    }

    if restart_gateway; then
        assert_contains "restart attempted first" "$calls" "gateway restart"
        assert_contains "start fallback used" "$calls" "gateway start"
        assert_contains "bootstrap fallback used" "$calls" "launchctl bootstrap"
        assert_contains "kickstart fallback used" "$calls" "launchctl kickstart -k"
    else
        fail "restart fallback uses start and launchctl when restart cannot work" "restart_gateway returned non-zero"
    fi

    teardown
}

test_run_with_timeout_times_out() {
    echo "[test] run_with_timeout returns timeout exit code"
    setup
    source_watchdog

    local rc=0
    run_with_timeout 1 /bin/sh -c 'sleep 2' || rc=$?
    if [[ "$rc" == "124" || "$rc" == "142" ]]; then
        pass "run_with_timeout returns timeout code"
    else
        fail "run_with_timeout returns timeout code" "got '$rc'"
    fi

    teardown
}

test_reload_logs_missing_plist() {
    echo "[test] reload logs when plist is missing"
    setup
    source_watchdog

    local log_lines=""
    log() {
        log_lines+="$*"$'\n'
    }
    wait_for_health() { return 0; }
    check_launchctl() { return 1; }

    write_mock_openclaw 'exit 0'

    if reload_gateway_service; then
        fail "reload logs when plist is missing" "reload_gateway_service returned zero"
    else
        assert_contains "missing plist is reported" "$log_lines" "plist not found"
    fi

    teardown
}

test_show_status_reports_loaded_without_pid() {
    echo "[test] status shows loaded without pid"
    setup
    source_watchdog

    check_health_cmd() { return 1; }
    check_http() { return 1; }
    check_launchctl_running() { return 1; }
    check_launchctl() { return 0; }
    is_healthy() { return 1; }

    local output
    output="$(show_status)"
    assert_contains "loaded status shown" "$output" "LOADED (no active PID)"

    teardown
}

main() {
    test_restart_falls_back_to_start_and_launchctl_when_service_missing
    test_run_with_timeout_times_out
    test_reload_logs_missing_plist
    test_show_status_reports_loaded_without_pid

    printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
    [[ "$TESTS_FAILED" -eq 0 ]]
}

main "$@"
