# Run:  powershell -NoProfile -Command "Invoke-Pester <repo>\tests\runner\Invoke-TestRig.CwChecks.Tests.ps1"
# Pester 3.4 / Windows PowerShell 5.1. Suite checks (S10 #61, F-S10-1/6): PostRunChecks (CW-2 per run) and JobChecks
# (CW-1 per job) run by the runner after the fetch, their exit codes, the offline re-judgement (Update-RigJobResult), plus
# the runner review fixes (suite name normalisation, Build-Package without the suite table, -PackageFrom with
# CoherentWarAI). Fake check scripts in a fixture workspace stand in for the CoherentWarAI tools: hermetic and fast.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\runner\Invoke-TestRig.ps1')
$script:invokeScript = Join-Path $here '..\..\runner\Invoke-TestRig.ps1'

# Fake CW-2: the "log" is the JSON array of verdict rows to report; a log starting with NORESULT makes it exit 1 without
# a result. Records its arguments next to the result file.
$script:fakeCommandLog = @'
param([string]$LogPath, [string]$Mode, [int]$MinDays = -1, [string]$ResultPath = '')
[IO.File]::WriteAllText($ResultPath + '.args', "$Mode|$MinDays|$LogPath")
$spec = [IO.File]::ReadAllText($LogPath)
if ($spec.StartsWith('NORESULT')) { Write-Host 'Log file not parseable'; exit 1 }
$parsed = ConvertFrom-Json -InputObject $spec   # one Object[] (piping would wrap it once more)
$rows = @($parsed)
$doc = @{ schema = 1; mode = $Mode; days = $MinDays + 1; rows = $rows }
[IO.File]::WriteAllText($ResultPath, (ConvertTo-Json -InputObject $doc -Depth 4))
if (@($rows | Where-Object { $_.verdict -eq 'FAIL' }).Count -gt 0) { exit 1 }
exit 0
'@
# Fake CW-1: copies <job>\compare-spec.json to the result path; without it exits 1 (job folder unusable).
$script:fakeCompare = @'
param([string]$JobPath, [string]$ResultPath = '', [string]$JobManifestPath = '')
[IO.File]::WriteAllText((Join-Path $JobPath 'compare.args'), "$JobPath|$ResultPath|$JobManifestPath")
$spec = Join-Path $JobPath 'compare-spec.json'
if (-not (Test-Path -LiteralPath $spec)) { Write-Host "No run folders r<N> in $JobPath"; exit 1 }
Copy-Item -LiteralPath $spec -Destination $ResultPath
exit 0
'@

function New-CwFixture {
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $ws = Join-Path $root 'ws'
    $tools = Join-Path $ws 'BannerlordCoherentWarAI\tools'
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $tools 'Check-CommandLog.ps1'), $script:fakeCommandLog)
    [IO.File]::WriteAllText((Join-Path $tools 'Compare-Ac25a.ps1'), $script:fakeCompare)
    $id = '20261103-170000-c0de'
    $rd = Join-Path $root "out\results\$id"
    New-Item -ItemType Directory -Path $rd -Force | Out-Null
    [pscustomobject]@{ Root = $root; Workspace = $ws; Tools = $tools; JobId = $id; ResultDir = $rd; OutRoot = (Join-Path $root 'out') }
}

function Write-CwDone([string]$Status, [string[]]$RunIds, [string]$ExitClass = 'Completed') {
    $runs = @($RunIds | ForEach-Object { '{"runId":"' + $_ + '","exitClass":"' + $ExitClass + '"}' }) -join ','
    [IO.File]::WriteAllText((Join-Path $script:f.ResultDir 'done.json'), ('{"schema":1,"jobId":"' + $script:f.JobId + '","status":"' + $Status + '","runs":[' + $runs + ']}'))
}

# A run folder; $Rows = the JSON array the fake CW-2 reports ($null = no CoherentWarAI.log), $Result = run-result.json text.
function Write-CwRun([string]$RunId, [AllowNull()][string]$Rows, [string]$Result = '{"schema":1,"status":"Completed","daysReached":3,"scenarios":[{"id":"soak","status":"Passed"}]}') {
    $dir = Join-Path $script:f.ResultDir $RunId
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir 'run-result.json'), $Result)
    if ($Rows) { [IO.File]::WriteAllText((Join-Path $dir 'CoherentWarAI.log'), $Rows) }
}

$script:passRows = '[{"ac":"AC1","verdict":"PASS","evidence":"ok"},{"ac":"AC10","verdict":"N/A for mode","evidence":"-"},{"ac":"AC25a","verdict":"MANUAL","evidence":"CW-1"}]'
$script:failRows = '[{"ac":"AC1","verdict":"PASS","evidence":"ok"},{"ac":"AC10","verdict":"FAIL","evidence":"3 Command lines with the feature off"}]'
$script:warnRows = '[{"ac":"AC1","verdict":"PASS","evidence":"ok"},{"ac":"AC13","verdict":"INSUFFICIENT DATA","evidence":"2 of 3 days"},{"ac":"AC26","verdict":"WARN - verify fallback","evidence":"1 potential violation"}]'

# Test suites with the real check definitions: a soak suite with CW-2 only, and a two-run scenario suite with CW-2 and CW-1.
$script:cwSoak = @{ Harness = 'TestRig'; Mode = 'WarSails'; Seed = 1; Days = 3; Kind = 'soak'; WithCoherentWarAI = $true
    ExtraModules = @(); TailModules = @(); PostRunChecks = @($script:RigCommandLogCheck) }
