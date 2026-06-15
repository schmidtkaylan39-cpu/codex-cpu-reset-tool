BeforeAll {
  $script:RepoRoot = Split-Path -Parent $PSScriptRoot
  $script:ResetScript = Join-Path $script:RepoRoot 'codex-cpu-reset.ps1'

  function New-FakeCodexHome {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-reset-test-" + [guid]::NewGuid().ToString('N'))
    $codex = Join-Path $root '.codex'
    New-Item -ItemType Directory -Path $codex -Force | Out-Null

    foreach ($dir in @('cache', 'backups', 'archived_sessions', 'sessions', 'tmp', '.tmp')) {
      New-Item -ItemType Directory -Path (Join-Path $codex $dir) -Force | Out-Null
    }

    Set-Content -LiteralPath (Join-Path $codex 'cache\cache.txt') -Value 'cache'
    Set-Content -LiteralPath (Join-Path $codex 'backups\backup.txt') -Value 'backup'
    Set-Content -LiteralPath (Join-Path $codex 'archived_sessions\archived.jsonl') -Value '{}'
    Set-Content -LiteralPath (Join-Path $codex 'session_index.jsonl') -Value '{}'

    $today = Get-Date
    $todayDir = Join-Path $codex ("sessions\{0:yyyy}\\{0:MM}\\{0:dd}" -f $today)
    New-Item -ItemType Directory -Path $todayDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $todayDir ("rollout-{0:yyyy-MM-dd}T00-00-00-today-thread.jsonl" -f $today)) -Value '{}'

    $oldDir = Join-Path $codex 'sessions\2020\01\01'
    New-Item -ItemType Directory -Path $oldDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $oldDir 'rollout-2020-01-01T00-00-00-old-thread.jsonl') -Value '{}'
    Set-Content -LiteralPath (Join-Path $oldDir 'rollout-2020-01-01T00-00-00-keep-me-thread.jsonl') -Value '{}'

    [PSCustomObject]@{
      Root  = $root
      Codex = $codex
      Cold  = Join-Path $root 'cold'
    }
  }

}

