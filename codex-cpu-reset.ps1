<#
.SYNOPSIS
  Diagnose and reset Codex Desktop local state when codex.exe app-server
  keeps using high CPU while idle.

.DESCRIPTION
  This script is intentionally conservative:
  - Dry run by default. Add -Apply to move anything.
  - Supports -WhatIf and -Confirm when -Apply is present.
  - Moves old logs, caches, archived sessions, backups, and old sessions
    into cold storage outside .codex.
  - Does not read or move auth.json, config.toml, automations, skills,
    worktrees, or secrets.
  - Rebuilds Codex's session index by moving session_index.jsonl aside.
  - Writes manifest.json, report.json, and a dry-run restore script on apply.

  The old conversations are not deleted. They are moved to:
    <home>\CodexColdStorage\codex-cpu-reset-<timestamp>

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\codex-cpu-reset.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\codex-cpu-reset.ps1 -Apply -KeepDays 1 -StopCodexFirst -RestartCodex -ObserveSeconds 60

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\codex-cpu-reset.ps1 -Apply -KeepDays 7 -KeepThreadId THREAD_ID_HERE
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
  [switch]$Apply,
  [int]$KeepDays = 7,
  [string[]]$KeepThreadId = @(),
  [switch]$StopCodexFirst,
  [switch]$RestartCodex,
  [int]$ObserveSeconds = 0,
  [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }),
  [string]$ColdStorageRoot = (Join-Path $HOME 'CodexColdStorage'),
  [string]$CodexAppId = $(if ($env:CODEX_APP_ID) { $env:CODEX_APP_ID } else { 'OpenAI.Codex_2p2nqsd0c76g0!App' }),
  [string]$CodexStartCommand = '',
  [switch]$AllowNonStandardCodexHome,
  [switch]$SkipSessions,
  [switch]$SkipArchivedSessions,
  [switch]$SkipBackups,
  [switch]$SkipDesktopLogs
)

$ErrorActionPreference = 'Stop'

function Write-Step {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Information -InformationAction Continue -MessageData ''
  Write-Information -InformationAction Continue -MessageData "== $Message"
}

function Write-Line {
  param([string]$Message = '')
  Write-Information -InformationAction Continue -MessageData $Message
}

function Format-MB {
  param([double]$Bytes)
  if ($null -eq $Bytes) { return 0 }
  return [math]::Round(($Bytes / 1MB), 2)
}

function Add-TrailingDirectorySeparator {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = [System.IO.Path]::GetFullPath($Path)
  $separator = [System.IO.Path]::DirectorySeparatorChar
  $altSeparator = [System.IO.Path]::AltDirectorySeparatorChar

  if (-not ($full.EndsWith([string]$separator) -or $full.EndsWith([string]$altSeparator))) {
    $full += $separator
  }

  return $full
}

function Test-IsSameOrChildPath {
  param(
    [Parameter(Mandatory = $true)][string]$BasePath,
    [Parameter(Mandatory = $true)][string]$CandidatePath
  )

  $baseFull = Add-TrailingDirectorySeparator -Path $BasePath
  $candidateFull = Add-TrailingDirectorySeparator -Path $CandidatePath

  return $candidateFull.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativeChildPath {
  param(
    [Parameter(Mandatory = $true)][string]$BasePath,
    [Parameter(Mandatory = $true)][string]$ChildPath
  )

  $baseFull = Add-TrailingDirectorySeparator -Path $BasePath
  $childFull = [System.IO.Path]::GetFullPath($ChildPath)

  if (-not $childFull.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Path is not under base path. Base: $BasePath Child: $ChildPath"
  }

  return $childFull.Substring($baseFull.Length)
}

function Get-PathStat {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return [PSCustomObject]@{ Files = 0; Bytes = 0L }
  }

  $item = Get-Item -LiteralPath $Path -Force
  if (-not $item.PSIsContainer) {
    return [PSCustomObject]@{ Files = 1; Bytes = [int64]$item.Length }
  }

  $count = 0
  $bytes = 0L

  Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
    $count++
    $bytes += [int64]$_.Length
  }

  return [PSCustomObject]@{ Files = $count; Bytes = $bytes }
}