$script:cwJob = @{ Harness = 'TestRig'; Mode = 'WarSails'; Seed = 1; Days = 3; Kind = 'scenarios'; WithCoherentWarAI = $true
    ExtraModules = @(); TailModules = @('CoherentWarAI.Scenarios')
    PostRunChecks = @($script:RigCommandLogCheck); JobChecks = $script:RigSuites['CW1'].JobChecks
    Runs = @(
        @{ RunId = 'r1'; Seed = 1; Mode = 'WarSails'; Scenarios = @('x.digest'); HardTimeoutMinutes = 5; ExpectedExitClass = 'Completed' },
        @{ RunId = 'r2'; Seed = 1; Mode = 'FeatureOff'; Scenarios = @('x.digest'); HardTimeoutMinutes = 5; ExpectedExitClass = 'Completed' }) }
$script:jobRuns2 = @([pscustomobject]@{ runId = 'r1'; mode = 'WarSails' }, [pscustomobject]@{ runId = 'r2'; mode = 'FeatureOff' })
$script:scenarioResult = '{"schema":1,"status":"Completed","daysReached":3,"scenarios":[{"id":"x.digest","status":"Passed"}]}'

function Get-CwJobResult { Get-Content -LiteralPath (Join-Path $script:f.ResultDir 'job-result.json') -Raw | ConvertFrom-Json }
function Get-CwLines([string]$Pattern) { @($script:lines | Where-Object { $_ -match $Pattern }) }
function Set-CompareSpec([string[]]$Verdicts, [string]$Violation = '') {
    $names = @('coherentwarai.ac25a-invariant', 'coherentwarai.ac25a-armydays')
    $checks = for ($i = 0; $i -lt $Verdicts.Count; $i++) {
        $v = if ($i -eq 0 -and $Violation) { ',"violations":["' + $Violation + '"]' } else { ',"violations":[]' }
        '{"check":"' + $names[$i] + '","verdict":"' + $Verdicts[$i] + '","detail":"detail ' + $i + '"' + $v + '}'
    }
    [IO.File]::WriteAllText((Join-Path $script:f.ResultDir 'compare-spec.json'), ('{"schema":1,"checks":[' + (@($checks) -join ',') + ']}'))
}

Describe 'Suite table: PostRunChecks and JobChecks (F-S10-1/6)' {
    It 'L1 and CW1 run CW-2 (Check-CommandLog.ps1 on CoherentWarAI.log); CW1 also runs CW-1 (Compare-Ac25a.ps1)' {
        foreach ($s in 'L1', 'CW1') {
            $c = @($script:RigSuites[$s].PostRunChecks)
            $c.Count | Should Be 1
            $c[0].Id | Should BeExactly 'coherentwarai.command-log'
            $c[0].Script | Should BeExactly 'BannerlordCoherentWarAI\tools\Check-CommandLog.ps1'
            $c[0].Log | Should BeExactly 'CoherentWarAI.log'
        }
        $j = @($script:RigSuites['CW1'].JobChecks)
        $j.Count | Should Be 1
        $j[0].Script | Should BeExactly 'BannerlordCoherentWarAI\tools\Compare-Ac25a.ps1'
        $j[0].ResultFile | Should BeExactly 'ac25a-compare.json'
        $script:RigSuites['L1'].ContainsKey('JobChecks') | Should Be $false
    }
    It 'every suite with a check loads CoherentWarAI, and no suite without it has one' {
        foreach ($name in $script:RigSuites.Keys) {
            $s = $script:RigSuites[$name]
            ($s.ContainsKey('PostRunChecks') -or $s.ContainsKey('JobChecks')) | Should Be ([bool]$s.WithCoherentWarAI)
        }
    }
    It 'the scripts the suite table names exist in the CoherentWarAI repo next to this repo' -Skip:(-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $here))) 'BannerlordCoherentWarAI\tools'))) {
        $ws = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $here))
        foreach ($check in @($script:RigSuites['CW1'].PostRunChecks) + @($script:RigSuites['CW1'].JobChecks)) {
            Test-Path -LiteralPath (Join-Path $ws $check.Script) -PathType Leaf | Should Be $true
        }
    }
}

