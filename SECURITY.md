# Security Policy

AI Usage Bar is designed around a strict "no secrets" rule.

## What the app does not read

- It does not read browser cookies.
- It does not read Claude Desktop storage, IndexedDB, SQLite databases, or cache files.
- It does not read macOS Keychain items.
- It does not ask for Accessibility, Screen Recording, Full Disk Access, or Automation permissions.
- It does not collect session tokens, API keys, conversation content, prompts, or responses.
- It does not send usage data to any third-party server.

## How usage is collected

### Codex / ChatGPT usage

The app starts the local Codex app-server from the installed Codex app and calls:

```text
account/rateLimits/read
```

This returns account rate-limit percentages and reset times through Codex's local process.

### Claude usage

The app uses Claude Code's official statusline integration.

On setup, AI Usage Bar writes a `statusLine` command to:

```text
~/.claude/settings.json
```

The command points to a small native helper:

```text
~/.claude/usage-bar/statusline-bridge
```

Claude Code invokes that helper and passes statusline JSON on stdin. The helper extracts only:

- `rate_limits.five_hour.used_percentage`
- `rate_limits.five_hour.resets_at`
- `rate_limits.seven_day.used_percentage`
- `rate_limits.seven_day.resets_at`
- model display name, when provided

The helper writes a small cache file:

```text
~/.claude/usage-bar/latest.json
```

The menu bar app reads only that cache file.

## Files written by the app

```text
~/.claude/settings.json
~/.claude/usage-bar/statusline-bridge
~/.claude/usage-bar/latest.json
```

If an existing Claude Code statusline command is present, the app preserves a backup under:

```text
~/.claude/usage-bar/previous-statusline.json
```

## Installer behavior

The installer only places the app in `/Applications`.

It does not install login items, daemons, launch agents, kernel extensions, browser extensions, or background services.

Claude setup is performed later from the app UI, so users can inspect the project before enabling the bridge.

## Responsible disclosure

If you find a security issue, please open a private report through GitHub Security Advisories if available, or contact the repository owner privately before publishing details.

## Important note

No software can honestly promise mathematical "zero risk" across all future OS and dependency changes. This project instead keeps the attack surface small, avoids secret-bearing storage, and documents every file and integration point so the behavior is auditable.