function Get-SafeColdPath {
  param(
    [Parameter(Mandatory = $true)][string]$ColdRunRoot,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $safe = ($Label -replace '^[A-Za-z]:\\', '' -replace '[\\/:*?"<>|]', '__')
  return (Join-Path $ColdRunRoot $safe)
}

function Add-Report {
  param(
    [Parameter(Mandatory = $true)][string]$Item,
    [Parameter(Mandatory = $true)][string]$Action,
    [int]$Files,
    [double]$Bytes,
    [string]$Destination = ''
  )

  $script:Report.Add([PSCustomObject]@{
    Item        = $Item
    Action      = $Action
    Files       = $Files
    SizeMB      = Format-MB $Bytes
    Destination = $Destination
  }) | Out-Null
}

function Add-Manifest {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][string]$ItemType,
    [int]$Files,
    [Int64]$Bytes,
    [string]$Action = 'moved'
  )

  $script:Manifest.Add([PSCustomObject]@{
    Source      = $Source
    Destination = $Destination
    ItemType    = $ItemType
    Files       = $Files
    Bytes       = $Bytes
    Action      = $Action
    UtcTime     = (Get-Date).ToUniversalTime().ToString('o')
  }) | Out-Null
}

function Add-ResetError {
  param(
    [Parameter(Mandatory = $true)][string]$Stage,
    [string]$Source = '',
    [string]$Destination = '',
    [Parameter(Mandatory = $true)][string]$Message
  )

  $script:Errors.Add([PSCustomObject]@{
    Stage       = $Stage
    Source      = $Source
    Destination = $Destination
    Message     = $Message
    UtcTime     = (Get-Date).ToUniversalTime().ToString('o')
  }) | Out-Null
}

function Initialize-DirectoryIfNeeded {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
  param([Parameter(Mandatory = $true)][string]$Path)

  if (Test-Path -LiteralPath $Path) { return $true }
  if (-not $Apply) { return $false }

  if ($PSCmdlet.ShouldProcess($Path, 'Create directory')) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return $true
  }

  return $false
}

function Move-PathToCold {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Label,
    [switch]$RecreateDirectory
  )

  if (-not (Test-Path -LiteralPath $Source)) {
    Add-Report -Item $Label -Action 'absent' -Files 0 -Bytes 0
    return
  }

  $stats = Get-PathStat -Path $Source
  $sourceItem = Get-Item -LiteralPath $Source -Force
  $itemType = if ($sourceItem.PSIsContainer) { 'Directory' } else { 'File' }
  $dest = Get-SafeColdPath -ColdRunRoot $script:ColdRunRoot -Label $Label

  if (-not $Apply) {
    Add-Report -Item $Label -Action 'would move' -Files $stats.Files -Bytes $stats.Bytes -Destination $dest
    return
  }

  if (-not $PSCmdlet.ShouldProcess($Source, "Move to $dest")) {
    Add-Report -Item $Label -Action 'whatif' -Files $stats.Files -Bytes $stats.Bytes -Destination $dest
    return
  }

  try {
    $destParent = Split-Path -Parent $dest
    Initialize-DirectoryIfNeeded -Path $destParent | Out-Null
    Move-Item -LiteralPath $Source -Destination $dest -Force
    Add-Manifest -Source $Source -Destination $dest -ItemType $itemType -Files $stats.Files -Bytes $stats.Bytes
    Add-Report -Item $Label -Action 'moved' -Files $stats.Files -Bytes $stats.Bytes -Destination $dest

    if ($RecreateDirectory -and $sourceItem.PSIsContainer) {
      if ($PSCmdlet.ShouldProcess($Source, 'Recreate empty directory')) {
        New-Item -ItemType Directory -Path $Source -Force | Out-Null
      }
    }
  }
  catch {
    Add-ResetError -Stage "move:$Label" -Source $Source -Destination $dest -Message $_.Exception.Message
    Add-Report -Item $Label -Action 'failed' -Files $stats.Files -Bytes $stats.Bytes -Destination $dest
  }
}