Describe 'codex-cpu-reset.ps1' {
  AfterEach {
    if ($script:CurrentFakeRoot -and (Test-Path -LiteralPath $script:CurrentFakeRoot)) {
      Remove-Item -LiteralPath $script:CurrentFakeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:CurrentFakeRoot = $null
  }

  It 'dry run does not move files' {
    $fake = New-FakeCodexHome
    $script:CurrentFakeRoot = $fake.Root

    & $script:ResetScript -CodexHome $fake.Codex -ColdStorageRoot $fake.Cold -SkipDesktopLogs | Out-Null

    Test-Path -LiteralPath (Join-Path $fake.Codex 'cache\cache.txt') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $fake.Codex 'backups\backup.txt') | Should -BeTrue
    Test-Path -LiteralPath $fake.Cold | Should -BeFalse
  }

  It 'apply moves cache, backups, archived sessions, and session index to cold storage' {
    $fake = New-FakeCodexHome
    $script:CurrentFakeRoot = $fake.Root

    & $script:ResetScript -Apply -CodexHome $fake.Codex -ColdStorageRoot $fake.Cold -SkipDesktopLogs | Out-Null

    Test-Path -LiteralPath (Join-Path $fake.Codex 'cache\cache.txt') | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $fake.Codex 'backups\backup.txt') | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $fake.Codex 'archived_sessions\archived.jsonl') | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $fake.Codex 'session_index.jsonl') | Should -BeFalse
    (Get-ChildItem -LiteralPath $fake.Cold -Recurse -File | Measure-Object).Count | Should -BeGreaterThan 0
  }

  It 'recreates moved directories after apply' {
    $fake = New-FakeCodexHome
    $script:CurrentFakeRoot = $fake.Root

    & $script:ResetScript -Apply -CodexHome $fake.Codex -ColdStorageRoot $fake.Cold -SkipDesktopLogs | Out-Null

    Test-Path -LiteralPath (Join-Path $fake.Codex 'cache') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $fake.Codex 'backups') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $fake.Codex 'archived_sessions') | Should -BeTrue
  }

  It 'KeepDays 1 keeps today session and moves older sessions' {
    $fake = New-FakeCodexHome
    $script:CurrentFakeRoot = $fake.Root

    & $script:ResetScript -Apply -KeepDays 1 -CodexHome $fake.Codex -ColdStorageRoot $fake.Cold -SkipDesktopLogs | Out-Null

    (Get-ChildItem -LiteralPath (Join-Path $fake.Codex 'sessions') -Recurse -File -Filter '*today-thread.jsonl').Count | Should -Be 1
    (Get-ChildItem -LiteralPath (Join-Path $fake.Codex 'sessions') -Recurse -File -Filter '*old-thread.jsonl').Count | Should -Be 0
  }

  It 'KeepThreadId preserves a matching older session JSONL' {
    $fake = New-FakeCodexHome
    $script:CurrentFakeRoot = $fake.Root

    & $script:ResetScript -Apply -KeepDays 1 -KeepThreadId 'keep-me-thread' -CodexHome $fake.Codex -ColdStorageRoot $fake.Cold -SkipDesktopLogs | Out-Null

    (Get-ChildItem -LiteralPath (Join-Path $fake.Codex 'sessions') -Recurse -File -Filter '*keep-me-thread.jsonl').Count | Should -Be 1
  }

  It 'rejects cold storage inside .codex' {
    $fake = New-FakeCodexHome
    $script:CurrentFakeRoot = $fake.Root
    $inside = Join-Path $fake.Codex 'cold'

    { & $script:ResetScript -CodexHome $fake.Codex -ColdStorageRoot $inside -SkipDesktopLogs } | Should -Throw
  }

  It 'allows cold storage with a .codex-old prefix' {
    $fake = New-FakeCodexHome
    $script:CurrentFakeRoot = $fake.Root
    $prefix = Join-Path $fake.Root '.codex-old'

    { & $script:ResetScript -CodexHome $fake.Codex -ColdStorageRoot $prefix -SkipDesktopLogs } | Should -Not -Throw
  }

  It 'does not crash when APPDATA and LOCALAPPDATA are missing' {
    $fake = New-FakeCodexHome
    $script:CurrentFakeRoot = $fake.Root

    $oldAppData = $env:APPDATA
    $oldLocalAppData = $env:LOCALAPPDATA
    try {
      $env:APPDATA = ''
      $env:LOCALAPPDATA = ''
      { & $script:ResetScript -CodexHome $fake.Codex -ColdStorageRoot $fake.Cold } | Should -Not -Throw
    }
    finally {
      $env:APPDATA = $oldAppData
      $env:LOCALAPPDATA = $oldLocalAppData
    }
  }

  It 'creates manifest, report, and restore script on apply' {
    $fake = New-FakeCodexHome
    $script:CurrentFakeRoot = $fake.Root

    & $script:ResetScript -Apply -CodexHome $fake.Codex -ColdStorageRoot $fake.Cold -SkipDesktopLogs | Out-Null
    $run = Get-ChildItem -LiteralPath $fake.Cold -Directory | Select-Object -First 1

    Test-Path -LiteralPath (Join-Path $run.FullName 'manifest.json') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $run.FullName 'report.json') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $run.FullName 'restore-codex-cpu-reset.ps1') | Should -BeTrue
  }

  It 'Apply WhatIf does not move files' {
    $fake = New-FakeCodexHome
    $script:CurrentFakeRoot = $fake.Root

    & $script:ResetScript -Apply -WhatIf -CodexHome $fake.Codex -ColdStorageRoot $fake.Cold -SkipDesktopLogs | Out-Null

    Test-Path -LiteralPath (Join-Path $fake.Codex 'cache\cache.txt') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $fake.Codex 'session_index.jsonl') | Should -BeTrue
  }

  It 'accepts Windows Search mitigation as an opt-in dry run' {
    $fake = New-FakeCodexHome
    $script:CurrentFakeRoot = $fake.Root

    $output = & $script:ResetScript -DisableWindowsSearch -CodexHome $fake.Codex -ColdStorageRoot $fake.Cold -SkipDesktopLogs 6>&1 | Out-String

    $output | Should -Match 'windows search service'
    $output | Should -Match 'would disable'
  }

  It 'accepts Defender exclusions as an opt-in dry run' {
    $fake = New-FakeCodexHome
    $script:CurrentFakeRoot = $fake.Root

    $output = & $script:ResetScript -AddDefenderExclusions -CodexHome $fake.Codex -ColdStorageRoot $fake.Cold -SkipDesktopLogs 6>&1 | Out-String

    $output | Should -Match 'defender path exclusions'
    $output | Should -Match 'would add'
  }
}
