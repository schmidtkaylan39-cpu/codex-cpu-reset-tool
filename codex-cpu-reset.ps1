<#
.SYNOPSIS
  Diagnose and reset Codex Desktop local state when codex.exe app-server
  keeps using high CPU while idle.

.DESCRIPTION
  This script is intentionally conservative:
  - Dry run by default. Add -Apply to move anything.
  - Moves old logs, caches, archived sessions, backups, and old sessions
    into cold storage outside .codex.
  - Does not read or move auth.json, config.toml, automations, skills,
    worktrees, or secrets.
  - Rebuilds Codex's session index by moving session_index.jsonl aside.

  The old conversations are not deleted. They are moved to:
    %USERPROFILE%\CodexColdStorage\codex-cpu-reset-<timestamp>

.EXAMPLE
  # Check what would be moved.
  powershell -ExecutionPolicy Bypass -File .\codex-cpu-reset.ps1

.EXAMPLE
  # Fix aggressively, keeping only today's sessions active, then restart Codex.
  powershell -ExecutionPolicy Bypass -File .\codex-cpu-reset.ps1 -Apply -KeepDays 1 -StopCodexFirst -RestartCodex -ObserveSeconds 60

.EXAMPLE
  # Keep the last 7 days plus specific thread ids.
  powershell -ExecutionPolicy Bypass -File .\codex-cpu-reset.ps1 -Apply -KeepDays 7 -KeepThreadId THREAD_ID_HERE
#>

[CmdletBinding()]
param(
  [switch]$Apply,
  [int]$KeepDays = 7,
  [string[]]$KeepThreadId = @(),
  [switch]$StopCodexFirst,
  [switch]$RestartCodex,
  [int]$ObserveSeconds = 0,
  [string]$CodexHome = (Join-Path $env:USERPROFILE ".codex"),
  [string]$ColdStorageRoot = (Join-Path $env:USERPROFILE "CodexColdStorage"),
  [switch]$SkipSessions,
  [switch]$SkipArchivedSessions,
  [switch]$SkipBackups,
  [switch]$SkipDesktopLogs
)

$ErrorActionPreference = "Stop"

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "== $Message" -ForegroundColor Cyan
}

function Format-MB {
  param([double]$Bytes)
  if ($null -eq $Bytes) { return 0 }
  return [math]::Round(($Bytes / 1MB), 2)
}

function Get-PathStats {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return [PSCustomObject]@{ Files = 0; Bytes = 0 }
  }

  $item = Get-Item -LiteralPath $Path -Force
  if (-not $item.PSIsContainer) {
    return [PSCustomObject]@{ Files = 1; Bytes = $item.Length }
  }

  $files = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)
  $sum = ($files | Measure-Object -Property Length -Sum).Sum
  if ($null -eq $sum) { $sum = 0 }
  return [PSCustomObject]@{ Files = $files.Count; Bytes = $sum }
}

function New-SafeColdPath {
  param(
    [string]$ColdRunRoot,
    [string]$Label
  )
  $safe = ($Label -replace "^[A-Za-z]:\\", "" -replace "[\\/:*?`"<>|]", "__")
  return (Join-Path $ColdRunRoot $safe)
}

function Add-Report {
  param(
    [string]$Item,
    [string]$Action,
    [int]$Files,
    [double]$Bytes,
    [string]$Destination = ""
  )
  $script:Report.Add([PSCustomObject]@{
    Item        = $Item
    Action      = $Action
    Files       = $Files
    SizeMB      = Format-MB $Bytes
    Destination = $Destination
  }) | Out-Null
}

function Move-PathToCold {
  param(
    [string]$Source,
    [string]$Label,
    [switch]$RecreateDirectory
  )

  if (-not (Test-Path -LiteralPath $Source)) {
    Add-Report -Item $Label -Action "absent" -Files 0 -Bytes 0
    return
  }

  $stats = Get-PathStats -Path $Source
  $dest = New-SafeColdPath -ColdRunRoot $script:ColdRunRoot -Label $Label

  if (-not $Apply) {
    Add-Report -Item $Label -Action "would move" -Files $stats.Files -Bytes $stats.Bytes -Destination $dest
    return
  }

  $destParent = Split-Path -Parent $dest
  if (-not (Test-Path -LiteralPath $destParent)) {
    New-Item -ItemType Directory -Path $destParent -Force | Out-Null
  }

  Move-Item -LiteralPath $Source -Destination $dest -Force

  if ($RecreateDirectory) {
    New-Item -ItemType Directory -Path $Source -Force | Out-Null
  }

  Add-Report -Item $Label -Action "moved" -Files $stats.Files -Bytes $stats.Bytes -Destination $dest
}