function Get-SessionDate {
  param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

  if ($File.Name -match '^rollout-(\d{4})-(\d{2})-(\d{2})T') {
    return [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
  }

  return $File.LastWriteTime.Date
}

function Test-KeepSession {
  param(
    [Parameter(Mandatory = $true)][System.IO.FileInfo]$File,
    [Parameter(Mandatory = $true)][datetime]$Cutoff
  )

  if ((Get-SessionDate -File $File) -ge $Cutoff) { return $true }

  foreach ($id in $KeepThreadId) {
    if (-not [string]::IsNullOrWhiteSpace($id) -and $File.FullName.Contains($id)) {
      return $true
    }
  }

  return $false
}

function Move-OldSession {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
  param([Parameter(Mandatory = $true)][string]$SessionsDir)

  if (-not (Test-Path -LiteralPath $SessionsDir)) {
    Add-Report -Item 'sessions' -Action 'absent' -Files 0 -Bytes 0
    return
  }

  $keepAtLeastDays = [math]::Max($KeepDays, 1)
  $cutoff = (Get-Date).Date.AddDays(-1 * ($keepAtLeastDays - 1))
  $destRoot = Join-Path $script:ColdRunRoot 'sessions_old'
  $moved = 0
  $kept = 0
  $failed = 0
  $movedBytes = 0L

  Get-ChildItem -LiteralPath $SessionsDir -Recurse -Force -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
    $file = $_
    if (Test-KeepSession -File $file -Cutoff $cutoff) {
      $script:SessionKept++
      return
    }

    $relative = Get-RelativeChildPath -BasePath $SessionsDir -ChildPath $file.FullName
    $dest = Join-Path $destRoot $relative

    if (-not $Apply) {
      $script:SessionMoved++
      $script:SessionMovedBytes += [int64]$file.Length
      return
    }

    if (-not $PSCmdlet.ShouldProcess($file.FullName, "Move to $dest")) {
      $script:SessionMoved++
      $script:SessionMovedBytes += [int64]$file.Length
      return
    }

    try {
      $destDir = Split-Path -Parent $dest
      Initialize-DirectoryIfNeeded -Path $destDir | Out-Null
      Move-Item -LiteralPath $file.FullName -Destination $dest -Force
      $script:SessionMoved++
      $script:SessionMovedBytes += [int64]$file.Length
      Add-Manifest -Source $file.FullName -Destination $dest -ItemType 'File' -Files 1 -Bytes ([int64]$file.Length)
    }
    catch {
      $script:SessionFailed++
      Add-ResetError -Stage 'move:session' -Source $file.FullName -Destination $dest -Message $_.Exception.Message
    }
  }

  $moved = $script:SessionMoved
  $kept = $script:SessionKept
  $failed = $script:SessionFailed
  $movedBytes = $script:SessionMovedBytes
  $action = if ($Apply) { 'moved old sessions; kept recent/selected' } else { 'would move old sessions; keep recent/selected' }
  Add-Report -Item 'sessions old jsonl' -Action $action -Files $moved -Bytes $movedBytes -Destination $destRoot
  Add-Report -Item 'sessions kept jsonl' -Action 'kept active' -Files $kept -Bytes 0 -Destination $SessionsDir
  if ($failed -gt 0) {
    Add-Report -Item 'sessions move failures' -Action 'failed' -Files $failed -Bytes 0
  }
}