Describe 'Publish-RigResult PostRunChecks (CW-2 per run)' {
    BeforeEach {
        $script:f = New-CwFixture
        $script:RigSuites['CWSOAK'] = $script:cwSoak
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
    }
    AfterEach { $script:RigSuites.Remove('CWSOAK') }
    function Publish([object[]]$JobRuns = @([pscustomobject]@{ runId = 'r1'; mode = 'WarSails' }), [switch]$SkipChecks) {
        Publish-RigResult -ResultDir $script:f.ResultDir -JobId $script:f.JobId -Days 3 -Suite CWSOAK -JobRuns $JobRuns `
            -WorkspaceRoot $script:f.Workspace -SkipChecks:$SkipChecks
    }

    It 'all rows met: exit 0, one Passed row with expected/actual, the run mode and -MinDays = days passed, mode in job-result' {
        Write-CwDone completed @('r1'); Write-CwRun r1 $script:passRows
        (Publish) | Should Be 0
        $row = @(Get-CwLines '^r1\s+CWSOAK-coherentwarai\.command-log ')
        $row.Count | Should Be 1
        $row[0] | Should Match 'CWSOAK-coherentwarai\.command-log Passed\s+expected no FAIL, actual 1 PASS, 1 N/A for mode, 1 MANUAL'
        $row[0] | Should Match ([regex]::Escape((Join-Path $script:f.ResultDir 'r1\coherentwarai.command-log.json')))
        (Get-CwLines '^    ').Count | Should Be 0
        $recorded = [IO.File]::ReadAllText((Join-Path $script:f.ResultDir 'r1\coherentwarai.command-log.json.args'))
        $recorded | Should BeExactly ('WarSails|3|' + (Join-Path $script:f.ResultDir 'r1\CoherentWarAI.log'))
        $r = Get-CwJobResult
        $r.runs[0].mode | Should BeExactly 'WarSails'
        $r.runs[0].checks[0].id | Should BeExactly 'coherentwarai.command-log'
        $r.runs[0].checks[0].outcome | Should BeExactly 'Passed'
        @($r.runs[0].checks[0].rows).Count | Should Be 0
    }
    It 'a FAIL row: exit 2, the row Failed and the FAIL row with expected and actual below it, also in job-result' {
        Write-CwDone completed @('r1'); Write-CwRun r1 $script:failRows
        (Publish) | Should Be 2
        (Get-CwLines '^r1\s+CWSOAK-coherentwarai\.command-log Failed ').Count | Should Be 1
        (Get-CwLines '^    AC10: expected PASS, actual FAIL \(FAIL\) - 3 Command lines with the feature off$').Count | Should Be 1
        $c = (Get-CwJobResult).runs[0].checks[0]
        $c.outcome | Should BeExactly 'Failed'
        $c.rows[0].ac | Should BeExactly 'AC10'
        $c.rows[0].expected | Should BeExactly 'PASS'
        $c.rows[0].actual | Should BeExactly 'FAIL'
    }
    It 'INSUFFICIENT DATA and WARN rows are warnings: exit 0, Passed, each shown as WARN' {
        Write-CwDone completed @('r1'); Write-CwRun r1 $script:warnRows
        (Publish) | Should Be 0
        (Get-CwLines '^r1\s+CWSOAK-coherentwarai\.command-log Passed ').Count | Should Be 1
        (Get-CwLines '^    AC13: expected PASS, actual INSUFFICIENT DATA \(WARN\)').Count | Should Be 1
        (Get-CwLines '^    AC26: expected PASS, actual WARN - verify fallback \(WARN\)').Count | Should Be 1
    }
    It 'an unknown verdict is a rig error: exit 1' {
        Write-CwDone completed @('r1'); Write-CwRun r1 '[{"ac":"AC1","verdict":"MAYBE","evidence":"?"}]'
        (Publish) | Should Be 1
        (Get-CwLines '^r1\s+CWSOAK-coherentwarai\.command-log Error ').Count | Should Be 1
        (Get-CwLines '^    AC1: expected PASS, actual MAYBE \(UNKNOWN\)').Count | Should Be 1
    }
    It 'a missing log: exit 1 with an Error row naming it; the script is not called' {
        Write-CwDone completed @('r1'); Write-CwRun r1 $null
        (Publish) | Should Be 1
        (Get-CwLines '^r1\s+CWSOAK-coherentwarai\.command-log Error\s+log missing: .*CoherentWarAI\.log').Count | Should Be 1
        Test-Path -LiteralPath (Join-Path $script:f.ResultDir 'r1\coherentwarai.command-log.json.args') | Should Be $false
    }
    It 'a missing script: exit 1 with an Error row naming it' {
        Remove-Item -LiteralPath (Join-Path $script:f.Tools 'Check-CommandLog.ps1')
        Write-CwDone completed @('r1'); Write-CwRun r1 $script:passRows
        (Publish) | Should Be 1
        (Get-CwLines '^r1\s+CWSOAK-coherentwarai\.command-log Error\s+check script not found: .*Check-CommandLog\.ps1').Count | Should Be 1
    }
    It 'a script that writes no result: exit 1 with its exit code and last line; a stale result from before does not count' {
        Write-CwDone completed @('r1'); Write-CwRun r1 'NORESULT'
        [IO.File]::WriteAllText((Join-Path $script:f.ResultDir 'r1\coherentwarai.command-log.json'), ('{"rows":' + $script:passRows + '}'))
        (Publish) | Should Be 1
        (Get-CwLines '^r1\s+CWSOAK-coherentwarai\.command-log Error\s+Check-CommandLog\.ps1 wrote no result \(exit 1\): Log file not parseable').Count | Should Be 1
    }
    It 'a run without a job.json mode: exit 1 (the mode decides AC1/AC2/AC10)' {
        Write-CwDone completed @('r1'); Write-CwRun r1 $script:passRows
        (Publish -JobRuns @()) | Should Be 1
        (Get-CwLines '^r1\s+CWSOAK-coherentwarai\.command-log Error\s+run mode unknown').Count | Should Be 1
        (Get-CwJobResult).runs[0].mode | Should Be $null
    }
    It 'a stale result file is deleted on every path: missing log, unknown mode and missing script' {
        $stale = Join-Path $script:f.ResultDir 'r1\coherentwarai.command-log.json'
        $writeStale = { [IO.File]::WriteAllText($stale, ('{"rows":' + $script:passRows + '}')) }
        Write-CwDone completed @('r1'); Write-CwRun r1 $null
        & $writeStale
        (Publish) | Should Be 1   # log missing
        Test-Path -LiteralPath $stale | Should Be $false
        Write-CwRun r1 $script:passRows
        & $writeStale
        (Publish -JobRuns @()) | Should Be 1   # run mode unknown
        Test-Path -LiteralPath $stale | Should Be $false
        Remove-Item -LiteralPath (Join-Path $script:f.Tools 'Check-CommandLog.ps1')
        & $writeStale
        (Publish) | Should Be 1   # script missing
        Test-Path -LiteralPath $stale | Should Be $false
    }
    It 'a run that is not Completed is not checked (its exit class decides: Crashed = 2), checks empty in job-result' {
        Write-CwDone completed @('r1') -ExitClass Crashed; Write-CwRun r1 $script:passRows
        (Publish) | Should Be 2
        (Get-CwLines 'coherentwarai\.command-log').Count | Should Be 0
        @((Get-CwJobResult).runs[0].checks).Count | Should Be 0
    }
    It '-SkipChecks runs no check and writes no checks field' {
        Write-CwDone completed @('r1'); Write-CwRun r1 $script:failRows
        (Publish -SkipChecks) | Should Be 0
        (Get-CwLines 'coherentwarai\.command-log').Count | Should Be 0
        ((Get-CwJobResult).runs[0].PSObject.Properties.Name -contains 'checks') | Should Be $false
    }
}

Describe 'Publish-RigResult JobChecks (CW-1 per job) and exit precedence' {
    BeforeEach {
        $script:f = New-CwFixture
        $script:RigSuites['CWJOB'] = $script:cwJob
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
        Write-CwDone completed @('r1', 'r2')
        Write-CwRun r1 $script:passRows $script:scenarioResult
        Write-CwRun r2 $script:passRows $script:scenarioResult
    }
    AfterEach { $script:RigSuites.Remove('CWJOB') }
    function Publish([switch]$NoManifest) {
        $manifest = Join-Path $script:f.OutRoot "jobs\$($script:f.JobId)\job.json"
        if (-not $NoManifest) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $manifest) -Force | Out-Null
            [IO.File]::WriteAllText($manifest, '{"schema":1}')
        }
        Publish-RigResult -ResultDir $script:f.ResultDir -JobId $script:f.JobId -Days 3 -Suite CWJOB -JobRuns $script:jobRuns2 -WorkspaceRoot $script:f.Workspace -JobManifestPath $manifest
    }

    It 'both verdicts Passed: exit 0, one job row per check, -JobPath, the default result path and -JobManifestPath, CW-2 per run with its mode' {
        Set-CompareSpec @('Passed', 'Passed')
        (Publish) | Should Be 0
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a-invariant Passed\s+detail 0  ').Count | Should Be 1
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a-armydays Passed\s+detail 1  ').Count | Should Be 1
        [IO.File]::ReadAllText((Join-Path $script:f.ResultDir 'compare.args')) | Should BeExactly ($script:f.ResultDir + '|' + (Join-Path $script:f.ResultDir 'ac25a-compare.json') + '|' + (Join-Path $script:f.OutRoot "jobs\$($script:f.JobId)\job.json"))
        [IO.File]::ReadAllText((Join-Path $script:f.ResultDir 'r2\coherentwarai.command-log.json.args')) | Should Match '^FeatureOff\|3\|'
        $r = Get-CwJobResult
        (@($r.runs | ForEach-Object { $_.mode }) -join ',') | Should BeExactly 'WarSails,FeatureOff'
        (@($r.jobChecks | ForEach-Object { "$($_.id)=$($_.outcome)" }) -join ',') | Should BeExactly 'coherentwarai.ac25a-invariant=Passed,coherentwarai.ac25a-armydays=Passed'
    }
    It 'a Failed verdict: exit 2, its violation shown below its row' {
        Set-CompareSpec @('Failed', 'Passed') -Violation 'r1 day 4 Lucon (Defense only)'
        (Publish) | Should Be 2
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a-invariant Failed ').Count | Should Be 1
        (Get-CwLines '^    FAIL  r1 day 4 Lucon \(Defense only\)$').Count | Should Be 1
        @((Get-CwJobResult).jobChecks[0].violations)[0] | Should BeExactly 'r1 day 4 Lucon (Defense only)'
    }
    It 'Inconclusive beats Failed: exit 3' {
        Set-CompareSpec @('Failed', 'Inconclusive')
        (Publish) | Should Be 3
    }
    It 'a rig error beats Inconclusive: a Failed CW-2 run plus Inconclusive CW-1 is 3, plus a missing log is 1' {
        Set-CompareSpec @('Passed', 'Inconclusive')
        Write-CwRun r1 $script:failRows $script:scenarioResult
        (Publish) | Should Be 3
        Remove-Item -LiteralPath (Join-Path $script:f.ResultDir 'r2\CoherentWarAI.log')
        (Publish) | Should Be 1
    }
    It 'a script that finds the job unusable (exit 1, no result): exit 1 with an Error row under the JobCheck id' {
        (Publish) | Should Be 1
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a Error\s+Compare-Ac25a\.ps1 wrote no result \(exit 1\): No run folders').Count | Should Be 1
        (Get-CwJobResult).jobChecks[0].outcome | Should BeExactly 'RigError'
    }
    It 'an unknown verdict or a result without checks is a rig error: exit 1' {
        Set-CompareSpec @('Passed', 'Maybe')
        (Publish) | Should Be 1
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a-armydays Error ').Count | Should Be 1
        Set-CompareSpec @()
        (Publish) | Should Be 1
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a Error\s+no checks in ').Count | Should Be 1
    }
    It 'a job.json that does not exist is not passed to the script' {
        Set-CompareSpec @('Passed', 'Passed')
        (Publish -NoManifest) | Should Be 0
        [IO.File]::ReadAllText((Join-Path $script:f.ResultDir 'compare.args')) | Should Match '\|$'
    }
    It 'a RigError verdict from the job check is exit 1, shown as Error' {
        Set-CompareSpec @('RigError', 'Passed')
        (Publish) | Should Be 1
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a-invariant Error ').Count | Should Be 1
        (Get-CwJobResult).jobChecks[0].outcome | Should BeExactly 'RigError'
    }
    function Write-CwCrashedDone {
        [IO.File]::WriteAllText((Join-Path $script:f.ResultDir 'done.json'), ('{"schema":1,"jobId":"' + $script:f.JobId + '","status":"completed","runs":[' +
                '{"runId":"r1","exitClass":"Completed"},{"runId":"r2","exitClass":"Crashed"}]}'))
    }
    It 'a run that did not complete: the check still runs, its Inconclusive becomes Skipped and cannot outrank the run (Crashed = 2)' {
        Set-CompareSpec @('Inconclusive', 'Inconclusive')
        Write-CwCrashedDone
        (Publish) | Should Be 2
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a-invariant Skipped\s+not judged: run\(s\) r2 did not meet its expectation \(check said Inconclusive\)').Count | Should Be 1
        Test-Path -LiteralPath (Join-Path $script:f.ResultDir 'compare.args') | Should Be $true
        (Get-CwJobResult).jobChecks[0].outcome | Should BeExactly 'Skipped'
    }
    It 'a run that did not complete: a Failed verdict stays Failed (shown, counted, exit 2) while a Passed one is Skipped' {
        Set-CompareSpec @('Failed', 'Passed') -Violation 'r1 day 4 Lucon (Defense only)'
        Write-CwCrashedDone
        (Publish) | Should Be 2
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a-invariant Failed ').Count | Should Be 1
        (Get-CwLines '^    FAIL  r1 day 4 Lucon \(Defense only\)$').Count | Should Be 1
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a-armydays Skipped\s+not judged: run\(s\) r2 did not meet its expectation \(check said Passed\)').Count | Should Be 1
        $r = Get-CwJobResult
        $r.jobChecks[0].outcome | Should BeExactly 'Failed'
        $r.jobChecks[1].outcome | Should BeExactly 'Skipped'
    }
    It 'a run that did not complete: a Failed verdict plus an Inconclusive one is 2, not 3 (Inconclusive is Skipped)' {
        Set-CompareSpec @('Failed', 'Inconclusive')
        Write-CwCrashedDone
        (Publish) | Should Be 2
    }
    It 'a run that did not complete: a RigError (script wrote no result) becomes Skipped, exit stays the run verdict 2' {
        Write-CwCrashedDone
        (Publish) | Should Be 2
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a Skipped\s+not judged: run\(s\) r2 did not meet its expectation \(check said RigError\)').Count | Should Be 1
        (Get-CwJobResult).jobChecks[0].outcome | Should BeExactly 'Skipped'
    }
    # A run that ended Completed but missed its expectation (a scenario check Failed) is as unusable for the job check
    # as a crashed one: the check could only outrank the run's own verdict (Mismatch = 2).
    function Write-CwFailedScenario { Write-CwRun r1 $script:passRows '{"schema":1,"status":"Completed","daysReached":3,"scenarios":[{"id":"x.digest","status":"Failed"}]}' }
    It 'a Completed run that missed its expectation: an Inconclusive job check becomes Skipped, exit 2 not 3' {
        Set-CompareSpec @('Inconclusive', 'Inconclusive')
        Write-CwFailedScenario
        (Publish) | Should Be 2
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a-invariant Skipped\s+not judged: run\(s\) r1 did not meet its expectation \(check said Inconclusive\)').Count | Should Be 1
        (Get-CwJobResult).jobChecks[0].outcome | Should BeExactly 'Skipped'
    }
    It 'a Completed run that missed its expectation: a RigError job check (no result) becomes Skipped, exit 2 not 1' {
        Write-CwFailedScenario
        (Publish) | Should Be 2
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a Skipped\s+not judged: run\(s\) r1 did not meet its expectation \(check said RigError\)').Count | Should Be 1
    }
    It 'a stale ac25a-compare.json is deleted before the check runs: a Skipped/RigError row never leaves an old result looking current' {
        $stale = Join-Path $script:f.ResultDir 'ac25a-compare.json'
        [IO.File]::WriteAllText($stale, '{"schema":1,"checks":[{"check":"stale","verdict":"Passed","detail":"old"}]}')
        Write-CwCrashedDone
        (Publish) | Should Be 2   # no compare-spec.json: the fake script exits 1 without writing a result
        Test-Path -LiteralPath $stale | Should Be $false
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a Skipped ').Count | Should Be 1
    }
    It 'a stale ac25a-compare.json is also deleted when the script is missing' {
        $stale = Join-Path $script:f.ResultDir 'ac25a-compare.json'
        [IO.File]::WriteAllText($stale, '{"schema":1,"checks":[{"check":"stale","verdict":"Passed","detail":"old"}]}')
        Remove-Item -LiteralPath (Join-Path $script:f.Tools 'Compare-Ac25a.ps1')
        (Publish) | Should Be 1
        Test-Path -LiteralPath $stale | Should Be $false
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a Error\s+check script not found').Count | Should Be 1
    }
    It 'a check without a name falls back to the id of the JobCheck for its row' {
        [IO.File]::WriteAllText((Join-Path $script:f.ResultDir 'compare-spec.json'), '{"schema":1,"checks":[{"check":"","verdict":"Passed","detail":"d"},{"verdict":"Passed","detail":"d"}]}')
        (Publish) | Should Be 0
        (Get-CwJobResult).jobChecks[0].id | Should BeExactly 'coherentwarai.ac25a'
        (Get-CwJobResult).jobChecks[1].id | Should BeExactly 'coherentwarai.ac25a'
        (Get-CwLines '^job\s+CWJOB-coherentwarai\.ac25a Passed ').Count | Should Be 2
    }
    It 'a job that is not completed runs no job check (the job status decides)' {
        Set-CompareSpec @('Failed', 'Failed')
        Write-CwDone aborted @('r1', 'r2')
        (Publish) | Should Be 3
        (Get-CwLines '^job\s+CWJOB-').Count | Should Be 0
        @((Get-CwJobResult).jobChecks).Count | Should Be 0
    }
}

Describe 'Resolve-RigExitCode -CheckOutcomes' {
    $ok = @([pscustomobject]@{ runId = 'r1'; kind = 'scenarios'; exitClass = 'Completed'; daysReached = 1; scenarioStatuses = @('Passed'); scenarioIds = @('x') })
    It 'Passed = 0, Failed = 2, Inconclusive = 3, RigError or unknown = 1, precedence 1 > 3 > 2 > 0' {
        Resolve-RigExitCode -DoneStatus completed -Runs $ok -Days 1 -CheckOutcomes @('Passed') | Should Be 0
        Resolve-RigExitCode -DoneStatus completed -Runs $ok -Days 1 -CheckOutcomes @('Passed', 'Failed') | Should Be 2
        Resolve-RigExitCode -DoneStatus completed -Runs $ok -Days 1 -CheckOutcomes @('Failed', 'Inconclusive') | Should Be 3
        Resolve-RigExitCode -DoneStatus completed -Runs $ok -Days 1 -CheckOutcomes @('Inconclusive', 'RigError', 'Failed') | Should Be 1
        Resolve-RigExitCode -DoneStatus completed -Runs $ok -Days 1 -CheckOutcomes @('passed') | Should Be 1
        Resolve-RigExitCode -DoneStatus completed -Runs $ok -Days 1 -CheckOutcomes @('Skipped', 'Passed') | Should Be 0
        Resolve-RigExitCode -DoneStatus completed -Runs $ok -Days 1 -CheckOutcomes @('skipped') | Should Be 1
    }
}

Describe 'Update-RigJobResult (offline re-judgement)' {
    BeforeEach {
        $script:f = New-CwFixture
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
        $script:modules = @('Native', 'CoherentWarAI', 'TestRig.Harness')
        $jobDir = Join-Path $script:f.OutRoot "jobs\$($script:f.JobId)"
        New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $jobDir 'job.json'), ('{"schema":1,"jobId":"' + $script:f.JobId + '","modules":["Native","CoherentWarAI","TestRig.Harness"],' +
                '"runs":[{"runId":"r1","kind":"soak","days":3,"mode":"FeatureOff","health":["coherentwarai.health"]}]}'))
        $modulesJson = '[{"id":"Native","version":"v1"},{"id":"CoherentWarAI","version":"v1"},{"id":"TestRig.Harness","version":"v1"}]'
        $l1Result = '{"schema":1,"status":"Completed","daysReached":3,"runningDaysPerRealMinute":18.17,"playerMapEvents":3,"modules":' + $modulesJson +
            ',"exceptions":{"total":0,"own":0,"harness":0,"vanilla":0,"unhandled":0,"classification":{"walks":0,"walkMs":0,"handlerMs":0,"maxHandlerMs":0,"ownExact":true},"top":[]}' +
            ',"scenarios":[{"id":"coherentwarai.health@0","status":"Passed"},{"id":"soak","status":"Passed"},{"id":"coherentwarai.health@3","status":"Passed"}]}'
        Write-CwDone completed @('r1'); Write-CwRun r1 $script:passRows $l1Result
        # The suite L1 with this fixture's single health id (the real one lists four).
        $script:savedL1 = $script:RigSuites['L1']
        $l1 = $script:savedL1.Clone(); $l1.Health = @('coherentwarai.health')
        $script:RigSuites['L1'] = $l1
    }
    AfterEach { $script:RigSuites['L1'] = $script:savedL1 }
    function Rejudge([string]$Suite) {
        Update-RigJobResult -JobId $script:f.JobId -OutRoot $script:f.OutRoot -Suite $Suite -WorkspaceRoot $script:f.Workspace `
            -BaselinePath (Join-Path $script:f.Root 'no-baseline.json')
    }

    It 'takes the suite from job-result.json (normalised: l1 = L1), days and run modes from job.json; rewrites job-result.json' {
        [IO.File]::WriteAllText((Join-Path $script:f.ResultDir 'job-result.json'), '{"jobId":"x","suite":"l1","exitCode":0,"runs":[]}')
        (Rejudge) | Should Be 0
        (Get-CwLines '^r1\s+L1-coherentwarai\.command-log Passed ').Count | Should Be 1
        (Get-CwLines '^r1\s+L1-own\s').Count | Should Be 1   # the L1 verdict ran: the suite compared as L1, not l1
        [IO.File]::ReadAllText((Join-Path $script:f.ResultDir 'r1\coherentwarai.command-log.json.args')) | Should Match '^FeatureOff\|3\|'
        $r = Get-CwJobResult
        $r.suite | Should BeExactly 'L1'
        $r.jobId | Should BeExactly $script:f.JobId
        $r.runs[0].mode | Should BeExactly 'FeatureOff'
        $r.runs[0].checks[0].outcome | Should BeExactly 'Passed'
    }
    It 'keeps the evidence of the earlier judgement: job-result.previous.json, versionWarnings carried over, rejudgedFrom with the old exit code' {
        $original = '{"jobId":"x","suite":"L1","exitCode":3,"runs":[],"versionWarnings":["WARN game version differs","WARN module X differs"]}'
        [IO.File]::WriteAllText((Join-Path $script:f.ResultDir 'job-result.json'), $original)
        (Rejudge) | Should Be 0
        [IO.File]::ReadAllText((Join-Path $script:f.ResultDir 'job-result.previous.json')) | Should BeExactly $original
        $r = Get-CwJobResult
        (@($r.versionWarnings) -join '|') | Should BeExactly 'WARN game version differs|WARN module X differs'
        $r.rejudgedFrom.exitCode | Should Be 3
        { [datetime]::Parse([string]$r.rejudgedFrom.at) } | Should Not Throw
        # A second re-judgement keeps the very first evidence
        (Rejudge) | Should Be 0
        [IO.File]::ReadAllText((Join-Path $script:f.ResultDir 'job-result.previous.json')) | Should BeExactly $original
        (Get-CwJobResult).rejudgedFrom.exitCode | Should Be 3
        (@((Get-CwJobResult).versionWarnings) -join '|') | Should BeExactly 'WARN game version differs|WARN module X differs'
    }
    It 'without an earlier job-result.json there is nothing to keep: no previous file, no rejudgedFrom, no version warnings' {
        (Rejudge 'L1') | Should Be 0
        Test-Path -LiteralPath (Join-Path $script:f.ResultDir 'job-result.previous.json') | Should Be $false
        $r = Get-CwJobResult
        ($r.PSObject.Properties.Name -contains 'rejudgedFrom') | Should Be $false
        @($r.versionWarnings).Count | Should Be 0
    }
    It '-Suite overrides job-result.json; an unknown suite is exit 1' {
        [IO.File]::WriteAllText((Join-Path $script:f.ResultDir 'job-result.json'), '{"suite":null}')
        (Rejudge 'L1') | Should Be 0
        (Get-CwJobResult).suite | Should BeExactly 'L1'
        (Rejudge 'L9') | Should Be 1
        (Get-CwLines "^ERROR: unknown suite 'L9'").Count | Should Be 1
    }
    It 'the entry script Update-JobResult.ps1 under powershell -File: own -Suite/-OutRoot are not shadowed by the dot-sourced parameters; exit code' {
        $entry = (Resolve-Path (Join-Path $here '..\..\runner\Update-JobResult.ps1')).Path
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # No suite: judged as a plain soak run (3 days reached of 3) -> 0
        $out = @(& $ps -NoProfile -NonInteractive -File $entry -JobId $script:f.JobId -OutRoot $script:f.OutRoot 2>&1 | ForEach-Object { "$_" })
        $LASTEXITCODE | Should Be 0
        (Test-Path -LiteralPath (Join-Path $script:f.ResultDir 'job-result.json')) | Should Be $true
        # -Suite reaches Update-RigJobResult (an unknown suite is reported by name) -> 1
        $out = @(& $ps -NoProfile -NonInteractive -File $entry -JobId $script:f.JobId -OutRoot $script:f.OutRoot -Suite L9 2>&1 | ForEach-Object { "$_" })
        $LASTEXITCODE | Should Be 1
        (@($out | Where-Object { $_ -match "unknown suite 'L9'" })).Count | Should Be 1
    }
    It 'a missing job.json or result folder is exit 1 naming it' {
        Remove-Item -LiteralPath (Join-Path $script:f.OutRoot "jobs\$($script:f.JobId)\job.json")
        (Rejudge 'L1') | Should Be 1
        (Get-CwLines '^ERROR: job\.json not found').Count | Should Be 1
        (Update-RigJobResult -JobId '20990101-000000-ffff' -OutRoot $script:f.OutRoot) | Should Be 1
        (Get-CwLines '^ERROR: Result folder not found').Count | Should Be 1
    }
}

