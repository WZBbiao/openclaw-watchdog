#!/usr/bin/env bash
# openclaw-watchdog.sh - Monitor and auto-restart OpenClaw gateway
#
# Usage:
#   ./openclaw-watchdog.sh              # Run a single health check (for cron/launchd)
#   ./openclaw-watchdog.sh --status     # Show current status without restarting
#   ./openclaw-watchdog.sh --verbose    # Run with console output
#
# Exit codes:
#   0 - Gateway is healthy (or was successfully restarted)
#   1 - All restart attempts failed

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment)
# ---------------------------------------------------------------------------
OPENCLAW_BIN="${OPENCLAW_BIN:-}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
GATEWAY_LABEL="${OPENCLAW_GATEWAY_LABEL:-ai.openclaw.gateway}"
LAUNCHD_DOMAIN="${OPENCLAW_LAUNCHD_DOMAIN:-gui/$UID}"
GATEWAY_PLIST="${OPENCLAW_GATEWAY_PLIST:-$HOME/Library/LaunchAgents/${GATEWAY_LABEL}.plist}"
LOG_DIR="${OPENCLAW_WATCHDOG_LOG_DIR:-$HOME/.openclaw/watchdog}"
LOG_FILE="${LOG_DIR}/watchdog.log"
MAX_LOG_BYTES="${MAX_LOG_BYTES:-$((10 * 1024 * 1024))}"  # 10 MB
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"
STARTUP_WAIT="${STARTUP_WAIT:-20}"
STARTUP_POLL="${STARTUP_POLL:-2}"
CONTROL_TIMEOUT="${CONTROL_TIMEOUT:-15}"
VERBOSE="${VERBOSE:-0}"

resolve_openclaw_bin() {
    local candidate
    if [[ -n "$OPENCLAW_BIN" ]]; then
        echo "$OPENCLAW_BIN"
        return 0
    fi

    for candidate in \
        "$(command -v openclaw 2>/dev/null || true)" \
        /usr/local/bin/openclaw \
        /opt/homebrew/bin/openclaw
    do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local msg="$ts [$level] $*"

    [[ -d "$LOG_DIR" ]] || mkdir -p "$LOG_DIR"
    echo "$msg" >> "$LOG_FILE"

    if [[ "$VERBOSE" == "1" ]] || [[ "$level" == "WARN" ]] || [[ "$level" == "ERROR" ]]; then
        echo "$msg" >&2
    fi
}

# ---------------------------------------------------------------------------
# Log rotation — keep one backup
# ---------------------------------------------------------------------------
rotate_log() {
    [[ -f "$LOG_FILE" ]] || return 0
    local size
    size="$(stat -f%z "$LOG_FILE" 2>/dev/null || stat --format=%s "$LOG_FILE" 2>/dev/null || echo 0)"
    if (( size > MAX_LOG_BYTES )); then
        mv "$LOG_FILE" "${LOG_FILE}.1"
        log INFO "Log rotated (previous size: ${size} bytes)"
    fi
}

# ---------------------------------------------------------------------------
# Health checks
#
# Why not pgrep / lsof?
# On macOS, OpenClaw's Node.js process sets process.title to
# "openclaw-gateway", which changes the display name in `ps` but NOT
# the original command-line args that pgrep -f searches. This means
# `pgrep -f "openclaw-gateway"` silently fails. Similarly, non-root
# `lsof -iTCP:<port>` can miss processes due to macOS permissions.
#
# The most reliable checks are:
#   1. `openclaw health` — tests actual RPC connectivity
#   2. HTTP probe — tests the gateway's HTTP listener directly
#   3. launchctl — checks the LaunchAgent service state
# ---------------------------------------------------------------------------

check_health_cmd() {
    "$OPENCLAW_BIN" health > /dev/null 2>&1
}

check_http() {
    curl -sf -o /dev/null --connect-timeout 5 "http://127.0.0.1:${GATEWAY_PORT}/" 2>/dev/null
}

gateway_pid() {
    local pid
    pid="$(launchctl list 2>/dev/null | awk -v label="$GATEWAY_LABEL" '$3 == label { print $1 }')"
    echo "$pid"
}

check_launchctl() {
    launchctl print "${LAUNCHD_DOMAIN}/${GATEWAY_LABEL}" > /dev/null 2>&1
}

check_launchctl_running() {
    local pid
    pid="$(gateway_pid)"
    [[ -n "$pid" && "$pid" != "-" ]]
}

# Combined: healthy if CLI health check passes OR HTTP probe succeeds.
is_healthy() {
    check_health_cmd || check_http
}

wait_for_health() {
    local elapsed=0
    while (( elapsed < STARTUP_WAIT )); do
        sleep "$STARTUP_POLL"
        (( elapsed += STARTUP_POLL ))
        if is_healthy; then
            log INFO "Gateway is healthy after ${elapsed}s"
            return 0
        fi
    done

    log ERROR "Gateway not healthy after ${STARTUP_WAIT}s"
    return 1
}

run_with_timeout() {
    local timeout_secs="$1"
    shift
    env LC_ALL=C LANG=C /usr/bin/perl -e '
        my $timeout = shift @ARGV;
        my $pid = fork();
        exit 125 unless defined $pid;
        if ($pid == 0) {
            exec @ARGV;
            exit 127;
        }
        $SIG{ALRM} = sub {
            kill 9, $pid;
            waitpid($pid, 0);
            exit 124;
        };
        alarm $timeout;
        waitpid($pid, 0);
        my $status = $?;
        exit(($status & 127) ? (128 + ($status & 127)) : ($status >> 8));
    ' "$timeout_secs" "$@"
}

