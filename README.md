# ChatGPT Usage Widget

A tiny native macOS menu bar utility that displays selectable ChatGPT/Codex usage limits.

It was built as a small, practical Swift project: no Electron, no analytics, no credential scraping, and no network calls from the widget itself.

## What It Shows

- Remaining usage percentage from the authoritative Codex account endpoint.
- The official ChatGPT template icon beside the selected percentage in the menu bar.
- A persistent selector for every available limit window, such as Codex weekly,
  Spark 5-hour, and Spark weekly.
- `STALE` when the last real snapshot is older than 180 seconds.
- `UNAVAILABLE` when no trusted local source can be read.
- Last updated time, reset time, source status, confidence, refresh, dashboard shortcut, and quit controls.

## Data Source

The menu bar app starts the locally installed Codex App Server and requests
`account/rateLimits/read`. It reads `rateLimitsByLimitId`, keeps every primary
and secondary window separate, and stores the selected window in macOS
preferences. Activity in one model-specific bucket can no longer silently
replace the selected percentage.

The older helper and JSONL readers remain in the core library for compatibility.

## Legacy Data Sources

The widget uses explicit local sources only:

1. An optional helper command:

   ```sh
   chatgpt-usage-helper --json
   ```

   You can override the helper path with:

   ```sh
   export CHATGPT_USAGE_WIDGET_HELPER=/absolute/path/to/chatgpt-usage-helper
   ```

2. A read-only fallback over local Codex session JSONL files:

   ```text
   ~/.codex/sessions/**/*.jsonl
   ```

   The fallback reads only recent files and only the tail of each file. It extracts `token_count.payload.rate_limits` metadata and ignores conversation content.

The app does not read browser cookies, Keychain items, browser storage, auth files, bearer tokens, or passwords.

## Expected Helper JSON

```json
{
  "source_status": "authorized local helper",
  "metrics": [
    {
      "name": "chatgpt_remaining",
      "value": 82.5,
      "unit": "percent",
      "source": "codex-desktop-local-helper",
      "timestamp": "2026-09-07T16:00:00Z",
      "reset_time": "2026-09-08T00:00:00Z",
      "confidence": 0.98
    }
  ]
}
```

Required metric fields are `name`, `value`, `unit`, `source`, `timestamp`, and `confidence`. `reset_time` is optional.

## Efficiency Notes

- Refreshes every 60 seconds.
- Uses a 10 second timer tolerance so macOS can coalesce background wakeups.
- Prevents overlapping refreshes.
- Inspects only the 12 most recently modified session logs.
- Reads at most 256 KB from the tail of each log file.
- Runs parsing work off the main actor, then updates the menu on the main actor.

## Build

```sh
swift build -c release --product ChatGPTUsageWidget
```

Run from the package directory:

```sh
.build/release/ChatGPTUsageWidget
```

## Tests

This project avoids external dependencies. Parser checks are implemented as a small executable test runner:

```sh
swift run ChatGPTUsageWidgetParserTests
```

## Install On macOS

Build and copy the release binary:

```sh
swift build -c release --product ChatGPTUsageWidget
mkdir -p ~/Applications/ChatGPTUsageWidget
cp .build/release/ChatGPTUsageWidget ~/Applications/ChatGPTUsageWidget/
```

To start it automatically at login, copy and adapt the LaunchAgent template:

```sh
mkdir -p ~/Library/LaunchAgents ~/Library/Logs/ChatGPTUsageWidget
cp Support/com.local.chatgpt-usage-widget.plist.example ~/Library/LaunchAgents/com.local.chatgpt-usage-widget.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.local.chatgpt-usage-widget.plist
launchctl kickstart -k "gui/$(id -u)/com.local.chatgpt-usage-widget"
```

## Uninstall

```sh
launchctl bootout "gui/$(id -u)/com.local.chatgpt-usage-widget" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.local.chatgpt-usage-widget.plist
rm -rf ~/Applications/ChatGPTUsageWidget
```

## License

MIT
