$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\runner\Invoke-TestRig.ps1')

# L1 verdict on the run's measurements (#21): own, unhandled, vanilla vs. baseline threshold, tempo vs. baseline median,
# modules vs. job.modules, playerMapEvents and ownExact (warnings only), and the baseline file runner/baselines/L1.json.

$script:verdictModules = @('Native', 'SandBoxCore', 'CoherentWarAI', 'TestRig.Harness')

function New-VerdictTempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('rigl1-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    $d
}

# run-result.json text of a Completed 3-day L1 run. Numeric arguments are inserted raw, so 'null' is possible.
function New-L1ResultJson {
    param(
        [string]$Own = '0', [string]$Unhandled = '0', [string]$Vanilla = '0', [string]$Tempo = '18.17', [string]$MapEvents = '3',
        [string[]]$Modules = $script:verdictModules, [switch]$NoExceptions, [switch]$NoModules, [string]$ScenariosJson = '',
        [string]$OwnExact = 'true', [switch]$NoClassification
    )
    $modulesJson = '[' + (@($Modules | ForEach-Object { '{"id":"' + $_ + '","version":"v1.4.8"}' }) -join ',') + ']'
    $classificationJson = if ($NoClassification) { '' } else {
        ',"classification":{"walks":0,"walkMs":0.00,"handlerMs":0.00,"maxHandlerMs":0.00,"ownExact":' + $OwnExact + '}'
    }
    $exceptionsJson = '{"total":0,"own":' + $Own + ',"harness":0,"vanilla":' + $Vanilla + ',"unhandled":' + $Unhandled +
        $classificationJson + ',"top":[]}'
    $text = '{"schema":1,"status":"Completed","seed":1,"daysRequested":3,"daysReached":3,"gameDaysPerRealMinute":5.36,' +
        '"runningDaysPerRealMinute":' + $Tempo + ',"playerMapEvents":' + $MapEvents
    if (-not $NoModules) { $text += ',"modules":' + $modulesJson }
    if (-not $NoExceptions) { $text += ',"exceptions":' + $exceptionsJson }
    if ($ScenariosJson) { $text += ',"scenarios":' + $ScenariosJson }
    $text + '}'
}

function New-L1Result { param([hashtable]$Arguments = @{}) New-L1ResultJson @Arguments | ConvertFrom-Json }

# A baseline file in the documented format: one base run per tempo/vanilla pair.
function Write-BaselineFile {
    param([string]$Path, [string[]]$Tempos = @('10', '10', '10', '10', '10'), [string[]]$Vanillas = @('0', '4', '0', '0', '0'), [string]$GameVersion = '"v1.4.8"')
    $runs = for ($i = 0; $i -lt $Tempos.Count; $i++) {
        '{"jobId":"20261103-100000-aaaa","runId":"r' + ($i + 1) + '","seed":1,"daysReached":30,"runningDaysPerRealMinute":' + $Tempos[$i] +
        ',"playerMapEvents":0,"exceptions":{"total":' + $Vanillas[$i] + ',"own":0,"harness":0,"vanilla":' + $Vanillas[$i] + ',"unhandled":0}}'
    }
    $text = '{"schema":1,"suite":"L1","gameVersion":' + $GameVersion + ',"updatedUtc":"2026-11-03T10:00:00Z","jobs":[],"baseRuns":[' +
        (@($runs) -join ',') + '],"l1Runs":[],"derived":null}'
    [IO.File]::WriteAllText($Path, $text)
}

function Get-Check($Verdict, [string]$Name) { @($Verdict.Checks | Where-Object { $_.name -ceq $Name })[0] }

Describe 'Get-RigL1Thresholds' {
    It 'median of an odd count, vanilla threshold 1.5 x max + 20, tempo threshold 0.7 x median, spread (max-min)/median' {
        $t = Get-RigL1Thresholds -Tempos @(18.2, 17.5, 18.0, 18.1, 17.9) -Vanillas @(0, 4, 2, 0, 0)
        $t.TempoMedian | Should Be 18.0
        $t.TempoMin | Should Be 17.5
        $t.TempoMax | Should Be 18.2
        [math]::Round($t.TempoSpread, 6) | Should Be ([math]::Round(0.7 / 18.0, 6))
        [math]::Round($t.TempoThreshold, 6) | Should Be 12.6
        $t.VanillaMax | Should Be 4
        $t.VanillaThreshold | Should Be 26
    }
    It 'median of an even count is the mean of the two middle values; vanilla max 0 gives threshold 20' {
        $t = Get-RigL1Thresholds -Tempos @(10, 12, 14, 20) -Vanillas @(0, 0, 0, 0)
        $t.TempoMedian | Should Be 13
        $t.VanillaThreshold | Should Be 20
    }
}

