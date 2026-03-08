# Contributing to openclaw-watchdog

Thanks for your interest in contributing! This is a small project, so the process is lightweight.

## How to contribute

1. **Fork** this repository
2. **Create a branch** for your change (`git checkout -b fix/my-fix`)
3. **Make your changes**
4. **Test locally** (see below)
5. **Submit a Pull Request**

## Testing

Before submitting a PR, please test the script:

```bash
# Check syntax
bash -n openclaw-watchdog.sh

# Run status check
./openclaw-watchdog.sh --status

# Run with verbose output
./openclaw-watchdog.sh --verbose

# Test with custom config
GATEWAY_PORT=99999 ./openclaw-watchdog.sh --status  # should show UNHEALTHY
```

## Commit messages

Use clear, descriptive commit messages:

- `fix: handle missing curl on minimal installs`
- `feat: add Discord webhook notification on restart`
- `docs: add systemd timer example`

## What we're looking for

- 🐛 **Bug fixes** — especially platform-specific edge cases
- 🐧 **Linux improvements** — systemd integration, distro-specific fixes
- 📢 **Notification support** — Slack/Discord/email alerts on restart
- 🧪 **Tests** — automated test suite (shellcheck, bats, etc.)
- 📖 **Documentation** — usage examples, FAQ entries

## Code style

- Use `shellcheck` — no warnings
- Quote all variables (`"$VAR"`, not `$VAR`)
- Use `[[ ]]` instead of `[ ]`
- Functions should be documented with a comment

## Questions?

Open an issue — happy to help!
