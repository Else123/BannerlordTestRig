# Run:  powershell -NoProfile -Command "Invoke-Pester <repo>\tests\runner\TowerGuard.Tests.ps1"
# Pester 3.4 / Windows PowerShell 5.1. The tower guard (AC2 of TESTRIG-SPEC): no Bannerlord.exe on the tower during a job and
# the tower's <game>\Modules and Documents\Mount and Blade II Bannerlord unchanged (docs\JOB-PROTOCOL.md "Tower guard").
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\runner\Invoke-TestRig.ps1')

function New-TempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('rigguard-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    $d
}

Describe 'Get-RigTowerDocumentsPath' {
    It 'uses the configured path when given' {
        Get-RigTowerDocumentsPath -ConfiguredPath 'D:\Docs\Bannerlord' | Should Be 'D:\Docs\Bannerlord'
    }
    It 'defaults to the Mount and Blade II Bannerlord folder of the current user''s Documents folder' {
        $expected = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Mount and Blade II Bannerlord'
        Get-RigTowerDocumentsPath | Should Be $expected
        Get-RigTowerDocumentsPath -ConfiguredPath '  ' | Should Be $expected
    }
}

Describe 'Tower guard (Start-/Update-/Complete-RigTowerGuard)' {
    BeforeEach {
        $script:t = New-TempDir
        $script:game = Join-Path $script:t 'game'
        $script:docs = Join-Path $script:t 'docs\Mount and Blade II Bannerlord'
        New-Item -ItemType Directory -Path (Join-Path $script:game 'Modules\Native') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:docs 'Game Saves') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:game 'Modules\Native\SubModule.xml') -Value 'x'
        Set-Content -LiteralPath (Join-Path $script:docs 'Game Saves\a.sav') -Value 's'
        $script:gameProcesses = @()
        Mock Get-RigTowerGameProcessId { $script:gameProcesses }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    function Start-Guard { Start-RigTowerGuard -TowerGamePath $script:game -DocumentsPath $script:docs }

    It 'Passed when nothing ran and nothing changed' {
        $g = Start-Guard
        $r = Complete-RigTowerGuard -Guard $g
        $r.outcome | Should Be 'Passed'
        $r.gameRunningAtStart | Should Be $false
        $r.gameStartedDuringJob | Should Be $false
        @($r.modulesChanged).Count | Should Be 0
        @($r.documentsChanged).Count | Should Be 0
        (Format-RigTowerGuardLine -Guard $r) | Should Be ('tower guard: ' + $r.detail)
        $r.detail | Should Match 'no game or launcher process'
        $r.detail | Should Match 'Modules and Documents unchanged'
    }
    It 'RigError when a file below the tower Modules folder changed' {
        $g = Start-Guard
        Set-Content -LiteralPath (Join-Path $script:game 'Modules\Native\new.dll') -Value 'n'
        $r = Complete-RigTowerGuard -Guard $g
        $r.outcome | Should Be 'RigError'
        (@($r.modulesChanged) -contains 'Native/new.dll') | Should Be $true
        $r.detail | Should Match 'tower Modules changed: Native/new\.dll'
        (Format-RigTowerGuardLine -Guard $r) | Should Match '^ERROR tower guard: '
    }
    It 'Inconclusive (not RigError) when Documents changed and no game process was seen: the launcher and Steam cloud write there' {
        $g = Start-Guard
        Set-Content -LiteralPath (Join-Path $script:docs 'Game Saves\steam_autocloud.vdf') -Value 'n'
        $r = Complete-RigTowerGuard -Guard $g
        $r.outcome | Should Be 'Inconclusive'
        (@($r.documentsChanged) -contains 'Game Saves/steam_autocloud.vdf') | Should Be $true
        $r.detail | Should Match 'unattributed Documents change: Game Saves/steam_autocloud\.vdf'
        (Format-RigTowerGuardLine -Guard $r) | Should Match '^WARN tower guard: '
    }
    It 'a changed LastWriteTime in Documents counts as a change' {
        $f = Join-Path $script:docs 'Game Saves\a.sav'
        (Get-Item -LiteralPath $f).LastWriteTimeUtc = [datetime]'2026-01-01T00:00:00Z'
        $g = Start-Guard
        (Get-Item -LiteralPath $f).LastWriteTimeUtc = [datetime]'2026-01-02T00:00:00Z'
        (Complete-RigTowerGuard -Guard $g).outcome | Should Be 'Inconclusive'
    }
    It 'Inconclusive when a game or launcher process was already running at job start, even if nothing changed' {
        $script:gameProcesses = @(4711)
        $g = Start-Guard
        $r = Complete-RigTowerGuard -Guard $g
        $r.outcome | Should Be 'Inconclusive'
        $r.gameRunningAtStart | Should Be $true
        $r.gameStartedDuringJob | Should Be $false
        $r.detail | Should Match 'running at job start'
        $r.detail | Should Match 'game or launcher process'
        (Format-RigTowerGuardLine -Guard $r) | Should Match '^WARN tower guard: '
    }
    It 'Inconclusive (not RigError) when Documents changed while the user''s Bannerlord.exe was running' {
        $script:gameProcesses = @(4711)
        $g = Start-Guard
        Set-Content -LiteralPath (Join-Path $script:docs 'Game Saves\b.sav') -Value 'n'
        $r = Complete-RigTowerGuard -Guard $g
        $r.outcome | Should Be 'Inconclusive'
        $r.detail | Should Match 'cannot be attributed'
        (@($r.documentsChanged) -contains 'Game Saves/b.sav') | Should Be $true
    }
    It 'Inconclusive when Bannerlord.exe appeared during the job (seen by Update-RigTowerGuard)' {
        $g = Start-Guard
        Update-RigTowerGuard -Guard $g
        $script:gameProcesses = @(99)
        Update-RigTowerGuard -Guard $g
        $script:gameProcesses = @()   # gone again before the end
        $r = Complete-RigTowerGuard -Guard $g
        $r.outcome | Should Be 'Inconclusive'
        $r.gameRunningAtStart | Should Be $false
        $r.gameStartedDuringJob | Should Be $true
    }
    It 'Complete-RigTowerGuard samples the processes itself (a game running only at the end)' {
        $g = Start-Guard
        $script:gameProcesses = @(99)
        (Complete-RigTowerGuard -Guard $g).gameStartedDuringJob | Should Be $true
    }
    It 'a changed tower Modules folder wins over a running Bannerlord.exe (RigError)' {
        $script:gameProcesses = @(4711)
        $g = Start-Guard
        Set-Content -LiteralPath (Join-Path $script:game 'Modules\Native\new.dll') -Value 'n'
        (Complete-RigTowerGuard -Guard $g).outcome | Should Be 'RigError'
    }
    It 'the default Documents folder may be absent (empty tree, noted in the detail): still absent = Passed, created = Inconclusive' {
        Remove-Item -LiteralPath $script:docs -Recurse -Force
        Mock Get-RigTowerDocumentsPath { if ($ConfiguredPath) { $ConfiguredPath } else { $script:docs } }
        $g = Start-RigTowerGuard -TowerGamePath $script:game
        $r = Complete-RigTowerGuard -Guard $g
        $r.outcome | Should Be 'Passed'
        $r.detail | Should Match '\(Documents folder absent at start\)'
        $g = Start-RigTowerGuard -TowerGamePath $script:game
        New-Item -ItemType Directory -Path $script:docs -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:docs 'first.ini') -Value 'x'
        (Complete-RigTowerGuard -Guard $g).outcome | Should Be 'Inconclusive'
    }
    It 'a configured towerDocumentsPath that does not exist fails at start' {
        $missing = Join-Path $script:t 'nope'
        $msg = $null
        try { Start-RigTowerGuard -TowerGamePath $script:game -DocumentsPath $missing | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'towerDocumentsPath not found'
        $msg.Contains($missing) | Should Be $true
    }
    It 'fails closed: a junction in the Documents tree throws at start, naming the path' {
        $target = Join-Path $script:t 'elsewhere'
        New-Item -ItemType Directory -Path $target | Out-Null
        cmd /c mklink /J "$(Join-Path $script:docs 'link')" "$target" | Out-Null
        $msg = $null
        try { Start-Guard | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should Match '^tower guard: cannot watch '
        $msg.Contains($script:docs) | Should Be $true
    }
    It 'the window text appears in the record and in the console line' {
        $g = Start-Guard
        $r = Complete-RigTowerGuard -Guard $g -Window 'until publish only, job not waited for'
        $r.window | Should Be 'until publish only, job not waited for'
        (Format-RigTowerGuardLine -Guard $r) | Should Match '^tower guard \(until publish only, job not waited for\): '
        (Complete-RigTowerGuard -Guard $g).window | Should Be $null
    }
    It 'lists at most 20 changed paths in the detail but keeps all of them in the record' {
        $g = Start-Guard
        1..25 | ForEach-Object { Set-Content -LiteralPath (Join-Path $script:docs "Game Saves\n$_.sav") -Value 'n' }
        $r = Complete-RigTowerGuard -Guard $g
        @($r.documentsChanged).Count | Should Be 25
        $r.detail | Should Match 'and 5 more'
    }
}

Describe 'Complete-RigTowerGuard with a tree that cannot be snapshotted at the end' {
    BeforeEach {
        $script:t = New-TempDir
        $script:game = Join-Path $script:t 'game'
        New-Item -ItemType Directory -Path (Join-Path $script:game 'Modules') -Force | Out-Null
        $script:docs = Join-Path $script:t 'docs'
        New-Item -ItemType Directory -Path $script:docs | Out-Null
        Mock Get-RigTowerGameProcessId { @() }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    It 'gives a RigError record instead of throwing (the job result survives)' {
        $g = Start-RigTowerGuard -TowerGamePath $script:game -DocumentsPath $script:docs
        Mock Get-RigGuardSnapshot { throw 'disk gone' }
        $r = Complete-RigTowerGuard -Guard $g
        $r.outcome | Should Be 'RigError'
        $r.detail | Should Match '^tower guard could not snapshot .*: disk gone'
        @($r.modulesChanged).Count | Should Be 0
        (Get-RigTowerGuardExitCode -Guard $r) | Should Be 1
        # Close-RigTowerGuard prints that record and returns 1 (the mock above is still active)
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
        Close-RigTowerGuard -Guard $g -Code 0 -Window 'w' | Should Be 1
        ($script:lines -join "`n") | Should Match '^ERROR tower guard \(w\): tower guard could not snapshot'
    }
}

Describe 'Get-RigTowerGameProcessId (real processes)' {
    BeforeEach { $script:t = New-TempDir; $script:proc = $null }
    AfterEach {
        if ($script:proc) { Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 200
        Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'finds a process whose executable lies below the game bin folder (any name), not one elsewhere, and does not throw on unreadable paths' {
        $bin = Join-Path $script:t 'bin\Win64_Shipping_Client'
        New-Item -ItemType Directory -Path $bin | Out-Null
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination (Join-Path $bin 'Fake.Launcher.exe')
        $script:proc = Start-Process -FilePath (Join-Path $bin 'Fake.Launcher.exe') -ArgumentList '/c', 'ping -n 30 127.0.0.1 >nul' -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 500
        (@(Get-RigTowerGameProcessId -GameBinPath (Join-Path $script:t 'bin')) -contains $script:proc.Id) | Should Be $true
        @(Get-RigTowerGameProcessId -GameBinPath (Join-Path $script:t 'other')).Count | Should Be 0
        @(Get-RigTowerGameProcessId -GameBinPath (Join-Path $script:t 'bin\Win64')).Count | Should Be 0
    }
}

Describe 'Format-RigTowerGuardLine / Get-RigTowerGuardExitCode' {
    It 'maps the outcome to the runner exit codes (Passed 0, Inconclusive 3, RigError 1, unknown 1)' {
        Get-RigTowerGuardExitCode -Guard ([pscustomobject]@{ outcome = 'Passed' }) | Should Be 0
        Get-RigTowerGuardExitCode -Guard ([pscustomobject]@{ outcome = 'Inconclusive' }) | Should Be 3
        Get-RigTowerGuardExitCode -Guard ([pscustomobject]@{ outcome = 'RigError' }) | Should Be 1
        Get-RigTowerGuardExitCode -Guard ([pscustomobject]@{ outcome = 'bogus' }) | Should Be 1
        Get-RigTowerGuardExitCode -Guard $null | Should Be 0
    }
    It 'Join-RigExitCode keeps the precedence 1 > 3 > 2 > 0' {
        Join-RigExitCode 0 3 | Should Be 3
        Join-RigExitCode 3 2 | Should Be 3
        Join-RigExitCode 2 0 | Should Be 2
        Join-RigExitCode 1 3 | Should Be 1
        Join-RigExitCode 3 1 | Should Be 1
        Join-RigExitCode 0 0 | Should Be 0
    }
}

Describe 'Close-RigTowerGuard (early exits of Start-TestRigJob)' {
    BeforeEach {
        $script:t = New-TempDir
        $script:game = Join-Path $script:t 'game'
        New-Item -ItemType Directory -Path (Join-Path $script:game 'Modules') -Force | Out-Null
        $script:docs = Join-Path $script:t 'docs'
        New-Item -ItemType Directory -Path $script:docs | Out-Null
        $script:gameProcesses = @()
        $script:lines = @()
        Mock Get-RigTowerGameProcessId { $script:gameProcesses }
        Mock Write-Host { $script:lines += "$Object" }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    It 'without a guard it returns the code unchanged and prints nothing' {
        Close-RigTowerGuard -Guard $null -Code 3 -Window 'w' | Should Be 3
        $script:lines.Count | Should Be 0
    }
    It 'prints the guard line and joins the codes' {
        $g = Start-RigTowerGuard -TowerGamePath $script:game -DocumentsPath $script:docs
        Close-RigTowerGuard -Guard $g -Code 2 -Window 'until publish only, job not waited for' | Should Be 2
        ($script:lines -join "`n") | Should Match '^tower guard \(until publish only, job not waited for\): no game or launcher process'
        $script:lines = @()
        $script:gameProcesses = @(7)
        Close-RigTowerGuard -Guard $g -Code 0 -Window 'w' | Should Be 3
        ($script:lines -join "`n") | Should Match 'WARN tower guard \(w\): .*started on the tower during the job'
        $script:lines = @()
        Set-Content -LiteralPath (Join-Path $script:docs 'x.txt') -Value 'x'
        Close-RigTowerGuard -Guard $g -Code 2 -Window 'w' | Should Be 3
        ($script:lines -join "`n") | Should Match 'WARN tower guard \(w\): .*tower Documents changed: x\.txt'
        $script:lines = @()
        Set-Content -LiteralPath (Join-Path $script:game 'Modules\y.dll') -Value 'y'
        Close-RigTowerGuard -Guard $g -Code 3 -Window 'w' | Should Be 1
        ($script:lines -join "`n") | Should Match 'ERROR tower guard \(w\): tower Modules changed: y\.dll'
    }
}

Describe 'Wait-RigJob -TowerGuard' {
    BeforeEach {
        $script:polls = 0
        $script:target = [pscustomobject]@{ host = 'h' }
        Mock Update-RigTowerGuard { $script:polls++ }
    }
    It 'samples the guard on every poll (also the one that sees the job done)' {
        Mock Get-JobState { [pscustomobject]@{ jobJson = $true; claimed = $true; withdrawn = $false; state = $null; done = $true } }
        Wait-RigJob -Target $script:target -JobId 'j' -ClaimTimeoutSeconds 1 -StaleSeconds 1 -OverallSeconds 5 -PollSeconds 0.01 `
            -AbortWaitSeconds 1 -TowerGuard ([pscustomobject]@{ g = 1 }) | Should Be 'Done'
        $script:polls | Should Be 1
    }
    It 'also samples while the abort is awaited after the overall deadline' {
        $script:n = 0
        Mock Get-JobState { $script:n++; [pscustomobject]@{ jobJson = $false; claimed = $true; withdrawn = $false; state = $null; done = ($script:n -ge 3) } }
        Mock Send-JobAbort { }
        Wait-RigJob -Target $script:target -JobId 'j' -ClaimTimeoutSeconds 1 -StaleSeconds 100 -OverallSeconds 0 -PollSeconds 0.01 `
            -AbortWaitSeconds 5 -TowerGuard ([pscustomobject]@{ g = 1 }) | Should Be 'DeadlineDone'
        $script:polls | Should Be 3
    }
    It 'works without a guard' {
        Mock Get-JobState { [pscustomobject]@{ jobJson = $true; claimed = $true; withdrawn = $false; state = $null; done = $true } }
        Wait-RigJob -Target $script:target -JobId 'j' -ClaimTimeoutSeconds 1 -StaleSeconds 1 -OverallSeconds 5 -PollSeconds 0.01 `
            -AbortWaitSeconds 1 -TowerGuard $null | Should Be 'Done'
        $script:polls | Should Be 0
    }
}

Describe 'Publish-RigResult with a tower guard' {
    BeforeEach {
        $script:t = New-TempDir
        $script:id = '20261031-153000-a1b2'
        $script:rd = Join-Path $script:t $script:id
        New-Item -ItemType Directory -Path (Join-Path $script:rd 'r1') | Out-Null
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
        [IO.File]::WriteAllText((Join-Path $script:rd 'done.json'), '{"schema":1,"jobId":"20261031-153000-a1b2","status":"completed","runs":[{"runId":"r1","exitClass":"Completed"}]}')
        [IO.File]::WriteAllText((Join-Path $script:rd 'r1\run-result.json'), '{"schema":1,"status":"Completed","daysReached":1,"scenarios":[{"id":"soak","status":"Passed","seconds":25}]}')
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    function New-GuardRecord([string]$Outcome, [string]$Detail = 'something') {
        [ordered]@{
            outcome = $Outcome; detail = $Detail; gameRunningAtStart = $false; gameStartedDuringJob = $false
            modulesChanged = @(); documentsChanged = @()
        }
    }
    function Publish([hashtable]$Extra = @{}) { Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -SkipChecks @Extra }
    function Get-JobResult { Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json }

    It 'no guard: exit 0 and towerGuard null in job-result.json' {
        Publish | Should Be 0
        $r = Get-JobResult
        ($r.PSObject.Properties.Name -contains 'towerGuard') | Should Be $true
        $r.towerGuard | Should Be $null
        ($script:lines -join "`n") | Should Not Match 'tower guard'
    }
    It 'Passed: exit 0, record and console line' {
        Publish @{ TowerGuard = (New-GuardRecord 'Passed' 'all fine') } | Should Be 0
        $r = Get-JobResult
        $r.towerGuard.outcome | Should Be 'Passed'
        $r.towerGuard.detail | Should Be 'all fine'
        @($r.towerGuard.modulesChanged).Count | Should Be 0
        ($script:lines -contains 'tower guard: all fine') | Should Be $true
    }
    It 'Inconclusive raises a passing job to exit 3 and WARNs' {
        Publish @{ TowerGuard = (New-GuardRecord 'Inconclusive' 'game was running') } | Should Be 3
        (Get-JobResult).exitCode | Should Be 3
        ($script:lines -contains 'WARN tower guard: game was running') | Should Be $true
    }
    It 'RigError gives exit 1' {
        Publish @{ TowerGuard = (New-GuardRecord 'RigError' 'Documents changed') } | Should Be 1
        ($script:lines -contains 'ERROR tower guard: Documents changed') | Should Be $true
    }
    It 'Inconclusive does not hide a test failure behind 2 (precedence 3 > 2)' {
        [IO.File]::WriteAllText((Join-Path $script:rd 'r1\run-result.json'), '{"schema":1,"status":"Completed","daysReached":1,"scenarios":[{"id":"soak","status":"Failed","seconds":25}]}')
        Publish @{ TowerGuard = (New-GuardRecord 'Inconclusive') } | Should Be 3
        (Get-JobResult).runs[0].result.scenarios[0].status | Should Be 'Failed'
    }
}
