# Codex CPU Reset Tool

A conservative PowerShell tool for Windows users who see Codex Desktop using high CPU while idle, especially when Task Manager shows `codex.exe app-server` consuming CPU even when no task appears to be running.

This tool was created after diagnosing a real case where Codex Desktop stayed around 30% CPU at idle because local Codex state had grown very large: desktop logs, session history, archived sessions, backups, caches, and local indexes.

## What It Does

By default, the script only performs a dry run and shows what it would move.

When run with `-Apply`, it moves bulky local Codex state out of `.codex` into cold storage so Codex can rebuild a smaller active index:

- Old Codex desktop logs
- `logs_2.sqlite` and related SQLite sidecar files
- Codex cache and temp folders
- Electron cache folders
- `.codex\backups`
- `.codex\archived_sessions`
- Old `.codex\sessions` JSONL files
- `session_index.jsonl` so Codex can rebuild it

The tool does **not** intentionally read, print, or move:

- `auth.json`
- `config.toml`
- `automations`
- `skills`
- `worktrees`
- secrets, tokens, cookies, or credentials

## Safety Model

The script moves data instead of deleting it.

Cold storage is created outside `.codex`:

```powershell
%USERPROFILE%\CodexColdStorage\codex-cpu-reset-<timestamp>
```

If you later need an old session, you can manually move the relevant `.jsonl` file back into `.codex\sessions`.

## Requirements

- Windows
- PowerShell 5 or newer
- Codex Desktop installed

## Usage

Download `codex-cpu-reset.ps1`, then open PowerShell.

### 1. Dry Run

Always start here:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex-cpu-reset.ps1
```

This prints the actions the tool would take without moving anything.

### 2. Conservative Fix

Keep the last 30 days of active sessions:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex-cpu-reset.ps1 -Apply -KeepDays 30 -StopCodexFirst -RestartCodex -ObserveSeconds 60
```

### 3. Aggressive Fix

Keep only recent active sessions from today:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex-cpu-reset.ps1 -Apply -KeepDays 1 -StopCodexFirst -RestartCodex -ObserveSeconds 60
```

### 4. Keep Specific Threads

If you know a thread id, preserve it even if it is older than `KeepDays`:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex-cpu-reset.ps1 -Apply -KeepDays 1 -KeepThreadId THREAD_ID_HERE -StopCodexFirst -RestartCodex -ObserveSeconds 60
```

You can pass multiple ids:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex-cpu-reset.ps1 -Apply -KeepDays 1 -KeepThreadId THREAD_ID_1,THREAD_ID_2 -StopCodexFirst -RestartCodex -ObserveSeconds 60
```

## Useful Options

```powershell
-Apply                 Actually move data. Without this, the script is dry run only.
-KeepDays 7            Keep active sessions from the last N days.
-KeepThreadId ID       Keep one or more specific thread ids.
-StopCodexFirst        Stop Codex before moving files.
-RestartCodex          Start Codex after moving files.
-ObserveSeconds 60     Measure Codex CPU after restart.
-SkipSessions          Do not move old sessions.
-SkipArchivedSessions  Do not move archived sessions.
-SkipBackups           Do not move backups.
-SkipDesktopLogs       Do not move desktop logs.
```

## When To Use This

Use this when all of these are true:

- Windows Task Manager shows high CPU under Codex.
- Expanding the Codex process group shows `codex.exe` or `codex.exe app-server` as the busy process.
- No obvious Codex task is actively running.
- Restarting Codex does not fix it for long.

## When Not To Use This

Do not use this as your first debugging step if:

- A real Codex task is currently running.
- You need all old threads visible in the sidebar at the same time.
- Your high CPU is actually from Python, Node, PowerShell, Defender, Chrome, or another process.

## If CPU Is Still High

If Codex still idles above 20-30% after this reset, the issue may be in the Codex Desktop profile, installation, or current Codex version. The next steps are:

1. Try a full Codex Desktop profile reset.
2. Reinstall Codex Desktop.
3. Report the issue with CPU samples and process command lines.

## Disclaimer

This is an unofficial community troubleshooting script. Review the dry run output before using `-Apply`.
