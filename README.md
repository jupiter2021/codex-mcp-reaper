# codex-mcp-reaper

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Windows-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE)

**English** · [简体中文](README.zh-CN.md)

Reclaim the **idle, leaked** stdio MCP server processes that the **codex (ChatGPT desktop app)** app-server piles up. Pure process-level, zero dependencies, fully background with no popup window. Windows + PowerShell 5.1/7.

> Reclaims the idle, leaked stdio MCP server processes (`node.exe`, `node_repl.exe`, `powershell.exe`, `python.exe`, `uv`/`uvx` …) that the ChatGPT desktop app / OpenAI Codex app-server accumulates on Windows — automatically, in the background.

---

## Background & Motivation (is this your problem?)

If you use the **ChatGPT desktop app / OpenAI Codex** and hit any of the following, this tool is for you:

- Task Manager shows **dozens to hundreds of `node.exe` / `node_repl.exe` / `powershell.exe` / `python.exe`** processes.
- The ChatGPT desktop app (Codex) **grows in memory the longer it runs** — often into double-digit GB — and **only a restart frees it**.
- After you **close or switch conversations**, the old conversation's MCP server processes **do not exit** and are never reclaimed.
- Within one long task, **every turn spawns a fresh full set** of the same MCP servers.
- The process tree under a single `codex.exe app-server` balloons to **hundreds of processes**.

**Root cause**: codex starts a full set of stdio MCP servers **per conversation (thread)**; when a conversation is closed or switched, the old set is **not reclaimed** and keeps accumulating under a single app-server. This tool periodically identifies and reaps the ones that have been **continuously idle**, **without touching conversations you are actively using**, bringing memory back to normal — no manual ChatGPT restart required.

> **Keywords**: ChatGPT desktop high memory usage, OpenAI Codex app-server memory leak, `node_repl.exe` many processes, too many `node.exe` processes, MCP server processes not cleaned up / not reaped, idle stdio MCP processes accumulate, Windows, PowerShell, Task Scheduler.

---

## Quick start