Describe 'Suite name normalisation (W2)' {
    It 'Get-RigSuiteName returns the table spelling, $null for an unknown suite' {
        Get-RigSuiteName 'l1' | Should BeExactly 'L1'
        Get-RigSuiteName 'cw1' | Should BeExactly 'CW1'
        Get-RigSuiteName 'l1-base' | Should BeExactly 'L1-BASE'
        Get-RigSuiteName 'nope' | Should Be $null
    }
    It '-Suite l1 is the suite L1 (its rules and messages use the canonical name), exit 1 before the config is read' {
        $out = (& powershell -NoProfile -File $script:invokeScript -PackageFrom C:\nowhere -Suite l1 -Harness CoherentWarAI 2>&1 | Out-String)
        $LASTEXITCODE | Should Be 1
        $out | Should MatchExactly '-Suite L1 fixes -Harness TestRig'
        $out | Should Not Match 'Config not found'
    }
    It "-Suite '' is no suite (no usage error; here the missing config ends it)" {
        $cfg = Join-Path $TestDrive 'missing.config.json'
        # -Command: powershell -File drops an empty argument, so -Suite '' would lack its value.
        $command = "& '$($script:invokeScript)' -PackageFrom C:\nowhere -Suite '' -ConfigPath '$cfg'; exit `$LASTEXITCODE"
        $out = (& powershell -NoProfile -Command $command 2>&1 | Out-String)
        $LASTEXITCODE | Should Be 1
        $out | Should Not Match 'unknown -Suite'
        $out | Should Match 'Config not found'
    }
}