function Move-DesktopLog {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
  param()

  if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    Add-Report -Item 'desktop logs before today' -Action 'LOCALAPPDATA unavailable' -Files 0 -Bytes 0
    return
  }

  $logRoot = Join-Path $env:LOCALAPPDATA 'Codex\Logs'
  if (-not (Test-Path -LiteralPath $logRoot)) {
    Add-Report -Item 'desktop logs before today' -Action 'absent' -Files 0 -Bytes 0
    return
  }

  $today = (Get-Date).Date
  $destRoot = Join-Path $script:ColdRunRoot 'desktop_logs_before_today'

  Get-ChildItem -LiteralPath $logRoot -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object {
    $_.LastWriteTime -lt $today
  } | ForEach-Object {
    $file = $_
    $relative = Get-RelativeChildPath -BasePath $logRoot -ChildPath $file.FullName
    $dest = Join-Path $destRoot $relative

    if (-not $Apply) {
      $script:DesktopLogMoved++
      $script:DesktopLogBytes += [int64]$file.Length
      return
    }

    if (-not $PSCmdlet.ShouldProcess($file.FullName, "Move to $dest")) {
      $script:DesktopLogMoved++
      $script:DesktopLogBytes += [int64]$file.Length
      return
    }

    try {
      $destDir = Split-Path -Parent $dest
      Initialize-DirectoryIfNeeded -Path $destDir | Out-Null
      Move-Item -LiteralPath $file.FullName -Destination $dest -Force
      $script:DesktopLogMoved++
      $script:DesktopLogBytes += [int64]$file.Length
      Add-Manifest -Source $file.FullName -Destination $dest -ItemType 'File' -Files 1 -Bytes ([int64]$file.Length)
    }
    catch {
      $script:DesktopLogFailed++
      Add-ResetError -Stage 'move:desktop-log' -Source $file.FullName -Destination $dest -Message $_.Exception.Message
    }
  }

  $action = if ($Apply) { 'moved' } else { 'would move' }
  Add-Report -Item 'desktop logs before today' -Action $action -Files $script:DesktopLogMoved -Bytes $script:DesktopLogBytes -Destination $destRoot
  if ($script:DesktopLogFailed -gt 0) {
    Add-Report -Item 'desktop log move failures' -Action 'failed' -Files $script:DesktopLogFailed -Bytes 0
  }
}

function Move-SessionIndex {
  foreach ($name in @('session_index.jsonl', 'session_index.jsonl.bak')) {
    Move-PathToCold -Source (Join-Path $CodexHome $name) -Label $name
  }
}

function Measure-CodexCpu {
  param([int]$Seconds = 10)

  $firstSample = Get-Process | Where-Object { $_.ProcessName -match '^(codex|Codex)$' } | Select-Object Id, ProcessName, CPU, StartTime
  Start-Sleep -Seconds $Seconds
  $secondSample = Get-Process | Where-Object { $_.ProcessName -match '^(codex|Codex)$' } | Select-Object Id, ProcessName, CPU, StartTime

  $rows = foreach ($process in $secondSample) {
    $previous = $firstSample | Where-Object { $_.Id -eq $process.Id } | Select-Object -First 1
    if ($previous -and $null -ne $previous.CPU -and $null -ne $process.CPU) {
      $delta = $process.CPU - $previous.CPU
      [PSCustomObject]@{
        Id              = $process.Id
        Name            = $process.ProcessName
        CpuSeconds      = [math]::Round($delta, 2)
        AvgCorePct      = [math]::Round(($delta / $Seconds * 100), 1)
        TotalCpuSeconds = [math]::Round($process.CPU, 1)
        StartTime       = $process.StartTime
      }
    }
  }

  $rows | Sort-Object AvgCorePct -Descending
}

function Stop-CodexProcess {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
  param()

  $processes = @(Get-Process -Name Codex,codex -ErrorAction SilentlyContinue)
  if ($processes.Count -eq 0) { return }

  Write-Step 'Stopping Codex processes'
  foreach ($process in $processes) {
    if (-not $Apply) { continue }
    if (-not $PSCmdlet.ShouldProcess($process.Id, 'Stop Codex process')) { continue }

    try {
      Stop-Process -Id $process.Id -Force
    }
    catch {
      Add-ResetError -Stage 'stop-process' -Source ([string]$process.Id) -Message $_.Exception.Message
    }
  }

  Start-Sleep -Seconds 3
}

function Join-PathIfBase {
  param(
    [string]$Base,
    [string]$Child
  )

  if ([string]::IsNullOrWhiteSpace($Base)) { return $null }
  return (Join-Path $Base $Child)
}