function Get-SessionDate {
  param([System.IO.FileInfo]$File)
  if ($File.Name -match "^rollout-(\d{4})-(\d{2})-(\d{2})T") {
    return [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
  }
  return $File.LastWriteTime.Date
}

function Move-OldSessions {
  param([string]$SessionsDir)

  if (-not (Test-Path -LiteralPath $SessionsDir)) {
    Add-Report -Item "sessions" -Action "absent" -Files 0 -Bytes 0
    return
  }

  $keepAtLeastDays = [math]::Max($KeepDays, 1)
  $cutoff = (Get-Date).Date.AddDays(-1 * ($keepAtLeastDays - 1))
  $destRoot = Join-Path $script:ColdRunRoot "sessions_old"
  $files = @(Get-ChildItem -LiteralPath $SessionsDir -Recurse -Force -File -Filter "*.jsonl" -ErrorAction SilentlyContinue)
  $moved = 0
  $kept = 0
  $failed = 0
  $movedBytes = 0

  foreach ($file in $files) {
    $sessionDate = Get-SessionDate -File $file
    $keepByDate = ($sessionDate -ge $cutoff)
    $keepById = $false
    foreach ($id in $KeepThreadId) {
      if (-not [string]::IsNullOrWhiteSpace($id) -and $file.FullName.Contains($id)) {
        $keepById = $true
        break
      }
    }

    if ($keepByDate -or $keepById) {
      $kept++
      continue
    }

    $relative = $file.FullName.Substring($SessionsDir.Length).TrimStart("\")
    $dest = Join-Path $destRoot $relative

    if (-not $Apply) {
      $moved++
      $movedBytes += $file.Length
      continue
    }

    try {
      $destDir = Split-Path -Parent $dest
      if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
      }
      $movedBytes += $file.Length
      Move-Item -LiteralPath $file.FullName -Destination $dest -Force
      $moved++
    }
    catch {
      $failed++
    }
  }

  $action = if ($Apply) { "moved old sessions; kept recent/selected" } else { "would move old sessions; keep recent/selected" }
  Add-Report -Item "sessions old jsonl" -Action $action -Files $moved -Bytes $movedBytes -Destination $destRoot
  Add-Report -Item "sessions kept jsonl" -Action "kept active" -Files $kept -Bytes 0 -Destination $SessionsDir
  if ($failed -gt 0) {
    Add-Report -Item "sessions move failures" -Action "failed" -Files $failed -Bytes 0
  }
}

function Move-DesktopLogs {
  $logRoot = Join-Path $env:LOCALAPPDATA "Codex\Logs"
  if (-not (Test-Path -LiteralPath $logRoot)) {
    Add-Report -Item "desktop logs before today" -Action "absent" -Files 0 -Bytes 0
    return
  }

  $today = (Get-Date).Date
  $files = @(Get-ChildItem -LiteralPath $logRoot -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $today })
  $bytes = ($files | Measure-Object -Property Length -Sum).Sum
  if ($null -eq $bytes) { $bytes = 0 }
  $destRoot = Join-Path $script:ColdRunRoot "desktop_logs_before_today"

  if (-not $Apply) {
    Add-Report -Item "desktop logs before today" -Action "would move" -Files $files.Count -Bytes $bytes -Destination $destRoot
    return
  }

  $moved = 0
  $failed = 0
  foreach ($file in $files) {
    $relative = $file.FullName.Substring($logRoot.Length).TrimStart("\")
    $dest = Join-Path $destRoot $relative
    try {
      $destDir = Split-Path -Parent $dest
      if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
      }
      Move-Item -LiteralPath $file.FullName -Destination $dest -Force
      $moved++
    }
    catch {
      $failed++
    }
  }

  Add-Report -Item "desktop logs before today" -Action "moved" -Files $moved -Bytes $bytes -Destination $destRoot
  if ($failed -gt 0) {
    Add-Report -Item "desktop log move failures" -Action "failed" -Files $failed -Bytes 0
  }
}

function Move-SessionIndexes {
  foreach ($name in @("session_index.jsonl", "session_index.jsonl.bak")) {
    Move-PathToCold -Source (Join-Path $CodexHome $name) -Label $name
  }
}

function Measure-CodexCpu {
  param([int]$Seconds = 10)
  $p1 = Get-Process | Where-Object { $_.ProcessName -match "^(codex|Codex)$" } | Select-Object Id, ProcessName, CPU, StartTime, Path
  Start-Sleep -Seconds $Seconds
  $p2 = Get-Process | Where-Object { $_.ProcessName -match "^(codex|Codex)$" } | Select-Object Id, ProcessName, CPU, StartTime, Path
  $rows = foreach ($b in $p2) {
    $a = $p1 | Where-Object Id -eq $b.Id | Select-Object -First 1
    if ($a -and $a.CPU -ne $null -and $b.CPU -ne $null) {
      $delta = $b.CPU - $a.CPU
      [PSCustomObject]@{
        Id              = $b.Id
        Name            = $b.ProcessName
        CpuSeconds      = [math]::Round($delta, 2)
        AvgCorePct      = [math]::Round(($delta / $Seconds * 100), 1)
        TotalCpuSeconds = [math]::Round($b.CPU, 1)
        StartTime       = $b.StartTime
      }
    }
  }
  $rows | Sort-Object AvgCorePct -Descending
}