Describe 'Read-RigL1Baseline' {
    BeforeEach { $script:t = New-VerdictTempDir; $script:file = Join-Path $script:t 'L1.json' }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    It 'a missing file: Missing with the path in the reason' {
        $b = Read-RigL1Baseline -Path $script:file
        $b.Status | Should Be 'Missing'
        $b.Reason | Should Match 'baseline missing'
        $b.Reason | Should Match ([regex]::Escape($script:file))
    }
    It 'a placeholder without base runs: Missing (no base runs)' {
        [IO.File]::WriteAllText($script:file, '{"schema":1,"suite":"L1","gameVersion":null,"baseRuns":[],"l1Runs":[]}')
        $b = Read-RigL1Baseline -Path $script:file
        $b.Status | Should Be 'Missing'
        $b.Reason | Should Match 'no base runs'
    }
    It 'the committed runner/baselines/L1.json (calibrated by Update-L1Baseline.ps1) reads as Ok with base runs' {
        $b = Read-RigL1Baseline -Path (Join-Path $here '..\..\runner\baselines\L1.json')
        $b.Status | Should Be 'Ok'
        $b.BaseRunCount -ge 1 | Should Be $true
        $b.GameVersion | Should Not BeNullOrEmpty
    }
    It 'invalid JSON: Invalid' {
        [IO.File]::WriteAllText($script:file, '{"baseRuns": [')
        (Read-RigL1Baseline -Path $script:file).Status | Should Be 'Invalid'
    }
    It 'base runs without a game version: Invalid' {
        Write-BaselineFile $script:file -GameVersion 'null'
        $b = Read-RigL1Baseline -Path $script:file
        $b.Status | Should Be 'Invalid'
        $b.Reason | Should Match 'gameVersion'
    }
    It 'a base run with a null tempo: Invalid naming the run' {
        Write-BaselineFile $script:file -Tempos @('10', 'null') -Vanillas @('0', '0')
        $b = Read-RigL1Baseline -Path $script:file
        $b.Status | Should Be 'Invalid'
        $b.Reason | Should Match '20261103-100000-aaaa/r2'
    }
    It 'a valid file: Ok with game version, run count, thresholds and job ids' {
        Write-BaselineFile $script:file
        $b = Read-RigL1Baseline -Path $script:file
        $b.Status | Should Be 'Ok'
        $b.GameVersion | Should Be 'v1.4.8'
        $b.BaseRunCount | Should Be 5
        $b.Thresholds.TempoMedian | Should Be 10
        $b.Thresholds.VanillaThreshold | Should Be 26
        (@($b.JobIds) -join ',') | Should Be '20261103-100000-aaaa'
    }
}