function Start-CodexApp {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
  param(
    [string]$StartCommand,
    [string]$AppId
  )

  Write-Step 'Starting Codex app'

  if (-not $Apply) { return }

  if (-not [string]::IsNullOrWhiteSpace($StartCommand)) {
    if ($PSCmdlet.ShouldProcess('CodexStartCommand', 'Start Codex app')) {
      try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', $StartCommand)
        return
      }
      catch {
        Add-ResetError -Stage 'start:custom-command' -Message $_.Exception.Message
      }
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($AppId)) {
    if ($PSCmdlet.ShouldProcess($AppId, 'Start Codex app by AppsFolder id')) {
      try {
        Start-Process explorer.exe "shell:AppsFolder\$AppId"
        Start-Sleep -Seconds 5
        if (@(Get-Process -Name Codex,codex -ErrorAction SilentlyContinue).Count -gt 0) {
          return
        }
      }
      catch {
        Add-ResetError -Stage 'start:appsfolder' -Source $AppId -Message $_.Exception.Message
      }
    }
  }

  $shortcutRoots = @(
    (Join-PathIfBase -Base $env:APPDATA -Child 'Microsoft\Windows\Start Menu\Programs'),
    (Join-PathIfBase -Base $env:ProgramData -Child 'Microsoft\Windows\Start Menu\Programs')
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }

  $shortcut = $null
  foreach ($root in $shortcutRoots) {
    $shortcut = Get-ChildItem -LiteralPath $root -Recurse -Force -File -Filter '*Codex*.lnk' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($shortcut) { break }
  }

  if ($shortcut -and $PSCmdlet.ShouldProcess($shortcut.FullName, 'Start Codex app by Start Menu shortcut')) {
    try {
      Start-Process -FilePath $shortcut.FullName
      return
    }
    catch {
      Add-ResetError -Stage 'start:shortcut' -Source $shortcut.FullName -Message $_.Exception.Message
    }
  }

  Add-ResetError -Stage 'start' -Message 'Could not start Codex automatically. Open Codex manually from the Start Menu.'
}

function Get-RestoreScript {
  $restoreScript = @'
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
  [switch]$Apply,
  [switch]$Force,
  [string]$ManifestPath = ''
)

$ErrorActionPreference = 'Stop'

function Write-RestoreLine {
  param([string]$Message)
  Write-Information -InformationAction Continue -MessageData $Message
}

function Test-DirectoryEmpty {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
  return $null -eq (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  $scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
  }
  else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
  }
  $ManifestPath = Join-Path $scriptRoot 'manifest.json'
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
  throw "Manifest not found: $ManifestPath"
}

$rawEntries = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$entriesList = New-Object System.Collections.ArrayList
foreach ($entry in $rawEntries) {
  [void]$entriesList.Add($entry)
}
$entries = @($entriesList.ToArray())
[array]::Reverse($entries)

$restored = 0
$skipped = 0
$failed = 0

foreach ($entry in $entries) {
  $source = [string]$entry.Source
  $destination = [string]$entry.Destination
  $itemType = [string]$entry.ItemType

  if (-not (Test-Path -LiteralPath $destination)) {
    Write-Warning "Cold item missing, skip: $destination"
    $skipped++
    continue
  }

  try {
    if ($itemType -eq 'Directory') {
      if (Test-Path -LiteralPath $source) {
        if (Test-DirectoryEmpty -Path $source) {
          if ($Apply -and $PSCmdlet.ShouldProcess($source, 'Remove empty placeholder directory')) {
            Remove-Item -LiteralPath $source -Force
          }
        }
        else {
          Write-Warning "Source directory exists and is not empty, skip: $source"
          $skipped++
          continue
        }
      }

      $parent = Split-Path -Parent $source
      if ($Apply -and -not (Test-Path -LiteralPath $parent) -and $PSCmdlet.ShouldProcess($parent, 'Create parent directory')) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
      }

      if ($Apply -and $PSCmdlet.ShouldProcess($destination, "Move back to $source")) {
        Move-Item -LiteralPath $destination -Destination $source -Force
      }
      $restored++
      continue
    }

    if (Test-Path -LiteralPath $source) {
      if (-not $Force) {
        Write-Warning "Source file exists, skip without -Force: $source"
        $skipped++
        continue
      }
    }

    $sourceParent = Split-Path -Parent $source
    if ($Apply -and -not (Test-Path -LiteralPath $sourceParent) -and $PSCmdlet.ShouldProcess($sourceParent, 'Create parent directory')) {
      New-Item -ItemType Directory -Path $sourceParent -Force | Out-Null
    }

    if ($Apply -and $PSCmdlet.ShouldProcess($destination, "Move back to $source")) {
      Move-Item -LiteralPath $destination -Destination $source -Force
    }
    $restored++
  }
  catch {
    Write-Warning "Failed to restore $destination -> $source : $($_.Exception.Message)"
    $failed++
  }
}