Describe 'Get-RigSuiteBuildProjects without the suite table (W1)' {
    It 'takes the suite from -SuiteDefinition; by name without the table it throws a clear error' {
        $saved = $script:RigSuites
        try {
            $script:RigSuites = $null
            $r = @(Get-RigSuiteBuildProjects -WorkspaceRoot 'C:\ws' -Suite 'CW1' -SuiteDefinition $saved['CW1'])
            $r[-1].ModuleId | Should BeExactly 'CoherentWarAI.Scenarios'
            { Get-RigSuiteBuildProjects -WorkspaceRoot 'C:\ws' -Suite 'CW1' } | Should Throw 'no suite table'
        } finally { $script:RigSuites = $saved }
        @(Get-RigSuiteBuildProjects -WorkspaceRoot 'C:\ws' -Suite 'CW1')[-1].ModuleId | Should BeExactly 'CoherentWarAI.Scenarios'
    }
}

Describe 'Start-TestRigJob -PackageFrom: suites with CoherentWarAI need it in the package' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:cfg = Join-Path $script:root 'runner.config.json'
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        [IO.File]::WriteAllText($script:cfg, '{"host":"testpc","user":"rig","keyPath":"C:\\keys\\k","remoteQueueRoot":"C:\\TestRig\\queue"}')
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
        Mock Get-JobState { throw 'must not contact the test PC' }
        Mock Publish-Job { throw 'must not publish' }
    }
    It '-Suite CW1 with a package without Modules\CoherentWarAI: exit 1 naming it, nothing contacted' {
        $pkg = Join-Path $script:root 'pkg'
        foreach ($m in 'TestRig.Harness', 'CoherentWarAI.Scenarios') {
            New-Item -ItemType Directory -Path (Join-Path $pkg "Modules\$m") -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $pkg "Modules\$m\SubModule.xml"), '<Module/>')
        }
        $code = Start-TestRigJob -PackageFrom $pkg -Seed 1 -Days 3 -Mode WarSails -Harness TestRig -Suite CW1 `
            -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -ClaimTimeoutSeconds 0.3 -TimeoutMinutes 0.5 `
            -ConfigPath $script:cfg -OutRoot (Join-Path $script:root 'out') -RetryDelaySeconds 0
        $code | Should Be 1
        ($script:lines -join "`n") | Should Match ([regex]::Escape('has no Modules\CoherentWarAI (needed by -Suite CW1)'))
        Assert-MockCalled Get-JobState -Exactly 0 -Scope It
    }
}