Describe 'Get-RigL1Verdict' {
    BeforeAll {
        $script:bt = New-VerdictTempDir
        $script:okFile = Join-Path $script:bt 'L1.json'
        Write-BaselineFile $script:okFile   # median tempo 10, vanilla max 4 -> threshold 26
        $script:ok = Read-RigL1Baseline -Path $script:okFile
        $script:missing = Read-RigL1Baseline -Path (Join-Path $script:bt 'none.json')
    }
    AfterAll { Remove-Item -LiteralPath $script:bt -Recurse -Force -ErrorAction SilentlyContinue }
    function Judge([hashtable]$Arguments = @{}, $Baseline = $script:ok, $GameVersion = 'v1.4.8', $Expected = $script:verdictModules) {
        Get-RigL1Verdict -RunId r1 -Result (New-L1Result $Arguments) -ExpectedModules $Expected -GameVersion $GameVersion -Baseline $Baseline
    }

    It 'all values within the rules: Met, every check Passed (seven checks in a fixed order)' {
        $v = Judge @{ Tempo = '10.00'; Vanilla = '0' }
        $v.Outcome | Should Be 'Met'
        (@($v.Checks | ForEach-Object { $_.name }) -join ',') | Should Be 'own,unhandled,vanilla,tempo,modules,playerMapEvents,ownExact'
        foreach ($c in $v.Checks) { $c.status | Should Be 'Passed' }
        @($v.Warnings).Count | Should Be 0
    }
    It 'own 1: Failed with expected 0 and actual 1' {
        $v = Judge @{ Own = '1' }
        $v.Outcome | Should Be 'Failed'
        $c = Get-Check $v 'own'
        $c.status | Should Be 'Failed'; $c.expected | Should Be '0'; $c.actual | Should Be '1'
    }
    It 'unhandled 1: Failed' {
        $v = Judge @{ Unhandled = '1' }
        $v.Outcome | Should Be 'Failed'
        (Get-Check $v 'unhandled').status | Should Be 'Failed'
        (Get-Check $v 'own').status | Should Be 'Passed'
    }
    It 'no exceptions block: own and unhandled are rig errors (RigError beats Failed)' {
        $v = Judge @{ NoExceptions = $true; Tempo = '1.00' }
        $v.Outcome | Should Be 'RigError'
        (Get-Check $v 'own').status | Should Be 'Error'
        (Get-Check $v 'own').actual | Should Be 'null'
        (Get-Check $v 'vanilla').status | Should Be 'Error'
    }
    It 'vanilla exactly at the threshold (26 = 1.5 x 4 + 20): Passed' {
        $c = Get-Check (Judge @{ Vanilla = '26' }) 'vanilla'
        $c.status | Should Be 'Passed'
        $c.expected | Should Be '<= 26 (1.5 x baseline max 4 + 20)'
        $c.actual | Should Be '26'
    }
    It 'vanilla just above the threshold (27): Failed' {
        $v = Judge @{ Vanilla = '27' }
        $v.Outcome | Should Be 'Failed'
        (Get-Check $v 'vanilla').status | Should Be 'Failed'
    }
    It 'tempo ratio exactly 0.7 (7.00 vs median 10): Passed' {
        $c = Get-Check (Judge @{ Tempo = '7.00' }) 'tempo'
        $c.status | Should Be 'Passed'
        $c.expected | Should Be 'ratio >= 0.7 (0.7 x baseline median 10.00 = 7.00 days/min)'
        $c.actual | Should Be '7.00 days/min, ratio 0.700'
    }
    It 'tempo just above (7.01): Passed; just below (6.99): Failed' {
        (Get-Check (Judge @{ Tempo = '7.01' }) 'tempo').status | Should Be 'Passed'
        $v = Judge @{ Tempo = '6.99' }
        $v.Outcome | Should Be 'Failed'
        (Get-Check $v 'tempo').status | Should Be 'Failed'
        (Get-Check $v 'tempo').actual | Should Be '6.99 days/min, ratio 0.699'
    }
    It 'tempo null: not judged with a WARN, the other checks still decide (Met)' {
        $v = Judge @{ Tempo = 'null' }
        $v.Outcome | Should Be 'Met'
        (Get-Check $v 'tempo').status | Should Be 'NotJudged'
        @($v.Warnings | Where-Object { $_ -match '^WARN L1 r1 tempo not judged: runningDaysPerRealMinute is null' }).Count | Should Be 1
    }
    It 'baseline missing: vanilla and tempo not judged with a WARN, far-off values do not fail' {
        $v = Judge @{ Vanilla = '5000'; Tempo = '0.10' } -Baseline $script:missing
        $v.Outcome | Should Be 'Met'
        (Get-Check $v 'vanilla').status | Should Be 'NotJudged'
        (Get-Check $v 'vanilla').actual | Should Be '5000'
        (Get-Check $v 'tempo').status | Should Be 'NotJudged'
        @($v.Warnings | Where-Object { $_ -match '^WARN L1 r1 vanilla and tempo not judged: baseline missing' }).Count | Should Be 1
    }
    It 'baseline missing: own, unhandled and modules are still judged' {
        (Judge @{ Own = '2' } -Baseline $script:missing).Outcome | Should Be 'Failed'
        (Judge @{ Unhandled = '1' } -Baseline $script:missing).Outcome | Should Be 'Failed'
        (Judge @{ Modules = @('Native') } -Baseline $script:missing).Outcome | Should Be 'Failed'
    }
    It 'baseline for another game version: not judged with a WARN naming both versions' {
        $v = Judge @{ Vanilla = '5000' } -GameVersion 'v1.4.9'
        $v.Outcome | Should Be 'Met'
        (Get-Check $v 'vanilla').status | Should Be 'NotJudged'
        @($v.Warnings | Where-Object { $_ -match 'baseline is for game v1\.4\.8, the run ran v1\.4\.9' }).Count | Should Be 1
    }
    It 'the run reported no game version: not judged' {
        $v = Judge @{ Tempo = '0.10' } -GameVersion $null
        $v.Outcome | Should Be 'Met'
        (Get-Check $v 'tempo').status | Should Be 'NotJudged'
        @($v.Warnings | Where-Object { $_ -match 'no game version' }).Count | Should Be 1
    }
    It 'an invalid baseline: not judged with its reason' {
        $bad = Join-Path $script:bt 'bad.json'
        [IO.File]::WriteAllText($bad, 'nope')
        $v = Judge @{ Vanilla = '5000' } -Baseline (Read-RigL1Baseline -Path $bad)
        (Get-Check $v 'vanilla').status | Should Be 'NotJudged'
        @($v.Warnings | Where-Object { $_ -match 'baseline invalid' }).Count | Should Be 1
    }
    It 'modules: a missing module is Failed and named' {
        $v = Judge @{ Modules = @('Native', 'SandBoxCore', 'TestRig.Harness') }
        $v.Outcome | Should Be 'Failed'
        (Get-Check $v 'modules').actual | Should Match 'missing CoherentWarAI'
    }
    It 'modules: an extra module is Failed and named' {
        $v = Judge @{ Modules = @($script:verdictModules + 'Other.Mod') }
        (Get-Check $v 'modules').status | Should Be 'Failed'
        (Get-Check $v 'modules').actual | Should Match 'extra Other\.Mod'
    }
    It 'modules: the same ids in another order are Failed (load order matters)' {
        $v = Judge @{ Modules = @('SandBoxCore', 'Native', 'CoherentWarAI', 'TestRig.Harness') }
        (Get-Check $v 'modules').status | Should Be 'Failed'
        (Get-Check $v 'modules').actual | Should Match 'order differs at position 1: SandBoxCore'
    }
    It 'modules: ids compare case-sensitively' {
        (Get-Check (Judge @{ Modules = @('native', 'SandBoxCore', 'CoherentWarAI', 'TestRig.Harness') }) 'modules').status | Should Be 'Failed'
    }
    It 'modules: equal lists Passed with the count' {
        (Get-Check (Judge) 'modules').actual | Should Be '4 modules, same order'
        (Get-Check (Judge) 'modules').expected | Should Be 'job.modules (4)'
    }
    It 'modules not reported, or job.modules unknown to the runner: rig error' {
        (Judge @{ NoModules = $true }).Outcome | Should Be 'RigError'
        (Judge -Expected $null).Outcome | Should Be 'RigError'
    }
    It 'playerMapEvents 0: WARN only (outcome Met), with a warning line' {
        $v = Judge @{ MapEvents = '0' }
        $v.Outcome | Should Be 'Met'
        (Get-Check $v 'playerMapEvents').status | Should Be 'Warn'
        @($v.Warnings | Where-Object { $_ -match '^WARN L1 r1 playerMapEvents is 0' }).Count | Should Be 1
    }
    It 'ownExact true: Passed, no warning' {
        $v = Judge @{ OwnExact = 'true' }
        $c = Get-Check $v 'ownExact'
        $c.status | Should Be 'Passed'; $c.expected | Should Be 'true'; $c.actual | Should Be 'true'
        @($v.Warnings).Count | Should Be 0
    }
    It 'ownExact false: WARN only (outcome Met), with a warning line saying own is an estimate' {
        $v = Judge @{ OwnExact = 'false' }
        $v.Outcome | Should Be 'Met'
        $c = Get-Check $v 'ownExact'
        $c.status | Should Be 'Warn'; $c.expected | Should Be 'true'; $c.actual | Should Be 'false'
        @($v.Warnings | Where-Object { $_ -match '^WARN L1 r1 ownExact is false: exceptions\.own is an estimate' }).Count | Should Be 1
    }
    It 'ownExact false does not hide a failed check (own 1 stays Failed)' {
        (Judge @{ OwnExact = 'false'; Own = '1' }).Outcome | Should Be 'Failed'
    }
    It 'ownExact missing, null or not a boolean: NotJudged with a WARN, never a failure or rig error' {
        foreach ($arguments in @{ NoClassification = $true }, @{ OwnExact = 'null' }, @{ OwnExact = '"false"' }, @{ OwnExact = '0' }, @{ OwnExact = '[true]' }) {
            $v = Judge $arguments
            $v.Outcome | Should Be 'Met'
            (Get-Check $v 'ownExact').status | Should Be 'NotJudged'
            @($v.Warnings | Where-Object { $_ -match '^WARN L1 r1 ownExact not judged: ' }).Count | Should Be 1
        }
    }
    It 'a result without any field (result.txt run): rig error' {
        $v = Get-RigL1Verdict -RunId r1 -Result ([ordered]@{}) -ExpectedModules $script:verdictModules -GameVersion 'v1.4.8' -Baseline $script:ok
        $v.Outcome | Should Be 'RigError'
    }
}