Write-RestoreLine "Restore summary: restored=$restored skipped=$skipped failed=$failed apply=$Apply"
if (-not $Apply) {
  Write-RestoreLine 'Dry run only. Re-run with -Apply to restore.'
}
'@

  return $restoreScript
}

function Save-RunArtifact {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
  param()

  if (-not $Apply -or $WhatIfPreference) { return }
  if (-not (Test-Path -LiteralPath $script:ColdRunRoot)) { return }

  $manifestPath = Join-Path $script:ColdRunRoot 'manifest.json'
  $reportPath = Join-Path $script:ColdRunRoot 'report.json'
  $restorePath = Join-Path $script:ColdRunRoot 'restore-codex-cpu-reset.ps1'
  $errorPath = Join-Path $script:ColdRunRoot 'errors.json'

  if ($PSCmdlet.ShouldProcess($manifestPath, 'Write manifest')) {
    $script:Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
  }
  if ($PSCmdlet.ShouldProcess($reportPath, 'Write report')) {
    $script:Report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
  }
  if ($PSCmdlet.ShouldProcess($restorePath, 'Write restore script')) {
    Get-RestoreScript | Set-Content -LiteralPath $restorePath -Encoding UTF8
  }
  if ($script:Errors.Count -gt 0 -and $PSCmdlet.ShouldProcess($errorPath, 'Write errors')) {
    $script:Errors | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $errorPath -Encoding UTF8
  }

  $script:ManifestPath = $manifestPath
  $script:ReportPath = $reportPath
  $script:RestorePath = $restorePath
  if ($script:Errors.Count -gt 0) {
    $script:ErrorPath = $errorPath
  }
}

$script:Report = New-Object System.Collections.Generic.List[object]
$script:Manifest = New-Object System.Collections.Generic.List[object]
$script:Errors = New-Object System.Collections.Generic.List[object]
$script:DesktopLogMoved = 0
$script:DesktopLogBytes = 0L
$script:DesktopLogFailed = 0
$script:SessionMoved = 0
$script:SessionMovedBytes = 0L
$script:SessionKept = 0
$script:SessionFailed = 0
$script:ManifestPath = ''
$script:ReportPath = ''
$script:RestorePath = ''
$script:ErrorPath = ''

