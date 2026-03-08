# 🐕 openclaw-watchdog

A lightweight watchdog script that monitors your [OpenClaw](https://github.com/openclaw/openclaw) gateway and auto-restarts it when it goes down.

**Why?** OpenClaw's gateway can occasionally crash due to memory pressure, API timeouts, or long idle periods. This watchdog ensures your AI agent stays online 24/7 without manual intervention.

## Features

- 🏥 **Reliable health checks** — Uses `openclaw health` + HTTP probe (not `pgrep`/`lsof` which are [unreliable on macOS](#why-not-pgrep--lsof))
- 🔄 **Auto-restart** with configurable retries and backoff
- 📋 **Log rotation** — Keeps logs under 10 MB automatically
- 🍎 **macOS LaunchAgent** included — Set-and-forget scheduling
- 🐧 **Linux compatible** — Works with cron or systemd timers
- ⚙️ **Fully configurable** via environment variables

## Quick Start

### 1. Download

```bash
curl -o /usr/local/bin/openclaw-watchdog.sh \
  https://raw.githubusercontent.com/WZBbiao/openclaw-watchdog/main/openclaw-watchdog.sh
chmod +x /usr/local/bin/openclaw-watchdog.sh
```

### 2. Test it

```bash
# Check current gateway status
openclaw-watchdog.sh --status

# Run a health check (with output)
openclaw-watchdog.sh --verbose
```

### 3. Schedule it

<details>
<summary><b>macOS (LaunchAgent) — recommended</b></summary>

```bash
# Download the plist
curl -o ~/Library/LaunchAgents/com.openclaw.watchdog.plist \
  https://raw.githubusercontent.com/WZBbiao/openclaw-watchdog/main/com.openclaw.watchdog.plist

# Load it (starts immediately + every 2 hours)
launchctl load ~/Library/LaunchAgents/com.openclaw.watchdog.plist
```

To unload:
```bash
launchctl unload ~/Library/LaunchAgents/com.openclaw.watchdog.plist
```

</details>

<details>
<summary><b>Linux (cron)</b></summary>

```bash
# Run every 2 hours
crontab -e
# Add this line:
0 */2 * * * /usr/local/bin/openclaw-watchdog.sh
```

</details>

<details>
<summary><b>Linux (systemd timer)</b></summary>

```ini
# /etc/systemd/system/openclaw-watchdog.service
[Unit]
Description=OpenClaw Gateway Watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openclaw-watchdog.sh
User=your-username

# /etc/systemd/system/openclaw-watchdog.timer
[Unit]
Description=Run OpenClaw watchdog every 2 hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=2h

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now openclaw-watchdog.timer
```

</details>

## Usage

```
openclaw-watchdog.sh [OPTIONS]

Options:
  --status    Show current gateway health (no restart)
  --verbose   Print all log messages to stderr
  --help      Show help
```

### Example output

```
$ openclaw-watchdog.sh --status
=== OpenClaw Watchdog Status ===

Health command (openclaw health): OK
HTTP probe (port 18789):      OK
LaunchAgent (ai.openclaw.gateway): RUNNING (PID 12345)

Overall: ✅ HEALTHY
```

## Configuration

All settings can be overridden via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCLAW_BIN` | `openclaw` | Path to the OpenClaw binary |
| `GATEWAY_PORT` | `18789` | Gateway HTTP port to probe |
| `OPENCLAW_WATCHDOG_LOG_DIR` | `~/.openclaw/watchdog` | Log directory |
| `MAX_LOG_BYTES` | `10485760` (10 MB) | Max log size before rotation |
| `MAX_RETRIES` | `3` | Restart attempts before giving up |
| `RETRY_DELAY` | `5` | Seconds between retry attempts |
| `STARTUP_WAIT` | `20` | Seconds to wait for gateway startup |
| `STARTUP_POLL` | `2` | Polling interval during startup |

Example with custom config:

```bash
GATEWAY_PORT=19000 MAX_RETRIES=5 openclaw-watchdog.sh --verbose
```

## How it works

```
┌─────────────────────────────────┐
│   launchd / cron / systemd      │
│   (triggers every 2 hours)      │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│   openclaw-watchdog.sh          │
│                                 │
│   1. openclaw health  ──► OK? ──┼──► Exit (healthy)
│      │                          │
│      ▼ FAIL                     │
│   2. curl :18789/     ──► OK? ──┼──► Exit (healthy)
│      │                          │
│      ▼ FAIL                     │
│   3. Restart gateway            │
│      └─► Retry up to 3x        │
│          └─► Log result         │
└─────────────────────────────────┘
```

## Why not pgrep / lsof?

Previous versions used `pgrep -f "openclaw-gateway"` and `lsof -iTCP:<port>` for health checks. Both are **unreliable on macOS**:

- **pgrep**: OpenClaw's Node.js process sets `process.title = "openclaw-gateway"`, which changes the display name in `ps` but NOT the original command-line args that `pgrep -f` searches. Result: `pgrep` silently fails to find a running gateway.

- **lsof**: Non-root `lsof -iTCP:<port>` can miss processes due to macOS security restrictions (System Integrity Protection).

The current approach uses `openclaw health` (which tests actual RPC connectivity) and `curl` (which tests the HTTP listener directly) — both are immune to these platform quirks.

## Logs

Logs are written to `~/.openclaw/watchdog/watchdog.log`:

```
2024-03-08 22:00:00 [INFO] Watchdog check started
2024-03-08 22:00:03 [INFO] Gateway is healthy — nothing to do
2024-03-08 00:00:00 [INFO] Watchdog check started
2024-03-08 00:00:05 [WARN] Gateway is DOWN — initiating restart sequence
2024-03-08 00:00:05 [INFO] Restart attempt 1/3
2024-03-08 00:00:25 [INFO] Gateway is healthy after 18s
2024-03-08 00:00:25 [INFO] Restart succeeded on attempt 1
```

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT](LICENSE)