Describe 'Format-RigL1Lines' {
    It 'one row per check (run, L1-<name>, status, expected, actual), then the warnings' {
        $verdict = [pscustomobject]@{
            Outcome = 'Failed'; Warnings = @('WARN L1 r1 something')
            Checks = @(
                (New-RigL1Check 'own' 'Passed' '0' '0'), (New-RigL1Check 'tempo' 'Failed' 'ratio >= 0.7' '1.00 days/min, ratio 0.100'),
                (New-RigL1Check 'vanilla' 'NotJudged' '-' '3'), (New-RigL1Check 'playerMapEvents' 'Warn' '> 0' '0'),
                (New-RigL1Check 'modules' 'Error' 'job.modules (4)' 'null'), (New-RigL1Check 'ownExact' 'Warn' 'true' 'false'))
        }
        $lines = @(Format-RigL1Lines -RunId r1 -Verdict $verdict)
        $lines.Count | Should Be 7
        $lines[5] | Should Match '^r1\s+L1-ownExact\s+WARN\s+expected true, actual false$'
        $lines[0] | Should Match '^r1\s+L1-own\s+Passed\s+expected 0, actual 0$'
        $lines[1] | Should Match '^r1\s+L1-tempo\s+Failed\s+expected ratio >= 0\.7, actual 1\.00 days/min, ratio 0\.100$'
        $lines[2] | Should Match '^r1\s+L1-vanilla\s+not judged\s+expected -, actual 3$'
        $lines[3] | Should Match '^r1\s+L1-playerMapEvents\s+WARN\s+'
        $lines[4] | Should Match '^r1\s+L1-modules\s+ERROR\s+'
        $lines[6] | Should Be 'WARN L1 r1 something'
    }
}