```powershell
# 1) Unzip anywhere, then dry-run first (only prints what WOULD be reaped; no changes)
powershell -ExecutionPolicy Bypass -File .\mcp-reaper.ps1

# 2) Once it looks right, install the background scheduled task
#    (runs every 20 min + 5 min after logon)
powershell -ExecutionPolicy Bypass -File .\install.ps1

# Uninstall
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

> Only touches the current user's own processes — no admin rights needed. The task runs fully in the background with no window.

---

## 1. Background: a known codex bug

The codex backend embedded in the ChatGPT desktop app (`codex.exe ... app-server`) starts **a full set of stdio MCP servers per conversation (thread)**; after a conversation is closed or switched, the old set is **not reclaimed**, accumulating into hundreds of processes and multiple GB under a single app-server.

This is an officially acknowledged, widely reported open issue:

| Issue | Symptom |
|---|---|
| [openai/codex#53285](https://github.com/openai/codex/issues/53285) | `[Windows 26.1007]` one stdio MCP set per thread; 13 sets / 353 processes / ~9.6 GiB under a single app-server |
| [#35485](https://github.com/openai/codex/issues/35485) | Windows Desktop: `node_repl` leaks one-per-thread, **never reaped until app-server exit** |
| [#30408](https://github.com/openai/codex/issues/30408) | MCP server processes leak per thread, never cleaned up (9+ GB) |
| [#53664](https://github.com/openai/codex/issues/53664) | `node_repl` sub-MCP leaks per invocation, exhausting memory |

### codex's own reclamation (why it's not enough)

- **Job Object (exit fallback)**: killing the app-server / ChatGPT main process terminates the whole tree via a Windows Job Object — but **only on full exit**.
- **Delayed idle reclaim**: the community has observed a weak ~30-minute reclaim, but "creation outpaces reclamation" so it still piles up under sustained use.
- **No** configurable idle timeout / instance reuse / instance cap.

---

## 2. What it does

On each run:

1. Locate the `ChatGPT.exe` → `codex.exe app-server` process tree.
2. Enumerate the MCP server roots among the app-server's direct children (excluding `cmd`/`conhost` shells), including each full subtree.
3. Compute each server's **continuous idle duration** by comparing CPU/IO **across runs** via a state file:
   - If CPU delta > 50 ms or IO delta > 256 KB between runs → "active", refresh the last-active timestamp; otherwise idle time keeps accumulating.
   - On first sighting of a server, use its **process start time** as the idle baseline.
4. A candidate = continuously idle ≥ `IdleMinutes` **and** alive ≥ `MinAgeMinutes`.
5. **Two-sample idle confirmation**: wait `IdleSampleSec` and measure again; only reap if there was still no activity between the two samples (excludes ones currently in use).
6. With `-Apply`, stop each candidate server's whole subtree by PID; otherwise it's a dry-run that only prints.

### Safety mechanisms

- **Protects the active conversation**: `IdleMinutes` (default 30) only reaps servers idle for a long time; an active conversation rarely goes 30 minutes without a tool call.
- **Two-sample idle check**: even a candidate is skipped if it had any activity within the `IdleSampleSec` window.
- **Only touches codex**: processes under the `ChatGPT.exe → app-server` tree that were started from MCP config.
- **Optional count guard**: with `KeepLatest > 0`, the newest N of each server are never reaped (default 0 = purely idle-based).

### Limitations / trade-offs (stated honestly)

- codex exclusively locks its SQLite at runtime, so the **true per-conversation "last activity" is unreadable**; this tool therefore cannot 100% guarantee the most-recently-used conversation is never touched. It uses process-level CPU/IO idleness as a proxy.
- The **first run** approximates the idle baseline with process start time, which may misjudge a "long-alive but recently-active" conversation as idle; the two-sample check mitigates this. From the second run on it tracks real CPU changes and is more accurate.
- A reaped server's conversation will report **"Transport closed"** on its next tool call; **reopening that conversation restores it** (codex cannot restart a stopped server). The consequence is mild.

---

## 3. Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Apply` | off (dry-run) | Actually stop processes; without it, only prints what would be reaped |
| `-IdleMinutes` | 30 | Continuous idle minutes before reaping (larger = more conservative) |
| `-KeepLatest` | 0 | Keep the newest N of each server; 0 = purely idle-based |
| `-MinAgeMinutes` | 15 | Minimum process age (skips just-started ones) |
| `-IdleSampleSec` | 45 | Gap between the two samples confirming "idle right now" |
| `-NoIdleCheck` | off | Skip the two-sample idle check (more aggressive; not recommended unattended) |
| `-LogPath` | `.\mcp-reaper.log` | Log file path |
| `-StatePath` | `.\mcp-reaper-state.json` | Idle-tracking state file |
| `-Quiet` | off | No console output, log only (used by the scheduled task) |

---

## 4. Operations

```powershell
# Tail the log (in the script's directory)
Get-Content .\mcp-reaper.log -Tail 40

# Manual dry-run / apply
powershell -ExecutionPolicy Bypass -File .\mcp-reaper.ps1
powershell -ExecutionPolicy Bypass -File .\mcp-reaper.ps1 -Apply

# Scheduled task
Start-ScheduledTask     -TaskName MCP-Reaper   # trigger once now
Disable-ScheduledTask   -TaskName MCP-Reaper   # pause
Enable-ScheduledTask    -TaskName MCP-Reaper   # resume
Get-ScheduledTaskInfo   -TaskName MCP-Reaper   # status & next run
```

### Tuning aggressiveness
- **More conservative**: install with `install.ps1 -IdleMinutes 45`, or add `-KeepLatest 2~4` to protect multiple active conversations.
- **More aggressive**: `-IdleMinutes 15`.

---

## 5. Alternatives (for reference)

- **Restart ChatGPT**: clears everything at once (Job Object full sweep), at the cost of interrupting all conversations.
- **Disable node_repl**: set `enabled=false` under `[mcp_servers.node_repl]` in codex `config.toml` to remove the biggest leak source, at the cost of browser/computer-use features.
- **Watch the upstream fix**: [openai/codex#30408](https://github.com/openai/codex/issues/30408) and related.

---

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

---

*This tool operates purely at the process level on your machine. It does not read codex's private databases, does not access the network, and sends no data anywhere. Licensed under [MIT](LICENSE). Author: Korben Xue.*
