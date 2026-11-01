$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\runner\Invoke-TestRig.ps1')

$script:jobIdPattern = '^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$'

function New-TempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('rigrun-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    $d
}

function New-PackageFixture([string]$Root) {
    foreach ($m in 'CoherentWarAI', 'CoherentWarAI.TestHarness', 'TestRig.Harness') {
        $bin = Join-Path $Root "Modules\$m\bin\Win64_Shipping_Client"
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bin "$m.dll") -Value "dll $m"
        Set-Content -LiteralPath (Join-Path $Root "Modules\$m\SubModule.xml") -Value '<Module/>'
    }
}

function Write-TestConfig([string]$Dir) {
    $p = Join-Path $Dir 'runner.config.json'
    $c = @{ host = 'testpc'; user = 'rig'; keyPath = 'C:\keys\k'; remoteQueueRoot = 'C:\TestRig\queue' }
    [IO.File]::WriteAllText($p, ($c | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $p
}

# Calls Start-TestRigJob with defaults; $o overrides.
function Start-Rig([hashtable]$o) {
    $p = @{
        PackageFrom = $script:pkg; Seed = 1; Days = 1; Mode = 'WarSails'
        StallMinutes = 5; BudgetMinutes = 60; HardTimeoutMinutes = 20
        ClaimTimeoutSeconds = 0.3; TimeoutMinutes = 0.5
        ConfigPath = $script:cfg; OutRoot = $script:out
        PollSeconds = 0.02; StaleSeconds = 0.3; AbortWaitSeconds = 0.3; RetryDelaySeconds = 0
    }
    foreach ($k in $o.Keys) { $p[$k] = $o[$k] }
    Start-TestRigJob @p
}

# Mock helper: fake fetched results in DestinationRoot\<jobId>
function New-FakeResult($Root, $JobId, $DoneStatus, $Runs, $ResultText) {
    $d = Join-Path $Root $JobId
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $done = @{ schema = 1; jobId = $JobId; status = $DoneStatus; runs = @($Runs | ForEach-Object { @{ runId = $_.runId; exitClass = $_.exitClass } }) }
    [IO.File]::WriteAllText((Join-Path $d 'done.json'), ($done | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    foreach ($r in $Runs) {
        $rd = Join-Path $d $r.runId
        New-Item -ItemType Directory -Path $rd -Force | Out-Null
        if ($ResultText) { [IO.File]::WriteAllText((Join-Path $rd 'result.txt'), $ResultText) }
        $ar = @{ schema = 1; runId = $r.runId; exitClass = $r.exitClass; startedUtc = '2026-10-31T15:00:00Z'; endedUtc = '2026-10-31T15:12:30Z' }
        [IO.File]::WriteAllText((Join-Path $rd 'agent-run.json'), ($ar | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    }
    $d
}

Describe 'New-RigJobId' {
    It 'matches yyyyMMdd-HHmmss-xxxx in UTC' {
        $id = New-RigJobId -UtcNow ([datetime]'2026-10-31T15:30:00Z').ToUniversalTime() -Suffix 'a1b2'
        $id | Should Be '20261031-153000-a1b2'
    }
    It 'generates a valid random suffix by default' {
        (New-RigJobId) | Should Match $script:jobIdPattern
    }
}

Describe 'Get-RigModules' {
    $base = @('Bannerlord.Harmony', 'Bannerlord.ButterLib', 'Bannerlord.UIExtenderEx', 'Bannerlord.MBOptionScreen', 'Native', 'SandBoxCore', 'Sandbox', 'StoryMode')
    It 'WarSails includes NavalDLC before the mod modules' {
        (Get-RigModules -Mode WarSails) -join ',' | Should Be (($base + 'NavalDLC' + 'CoherentWarAI' + 'CoherentWarAI.TestHarness') -join ',')
    }
    It 'FeatureOff includes NavalDLC' {
        (Get-RigModules -Mode FeatureOff) -join ',' | Should Be (($base + 'NavalDLC' + 'CoherentWarAI' + 'CoherentWarAI.TestHarness') -join ',')
    }
    It 'NoDlc omits NavalDLC' {
        (Get-RigModules -Mode NoDlc) -join ',' | Should Be (($base + 'CoherentWarAI' + 'CoherentWarAI.TestHarness') -join ',')
    }
    It 'Harness CoherentWarAI keeps the load order (ends with CoherentWarAI, CoherentWarAI.TestHarness)' {
        (Get-RigModules -Mode WarSails -Harness CoherentWarAI) -join ',' | Should Be (($base + 'NavalDLC' + 'CoherentWarAI' + 'CoherentWarAI.TestHarness') -join ',')
    }
    It 'Harness TestRig ends with CoherentWarAI, TestRig.Harness and omits CoherentWarAI.TestHarness' {
        $m = @(Get-RigModules -Mode WarSails -Harness TestRig)
        $m -join ',' | Should Be (($base + 'NavalDLC' + 'CoherentWarAI' + 'TestRig.Harness') -join ',')
        ($m -contains 'CoherentWarAI.TestHarness') | Should Be $false
    }
    It 'NoDlc drops NavalDLC for both harnesses' {
        (Get-RigModules -Mode NoDlc -Harness CoherentWarAI) -join ',' | Should Be (($base + 'CoherentWarAI' + 'CoherentWarAI.TestHarness') -join ',')
        (Get-RigModules -Mode NoDlc -Harness TestRig) -join ',' | Should Be (($base + 'CoherentWarAI' + 'TestRig.Harness') -join ',')
    }
    It 'rejects an unknown harness' {
        $err = $null
        try { Get-RigModules -Mode WarSails -Harness Other } catch { $err = $_ }
        $err | Should Not BeNullOrEmpty
        $err.FullyQualifiedErrorId | Should Match '^ParameterArgumentValidationError'
    }
}

Describe 'New-RigPackage' {
    BeforeEach { $script:t = New-TempDir; $script:src = Join-Path $script:t 'src'; New-PackageFixture $script:src }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    It 'zips Modules/<id>/... with forward-slash entries and returns an uppercase SHA-256' {
        $zip = Join-Path $script:t 'package.zip'
        $r = New-RigPackage -PackageFrom $script:src -ZipPath $zip
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try { $names = @($z.Entries | ForEach-Object { $_.FullName } | Sort-Object) } finally { $z.Dispose() }
        $names -contains 'Modules/CoherentWarAI/SubModule.xml' | Should Be $true
        $names -contains 'Modules/CoherentWarAI.TestHarness/bin/Win64_Shipping_Client/CoherentWarAI.TestHarness.dll' | Should Be $true
        @($names | Where-Object { $_ -match '\\' }).Count | Should Be 0
        @($names | Where-Object { $_ -notmatch '^Modules/' }).Count | Should Be 0
        $r.Sha256 | Should Be (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        $r.Sha256 | Should Match '^[0-9A-F]{64}$'
    }

    It 'throws when there is no Modules folder' {
        $empty = Join-Path $script:t 'empty'
        New-Item -ItemType Directory -Path $empty | Out-Null
        { New-RigPackage -PackageFrom $empty -ZipPath (Join-Path $script:t 'x.zip') } | Should Throw
    }
}

Describe 'New-RigJobManifest' {
    It 'matches the schema-1 contract' {
        $j = New-RigJobManifest -JobId '20261031-153000-a1b2' -CreatedUtc ([datetime]'2026-10-31T15:30:00Z').ToUniversalTime() `
            -PackageSha256 'ABC123' -Seed 7 -Days 3 -Mode NoDlc -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20
        $text = ConvertTo-RigJson $j
        $o = $text | ConvertFrom-Json
        $o.schema | Should Be 1
        $o.jobId | Should Be '20261031-153000-a1b2'
        $text | Should Match '"createdUtc":\s*"2026-10-31T15:30:00Z"'
        $o.expectedGameVersion | Should BeNullOrEmpty
        $o.package.file | Should Be 'package.zip'
        $o.package.sha256 | Should Be 'ABC123'
        @($o.repos).Count | Should Be 0
        ($o.modules -join ',') | Should Be ((Get-RigModules -Mode NoDlc) -join ',')
        @($o.runs).Count | Should Be 1
        $r = $o.runs[0]
        $r.runId | Should Be 'r1'
        $r.kind | Should Be 'soak'
        $r.harness | Should Be 'CoherentWarAI'
        $r.seed | Should Be 7
        $r.days | Should Be 3
        $r.mode | Should Be 'NoDlc'
        $r.stallMinutes | Should Be 5
        $r.budgetMinutes | Should Be 60
        $r.hardTimeoutMinutes | Should Be 20
        $text | Should Match '"repos":\s*\[\s*\]'
    }
    It 'sets runs[0].harness and the matching modules for -Harness TestRig' {
        $j = New-RigJobManifest -JobId '20261031-153000-a1b2' -CreatedUtc ([datetime]'2026-10-31T15:30:00Z').ToUniversalTime() `
            -PackageSha256 'ABC123' -Seed 7 -Days 3 -Mode WarSails -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -Harness TestRig
        $o = (ConvertTo-RigJson $j) | ConvertFrom-Json
        $o.runs[0].harness | Should Be 'TestRig'
        ($o.modules -join ',') | Should Be ((Get-RigModules -Mode WarSails -Harness TestRig) -join ',')
        ($o.modules -contains 'CoherentWarAI.TestHarness') | Should Be $false
    }
    It 'writes UTF-8 without BOM' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ('bom-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            Write-RigJsonFile -Path $f -InputObject @{ a = 1 }
            $b = [IO.File]::ReadAllBytes($f)
            ($b[0] -eq 0xEF) | Should Be $false
        } finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
    }
}

Describe 'ConvertFrom-RigResultText' {
    It 'parses key=value lines, tolerates empty values and CRLF' {
        $h = ConvertFrom-RigResultText "status=Completed`r`ndaysReached=3`r`nnote=`r`n# c`r`nbad line`r`n"
        $h['status'] | Should Be 'Completed'
        $h['daysReached'] | Should Be '3'
        $h['note'] | Should Be ''
        $h.Count | Should Be 3
    }
}

Describe 'Resolve-RigExitCode' {
    function Run($cls, $reached) { [pscustomobject]@{ exitClass = $cls; daysReached = $reached } }

    $cases = @(
        @{ s = 'completed'; c = 'Completed'; d = 3; e = 0 },
        @{ s = 'completed'; c = 'Completed'; d = 2; e = 2 },
        @{ s = 'completed'; c = 'Completed'; d = $null; e = 2 },
        @{ s = 'completed'; c = 'NotCompleted'; d = $null; e = 2 },
        @{ s = 'completed'; c = 'Crashed'; d = 1; e = 2 },
        @{ s = 'completed'; c = 'HardTimeout'; d = $null; e = 3 },
        @{ s = 'completed'; c = 'Aborted'; d = $null; e = 3 },
        @{ s = 'completed'; c = 'SetupError'; d = $null; e = 1 },
        @{ s = 'completed'; c = 'LaunchFailed'; d = $null; e = 1 },
        @{ s = 'completed'; c = 'CleanupFailed'; d = $null; e = 1 },
        @{ s = 'completed'; c = 'SomethingNew'; d = $null; e = 1 },
        @{ s = 'blocked'; c = 'Completed'; d = 3; e = 1 },
        @{ s = 'rejected'; c = 'Completed'; d = 3; e = 1 },
        @{ s = 'failed'; c = 'Completed'; d = 3; e = 1 },
        @{ s = 'aborted'; c = 'Aborted'; d = $null; e = 3 },
        @{ s = 'weird'; c = 'Completed'; d = 3; e = 1 }
    )
    foreach ($case in $cases) {
        It ("status=$($case.s) exitClass=$($case.c) daysReached=$($case.d) -> $($case.e)") {
            Resolve-RigExitCode -DoneStatus $case.s -Runs @(Run $case.c $case.d) -Days 3 | Should Be $case.e
        }
    }

    It 'precedence 1 > 3 > 2 > 0 across runs' {
        Resolve-RigExitCode -DoneStatus completed -Days 1 -Runs @((Run Completed 1), (Run NotCompleted $null)) | Should Be 2
        Resolve-RigExitCode -DoneStatus completed -Days 1 -Runs @((Run NotCompleted $null), (Run HardTimeout $null)) | Should Be 3
        Resolve-RigExitCode -DoneStatus completed -Days 1 -Runs @((Run HardTimeout $null), (Run SetupError $null)) | Should Be 1
        Resolve-RigExitCode -DoneStatus completed -Days 1 -Runs @((Run Completed 1), (Run Completed 1)) | Should Be 0
    }
    It '-ForceTimeout raises a clean result to 3 but never lowers 1' {
        Resolve-RigExitCode -DoneStatus completed -Days 1 -Runs @(Run Completed 1) -ForceTimeout | Should Be 3
        Resolve-RigExitCode -DoneStatus completed -Days 1 -Runs @(Run SetupError $null) -ForceTimeout | Should Be 1
        Resolve-RigExitCode -DoneStatus aborted -Days 1 -Runs @() -ForceTimeout | Should Be 3
    }
    It 'completed with zero runs is an infrastructure error' {
        Resolve-RigExitCode -DoneStatus completed -Days 1 -Runs @() | Should Be 1
    }
}

Describe 'Format-RigRunLine' {
    It 'contains runId, kind, status, days, exitClass, duration and path' {
        $l = Format-RigRunLine -RunId r1 -Kind soak -Status Completed -DaysReached 3 -Days 3 -ExitClass Completed `
            -Duration ([timespan]::FromSeconds(750)) -Path 'out\results\x\r1'
        $l | Should Match 'r1'
        $l | Should Match 'soak'
        $l | Should Match 'Completed'
        $l | Should Match '3/3'
        $l | Should Match '12m30s'
        $l | Should Match 'out\\results\\x\\r1'
    }
    It 'shows ? for unknown values' {
        $l = Format-RigRunLine -RunId r1 -Kind soak -Status $null -DaysReached $null -Days 3 -ExitClass SetupError -Duration $null -Path 'p'
        $l | Should Match '\?/3'
    }
}

Describe 'Start-TestRigJob' {
    BeforeEach {
        $script:t = New-TempDir
        $script:pkg = Join-Path $script:t 'pkg'; New-PackageFixture $script:pkg
        $script:out = Join-Path $script:t 'out'
        $script:cfg = Write-TestConfig $script:t
        $script:published = $null
        $script:stateQueue = @()
        $script:abortCalls = 0
        $script:calls = @{ Publish = 0; Withdraw = 0; Receive = 0; State = 0 }
        $script:withdrawQueue = @(W $true $false $false)   # popped per call, the last one repeats
        $script:stateFailures = 0
        $script:receiveFailures = 0
        $script:fake = $null
        Mock Get-JobState { @() } -ParameterFilter { $OpenJobs }
        Mock Get-JobState {
            $script:calls.State++
            if ($script:stateFailures -gt 0) { $script:stateFailures--; throw 'ssh failed (exit 255)' }
            if ($script:stateQueue.Count -gt 1) { $r = $script:stateQueue[0]; $script:stateQueue = @($script:stateQueue[1..($script:stateQueue.Count - 1)]); $r }
            else { $script:stateQueue[0] }
        } -ParameterFilter { $JobId }
        Mock Publish-Job {
            $script:calls.Publish++
            $script:published = @{ JobId = $JobId; Dir = $JobDirectory; Job = (Get-Content -LiteralPath (Join-Path $JobDirectory 'job.json') -Raw | ConvertFrom-Json) }
        }
        Mock Send-JobAbort {
            $script:calls.Withdraw++
            $r = $script:withdrawQueue[0]
            if ($script:withdrawQueue.Count -gt 1) { $script:withdrawQueue = @($script:withdrawQueue[1..($script:withdrawQueue.Count - 1)]) }
            $r
        } -ParameterFilter { $Withdraw }
        Mock Send-JobAbort { $script:abortCalls++ } -ParameterFilter { -not $Withdraw }
        Mock Receive-JobResult {
            $script:calls.Receive++
            if ($script:receiveFailures -gt 0) { $script:receiveFailures--; throw 'scp failed (exit 1)' }
            $f = $script:fake
            New-FakeResult -Root $DestinationRoot -JobId $JobId -DoneStatus $f.Status -Runs $f.Runs -ResultText $f.Text | Out-Null
            Join-Path $DestinationRoot $JobId
        }
        Mock Write-Host { }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    function S($jobJson, $claimed, $state, $done) { [pscustomobject]@{ jobJson = $jobJson; claimed = $claimed; withdrawn = $false; state = $state; done = $done } }
    function B($n) { [pscustomobject]@{ beat = $n; state = 'running' } }
    function W($withdrawn, $jobJsonPresent, $claimed) { [pscustomobject]@{ withdrawn = $withdrawn; jobJsonPresent = $jobJsonPresent; claimed = $claimed } }

    It 'refuses to publish while a job is open (exit 1, names the job)' {
        Mock Get-JobState { @('20261031-120000-dead') } -ParameterFilter { $OpenJobs }
        $script:msgs = @()
        Mock Write-Host { $script:msgs += "$Object" }
        Mock Write-Warning { $script:msgs += "$Message" }
        Mock Write-Error { $script:msgs += "$Message" }
        (Start-Rig @{}) | Should Be 1
        $script:calls.Publish | Should Be 0
        ($script:msgs -join "`n") | Should Match '20261031-120000-dead'
    }

    It 'without -Wait publishes job.json + package.zip and exits 0' {
        (Start-Rig @{}) | Should Be 0
        $script:calls.Publish | Should Be 1
        $script:published.JobId | Should Match $script:jobIdPattern
        $script:published.Job.jobId | Should Be $script:published.JobId
        $script:published.Job.package.sha256 | Should Be (Get-FileHash -LiteralPath (Join-Path $script:published.Dir 'package.zip') -Algorithm SHA256).Hash
        $script:published.Dir | Should Be (Join-Path (Join-Path $script:out 'jobs') $script:published.JobId)
        $script:calls.State | Should Be 0
    }

    It 'passes parameters into job.json' {
        Start-Rig @{ Seed = 9; Days = 4; Mode = 'NoDlc' } | Out-Null
        $r = $script:published.Job.runs[0]
        $r.seed | Should Be 9
        $r.days | Should Be 4
        $r.mode | Should Be 'NoDlc'
    }

    It 'defaults to harness CoherentWarAI in job.json' {
        Start-Rig @{} | Out-Null
        $script:published.Job.runs[0].harness | Should Be 'CoherentWarAI'
    }

    It 'passes -Harness TestRig into job.json (harness and modules)' {
        Start-Rig @{ Harness = 'TestRig' } | Out-Null
        $script:published.Job.runs[0].harness | Should Be 'TestRig'
        ($script:published.Job.modules -contains 'TestRig.Harness') | Should Be $true
        ($script:published.Job.modules -contains 'CoherentWarAI.TestHarness') | Should Be $false
    }

    It 'writes the canonical harness casing into job.json for -Harness testrig' {
        Start-Rig @{ Harness = 'testrig' } | Out-Null
        $script:published.Job.runs[0].harness | Should BeExactly 'TestRig'
        ($script:published.Job.modules -contains 'TestRig.Harness') | Should Be $true
    }

    It 'exits 1 before publishing when -PackageFrom lacks the harness module' {
        Remove-Item -LiteralPath (Join-Path $script:pkg 'Modules\TestRig.Harness') -Recurse -Force
        $script:msgs = @()
        Mock Write-Host { $script:msgs += "$Object" }
        (Start-Rig @{ Harness = 'TestRig' }) | Should Be 1
        $script:calls.Publish | Should Be 0
        ($script:msgs -join "`n") | Should Match 'TestRig\.Harness'
    }

    It 'returns 1 on a transport error while checking for open jobs' {
        Mock Get-JobState { throw 'ssh failed (exit 255)' } -ParameterFilter { $OpenJobs }
        Mock Write-Error { }
        (Start-Rig @{}) | Should Be 1
        $script:calls.Publish | Should Be 0
    }

    It 'returns 1 when the config is missing' {
        Mock Write-Error { }
        (Start-Rig @{ ConfigPath = (Join-Path $script:t 'nope.json') }) | Should Be 1
    }

    It 'claim timeout: withdraws and exits 3, nothing fetched' {
        $script:stateQueue = @(S $true $false $null $false)
        (Start-Rig @{ Wait = $true }) | Should Be 3
        $script:calls.Withdraw | Should Be 1
        $script:calls.Receive | Should Be 0
    }

    It 'withdraw losing the race to a claim (job.claimed.json) keeps waiting and then fetches the result' {
        $script:withdrawQueue = @(W $false $false $true)
        $script:fake = @{ Status = 'completed'; Runs = @(@{ runId = 'r1'; exitClass = 'Completed' }); Text = "status=Completed`ndaysReached=1`n" }
        $q = @(); 1..12 | ForEach-Object { $q += , (S $true $false $null $false) }
        $q += , (S $false $true (B 1) $false); $q += , (S $false $true (B 2) $true)
        $script:stateQueue = $q
        (Start-Rig @{ Wait = $true; ClaimTimeoutSeconds = 0.05; StaleSeconds = 5; TimeoutMinutes = 1 }) | Should Be 0
        $script:calls.Withdraw | Should Be 1
        $script:calls.Receive | Should Be 1
    }

    It 'a failed withdraw with job.json still present is not a claim: retried on the next polls until it succeeds' {
        $script:withdrawQueue = @((W $false $true $false), (W $false $true $false), (W $true $false $false))
        $script:stateQueue = @(S $true $false $null $false)
        (Start-Rig @{ Wait = $true; ClaimTimeoutSeconds = 0.05; StaleSeconds = 0.05; TimeoutMinutes = 1 }) | Should Be 3
        $script:calls.Withdraw | Should Be 3
        $script:abortCalls | Should Be 0
        $script:calls.Receive | Should Be 0
    }

    It 'a failed withdraw is retried until a claim shows up, then the run is followed normally' {
        $script:withdrawQueue = @((W $false $true $false), (W $false $false $true))
        $script:fake = @{ Status = 'completed'; Runs = @(@{ runId = 'r1'; exitClass = 'Completed' }); Text = "status=Completed`ndaysReached=1`n" }
        $q = @(); 1..8 | ForEach-Object { $q += , (S $true $false $null $false) }
        $q += , (S $false $true (B 1) $false); $q += , (S $false $true (B 2) $true)
        $script:stateQueue = $q
        (Start-Rig @{ Wait = $true; ClaimTimeoutSeconds = 0.05; StaleSeconds = 5; TimeoutMinutes = 1 }) | Should Be 0
        $script:calls.Withdraw | Should Be 2
        $script:calls.Receive | Should Be 1
    }

    It 'withdraw retry budget used up: exit 3 and says job.json may still be pending' {
        $script:withdrawQueue = @(W $false $true $false)
        $script:stateQueue = @(S $true $false $null $false)
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
        (Start-Rig @{ Wait = $true; ClaimTimeoutSeconds = 0.05; StaleSeconds = 0.05; TimeoutMinutes = 1; MaxWithdrawAttempts = 3 }) | Should Be 3
        $script:calls.Withdraw | Should Be 3
        $script:abortCalls | Should Be 0
        $script:calls.Receive | Should Be 0
        ($script:lines -join "`n") | Should Match 'job\.json may still be pending'
    }

    It 'stale heartbeat: exits 3 when beat does not change' {
        $script:stateQueue = @(S $false $true (B 5) $false)
        (Start-Rig @{ Wait = $true; StaleSeconds = 0.2; TimeoutMinutes = 1 }) | Should Be 3
        $script:calls.Withdraw | Should Be 0
        $script:calls.Receive | Should Be 0
    }

    It 'stale heartbeat: sends a best-effort abort' {
        $script:stateQueue = @(S $false $true (B 5) $false)
        (Start-Rig @{ Wait = $true; StaleSeconds = 0.2; TimeoutMinutes = 1 }) | Should Be 3
        $script:abortCalls | Should Be 1
    }

    It 'stale heartbeat: a failing abort does not change exit 3' {
        Mock Send-JobAbort { throw 'ssh failed (exit 255)' } -ParameterFilter { -not $Withdraw }
        $script:stateQueue = @(S $false $true (B 5) $false)
        (Start-Rig @{ Wait = $true; StaleSeconds = 0.2; TimeoutMinutes = 1 }) | Should Be 3
    }

    It 'a missing state.json after a beat was seen does not count as a beat change' {
        $script:n = 0
        Mock Get-JobState {
            $script:n++
            if ($script:n % 2 -eq 0) { S $false $true $null $false } else { S $false $true (B 5) $false }
        } -ParameterFilter { $JobId }
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
        (Start-Rig @{ Wait = $true; StaleSeconds = 0.3; TimeoutMinutes = 0.1 }) | Should Be 3
        ($script:lines -join "`n") | Should Match 'heartbeat'   # stale heartbeat, not the overall deadline
    }

    It 'a transient poll error is retried and the run continues' {
        $script:fake = @{ Status = 'completed'; Runs = @(@{ runId = 'r1'; exitClass = 'Completed' }); Text = "status=Completed`ndaysReached=1`n" }
        $script:stateFailures = 2
        $script:stateQueue = @((S $false $true (B 1) $false), (S $false $true (B 2) $true))
        (Start-Rig @{ Wait = $true; TimeoutMinutes = 1; StaleSeconds = 5 }) | Should Be 0
    }

    It 'a poll that keeps failing ends with exit 1 after 3 attempts' {
        $script:stateFailures = 99
        Mock Write-Error { }
        (Start-Rig @{ Wait = $true; TimeoutMinutes = 1 }) | Should Be 1
        $script:calls.State | Should Be 3
    }

    It 'failed polls do not reset the stale-heartbeat clock' {
        $script:stateFailures = 2
        $script:stateQueue = @(S $false $true (B 5) $false)
        (Start-Rig @{ Wait = $true; StaleSeconds = 0.2; TimeoutMinutes = 1 }) | Should Be 3
    }

    It 'a transient fetch error is retried (leftover handling lives in Receive-JobResult)' {
        $script:fake = @{ Status = 'completed'; Runs = @(@{ runId = 'r1'; exitClass = 'Completed' }); Text = "status=Completed`ndaysReached=1`n" }
        $script:receiveFailures = 2
        $script:stateQueue = @(S $false $true (B 1) $true)
        (Start-Rig @{ Wait = $true; TimeoutMinutes = 1 }) | Should Be 0
        $script:calls.Receive | Should Be 3
    }

    It 'a fetch that keeps failing ends with exit 1' {
        $script:receiveFailures = 99
        $script:stateQueue = @(S $false $true (B 1) $true)
        Mock Write-Error { }
        (Start-Rig @{ Wait = $true; TimeoutMinutes = 1 }) | Should Be 1
        $script:calls.Receive | Should Be 3
    }

    It 'changing beat does not trigger the stale check' {
        $script:fake = @{ Status = 'completed'; Runs = @(@{ runId = 'r1'; exitClass = 'Completed' }); Text = "status=Completed`ndaysReached=1`n" }
        $q = @(); 1..30 | ForEach-Object { $q += , (S $false $true (B $_) $false) }; $q += , (S $false $true (B 31) $true)
        $script:stateQueue = $q
        (Start-Rig @{ Wait = $true; StaleSeconds = 0.5; TimeoutMinutes = 1 }) | Should Be 0
    }

    It 'overall deadline: sends abort, waits for done.json, exits 3' {
        $script:fake = @{ Status = 'aborted'; Runs = @(@{ runId = 'r1'; exitClass = 'Aborted' }); Text = "status=Aborted`ndaysReached=0`n" }
        $script:beatCounter = 0
        Mock Get-JobState { $script:beatCounter++; S $false $true (B $script:beatCounter) ($script:abortCalls -gt 0) } -ParameterFilter { $JobId }
        (Start-Rig @{ Wait = $true; TimeoutMinutes = 0.005; StaleSeconds = 60 }) | Should Be 3
        $script:abortCalls | Should Be 1
        $script:calls.Receive | Should Be 1
    }

    It 'overall deadline without done.json after the abort wait: exits 3, no fetch' {
        $script:stateQueue = @(S $false $true (B 1) $false)
        # constantly changing beat is not needed: stale limit is larger than the deadline
        (Start-Rig @{ Wait = $true; TimeoutMinutes = 0.005; AbortWaitSeconds = 0.1; StaleSeconds = 60 }) | Should Be 3
        $script:abortCalls | Should Be 1
        $script:calls.Receive | Should Be 0
    }

    It 'done.json: fetches, prints one table line per run and writes job-result.json' {
        $script:fake = @{ Status = 'completed'; Runs = @(@{ runId = 'r1'; exitClass = 'Completed' }); Text = "status=Completed`ndaysReached=1`nseed=1`n" }
        $script:stateQueue = @((S $false $true (B 1) $false), (S $false $true (B 2) $true))
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
        (Start-Rig @{ Wait = $true; Days = 1; TimeoutMinutes = 1; StaleSeconds = 5 }) | Should Be 0
        $id = $script:published.JobId
        $resDir = Join-Path (Join-Path $script:out 'results') $id
        $jr = Get-Content -LiteralPath (Join-Path $resDir 'job-result.json') -Raw | ConvertFrom-Json
        $jr.jobId | Should Be $id
        $jr.status | Should Be 'completed'
        $jr.runs[0].runId | Should Be 'r1'
        $jr.runs[0].exitClass | Should Be 'Completed'
        $jr.runs[0].result.status | Should Be 'Completed'
        $jr.runs[0].result.daysReached | Should Be '1'
        $row = @($script:lines | Where-Object { $_ -match '^r1\s' })
        $row.Count | Should Be 1
        $row[0] | Should Match 'soak'
        $row[0] | Should Match '1/1'
        $row[0] | Should Match '12m30s'
    }

    It 'maps a failing run to its exit code (NotCompleted -> 2)' {
        $script:fake = @{ Status = 'completed'; Runs = @(@{ runId = 'r1'; exitClass = 'NotCompleted' }); Text = $null }
        $script:stateQueue = @(S $false $true (B 1) $true)
        (Start-Rig @{ Wait = $true; TimeoutMinutes = 1 }) | Should Be 2
    }

    It 'maps a blocked job to exit 1' {
        $script:fake = @{ Status = 'blocked'; Runs = @(); Text = $null }
        $script:stateQueue = @(S $false $true (B 1) $true)
        (Start-Rig @{ Wait = $true; TimeoutMinutes = 1 }) | Should Be 1
    }

    It 'returns 1 on a transport error while waiting' {
        Mock Get-JobState { throw 'ssh failed (exit 255)' } -ParameterFilter { $JobId }
        Mock Write-Error { }
        (Start-Rig @{ Wait = $true; TimeoutMinutes = 1 }) | Should Be 1
    }
}

Describe 'Invoke-TestRig.ps1 run via powershell -File (PS 5.1)' {
    It 'resolves the default ConfigPath in the body ($PSScriptRoot is empty in param defaults)' {
        # Copy to a temp folder without runner.config.json so the default path is guaranteed missing.
        $d = New-TempDir
        try {
            foreach ($f in 'Invoke-TestRig.ps1', 'Transport.Ssh.ps1', 'Build-Package.ps1') {
                Copy-Item -LiteralPath (Join-Path $here "..\..\runner\$f") -Destination $d
            }
            $pkg = New-TempDir
            $out = (& powershell -NoProfile -File (Join-Path $d 'Invoke-TestRig.ps1') -PackageFrom $pkg 2>&1 | Out-String)
            $LASTEXITCODE | Should Be 1
            $out | Should Match 'Config not found'
            $out | Should Match 'runner\.config\.json'
            $out | Should Not Match 'Join-Path'
            Remove-Item -LiteralPath $pkg -Recurse -Force -ErrorAction SilentlyContinue
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Job manifest serializes lists as JSON arrays' {
    It 'writes "modules" and "runs" as arrays in the job.json text' {
        $j = New-RigJobManifest -JobId '20261031-153000-a1b2' -CreatedUtc ([datetime]'2026-10-31T15:30:00Z').ToUniversalTime() `
            -PackageSha256 'ABC123' -Seed 7 -Days 3 -Mode NoDlc -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20
        $text = ConvertTo-RigJson $j
        $text | Should Match '"modules":\s*\[\s*"'
        $text | Should Match '"runs":\s*\[\s*\{'
        $text | Should Match '"repos":\s*\[\s*\]'
        $text | Should Not Match '"runs":\s*\{'
    }
}

Describe 'New-RigPackage path handling' {
    BeforeEach { $script:t = New-TempDir; $script:src = Join-Path $script:t 'src'; New-PackageFixture $script:src }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    It 'resolves a relative -PackageFrom against $PWD, not the process working directory' {
        [Environment]::CurrentDirectory | Should Not Be $script:t
        Push-Location -LiteralPath $script:t
        try {
            $r = New-RigPackage -PackageFrom 'src' -ZipPath (Join-Path $script:t 'rel.zip')
        } finally { Pop-Location }
        Test-Path -LiteralPath (Join-Path $script:t 'rel.zip') | Should Be $true
        $r.Sha256 | Should Match '^[0-9A-F]{64}$'
    }

    It 'includes hidden files' {
        $h = Join-Path $script:src 'Modules\CoherentWarAI\.hidden.cfg'
        Set-Content -LiteralPath $h -Value 'x'
        (Get-Item -LiteralPath $h -Force).Attributes = 'Hidden'
        $zip = Join-Path $script:t 'h.zip'
        New-RigPackage -PackageFrom $script:src -ZipPath $zip | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try { $names = @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
        ($names -contains 'Modules/CoherentWarAI/.hidden.cfg') | Should Be $true
    }
}

Describe 'Get-RigConfig host/user validation (no ssh option injection)' {
    BeforeEach { $script:t = New-TempDir }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    function Write-Cfg($hostName, $user) {
        $p = Join-Path $script:t 'c.json'
        $c = @{ host = $hostName; user = $user; keyPath = 'C:\keys\k'; remoteQueueRoot = 'C:\q' }
        [IO.File]::WriteAllText($p, ($c | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        $p
    }

    foreach ($bad in '-oProxyCommand=calc', 'a b', 'host;calc', "host`n", 'ho$t', '-h') {
        It "rejects host '$($bad -replace "`n", '\n')'" {
            { Get-RigConfig -Path (Write-Cfg $bad 'rig') } | Should Throw "'host'"
        }
    }
    foreach ($bad in '-oProxyCommand=calc', 'r ig', "rig`n", 'rig@x') {
        It "rejects user '$($bad -replace "`n", '\n')'" {
            { Get-RigConfig -Path (Write-Cfg 'testpc' $bad) } | Should Throw "'user'"
        }
    }
    foreach ($ok in @(@('testpc', 'rig'), @('test-pc.local', 'rig_1'), @('192.168.1.5', 'Rig.User'))) {
        It "accepts host '$($ok[0])' user '$($ok[1])'" {
            (Get-RigConfig -Path (Write-Cfg $ok[0] $ok[1])).host | Should Be $ok[0]
        }
    }
}

Describe 'Publish-RigResult with hostile or broken done.json' {
    BeforeEach {
        $script:t = New-TempDir
        $script:id = '20261031-153000-a1b2'
        $script:rd = Join-Path $script:t $script:id
        New-Item -ItemType Directory -Path $script:rd | Out-Null
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    function Write-Done([string]$Json) { [IO.File]::WriteAllText((Join-Path $script:rd 'done.json'), $Json, (New-Object Text.UTF8Encoding($false))) }
    function Get-JobResult { Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json }
    function Publish { Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 }

    It 'rejects a runId that escapes the result folder' {
        Write-Done '{"schema":1,"jobId":"20261031-153000-a1b2","status":"completed","runs":[{"runId":"..\\x","exitClass":"Completed"}]}'
        { Publish } | Should Throw 'Invalid runId'
        Test-Path -LiteralPath (Join-Path $script:rd 'job-result.json') | Should Be $false
    }

    It 'rejects a runId with a trailing newline' {
        Write-Done '{"schema":1,"jobId":"20261031-153000-a1b2","status":"completed","runs":[{"runId":"r1\n","exitClass":"Completed"}]}'
        { Publish } | Should Throw 'Invalid runId'
    }

    It 'treats runs: null as an empty list: clear message, job-result.json written, exit 1 for completed' {
        Write-Done '{"schema":1,"jobId":"20261031-153000-a1b2","status":"completed","runs":null}'
        Publish | Should Be 1
        ($script:lines -join "`n") | Should Match "no 'runs'"
        ($script:lines -join "`n") | Should Not Match 'Invalid runId'
        (Get-JobResult).exitCode | Should Be 1
        @((Get-JobResult).runs).Count | Should Be 0
    }

    It 'treats a missing runs list the same way' {
        Write-Done '{"schema":1,"jobId":"20261031-153000-a1b2","status":"completed"}'
        Publish | Should Be 1
        ($script:lines -join "`n") | Should Match "no 'runs'"
        (Get-JobResult).exitCode | Should Be 1
    }

    It 'keeps the exit code of an aborted job with runs: null (3)' {
        Write-Done '{"schema":1,"jobId":"20261031-153000-a1b2","status":"aborted","runs":null}'
        Publish | Should Be 3
    }

    It 'a missing status is exit 1 with a clear message and a job-result.json' {
        Write-Done '{"schema":1,"jobId":"20261031-153000-a1b2","runs":[{"runId":"r1","exitClass":"Completed"}]}'
        New-Item -ItemType Directory -Path (Join-Path $script:rd 'r1') | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:rd 'r1\result.txt'), "status=Completed`ndaysReached=1`n")
        Publish | Should Be 1
        ($script:lines -join "`n") | Should Match "no 'status'"
        (Get-JobResult).exitCode | Should Be 1
        (Get-JobResult).jobId | Should Be $script:id
    }

    It 'a done.json for another job is an error' {
        Write-Done '{"schema":1,"jobId":"20261031-160000-ffff","status":"completed","runs":[]}'
        { Publish } | Should Throw 'another job'
        Test-Path -LiteralPath (Join-Path $script:rd 'job-result.json') | Should Be $false
    }

    It 'a done.json without jobId is an error' {
        Write-Done '{"schema":1,"status":"completed","runs":[]}'
        { Publish } | Should Throw 'another job'
    }

    It 'the happy path still works' {
        Write-Done '{"schema":1,"jobId":"20261031-153000-a1b2","status":"completed","runs":[{"runId":"r1","exitClass":"Completed"}]}'
        New-Item -ItemType Directory -Path (Join-Path $script:rd 'r1') | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:rd 'r1\result.txt'), "status=Completed`ndaysReached=1`n")
        Publish | Should Be 0
    }
}

Describe 'Invoke-RigWithRetry' {
    It 'returns the value of the first successful attempt' {
        $script:n = 0
        $r = Invoke-RigWithRetry -DelaySeconds 0 -Action { $script:n++; if ($script:n -lt 3) { throw 'transient' }; 'ok' }
        $r | Should Be 'ok'
        $script:n | Should Be 3
    }
    It 'rethrows the last error after the attempts are used up' {
        $script:n = 0
        { Invoke-RigWithRetry -DelaySeconds 0 -Attempts 2 -Action { $script:n++; throw "boom $script:n" } } | Should Throw 'boom 2'
        $script:n | Should Be 2
    }
}

Describe 'Invoke-TestRig.ps1 parameter validation (powershell -File)' {
    $scriptPath = Join-Path $here '..\..\runner\Invoke-TestRig.ps1'
    foreach ($case in @(
            @('-Days', '0'), @('-StallMinutes', '0'), @('-BudgetMinutes', '0'), @('-HardTimeoutMinutes', '0'),
            @('-ClaimTimeoutSeconds', '0'), @('-TimeoutMinutes', '0'), @('-TimeoutMinutes', '-5'))) {
        It "rejects $($case[0]) $($case[1])" {
            $out = (& powershell -NoProfile -File $scriptPath -PackageFrom C:\nowhere $case[0] $case[1] 2>&1 | Out-String)
            $LASTEXITCODE | Should Not Be 0
            $out | Should Match ($case[0].TrimStart('-'))
            $out | Should Not Match 'Config not found'
        }
    }
}

Describe 'Invoke-TestRig.ps1 -Harness parameter' {
    $scriptPath = Join-Path $here '..\..\runner\Invoke-TestRig.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
    $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Harness' }

    It 'exists with default CoherentWarAI' {
        $param | Should Not BeNullOrEmpty
        $param.DefaultValue.Value | Should Be 'CoherentWarAI'
    }
    It 'has ValidateSet CoherentWarAI, TestRig' {
        $vs = @($param.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })
        $vs.Count | Should Be 1
        (@($vs[0].PositionalArguments | ForEach-Object { $_.Value }) -join ',') | Should Be 'CoherentWarAI,TestRig'
    }
    It 'rejects an unknown value (powershell -File)' {
        $out = (& powershell -NoProfile -File $scriptPath -PackageFrom C:\nowhere -Harness Other 2>&1 | Out-String)
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match 'ParameterArgumentValidationError'
        $out | Should Match 'Harness'
        $out | Should Match 'Other'
        $out | Should Not Match 'Config not found'
    }
}

Describe 'Start-TestRigJob build mode (no -PackageFrom)' {
    BeforeEach {
        $script:t = New-TempDir
        $script:out = Join-Path $script:t 'out'
        $script:cfg = Join-Path $script:t 'build.config.json'
        $script:buildCalls = @()
        $script:buildFailure = $null
        $script:published = $null
        $script:calls = @{ Publish = 0 }
        $script:lines = @()
        $script:fakeRepos = @(
            [pscustomobject]@{ name = 'RepoOne'; sha = ('a' * 40); dirty = $false },
            [pscustomobject]@{ name = 'RepoTwo'; sha = ('b' * 40); dirty = $true })
        Mock Get-JobState { @() } -ParameterFilter { $OpenJobs }
        Mock Publish-Job {
            $script:calls.Publish++
            $script:published = @{ JobId = $JobId; Dir = $JobDirectory; Job = (Get-Content -LiteralPath (Join-Path $JobDirectory 'job.json') -Raw | ConvertFrom-Json) }
        }
        Mock Write-Host { $script:lines += "$Object" }
        Mock Invoke-RigBuildPackage {
            $script:buildCalls += , @{ WorkspaceRoot = $WorkspaceRoot; StageDir = $StageDir; TowerGamePath = $TowerGamePath; MsBuildPath = $MsBuildPath }
            if ($script:buildFailure) { throw $script:buildFailure }
            $m = Join-Path $StageDir 'Modules\CoherentWarAI\bin\Win64_Shipping_Client'
            New-Item -ItemType Directory -Path $m -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $m 'CoherentWarAI.dll') -Value 'dll'
            Set-Content -LiteralPath (Join-Path $StageDir 'Modules\CoherentWarAI\SubModule.xml') -Value '<Module/>'
            Set-Content -LiteralPath (Join-Path $StageDir 'manifest.json') -Value '{"schema":1,"marker":"from-build"}'
            [pscustomobject]@{ StageDir = $StageDir; ManifestPath = (Join-Path $StageDir 'manifest.json'); Repos = $script:fakeRepos }
        }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    function Write-BuildConfig([hashtable]$Extra) {
        $c = @{ host = 'testpc'; user = 'rig'; keyPath = 'C:\keys\k'; remoteQueueRoot = 'C:\TestRig\queue' }
        foreach ($k in $Extra.Keys) { $c[$k] = $Extra[$k] }
        [IO.File]::WriteAllText($script:cfg, ($c | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    }
    function Start-BuildRig([hashtable]$o) {
        $p = @{
            PackageFrom = ''; Seed = 1; Days = 1; Mode = 'WarSails'
            StallMinutes = 5; BudgetMinutes = 60; HardTimeoutMinutes = 20
            ClaimTimeoutSeconds = 0.3; TimeoutMinutes = 0.5
            ConfigPath = $script:cfg; OutRoot = $script:out
            PollSeconds = 0.02; StaleSeconds = 0.3; AbortWaitSeconds = 0.3; RetryDelaySeconds = 0
        }
        foreach ($k in $o.Keys) { $p[$k] = $o[$k] }
        Start-TestRigJob @p
    }

    It 'builds into <OutRoot>\stage\<jobId> using towerGamePath\Modules and the default msbuildPath, then publishes' {
        Write-BuildConfig @{ towerGamePath = 'C:\Games\Bannerlord' }
        (Start-BuildRig @{}) | Should Be 0
        Assert-MockCalled Invoke-RigBuildPackage -Exactly 1 -Scope It
        $script:calls.Publish | Should Be 1
        $b = $script:buildCalls[0]
        $b.StageDir | Should Be (Join-Path (Join-Path $script:out 'stage') $script:published.JobId)
        $b.TowerGamePath | Should Be 'C:\Games\Bannerlord'
        $b.MsBuildPath | Should Be 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\MSBuild\Current\Bin\MSBuild.exe'
        $b.WorkspaceRoot | Should Be (Split-Path -Parent (Resolve-Path (Join-Path $here '..\..')).ProviderPath)
    }

    It 'uses msbuildPath from the config when given' {
        Write-BuildConfig @{ towerGamePath = 'C:\Games\Bannerlord'; msbuildPath = 'D:\tools\MSBuild.exe' }
        (Start-BuildRig @{}) | Should Be 0
        $script:buildCalls[0].MsBuildPath | Should Be 'D:\tools\MSBuild.exe'
    }

    It 'packs the staged folder, writes the repo states into job.json and copies manifest.json next to it' {
        Write-BuildConfig @{ towerGamePath = 'C:\Games\Bannerlord' }
        (Start-BuildRig @{}) | Should Be 0
        $dir = $script:published.Dir
        $dir | Should Be (Join-Path (Join-Path $script:out 'jobs') $script:published.JobId)
        $script:published.Job.package.sha256 | Should Be (Get-FileHash -LiteralPath (Join-Path $dir 'package.zip') -Algorithm SHA256).Hash
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead((Join-Path $dir 'package.zip'))
        try { $names = @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
        ($names -contains 'Modules/CoherentWarAI/SubModule.xml') | Should Be $true
        ($names -contains 'Modules/CoherentWarAI/bin/Win64_Shipping_Client/CoherentWarAI.dll') | Should Be $true
        @($script:published.Job.repos).Count | Should Be 2
        $script:published.Job.repos[0].name | Should Be 'RepoOne'
        $script:published.Job.repos[0].sha | Should Be ('a' * 40)
        $script:published.Job.repos[0].dirty | Should Be $false
        $script:published.Job.repos[1].name | Should Be 'RepoTwo'
        $script:published.Job.repos[1].dirty | Should Be $true
        Test-Path -LiteralPath (Join-Path $dir 'manifest.json') | Should Be $true
        (Get-Content -LiteralPath (Join-Path $dir 'manifest.json') -Raw) | Should Match 'from-build'
    }

    It 'keeps the module load order of job.json' {
        Write-BuildConfig @{ towerGamePath = 'C:\Games\Bannerlord' }
        Start-BuildRig @{ Mode = 'NoDlc' } | Out-Null
        ($script:published.Job.modules -join ',') | Should Be ((Get-RigModules -Mode NoDlc) -join ',')
    }

    It 'prints a line containing "tower Modules unchanged"' {
        Write-BuildConfig @{ towerGamePath = 'C:\Games\Bannerlord' }
        (Start-BuildRig @{}) | Should Be 0
        ($script:lines -join "`n") | Should Match 'tower Modules unchanged'
    }

    It 'missing towerGamePath: exit 1, message names the key, no build, nothing published' {
        Write-BuildConfig @{}
        (Start-BuildRig @{}) | Should Be 1
        ($script:lines -join "`n") | Should Match 'towerGamePath'
        Assert-MockCalled Invoke-RigBuildPackage -Exactly 0 -Scope It
        $script:calls.Publish | Should Be 0
    }

    It 'a build failure: exit 1, message shown, nothing published' {
        Write-BuildConfig @{ towerGamePath = 'C:\Games\Bannerlord' }
        $script:buildFailure = 'MSBuild failed for SmithingSuite.csproj (exit 1)'
        (Start-BuildRig @{}) | Should Be 1
        ($script:lines -join "`n") | Should Match 'SmithingSuite\.csproj'
        $script:calls.Publish | Should Be 0
    }

    It 'a tower change: exit 1, message shown, nothing published, no "unchanged" line' {
        Write-BuildConfig @{ towerGamePath = 'C:\Games\Bannerlord' }
        $script:buildFailure = 'tower Modules changed during the build: Native\x.dll'
        (Start-BuildRig @{}) | Should Be 1
        ($script:lines -join "`n") | Should Match 'tower Modules changed'
        ($script:lines -join "`n") | Should Not Match 'tower Modules unchanged'
        $script:calls.Publish | Should Be 0
    }

    It 'an open job refuses before anything is built' {
        Write-BuildConfig @{ towerGamePath = 'C:\Games\Bannerlord' }
        Mock Get-JobState { @('20261031-120000-dead') } -ParameterFilter { $OpenJobs }
        (Start-BuildRig @{}) | Should Be 1
        Assert-MockCalled Invoke-RigBuildPackage -Exactly 0 -Scope It
        $script:calls.Publish | Should Be 0
    }

    It 'with -PackageFrom: no build, repos stays an empty array, no manifest.json, towerGamePath not required' {
        Write-BuildConfig @{}
        $pkg = Join-Path $script:t 'pkg'; New-PackageFixture $pkg
        (Start-BuildRig @{ PackageFrom = $pkg }) | Should Be 0
        Assert-MockCalled Invoke-RigBuildPackage -Exactly 0 -Scope It
        $script:calls.Publish | Should Be 1
        @($script:published.Job.repos).Count | Should Be 0
        (Get-Content -LiteralPath (Join-Path $script:published.Dir 'job.json') -Raw) | Should Match '"repos":\s*\[\s*\]'
        Test-Path -LiteralPath (Join-Path $script:published.Dir 'manifest.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $script:out 'stage') | Should Be $false
    }
}

Describe 'New-RigPackage fails closed on unreadable files' {
    BeforeEach { $script:t = New-TempDir }
    AfterEach { try { [IO.Directory]::Delete('\\?\' + $script:t, $true) } catch { } }

    It 'throws instead of silently leaving out files below a path longer than MAX_PATH' {
        $dir = Join-Path $script:t 'pkg\Modules\Deep'
        while ($dir.Length -lt 330) { $dir = Join-Path $dir ('d' * 40) }
        $null = [IO.Directory]::CreateDirectory('\\?\' + $dir)
        [IO.File]::WriteAllText('\\?\' + (Join-Path $dir 'deep.dll'), 'x')
        Set-Content -LiteralPath (Join-Path $script:t 'pkg\Modules\Deep\SubModule.xml') -Value '<Module/>'
        { New-RigPackage -PackageFrom (Join-Path $script:t 'pkg') -ZipPath (Join-Path $script:t 'x.zip') } | Should Throw
    }
}