Describe 'Resolve-RigExitCode with an L1 verdict' {
    function Run-With($Outcome, [string]$ExitClass = 'Completed') {
        $v = if ($Outcome) { [pscustomobject]@{ Outcome = $Outcome; Checks = @(); Warnings = @() } } else { $null }
        [pscustomobject]@{ runId = 'r1'; kind = 'soak'; exitClass = $ExitClass; daysReached = 3; scenarioStatuses = @('Passed'); scenarioIds = @('soak'); l1Verdict = $v }
    }
    It 'Met: 0, Failed: 2, RigError: 1, no verdict: 0' {
        Resolve-RigExitCode -DoneStatus completed -Runs @(Run-With 'Met') -Days 3 | Should Be 0
        Resolve-RigExitCode -DoneStatus completed -Runs @(Run-With 'Failed') -Days 3 | Should Be 2
        Resolve-RigExitCode -DoneStatus completed -Runs @(Run-With 'RigError') -Days 3 | Should Be 1
        Resolve-RigExitCode -DoneStatus completed -Runs @(Run-With $null) -Days 3 | Should Be 0
    }
    It 'a rig error of the verdict beats a Failed scenario' {
        $r = Run-With 'RigError'; $r.scenarioStatuses = @('Failed')
        Resolve-RigExitCode -DoneStatus completed -Runs @($r) -Days 3 | Should Be 1
    }
}

Describe 'Publish-RigResult -Suite L1 verdict' {
    BeforeEach {
        $script:t = New-VerdictTempDir
        $script:id = '20261103-160000-c3d4'
        $script:rd = Join-Path $script:t $script:id
        New-Item -ItemType Directory -Path (Join-Path $script:rd 'r1') | Out-Null
        $script:baseFile = Join-Path $script:t 'L1.json'
        Write-BaselineFile $script:baseFile
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    $healthIds = @('coherentwarai.health', 'autotrader.health', 'smithingsuite.health', 'companionsuite.health')
    $scenarios = '[' + (@(@($healthIds | ForEach-Object { "$_@0" }) + 'soak' + @($healthIds | ForEach-Object { "$_@3" }) |
                ForEach-Object { '{"id":"' + $_ + '","status":"Passed","seconds":1}' }) -join ',') + ']'
    function Write-Job([string]$ExitClass, [string]$RunResultJson, [string]$GameVersion = 'v1.4.8') {
        [IO.File]::WriteAllText((Join-Path $script:rd 'done.json'), ('{"schema":1,"jobId":"' + $script:id + '","status":"completed","runs":[{"runId":"r1","exitClass":"' + $ExitClass + '"}]}'))
        [IO.File]::WriteAllText((Join-Path $script:rd 'r1\agent-run.json'), ('{"runId":"r1","startedUtc":"2026-11-03T16:00:00Z","endedUtc":"2026-11-03T16:01:00Z","gameVersion":"' + $GameVersion + '"}'))
        if ($RunResultJson) { [IO.File]::WriteAllText((Join-Path $script:rd 'r1\run-result.json'), $RunResultJson) }
    }
    function Publish([string]$BaselinePath = $script:baseFile) {
        Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1 -ExpectedModules $script:verdictModules -BaselinePath $BaselinePath -SkipChecks
    }
    function Get-JobResult { Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json }

    It 'within the rules: exit 0, the verdict rows follow the run rows, job-result.json holds l1 with checks and baseline' {
        Write-Job Completed (New-L1ResultJson -Vanilla '3' -Tempo '9.50' -ScenariosJson $scenarios)
        (Publish) | Should Be 0
        $first = [array]::IndexOf($script:lines, @($script:lines | Where-Object { $_ -match '^r1\s+L1-own ' })[0])
        $first | Should BeGreaterThan ([array]::IndexOf($script:lines, @($script:lines | Where-Object { $_ -match '^r1\s+L1-soak ' })[0]))
        @($script:lines | Where-Object { $_ -match '^r1\s+L1-vanilla\s+Passed\s+expected <= 26 \(1\.5 x baseline max 4 \+ 20\), actual 3$' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match '^r1\s+L1-tempo\s+Passed\s+expected ratio >= 0\.7 .*actual 9\.50 days/min, ratio 0\.950$' }).Count | Should Be 1
        $l1 = (Get-JobResult).runs[0].l1
        $l1.outcome | Should Be 'Met'
        $l1.baseline.status | Should Be 'Ok'
        $l1.baseline.gameVersion | Should Be 'v1.4.8'
        (@($l1.baseline.jobIds) -join ',') | Should Be '20261103-100000-aaaa'
        @($l1.checks).Count | Should Be 7
        (@($l1.checks) | Where-Object { $_.name -eq 'vanilla' }).expected | Should Be '<= 26 (1.5 x baseline max 4 + 20)'
        @($l1.warnings).Count | Should Be 0
    }
    It 'ownExact false: exit code stays 0, a WARN row and a warning line, outcome Met' {
        Write-Job Completed (New-L1ResultJson -Vanilla '3' -Tempo '9.50' -OwnExact 'false' -ScenariosJson $scenarios)
        (Publish) | Should Be 0
        @($script:lines | Where-Object { $_ -match '^r1\s+L1-ownExact\s+WARN\s+expected true, actual false$' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match '^WARN L1 r1 ownExact is false' }).Count | Should Be 1
        $l1 = (Get-JobResult).runs[0].l1
        $l1.outcome | Should Be 'Met'
        (@($l1.checks) | Where-Object { $_.name -eq 'ownExact' }).status | Should Be 'Warn'
        (Get-JobResult).exitCode | Should Be 0
    }
    It 'tempo below 0.7 x median: exit 2 with a Failed row showing expected and actual' {
        Write-Job Completed (New-L1ResultJson -Tempo '6.99' -ScenariosJson $scenarios)
        (Publish) | Should Be 2
        @($script:lines | Where-Object { $_ -match '^r1\s+L1-tempo\s+Failed\s+expected ratio >= 0\.7 .*, actual 6\.99 days/min, ratio 0\.699$' }).Count | Should Be 1
        (Get-JobResult).runs[0].l1.outcome | Should Be 'Failed'
        (Get-JobResult).exitCode | Should Be 2
    }
    It 'own > 0: exit 2' {
        Write-Job Completed (New-L1ResultJson -Own '1' -ScenariosJson $scenarios)
        (Publish) | Should Be 2
        @($script:lines | Where-Object { $_ -match '^r1\s+L1-own\s+Failed\s+expected 0, actual 1$' }).Count | Should Be 1
    }
    It 'modules differ from job.modules: exit 2' {
        Write-Job Completed (New-L1ResultJson -Modules @('Native') -ScenariosJson $scenarios)
        (Publish) | Should Be 2
    }
    It 'baseline missing: exit 0, the WARN line is printed, l1.baseline.status Missing' {
        Write-Job Completed (New-L1ResultJson -Vanilla '5000' -Tempo '0.10' -ScenariosJson $scenarios)
        (Publish -BaselinePath (Join-Path $script:t 'absent.json')) | Should Be 0
        @($script:lines | Where-Object { $_ -match '^WARN L1 r1 vanilla and tempo not judged: baseline missing' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match '^r1\s+L1-vanilla\s+not judged\s+expected -, actual 5000$' }).Count | Should Be 1
        (Get-JobResult).runs[0].l1.baseline.status | Should Be 'Missing'
        @((Get-JobResult).runs[0].l1.warnings).Count | Should Be 1
    }
    It 'another game version than the baseline: exit 0 with the WARN line' {
        Write-Job Completed (New-L1ResultJson -Tempo '0.10' -ScenariosJson $scenarios) -GameVersion 'v1.5.0'
        (Publish) | Should Be 0
        @($script:lines | Where-Object { $_ -match 'baseline is for game v1\.4\.8, the run ran v1\.5\.0' }).Count | Should Be 1
    }
    It 'a run that is not Completed is not judged: no verdict rows, l1 null' {
        Write-Job Crashed $null
        (Publish) | Should Be 2
        @($script:lines | Where-Object { $_ -match 'L1-own' }).Count | Should Be 0
        $run = (Get-JobResult).runs[0]
        ($run.PSObject.Properties.Name -contains 'l1') | Should Be $true
        $run.l1 | Should Be $null
    }
    It 'other suites get no l1 field and no verdict rows' {
        Write-Job Completed (New-L1ResultJson -Own '5' -ScenariosJson '[{"id":"soak","status":"Passed","seconds":1}]')
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -BaselinePath $script:baseFile) | Should Be 0
        ((Get-JobResult).runs[0].PSObject.Properties.Name -contains 'l1') | Should Be $false
        @($script:lines | Where-Object { $_ -match 'L1-own' }).Count | Should Be 0
    }
}