run_control_cmd() {
    local description="$1"
    shift
    local rc=0
    run_with_timeout "$CONTROL_TIMEOUT" "$@" >> "$LOG_FILE" 2>&1 || rc=$?
    if (( rc == 124 || rc == 142 )); then
        log WARN "$description timed out after ${CONTROL_TIMEOUT}s"
    fi
    return "$rc"
}

reload_gateway_service() {
    if [[ ! -f "$GATEWAY_PLIST" ]]; then
        log WARN "Gateway LaunchAgent plist not found at $GATEWAY_PLIST"
        return 1
    fi

    if ! check_launchctl; then
        log WARN "Gateway LaunchAgent exists but is not loaded"
        log INFO "Bootstrapping gateway service via: launchctl bootstrap ${LAUNCHD_DOMAIN} $GATEWAY_PLIST"
        run_control_cmd "launchctl bootstrap" launchctl bootstrap "$LAUNCHD_DOMAIN" "$GATEWAY_PLIST" || true
    fi

    log INFO "Kickstarting gateway service via: launchctl kickstart -k ${LAUNCHD_DOMAIN}/${GATEWAY_LABEL}"
    run_control_cmd "launchctl kickstart" launchctl kickstart -k "${LAUNCHD_DOMAIN}/${GATEWAY_LABEL}" || true

    wait_for_health
}

# ---------------------------------------------------------------------------
# Restart gateway via openclaw CLI
# ---------------------------------------------------------------------------
restart_gateway() {
    log INFO "Restarting gateway via: $OPENCLAW_BIN gateway restart"
    if run_control_cmd "openclaw gateway restart" "$OPENCLAW_BIN" gateway restart && wait_for_health; then
        return 0
    fi

    log WARN "Gateway restart did not recover the service; trying gateway start"
    if run_control_cmd "openclaw gateway start" "$OPENCLAW_BIN" gateway start && wait_for_health; then
        return 0
    fi

    log WARN "Gateway start did not recover the service; trying launchctl bootstrap/kickstart"
    reload_gateway_service
}

# ---------------------------------------------------------------------------
# Status display (--status flag)
# ---------------------------------------------------------------------------
show_status() {
    echo "=== OpenClaw Watchdog Status ==="
    echo ""

    printf "Health command (openclaw health): "
    if check_health_cmd; then
        echo "OK"
    else
        echo "FAILED"
    fi

    printf "HTTP probe (port $GATEWAY_PORT):      "
    if check_http; then
        echo "OK"
    else
        echo "FAILED"
    fi

    printf "LaunchAgent (ai.openclaw.gateway): "
    if check_launchctl_running; then
        local pid
        pid="$(gateway_pid)"
        echo "RUNNING (PID $pid)"
    elif check_launchctl; then
        echo "LOADED (no active PID)"
    else
        echo "NOT LOADED"
    fi

    echo ""
    if is_healthy; then
        echo "Overall: ✅ HEALTHY"
    else
        echo "Overall: ❌ UNHEALTHY"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local status_only=0
    for arg in "$@"; do
        case "$arg" in
            --status)  status_only=1 ;;
            --verbose) VERBOSE=1 ;;
            --help|-h)
                echo "Usage: $0 [--status] [--verbose] [--help]"
                exit 0
                ;;
            *)
                echo "Unknown option: $arg" >&2
                exit 1
                ;;
        esac
    done

    if ! OPENCLAW_BIN="$(resolve_openclaw_bin)"; then
        if (( status_only )); then
            echo "OpenClaw CLI not found. Set OPENCLAW_BIN or add openclaw to PATH." >&2
            exit 1
        fi

        mkdir -p "$LOG_DIR"
        log ERROR "OpenClaw CLI not found. Set OPENCLAW_BIN or add openclaw to PATH."
        exit 1
    fi

    if (( status_only )); then
        show_status
        exit 0
    fi

    mkdir -p "$LOG_DIR"
    rotate_log

    if ! [[ -x "$OPENCLAW_BIN" ]]; then
        log ERROR "OpenClaw CLI not found. Set OPENCLAW_BIN or add openclaw to PATH."
        exit 1
    fi

    log INFO "Watchdog check started"

    if is_healthy; then
        log INFO "Gateway is healthy — nothing to do"
        exit 0
    fi

    log WARN "Gateway is DOWN — initiating restart sequence"

    local attempt=1
    while (( attempt <= MAX_RETRIES )); do
        log INFO "Restart attempt $attempt/$MAX_RETRIES"
        if restart_gateway; then
            log INFO "Restart succeeded on attempt $attempt"
            exit 0
        fi
        log WARN "Restart attempt $attempt failed"
        (( attempt++ ))
        if (( attempt <= MAX_RETRIES )); then
            log INFO "Waiting ${RETRY_DELAY}s before next attempt..."
            sleep "$RETRY_DELAY"
        fi
    done

    log ERROR "All $MAX_RETRIES restart attempts FAILED"
    exit 1
}

if [[ "${OPENCLAW_WATCHDOG_TESTING:-}" != "1" ]]; then
    main "$@"
fi