$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
$ColdStorageRoot = [System.IO.Path]::GetFullPath($ColdStorageRoot)
if (-not (Test-Path -LiteralPath $CodexHome)) {
  throw "Codex home not found: $CodexHome"
}
if (-not $AllowNonStandardCodexHome -and -not ($CodexHome.EndsWith('\.codex') -or $CodexHome.EndsWith('/.codex'))) {
  throw "Refusing to operate on a non-.codex home: $CodexHome"
}
if (Test-IsSameOrChildPath -BasePath $CodexHome -CandidatePath $ColdStorageRoot) {
  throw "Cold storage must be outside .codex. Current value: $ColdStorageRoot"
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:ColdRunRoot = Join-Path $ColdStorageRoot "codex-cpu-reset-$timestamp"

Write-Step 'Codex CPU reset'
Write-Line "Mode:             $(if ($Apply) { 'APPLY' } else { 'DRY RUN' })"
Write-Line "CodexHome:        $CodexHome"
Write-Line "Cold storage:     $script:ColdRunRoot"
Write-Line "KeepDays:         $KeepDays"
Write-Line "KeepThreadId:     $($KeepThreadId -join ', ')"
Write-Line "CodexAppId:       $CodexAppId"

Write-Step 'Current Codex CPU sample'
Measure-CodexCpu -Seconds 5 | Select-Object -First 10 | Format-Table -AutoSize

if ($Apply -and $PSCmdlet.ShouldProcess($script:ColdRunRoot, 'Create cold storage run directory')) {
  New-Item -ItemType Directory -Path $script:ColdRunRoot -Force | Out-Null
}

if ($StopCodexFirst -and $Apply) {
  Stop-CodexProcess
}
elseif ($StopCodexFirst -and -not $Apply) {
  Write-Warning '-StopCodexFirst was ignored because this is a dry run.'
}

Write-Step 'Collecting reset actions'

if (-not $SkipDesktopLogs) {
  Move-DesktopLog
}

foreach ($name in @('logs_2.sqlite', 'logs_2.sqlite-shm', 'logs_2.sqlite-wal')) {
  Move-PathToCold -Source (Join-Path $CodexHome $name) -Label $name
}

foreach ($name in @('cache', '.tmp', 'tmp')) {
  Move-PathToCold -Source (Join-Path $CodexHome $name) -Label $name -RecreateDirectory
}

if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
  Add-Report -Item 'roaming electron caches' -Action 'APPDATA unavailable' -Files 0 -Bytes 0
}
else {
  $roamingCodex = Join-Path $env:APPDATA 'Codex'
  foreach ($name in @('Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache')) {
    Move-PathToCold -Source (Join-Path $roamingCodex $name) -Label "roaming_$name"
  }
}

if (-not $SkipBackups) {
  Move-PathToCold -Source (Join-Path $CodexHome 'backups') -Label 'backups' -RecreateDirectory
}

if (-not $SkipArchivedSessions) {
  Move-PathToCold -Source (Join-Path $CodexHome 'archived_sessions') -Label 'archived_sessions' -RecreateDirectory
}

if (-not $SkipSessions) {
  Move-OldSession -SessionsDir (Join-Path $CodexHome 'sessions')
  Move-SessionIndex
}

Write-Step 'Summary'
$script:Report | Format-Table -AutoSize

if (-not $Apply) {
  Write-Line ''
  Write-Line 'Dry run only. Re-run with -Apply to move the data.'
  Write-Line 'Suggested aggressive fix:'
  Write-Line '  powershell -ExecutionPolicy Bypass -File .\codex-cpu-reset.ps1 -Apply -KeepDays 1 -StopCodexFirst -RestartCodex -ObserveSeconds 60'
  return
}

Save-RunArtifact

Write-Line ''
Write-Line "Moved data is safe in: $script:ColdRunRoot"
if ($script:ManifestPath) { Write-Line "Manifest: $script:ManifestPath" }
if ($script:ReportPath) { Write-Line "Report: $script:ReportPath" }
if ($script:RestorePath) { Write-Line "Restore script: $script:RestorePath" }
if ($script:ErrorPath) { Write-Line "Errors: $script:ErrorPath" }

if ($RestartCodex) {
  Start-CodexApp -StartCommand $CodexStartCommand -AppId $CodexAppId
  Start-Sleep -Seconds 15
}

if ($ObserveSeconds -gt 0) {
  Write-Step 'Post-reset Codex CPU observation'
  $rounds = [math]::Max([math]::Floor($ObserveSeconds / 10), 1)
  for ($i = 1; $i -le $rounds; $i++) {
    Write-Line "Sample $i / $rounds"
    Measure-CodexCpu -Seconds 10 | Select-Object -First 10 | Format-Table -AutoSize
  }
}

Write-Step 'Done'
Write-Line 'If Codex still idles above 20-30% after this, try a full Codex profile reset or reinstall.'