# job-result.json text of a finished job: one run per tempo, game version per run.
function New-JobResultJson {
    param([string]$JobId, [string]$Suite, [int]$ExitCode = 0, [string[]]$Tempos = @('18.00'), [string]$GameVersion = 'v1.4.8',
        [string]$ExitClass = 'Completed', [string]$Vanilla = '0')
    $runs = for ($i = 0; $i -lt $Tempos.Count; $i++) {
        '{"runId":"r' + ($i + 1) + '","exitClass":"' + $ExitClass + '","gameVersion":"' + $GameVersion + '","moduleVersions":[],"result":' +
        (New-L1ResultJson -Tempo $Tempos[$i] -Vanilla $Vanilla -MapEvents '0') + '}'
    }
    '{"jobId":"' + $JobId + '","suite":"' + $Suite + '","status":"completed","exitCode":' + $ExitCode + ',"runs":[' + (@($runs) -join ',') + '],"versionWarnings":[]}'
}

Describe 'Update-RigL1Baseline' {
    BeforeEach {
        $script:t = New-VerdictTempDir
        $script:results = Join-Path $script:t 'results'
        $script:file = Join-Path $script:t 'baselines\L1.json'
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    function Write-JobResult([string]$JobId, [string]$Json) {
        $d = Join-Path $script:results $JobId
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'job-result.json'), $Json)
    }
    $baseId = '20261104-090000-0b0b'
    $l1Ids = @('20261104-093000-1111', '20261104-094000-2222', '20261104-095000-3333')
    function Write-Calibration {
        Write-JobResult $baseId (New-JobResultJson -JobId $baseId -Suite 'L1-BASE' -Tempos @('18.20', '17.50', '18.00', '18.10', '17.90') -Vanilla '2')
        $i = 0
        foreach ($l1 in $l1Ids) { Write-JobResult $l1 (New-JobResultJson -JobId $l1 -Suite 'L1' -Tempos @(@('17.00', '16.50', '17.20')[$i])); $i++ }
    }
    function Update([string[]]$Base = @($baseId), [string[]]$L1 = $l1Ids) {
        Update-RigL1Baseline -BaseJobIds $Base -L1JobIds $L1 -ResultsRoot $script:results -Path $script:file
    }

    It 'writes L1.json (LF, no BOM) that Read-RigL1Baseline accepts, with the 5 base runs, 3 L1 runs and derived values' {
        Write-Calibration
        (Update) | Should Be 0
        $bytes = [IO.File]::ReadAllBytes($script:file)
        ($bytes[0] -eq 0xEF) | Should Be $false
        ([IO.File]::ReadAllText($script:file)).Contains("`r") | Should Be $false
        $doc = Get-Content -LiteralPath $script:file -Raw | ConvertFrom-Json
        $doc.schema | Should Be 1
        $doc.suite | Should Be 'L1'
        $doc.gameVersion | Should Be 'v1.4.8'
        @($doc.baseRuns).Count | Should Be 5
        @($doc.l1Runs).Count | Should Be 3
        (@($doc.jobs | ForEach-Object { $_.jobId }) -join ',') | Should Be (@($baseId) + $l1Ids -join ',')
        @($doc.jobs)[0].suite | Should Be 'L1-BASE'
        @(@($doc.jobs)[0].modules).Count | Should Be 4
        @($doc.baseRuns)[1].runningDaysPerRealMinute | Should Be 17.5
        @($doc.baseRuns)[0].exceptions.vanilla | Should Be 2
        $doc.derived.tempoMedian | Should Be 18
        $doc.derived.vanillaThreshold | Should Be 23
        $doc.derived.l1TempoRatioMin | Should Be ([math]::Round(16.5 / 18, 4))
        $b = Read-RigL1Baseline -Path $script:file
        $b.Status | Should Be 'Ok'
        $b.Thresholds.TempoMedian | Should Be 18
        $b.Thresholds.VanillaThreshold | Should Be 23
    }
    It 'prints the derived values and the calibration warnings (spread > 10 %, slowest L1 run below 0.8 x median)' {
        Write-JobResult $baseId (New-JobResultJson -JobId $baseId -Suite 'L1-BASE' -Tempos @('10.00', '12.00', '10.00'))
        Write-JobResult $l1Ids[0] (New-JobResultJson -JobId $l1Ids[0] -Suite 'L1' -Tempos @('7.00'))
        (Update -L1 @($l1Ids[0])) | Should Be 0
        @($script:lines | Where-Object { $_ -match '^tempo \(days/min\): median 10\.00' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match '^WARN tempo spread 20\.0 %' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match '^WARN slowest L1 run / base median = 0\.700' }).Count | Should Be 1
    }
    It 'without L1 jobs: l1Runs empty and l1TempoRatioMin null' {
        Write-Calibration
        (Update -L1 @()) | Should Be 0
        $doc = Get-Content -LiteralPath $script:file -Raw | ConvertFrom-Json
        @($doc.l1Runs).Count | Should Be 0
        $doc.derived.l1TempoRatioMin | Should Be $null
    }
    It 'several base jobs are pooled (more base runs after a wide spread)' {
        Write-Calibration
        $more = '20261104-100000-4444'
        Write-JobResult $more (New-JobResultJson -JobId $more -Suite 'L1-BASE' -Tempos @('18.00', '18.00', '18.00'))
        (Update -Base @($baseId, $more)) | Should Be 0
        @((Get-Content -LiteralPath $script:file -Raw | ConvertFrom-Json).baseRuns).Count | Should Be 8
    }
    It 'refuses (exit 1, file untouched): a base job of another suite' {
        Write-Calibration
        Write-JobResult $baseId (New-JobResultJson -JobId $baseId -Suite 'L1')
        (Update) | Should Be 1
        Test-Path -LiteralPath $script:file | Should Be $false
        ($script:lines -join "`n") | Should Match 'suite'
    }
    It 'refuses: a base job with exit code other than 0' {
        Write-Calibration
        Write-JobResult $baseId (New-JobResultJson -JobId $baseId -Suite 'L1-BASE' -ExitCode 2)
        (Update) | Should Be 1
    }
    It 'refuses: a run that is not Completed, or one with a null tempo' {
        Write-Calibration
        Write-JobResult $l1Ids[1] (New-JobResultJson -JobId $l1Ids[1] -Suite 'L1' -ExitClass 'Crashed' -ExitCode 2)
        (Update) | Should Be 1
        Write-Calibration
        Write-JobResult $l1Ids[1] (New-JobResultJson -JobId $l1Ids[1] -Suite 'L1' -Tempos @('null'))
        (Update) | Should Be 1
    }
    It 'refuses: runs with different game versions' {
        Write-Calibration
        Write-JobResult $l1Ids[2] (New-JobResultJson -JobId $l1Ids[2] -Suite 'L1' -GameVersion 'v1.4.9')
        (Update) | Should Be 1
        ($script:lines -join "`n") | Should Match 'game versions'
    }
    It 'refuses: an invalid job id (path characters) or a missing job-result.json' {
        Write-Calibration
        (Update -Base @('..\x')) | Should Be 1
        (Update -Base @('20261104-090000-ffff')) | Should Be 1
    }
    It 'refuses: a job id given twice (its runs would count twice)' {
        Write-Calibration
        (Update -L1 @($l1Ids[0], $l1Ids[0])) | Should Be 1
        (Update -Base @($baseId) -L1 @($baseId)) | Should Be 1
    }
    It 'refuses: a job-result.json of another job' {
        Write-Calibration
        Write-JobResult $l1Ids[0] (New-JobResultJson -JobId $l1Ids[1] -Suite 'L1')
        (Update) | Should Be 1
    }
}