# Contract with the real CoherentWarAI check scripts (workspace = parent folder of this repo, like the runner's default):
# the parameters the runner passes must exist, else powershell -File fails at binding. Skipped without the sibling repo.
$script:realTools = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $here))) 'BannerlordCoherentWarAI\tools'
function Get-ScriptParameterNames([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "parse errors in ${Path}: $($errors[0].Message)" }
    @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}
Describe 'Contract: parameters of the real CoherentWarAI check scripts' {
    $compare = Join-Path $script:realTools 'Compare-Ac25a.ps1'
    $commandLog = Join-Path $script:realTools 'Check-CommandLog.ps1'
    It 'Compare-Ac25a.ps1 declares JobPath, ResultPath and JobManifestPath (what Invoke-RigJobCheck passes)' -Skip:(-not (Test-Path -LiteralPath $compare)) {
        $names = Get-ScriptParameterNames $compare
        foreach ($p in 'JobPath', 'ResultPath', 'JobManifestPath') { ($names -contains $p) | Should Be $true }
    }
    It 'Check-CommandLog.ps1 declares LogPath, Mode, MinDays and ResultPath (what Invoke-RigPostRunCheck passes)' -Skip:(-not (Test-Path -LiteralPath $commandLog)) {
        $names = Get-ScriptParameterNames $commandLog
        foreach ($p in 'LogPath', 'Mode', 'MinDays', 'ResultPath') { ($names -contains $p) | Should Be $true }
    }
}

