# 👁️ WANE: Warning & Error System Watcher & Inspector

**WANE** (*Warnings And Errors*) is a lightweight, 24/7 background service for NixOS that captures, parses, and logs all system warnings, errors, critical alerts, and emergencies into a central `wane-log` file, accompanied by a fast terminal CLI (`wane`) to inspect, filter, and clear logs.

---

## ✨ Features

- 🕒 **24/7 Continuous System Monitoring:** Streams logs directly from systemd `journald` (priority 0..4: Emergency, Alert, Critical, Error, Warning).
- 🏷️ **Clean Structured Format:** Every entry is timestamped and categorized:
  ```text
  [2026-09-08 03:25:10] [ERROR] [systemd] Failed to start docker-container.service
  [2026-09-08 03:26:02] [WARN]  [kernel]  iwlwifi: unhandled firmware notification
  ```
- 🔍 **Intuitive Peek Command (`wane --show`):** Filter by count, order (`desc` or `asc`), and type (`error`, `warn`, `all`).
- 🧹 **Instant Purge (`wane --clear`):** Clear the entire log with a single command without needing sudo.
- 📊 **Quick Statistics (`wane --status`):** Summarizes log size, total entries, error count, and warning count.
- 📡 **Live Stream (`wane --follow`):** Live tail of warnings and errors as they happen with color coding.
- 🛡️ **Self-Rotating:** Automatically prevents file bloat if log size exceeds configurable threshold (default: 50MB).

---

## 🚀 CLI Usage

### Quick Peek (`wane --show [number] [order] [type]`)

```bash
# Show the 20 most recent warnings & errors (default)
wane --show

# Peek at the last 10 errors only (newest first)
wane --show 10 desc error

# View the 50 oldest warnings
wane --show 50 asc warn

# View recent 30 entries of all types
wane --show 30 desc all
```

### Clear Log (`wane --clear`)

```bash
wane --clear
```

### Check Status & Error Counts (`wane --status`)

```bash
wane --status
```

### Live Stream in Real-Time (`wane --follow`)

```bash
wane --follow
```

---

## ⚙️ NixOS Integration

Configured under `homelab.shellRepo.waneWatcher`:

```nix
homelab.shellRepo = {
  enable = true;
  waneWatcher = {
    enable = true;
    logFile = "/var/log/wane/wane-log"; # Log file destination
    maxLogSizeMB = 50;                  # Auto-rotate threshold
  };
};
```

This registers:
1. `wane-watcher.service`: Systemd background daemon running `wane --daemon`.
2. `wane`: System-wide command available in any shell.