# Real jobs from the game PC, copied from out\results (job-result.json only, LF): the L1-BASE job 20261103-063455-cd32
# (five 30-day runs, tempo 22.26/22.26/22.23/22.27/22.26, vanilla 0/0/6/0/0 - r3 saw DNS/HTTP network noise) and the
# 3-day L1 job 20261103-063052-859d (tempo 18.17, exit 2 by a failed health line, run Completed).
Describe 'Update-RigL1Baseline with real jobs (fixtures/results)' {
    BeforeEach {
        $script:t = New-VerdictTempDir
        $script:file = Join-Path $script:t 'L1.json'
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    $fixtureResults = Join-Path $here 'fixtures\results'

    It 'derives median 22.26 and vanilla threshold 29 (1.5 x 6 + 20, tolerates the network noise of r3)' {
        (Update-RigL1Baseline -BaseJobIds @('20261103-063455-cd32') -L1JobIds @('20261103-063052-859d') -ResultsRoot $fixtureResults -Path $script:file) | Should Be 0
        $doc = Get-Content -LiteralPath $script:file -Raw | ConvertFrom-Json
        $doc.gameVersion | Should Be 'v1.4.8'
        @($doc.baseRuns).Count | Should Be 5
        (@($doc.baseRuns | ForEach-Object { $_.exceptions.vanilla }) -join ',') | Should Be '0,0,6,0,0'
        $doc.derived.tempoMedian | Should Be 22.26
        $doc.derived.vanillaMax | Should Be 6
        $doc.derived.vanillaThreshold | Should Be 29
        $doc.derived.tempoThreshold | Should Be 15.582
        $doc.derived.l1TempoRatioMin | Should Be 0.8163   # 18.17 / 22.26
        @($script:lines | Where-Object { $_ -match '^WARN' }).Count | Should Be 0   # spread 0.18 %, ratio 0.816 >= 0.8
        $b = Read-RigL1Baseline -Path $script:file
        $b.Status | Should Be 'Ok'
        (@($b.JobIds) -join ',') | Should Be '20261103-063455-cd32,20261103-063052-859d'
    }
    It 'the real 3-day L1 run judged against that baseline: own/unhandled 0, vanilla 0 <= 29, tempo ratio 0.816 Passed' {
        $null = Update-RigL1Baseline -BaseJobIds @('20261103-063455-cd32') -ResultsRoot $fixtureResults -Path $script:file
        $l1 = Read-RigJobResultFile -ResultsRoot $fixtureResults -JobId '20261103-063052-859d'
        $run = @($l1.runs)[0]
        $modules = @($run.result.modules | ForEach-Object { $_.id })
        $v = Get-RigL1Verdict -RunId r1 -Result $run.result -ExpectedModules $modules -GameVersion $run.gameVersion -Baseline (Read-RigL1Baseline -Path $script:file)
        $v.Outcome | Should Be 'Met'
        (Get-Check $v 'vanilla').expected | Should Be '<= 29 (1.5 x baseline max 6 + 20)'
        (Get-Check $v 'tempo').actual | Should Be '18.17 days/min, ratio 0.816'
        (Get-Check $v 'playerMapEvents').status | Should Be 'Warn'
    }
}

Describe 'Update-L1Baseline.ps1 (powershell -File)' {
    It 'accepts comma-separated job ids and writes the file' {
        $t = New-VerdictTempDir
        try {
            $results = Join-Path $t 'results'
            $base = '20261104-090000-0b0b'; $l1 = '20261104-093000-1111'; $l1b = '20261104-094000-2222'
            foreach ($pair in @(@($base, 'L1-BASE'), @($l1, 'L1'), @($l1b, 'L1'))) {
                New-Item -ItemType Directory -Path (Join-Path $results $pair[0]) -Force | Out-Null
                [IO.File]::WriteAllText((Join-Path $results "$($pair[0])\job-result.json"), (New-JobResultJson -JobId $pair[0] -Suite $pair[1] -Tempos @('18.00', '17.00')))
            }
            $file = Join-Path $t 'L1.json'
            $script = Join-Path $here '..\..\runner\Update-L1Baseline.ps1'
            $null = & powershell -NoProfile -File $script -BaseJobIds $base -L1JobIds "$l1,$l1b" -ResultsRoot $results -Path $file 2>&1
            $LASTEXITCODE | Should Be 0
            $doc = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            @($doc.baseRuns).Count | Should Be 2
            @($doc.l1Runs).Count | Should Be 4
        } finally { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