Describe 'Invoke-RigCheckScript timeout' {
    BeforeEach {
        $script:f = New-CwFixture
        $script:savedTimeout = $script:RigCheckScriptTimeoutSeconds
    }
    AfterEach { $script:RigCheckScriptTimeoutSeconds = $script:savedTimeout }

    It 'has a default of 10 minutes' {
        $script:RigCheckScriptTimeoutSeconds | Should Be 600
    }
    It 'kills a check script that runs too long and reports a RigError problem naming the timeout' {
        $slow = Join-Path $script:f.Tools 'Slow.ps1'
        [IO.File]::WriteAllText($slow, "param([string]`$ResultPath = '')`r`nStart-Sleep -Seconds 120")
        $script:RigCheckScriptTimeoutSeconds = 2
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-RigCheckScript -ScriptPath $slow -Arguments @('-ResultPath', (Join-Path $script:f.Root 'slow.json')) -ResultPath (Join-Path $script:f.Root 'slow.json')
        $watch.Stop()
        $r.Document | Should Be $null
        $r.Problem | Should Match 'Slow\.ps1 timed out after 2 seconds'
        $watch.Elapsed.TotalSeconds | Should BeLessThan 60
    }
    It 'a script that finishes in time is unaffected (arguments with spaces reach it intact)' {
        $dir = Join-Path $script:f.Root 'with space'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $ok = Join-Path $dir 'Ok.ps1'
        [IO.File]::WriteAllText($ok, "param([string]`$ResultPath = '')`r`n[IO.File]::WriteAllText(`$ResultPath, '{""schema"":1}')")
        $out = Join-Path $dir 'out file.json'
        $r = Invoke-RigCheckScript -ScriptPath $ok -Arguments @('-ResultPath', $out) -ResultPath $out
        $r.Problem | Should Be $null
        $r.Document.schema | Should Be 1
    }
}