function Stop-CodexProcesses {
  $procs = @(Get-Process -Name Codex,codex -ErrorAction SilentlyContinue)
  if ($procs.Count -eq 0) { return }
  Write-Step "Stopping Codex processes"
  $procs | Stop-Process -Force
  Start-Sleep -Seconds 3
}

function Start-CodexApp {
  Write-Step "Starting Codex app"
  try {
    Start-Process explorer.exe "shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App"
  }
  catch {
    Write-Warning "Could not start Codex automatically. Open Codex manually from Start Menu."
  }
}

$script:Report = New-Object System.Collections.Generic.List[object]

$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
$ColdStorageRoot = [System.IO.Path]::GetFullPath($ColdStorageRoot)
if (-not (Test-Path -LiteralPath $CodexHome)) {
  throw "Codex home not found: $CodexHome"
}
if (-not ($CodexHome.EndsWith("\.codex") -or $CodexHome.EndsWith("/.codex"))) {
  throw "Refusing to operate on a non-.codex home: $CodexHome"
}
if ($ColdStorageRoot.StartsWith($CodexHome, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Cold storage must be outside .codex. Current value: $ColdStorageRoot"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:ColdRunRoot = Join-Path $ColdStorageRoot "codex-cpu-reset-$timestamp"

Write-Step "Codex CPU reset"
Write-Host "Mode:             $(if ($Apply) { 'APPLY' } else { 'DRY RUN' })"
Write-Host "CodexHome:        $CodexHome"
Write-Host "Cold storage:     $script:ColdRunRoot"
Write-Host "KeepDays:         $KeepDays"
Write-Host "KeepThreadId:     $($KeepThreadId -join ', ')"

Write-Step "Current Codex CPU sample"
Measure-CodexCpu -Seconds 5 | Select-Object -First 10 | Format-Table -AutoSize

if ($Apply) {
  New-Item -ItemType Directory -Path $script:ColdRunRoot -Force | Out-Null
}

if ($StopCodexFirst -and $Apply) {
  Stop-CodexProcesses
}
elseif ($StopCodexFirst -and -not $Apply) {
  Write-Warning "-StopCodexFirst was ignored because this is a dry run."
}

Write-Step "Collecting reset actions"

if (-not $SkipDesktopLogs) {
  Move-DesktopLogs
}

foreach ($name in @("logs_2.sqlite", "logs_2.sqlite-shm", "logs_2.sqlite-wal")) {
  Move-PathToCold -Source (Join-Path $CodexHome $name) -Label $name
}

foreach ($name in @("cache", ".tmp", "tmp")) {
  Move-PathToCold -Source (Join-Path $CodexHome $name) -Label $name -RecreateDirectory
}

$roamingCodex = Join-Path $env:APPDATA "Codex"
foreach ($name in @("Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache")) {
  Move-PathToCold -Source (Join-Path $roamingCodex $name) -Label "roaming_$name"
}

if (-not $SkipBackups) {
  Move-PathToCold -Source (Join-Path $CodexHome "backups") -Label "backups" -RecreateDirectory
}

if (-not $SkipArchivedSessions) {
  Move-PathToCold -Source (Join-Path $CodexHome "archived_sessions") -Label "archived_sessions" -RecreateDirectory
}

if (-not $SkipSessions) {
  Move-OldSessions -SessionsDir (Join-Path $CodexHome "sessions")
  Move-SessionIndexes
}

Write-Step "Summary"
$script:Report | Format-Table -AutoSize

if (-not $Apply) {
  Write-Host ""
  Write-Host "Dry run only. Re-run with -Apply to move the data." -ForegroundColor Yellow
  Write-Host "Suggested aggressive fix:"
  Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Apply -KeepDays 1 -StopCodexFirst -RestartCodex -ObserveSeconds 60"
  exit 0
}

Write-Host ""
Write-Host "Moved data is safe in: $script:ColdRunRoot" -ForegroundColor Green

if ($RestartCodex) {
  Start-CodexApp
  Start-Sleep -Seconds 15
}

if ($ObserveSeconds -gt 0) {
  Write-Step "Post-reset Codex CPU observation"
  $rounds = [math]::Max([math]::Floor($ObserveSeconds / 10), 1)
  for ($i = 1; $i -le $rounds; $i++) {
    Write-Host "Sample $i / $rounds"
    Measure-CodexCpu -Seconds 10 | Select-Object -First 10 | Format-Table -AutoSize
  }
}

Write-Step "Done"
Write-Host "If Codex still idles above 20-30% after this, try a full Codex profile reset or reinstall."
