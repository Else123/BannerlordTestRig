$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\runner\Invoke-TestRig.ps1')

# -Suite L1: harness TestRig, the four mods plus the vanilla/framework load order, scenario row prefix.

$script:l1Modules = @(
    'Bannerlord.Harmony', 'Bannerlord.ButterLib', 'Bannerlord.UIExtenderEx', 'Bannerlord.MBOptionScreen',
    'Native', 'SandBoxCore', 'Sandbox', 'StoryMode', 'NavalDLC',
    'CoherentWarAI', 'AutoTraderSpeed', 'SmithingSuite', 'CompanionManagementSuite', 'TestRig.Harness',
    'CoherentWarAI.Scenarios', 'AutoTraderSpeed.Scenarios', 'SmithingSuite.Scenarios', 'CompanionManagementSuite.Scenarios')
$script:l1ScenarioModules = @('CoherentWarAI.Scenarios', 'AutoTraderSpeed.Scenarios', 'SmithingSuite.Scenarios', 'CompanionManagementSuite.Scenarios')
$script:l1Health = @('coherentwarai.health', 'autotrader.health', 'smithingsuite.health', 'companionsuite.health')
# The "scenarios" JSON array of an L1 run of $Days days: the health bracket (<id>@0 per id, soak, <id>@<Days> per id),
# every line with $Status unless $Override (line id -> status) says otherwise; ids in $Omit are left out.
function Get-L1ScenariosJson([int]$Days, [hashtable]$Override = @{}, [string[]]$Omit = @(), [string]$Status = 'Passed') {
    $ids = @($script:l1Health | ForEach-Object { "$_@0" }) + @('soak') + @($script:l1Health | ForEach-Object { "$_@$Days" })
    $items = foreach ($id in $ids) {
        if ($Omit -ccontains $id) { continue }
        $st = if ($Override.ContainsKey($id)) { $Override[$id] } else { $Status }
        '{"id":"' + $id + '","status":"' + $st + '","seconds":1}'
    }
    '[' + (@($items) -join ',') + ']'
}
# The measurement fields of an L1 run-result.json that pass the L1 verdict (#21) without a baseline (own 0, unhandled 0,
# modules = the L1 list, a player map event), as a JSON fragment that starts with a comma. Pass -ExpectedModules $script:l1Modules.
function Get-L1MeasuresJson {
    $modules = '[' + (@($script:l1Modules | ForEach-Object { '{"id":"' + $_ + '","version":"v1"}' }) -join ',') + ']'
    ',"runningDaysPerRealMinute":18.17,"playerMapEvents":3,"modules":' + $modules +
    ',"exceptions":{"total":0,"own":0,"harness":0,"vanilla":0,"unhandled":0,"classification":{"walks":0,"walkMs":0,"handlerMs":0,"maxHandlerMs":0,"ownExact":true},"top":[]}'
}
# -Suite L1-BASE (vanilla baseline): the L1 list without the four mods; the harness is the only non-vanilla module.
$script:l1BaseModules = @(
    'Bannerlord.Harmony', 'Bannerlord.ButterLib', 'Bannerlord.UIExtenderEx', 'Bannerlord.MBOptionScreen',
    'Native', 'SandBoxCore', 'Sandbox', 'StoryMode', 'NavalDLC', 'TestRig.Harness')
$script:suiteScript = Join-Path $here '..\..\runner\Invoke-TestRig.ps1'
# The run-result.json of RIG r4 (rig.selftest-exception-storm, #22 R2): by default it meets the r4 value checks (own 10000,
# walks 1000, ownExact false); walk mean 0.420 ms, cache hit at most (480 - 420) / (10012 - 1000) ms = 6.66 us.
# The value fields are JSON fragments (e.g. -Own '"10000"' for a string); -NoExceptions drops the exceptions block.
function Get-StormResultJson([string]$Own = '10000', [string]$Walks = '1000', [string]$OwnExact = 'false', [string]$WalkMs = '420.00',
    [string]$HandlerMs = '480.00', [string]$Total = '10012', [string]$Status = 'Passed', [switch]$NoExceptions) {
    $exceptions = if ($NoExceptions) { '' } else {
        ',"exceptions":{"total":' + $Total + ',"own":' + $Own + ',"harness":3,"vanilla":9,"unhandled":0,"classification":{"walks":' + $Walks +
        ',"walkMs":' + $WalkMs + ',"handlerMs":' + $HandlerMs + ',"maxHandlerMs":3.10,"ownExact":' + $OwnExact + '},"top":[]}'
    }
    '{"schema":1,"status":"Completed","scenarios":[{"id":"rig.selftest-exception-storm","status":"' + $Status + '","seconds":2}],"checks":[]' + $exceptions + '}'
}

function New-TempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('rigsuite-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    $d
}

function New-ModuleFixture([string]$Root, [string[]]$Ids) {
    foreach ($m in $Ids) {
        $bin = Join-Path $Root "Modules\$m\bin\Win64_Shipping_Client"
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $bin "$m.dll"), "dll $m")
        [IO.File]::WriteAllText((Join-Path $Root "Modules\$m\SubModule.xml"), '<Module/>')
    }
}

$l1Mods = @('CoherentWarAI', 'AutoTraderSpeed', 'SmithingSuite', 'CompanionManagementSuite', 'TestRig.Harness') + $script:l1ScenarioModules

Describe 'Get-RigModules -Suite L1' {
    It 'is the exact L1 load order (WarSails)' {
        (Get-RigModules -Mode WarSails -Harness TestRig -Suite L1) -join ',' | Should Be ($script:l1Modules -join ',')
    }
    It 'NoDlc drops NavalDLC and keeps the suite modules' {
        $m = @(Get-RigModules -Mode NoDlc -Harness TestRig -Suite L1)
        ($m -contains 'NavalDLC') | Should Be $false
        ($m[-8..-1] -join ',') | Should Be ((@('AutoTraderSpeed', 'SmithingSuite', 'CompanionManagementSuite', 'TestRig.Harness') + $script:l1ScenarioModules) -join ',')
    }
    It 'without -Suite the list is unchanged' {
        (Get-RigModules -Mode WarSails -Harness TestRig) -join ',' | Should Be (($script:l1Modules | Where-Object { $_ -notin (@('AutoTraderSpeed', 'SmithingSuite', 'CompanionManagementSuite') + $script:l1ScenarioModules) }) -join ',')
    }
    It 'rejects an unknown suite' {
        $err = $null
        try { Get-RigModules -Mode WarSails -Suite L2 } catch { $err = $_ }
        $err.FullyQualifiedErrorId | Should Match '^ParameterArgumentValidationError'
    }
}

Describe 'Resolve-RigSuiteSettings' {
    function Resolve-S([string]$Suite, [string[]]$Bound = @(), $Harness = 'TestRig', $Mode = 'WarSails', $Seed = 1, $Days = 1) {
        Resolve-RigSuiteSettings -Suite $Suite -BoundParameters $Bound -Harness $Harness -Mode $Mode -Seed $Seed -Days $Days
    }
    It 'without -Suite returns every value unchanged' {
        $r = Resolve-S -Suite '' -Bound @('Days') -Harness TestRig -Mode NoDlc -Seed 7 -Days 2
        $r.Harness | Should Be 'TestRig'
        $r.Mode | Should Be 'NoDlc'
        $r.Seed | Should Be 7
        $r.Days | Should Be 2
    }
    It 'L1 alone: TestRig, WarSails, seed 1, 30 days' {
        $r = Resolve-S -Suite L1
        $r.Harness | Should Be 'TestRig'
        $r.Mode | Should Be 'WarSails'
        $r.Seed | Should Be 1
        $r.Days | Should Be 30
    }
    It 'an explicit -Days wins' {
        (Resolve-S -Suite L1 -Bound @('Suite', 'Days') -Days 3).Days | Should Be 3
    }
    It 'an explicit -Seed and -Mode stay overridable' {
        $r = Resolve-S -Suite L1 -Bound @('Seed', 'Mode') -Seed 3 -Mode NoDlc
        $r.Seed | Should Be 3
        $r.Mode | Should Be 'NoDlc'
    }
    It 'an explicit -Harness TestRig is accepted (any casing)' {
        (Resolve-S -Suite L1 -Bound @('Harness') -Harness testrig).Harness | Should Be 'TestRig'
    }
}

Describe 'New-RigJobManifest with -Suite' {
    It 'carries the L1 module list and harness TestRig' {
        $j = New-RigJobManifest -JobId '20261031-153000-a1b2' -CreatedUtc ([datetime]'2026-10-31T15:30:00Z').ToUniversalTime() `
            -PackageSha256 'ABC' -Seed 1 -Days 3 -Mode WarSails -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -Harness TestRig -Suite L1
        $o = (ConvertTo-RigJson $j) | ConvertFrom-Json
        ($o.modules -join ',') | Should Be ($script:l1Modules -join ',')
        $o.runs[0].harness | Should Be 'TestRig'
        $o.runs[0].kind | Should Be 'soak'
    }
}

Describe 'Publish-RigResult with -Suite' {
    BeforeEach {
        $script:t = New-TempDir
        $script:id = '20261031-153000-a1b2'
        $script:rd = Join-Path $script:t $script:id
        New-Item -ItemType Directory -Path (Join-Path $script:rd 'r1') | Out-Null
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
        [IO.File]::WriteAllText((Join-Path $script:rd 'done.json'), '{"schema":1,"jobId":"20261031-153000-a1b2","status":"completed","runs":[{"runId":"r1","exitClass":"Completed"}]}')
        [IO.File]::WriteAllText((Join-Path $script:rd 'r1\run-result.json'), ('{"schema":1,"status":"Completed","daysReached":3,"scenarios":' + (Get-L1ScenariosJson 3) + (Get-L1MeasuresJson) + '}'))
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    function Get-JobResult { Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json }

    It 'prints the row as <Suite>-<scenario id> and records suite in job-result.json (raw ids kept)' {
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1 -ExpectedModules $script:l1Modules -SkipChecks) | Should Be 0
        @($script:lines | Where-Object { $_ -match '^r1 .*L1-soak ' })[0] | Should Match 'L1-soak\s+Passed\s+3/3\s+Completed'
        (Get-JobResult).suite | Should Be 'L1'
        (Get-JobResult).runs[0].result.scenarios[0].id | Should Be 'coherentwarai.health@0'
    }
    It 'prefixes the fallback row of a result without scenarios too (L1: no health line reported = rig error, exit 1)' {
        [IO.File]::WriteAllText((Join-Path $script:rd 'r1\run-result.json'), '{"schema":1,"status":"Completed","daysReached":3,"scenarios":[]}')
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1 -ExpectedModules $script:l1Modules -SkipChecks) | Should Be 1
        @($script:lines | Where-Object { $_ -match '^r1 ' })[0] | Should Match 'L1-soak\s+Completed'
    }
    It 'without -Suite the row is unchanged and suite is null' {
        [IO.File]::WriteAllText((Join-Path $script:rd 'r1\run-result.json'), '{"schema":1,"status":"Completed","daysReached":3,"scenarios":[{"id":"soak","status":"Passed","seconds":25}]}')
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -SkipChecks) | Should Be 0
        $row = @($script:lines | Where-Object { $_ -match '^r1 ' })[0]
        $row | Should Match 'r1\s+soak\s+Passed'
        $row | Should Not Match 'L1-'
        $r = Get-JobResult
        ($r.PSObject.Properties.Name -contains 'suite') | Should Be $true
        $r.suite | Should Be $null
    }
}

Describe 'Start-TestRigJob with -Suite' {
    BeforeEach {
        $script:t = New-TempDir
        $script:out = Join-Path $script:t 'out'
        $script:cfg = Join-Path $script:t 'runner.config.json'
        [IO.File]::WriteAllText($script:cfg, '{"host":"testpc","user":"rig","keyPath":"C:\\keys\\k","remoteQueueRoot":"C:\\TestRig\\queue"}')
        $script:published = $null
        $script:calls = @{ Publish = 0 }
        Mock Get-JobState { @() } -ParameterFilter { $OpenJobs }
        Mock Publish-Job {
            $script:calls.Publish++
            $script:published = @{ Job = (Get-Content -LiteralPath (Join-Path $JobDirectory 'job.json') -Raw | ConvertFrom-Json) }
        }
        Mock Write-Host { $script:lines += "$Object" }
        $script:lines = @()
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    function Start-SuiteRig([string]$Pkg) {
        Start-TestRigJob -PackageFrom $Pkg -Seed 1 -Days 3 -Mode WarSails -Harness TestRig -Suite L1 `
            -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -ClaimTimeoutSeconds 0.3 -TimeoutMinutes 0.5 `
            -ConfigPath $script:cfg -OutRoot $script:out -RetryDelaySeconds 0
    }

    It 'publishes the L1 module list when the package holds all suite modules' {
        $pkg = Join-Path $script:t 'pkg'; New-ModuleFixture $pkg $l1Mods
        (Start-SuiteRig $pkg) | Should Be 0
        ($script:published.Job.modules -join ',') | Should Be ($script:l1Modules -join ',')
        $script:published.Job.runs[0].harness | Should Be 'TestRig'
    }
    It 'a package without a suite module: exit 1 naming it, nothing published' {
        $pkg = Join-Path $script:t 'pkg'; New-ModuleFixture $pkg @('CoherentWarAI', 'TestRig.Harness', 'AutoTraderSpeed', 'SmithingSuite')
        (Start-SuiteRig $pkg) | Should Be 1
        ($script:lines -join "`n") | Should Match 'CompanionManagementSuite'
        $script:calls.Publish | Should Be 0
    }
}

Describe 'Invoke-TestRig.ps1 -Suite (powershell -File)' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:suiteScript, [ref]$null, [ref]$null)
    $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Suite' }

    It 'has a plain -Suite parameter (no ValidateSet: the suite table is the single source)' {
        $param | Should Not BeNullOrEmpty
        @($param.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }).Count | Should Be 0
    }
    It 'rejects an unknown suite as a usage error: exit 1, valid suites listed, before the config is read' {
        $out = (& powershell -NoProfile -File $script:suiteScript -PackageFrom C:\nowhere -Suite L2 2>&1 | Out-String)
        $LASTEXITCODE | Should Be 1
        $out | Should Match "unknown -Suite 'L2'"
        $out | Should Match 'Valid suites: AT, CS, CW1, L1, L1-BASE, RIG, SM, X\.'
        $out | Should Not Match 'Config not found'
    }
    It 'the retired -Harness CoherentWarAI is a usage error with a suite too, exit 1 before the config is read' {
        $out = (& powershell -NoProfile -File $script:suiteScript -PackageFrom C:\nowhere -Suite L1 -Harness CoherentWarAI 2>&1 | Out-String)
        $LASTEXITCODE | Should Be 1
        $out | Should Match 'Harness'
        $out | Should Match 'CoherentWarAI'
        $out | Should Not Match 'Config not found'
    }

    Context 'end to end with a stubbed transport' {
        BeforeEach {
            $script:d = New-TempDir
            $script:rdir = Join-Path $script:d 'runner'
            New-Item -ItemType Directory -Path $script:rdir | Out-Null
            foreach ($f in 'Invoke-TestRig.ps1', 'Build-Package.ps1') {
                Copy-Item -LiteralPath (Join-Path $here "..\..\runner\$f") -Destination $script:rdir
            }
            [IO.File]::WriteAllText((Join-Path $script:rdir 'runner.config.json'), '{"host":"testpc","user":"rig","keyPath":"C:\\keys\\k","remoteQueueRoot":"C:\\TestRig\\queue"}')
            $stub = 'function Get-JobState { @() }' + "`n" +
                'function Publish-Job { param($Target, $JobId, $JobDirectory) Copy-Item -LiteralPath (Join-Path $JobDirectory ''job.json'') -Destination $env:RIG_TEST_CAPTURE }' + "`n"
            [IO.File]::WriteAllText((Join-Path $script:rdir 'Transport.Ssh.ps1'), $stub)
            $script:pkgDir = Join-Path $script:d 'pkg'; New-ModuleFixture $script:pkgDir $l1Mods
            $env:RIG_TEST_CAPTURE = Join-Path $script:d 'captured-job.json'
        }
        AfterEach {
            Remove-Item Env:\RIG_TEST_CAPTURE -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $script:d -Recurse -Force -ErrorAction SilentlyContinue
        }
        function Invoke-Captured([string[]]$ExtraArgs) {
            $null = & powershell -NoProfile -File (Join-Path $script:rdir 'Invoke-TestRig.ps1') -PackageFrom $script:pkgDir @ExtraArgs 2>&1
            $script:exit = $LASTEXITCODE
            Get-Content -LiteralPath $env:RIG_TEST_CAPTURE -Raw | ConvertFrom-Json
        }

        It '-Suite L1 alone: TestRig, WarSails, seed 1, 30 days, L1 modules' {
            $j = Invoke-Captured @('-Suite', 'L1')
            $script:exit | Should Be 0
            $j.runs[0].harness | Should Be 'TestRig'
            $j.runs[0].mode | Should Be 'WarSails'
            $j.runs[0].seed | Should Be 1
            $j.runs[0].days | Should Be 30
            $j.runs[0].kind | Should Be 'soak'
            ($j.modules -join ',') | Should Be ($script:l1Modules -join ',')
        }
        It 'an explicit -Days, -Seed and -Mode win; -Harness TestRig is accepted' {
            $j = Invoke-Captured @('-Suite', 'L1', '-Days', '3', '-Seed', '2', '-Mode', 'NoDlc', '-Harness', 'TestRig')
            $script:exit | Should Be 0
            $j.runs[0].days | Should Be 3
            $j.runs[0].seed | Should Be 2
            $j.runs[0].mode | Should Be 'NoDlc'
        }
        It '-Suite SM alone: TestRig, WarSails, seed 1, 1 day, kind scenarios, SM modules' {
            New-ModuleFixture $script:pkgDir @('SmithingSuite.Scenarios')
            $j = Invoke-Captured @('-Suite', 'SM')
            $script:exit | Should Be 0
            $j.runs[0].harness | Should Be 'TestRig'
            $j.runs[0].mode | Should Be 'WarSails'
            $j.runs[0].seed | Should Be 1
            $j.runs[0].days | Should Be 1
            $j.runs[0].kind | Should Be 'scenarios'
            (@($j.runs[0].scenarios) -join ',') | Should Be 'smithing.smelt-then-refine,smithing.nothing-to-do,smithing.travel-stamina'
            ($j.modules[-3..-1] -join ',') | Should Be 'SmithingSuite,TestRig.Harness,SmithingSuite.Scenarios'
            ($j.modules -contains 'CoherentWarAI') | Should Be $false
        }
        It '-Suite L1-BASE alone: five 30-day soak runs with seeds 1, 1, 1, 2, 3 and 10 minute hard timeouts, no mod' {
            $j = Invoke-Captured @('-Suite', 'L1-BASE')
            $script:exit | Should Be 0
            (@($j.runs | ForEach-Object { $_.runId }) -join ',') | Should Be 'r1,r2,r3,r4,r5'
            (@($j.runs | ForEach-Object { $_.seed }) -join ',') | Should Be '1,1,1,2,3'
            foreach ($run in $j.runs) {
                $run.kind | Should Be 'soak'
                $run.days | Should Be 30
                $run.harness | Should Be 'TestRig'
                $run.mode | Should Be 'WarSails'
                $run.hardTimeoutMinutes | Should Be 10
                ($run.PSObject.Properties.Name -contains 'scenarios') | Should Be $false
            }
            ($j.modules -join ',') | Should Be ($script:l1BaseModules -join ',')
        }
        It '-Suite L1-BASE -Days 60 lengthens every run and doubles its hard timeout (20 minutes)' {
            $j = Invoke-Captured @('-Suite', 'L1-BASE', '-Days', '60')
            $script:exit | Should Be 0
            (@($j.runs | ForEach-Object { $_.days }) -join ',') | Should Be '60,60,60,60,60'
            (@($j.runs | ForEach-Object { $_.hardTimeoutMinutes }) -join ',') | Should Be '20,20,20,20,20'
        }
        It '-Suite L1-BASE -Days 3 shortens every run; -Seed is a usage error (the runs fix their seeds)' {
            $j = Invoke-Captured @('-Suite', 'L1-BASE', '-Days', '3')
            $script:exit | Should Be 0
            (@($j.runs | ForEach-Object { $_.days }) -join ',') | Should Be '3,3,3,3,3'
            $out = (& powershell -NoProfile -File (Join-Path $script:rdir 'Invoke-TestRig.ps1') -PackageFrom $script:pkgDir -Suite L1-BASE -Seed 2 2>&1 | Out-String)
            $LASTEXITCODE | Should Be 1
            $out | Should Match '-Seed conflicts'
        }
        It 'without -Suite the defaults stay (TestRig harness, 1 day)' {
            $j = Invoke-Captured @()
            $j.runs[0].harness | Should Be 'TestRig'
            $j.runs[0].days | Should Be 1
        }
    }
}

# -Suite SM: scenario suite. The suite defines its own mod list (no CoherentWarAI and no other mods);
# the scenario module loads AFTER the harness.

$script:smModules = @(
    'Bannerlord.Harmony', 'Bannerlord.ButterLib', 'Bannerlord.UIExtenderEx', 'Bannerlord.MBOptionScreen',
    'Native', 'SandBoxCore', 'Sandbox', 'StoryMode', 'NavalDLC',
    'SmithingSuite', 'TestRig.Harness', 'SmithingSuite.Scenarios')
$smMods = @('SmithingSuite', 'TestRig.Harness', 'SmithingSuite.Scenarios')
$script:smId = 'smithing.smelt-then-refine'

Describe 'Get-RigModules -Suite SM' {
    It 'is the exact SM load order (WarSails): base, mod, harness, scenario module' {
        (Get-RigModules -Mode WarSails -Harness TestRig -Suite SM) -join ',' | Should Be ($script:smModules -join ',')
    }
    It 'has no CoherentWarAI, AutoTraderSpeed or CompanionManagementSuite' {
        $m = @(Get-RigModules -Mode WarSails -Harness TestRig -Suite SM)
        foreach ($x in 'CoherentWarAI', 'AutoTraderSpeed', 'CompanionManagementSuite') { ($m -contains $x) | Should Be $false }
    }
    It 'NoDlc drops NavalDLC and keeps the suite tail' {
        $m = @(Get-RigModules -Mode NoDlc -Harness TestRig -Suite SM)
        ($m -contains 'NavalDLC') | Should Be $false
        ($m[-3..-1] -join ',') | Should Be 'SmithingSuite,TestRig.Harness,SmithingSuite.Scenarios'
    }
    It 'L1 stays byte-identical to the previous list' {
        (Get-RigModules -Mode WarSails -Harness TestRig -Suite L1) -join ',' | Should Be ($script:l1Modules -join ',')
    }
}

Describe 'Resolve-RigSuiteSettings -Suite SM' {
    It 'SM alone: TestRig, WarSails, seed 1, 1 day' {
        $r = Resolve-RigSuiteSettings -Suite SM -BoundParameters @('Suite') -Harness TestRig -Mode NoDlc -Seed 9 -Days 5
        $r.Harness | Should Be 'TestRig'
        $r.Mode | Should Be 'WarSails'
        $r.Seed | Should Be 1
        $r.Days | Should Be 1
    }
}

Describe 'New-RigJobManifest scenarios' {
    function New-Manifest([string]$Suite) {
        $p = @{
            JobId = '20261031-153000-a1b2'; CreatedUtc = ([datetime]'2026-10-31T15:30:00Z').ToUniversalTime()
            PackageSha256 = 'ABC'; Seed = 1; Days = 1; Mode = 'WarSails'; StallMinutes = 5; BudgetMinutes = 60; HardTimeoutMinutes = 20
            Harness = 'TestRig'
        }
        if ($Suite) { $p.Suite = $Suite }
        New-RigJobManifest @p
    }
    It '-Suite SM: kind scenarios, scenarios = the three SM ids in order (a JSON array), SM module list' {
        $json = ConvertTo-RigJson (New-Manifest 'SM')
        $o = $json | ConvertFrom-Json
        $o.runs[0].kind | Should Be 'scenarios'
        $json | Should Match '"scenarios":\s*\[\s*"smithing\.smelt-then-refine",\s*"smithing\.nothing-to-do",\s*"smithing\.travel-stamina"\s*\]'
        @($o.runs[0].scenarios).Count | Should Be 3
        @($o.runs[0].scenarios)[0] | Should Be $script:smId
        ($o.modules -join ',') | Should Be ($script:smModules -join ',')
    }
    It '-Suite L1: kind soak and no scenarios field (schema of soak runs unchanged)' {
        $o = (ConvertTo-RigJson (New-Manifest 'L1')) | ConvertFrom-Json
        $o.runs[0].kind | Should Be 'soak'
        ($o.runs[0].PSObject.Properties.Name -contains 'scenarios') | Should Be $false
    }
    It 'without -Suite: kind soak and no scenarios field' {
        $o = (ConvertTo-RigJson (New-Manifest '')) | ConvertFrom-Json
        $o.runs[0].kind | Should Be 'soak'
        ($o.runs[0].PSObject.Properties.Name -contains 'scenarios') | Should Be $false
    }
}

Describe 'Publish-RigResult: failed checks of a scenario run' {
    BeforeEach {
        $script:t = New-TempDir
        $script:id = '20261101-153000-a1b2'
        $script:rd = Join-Path $script:t $script:id
        New-Item -ItemType Directory -Path (Join-Path $script:rd 'r1') | Out-Null
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
        [IO.File]::WriteAllText((Join-Path $script:rd 'done.json'), '{"schema":1,"jobId":"20261101-153000-a1b2","status":"completed","runs":[{"runId":"r1","exitClass":"Completed"}]}')
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    function Write-RunResult([string]$Json) { [IO.File]::WriteAllText((Join-Path $script:rd 'r1\run-result.json'), $Json) }
    function Get-JobResult { Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json }
    $failed = '{"schema":1,"status":"Completed","scenarios":[{"id":"smithing.smelt-then-refine","status":"Failed","seconds":12},{"id":"other.one","status":"Passed","seconds":3},{"id":"smithing.nothing-to-do","status":"Passed","seconds":2},{"id":"smithing.travel-stamina","status":"Passed","seconds":4}],' +
        '"checks":[{"name":"smelted > 0","expected":">0","actual":"0","passed":false,"scenario":"smithing.smelt-then-refine"},' +
        '{"name":"setup ok","expected":"true","actual":"true","passed":true,"scenario":"smithing.smelt-then-refine"},' +
        '{"name":"other check","expected":"7","actual":"9","passed":false,"scenario":"other.one"}]}'

    It 'prints an indented line with name, expected and actual directly below the failed scenario row; exit 2' {
        Write-RunResult $failed
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -Suite SM) | Should Be 2
        $all = @($script:lines)
        $rowIdx = -1
        for ($i = 0; $i -lt $all.Count; $i++) { if ($all[$i] -match '^r1 .*SM-smithing\.smelt-then-refine\s+Failed') { $rowIdx = $i; break } }
        $rowIdx | Should BeGreaterThan -1
        $all[$rowIdx + 1] | Should Match '^\s+\S'
        $all[$rowIdx + 1] | Should Match 'smelted > 0'
        $all[$rowIdx + 1] | Should Match 'expected\W+>0'
        $all[$rowIdx + 1] | Should Match 'actual\W+0'
    }
    It 'does not print passed checks' {
        Write-RunResult $failed
        Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -Suite SM | Out-Null
        @($script:lines | Where-Object { $_ -match 'setup ok' }).Count | Should Be 0
    }
    It 'prints a failed check only below the row of its own scenario' {
        Write-RunResult $failed
        Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -Suite SM | Out-Null
        $all = @($script:lines)
        $failRow = -1; $otherRow = -1; $otherCheck = -1
        for ($i = 0; $i -lt $all.Count; $i++) {
            if ($all[$i] -match '^r1 .*SM-smithing\.smelt-then-refine') { $failRow = $i }
            if ($all[$i] -match '^r1 .*SM-other\.one') { $otherRow = $i }
            if ($all[$i] -match 'other check') { $otherCheck = $i }
        }
        $failRow | Should BeGreaterThan -1
        $otherRow | Should BeGreaterThan $failRow
        $otherCheck | Should BeGreaterThan $otherRow
    }
    It 'keeps the checks in job-result.json per run' {
        Write-RunResult $failed
        Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -Suite SM | Out-Null
        $c = @((Get-JobResult).runs[0].result.checks)
        $c.Count | Should Be 3
        $c[0].name | Should Be 'smelted > 0'
        $c[0].scenario | Should Be $script:smId
        $c[0].passed | Should Be $false
    }
    It 'a Passed scenario run prints one row and no check lines, exit 0' {
        Write-RunResult '{"schema":1,"status":"Completed","scenarios":[{"id":"smithing.smelt-then-refine","status":"Passed","seconds":5},{"id":"smithing.nothing-to-do","status":"Passed","seconds":2},{"id":"smithing.travel-stamina","status":"Passed","seconds":4}],"checks":[{"name":"smelted > 0","expected":">0","actual":"4","passed":true,"scenario":"smithing.smelt-then-refine"}]}'
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -Suite SM) | Should Be 0
        @($script:lines | Where-Object { $_ -match 'SM-smithing\.smelt-then-refine\s+Passed' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match 'smelted > 0' }).Count | Should Be 0
    }
    It 'a Skipped requested scenario in a Completed scenario run is a rig error (exit 1)' {
        Write-RunResult '{"schema":1,"status":"Completed","scenarios":[{"id":"smithing.smelt-then-refine","status":"Skipped","seconds":0}],"checks":[]}'
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -Suite SM) | Should Be 1
    }
    It 'a Completed scenario run with an empty scenarios list is a rig error (exit 1)' {
        Write-RunResult '{"schema":1,"status":"Completed","scenarios":[],"checks":[]}'
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -Suite SM) | Should Be 1
    }
    It 'a Completed scenario run without any scenarios property is a rig error (exit 1)' {
        Write-RunResult '{"schema":1,"status":"Completed"}'
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -Suite SM) | Should Be 1
    }
    It 'a Completed scenario run that reports a different scenario id than requested is a rig error (exit 1)' {
        Write-RunResult '{"schema":1,"status":"Completed","scenarios":[{"id":"other.one","status":"Passed","seconds":1}],"checks":[]}'
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -Suite SM) | Should Be 1
    }
    It 'shows - instead of reached/days for a scenario run row' {
        Write-RunResult '{"schema":1,"status":"Completed","scenarios":[{"id":"smithing.smelt-then-refine","status":"Passed","seconds":5}],"checks":[]}'
        Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -Suite SM | Out-Null
        $row = @($script:lines | Where-Object { $_ -match 'SM-smithing\.smelt-then-refine' })[0]
        $row | Should Not Match '\d/\d'
        $row | Should Match 'Passed\s+-\s'
    }
    It 'sanitizes control characters and caps the length of the failed-check line fields' {
        $long = 'x' * 500
        $json = '{"schema":1,"status":"Completed","scenarios":[{"id":"smithing.smelt-then-refine","status":"Failed","seconds":1}],' +
            '"checks":[{"name":"a\nb\r\u001b[31mc","expected":"' + $long + '","actual":"t\tu","passed":false,"scenario":"smithing.smelt-then-refine"}]}'
        Write-RunResult $json
        Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -Suite SM | Out-Null
        $line = @($script:lines | Where-Object { $_ -match '^\s+a' })[0]
        $line | Should Not BeNullOrEmpty
        $line | Should Not Match '[\x00-\x1F\x7F]'
        $line | Should Match 'a b  \[31mc: expected x{200}, actual t u$'
        $line | Should Not Match 'x{201}'
    }
    It 'a soak result (no checks) prints no check lines' {
        Write-RunResult ('{"schema":1,"status":"Completed","daysReached":3,"scenarios":' + (Get-L1ScenariosJson 3) + (Get-L1MeasuresJson) + '}')
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1 -ExpectedModules $script:l1Modules -SkipChecks) | Should Be 0
        @($script:lines | Where-Object { $_ -match '^\s+\S' -and $_ -match 'expected' }).Count | Should Be 0
    }
}

Describe 'Start-TestRigJob -Suite SM' {
    BeforeEach {
        $script:t = New-TempDir
        $script:out = Join-Path $script:t 'out'
        $script:cfg = Join-Path $script:t 'runner.config.json'
        [IO.File]::WriteAllText($script:cfg, '{"host":"testpc","user":"rig","keyPath":"C:\\keys\\k","remoteQueueRoot":"C:\\TestRig\\queue"}')
        $script:published = $null
        $script:calls = @{ Publish = 0 }
        Mock Get-JobState { @() } -ParameterFilter { $OpenJobs }
        Mock Publish-Job {
            $script:calls.Publish++
            $script:published = @{ Job = (Get-Content -LiteralPath (Join-Path $JobDirectory 'job.json') -Raw | ConvertFrom-Json) }
        }
        Mock Write-Host { $script:lines += "$Object" }
        $script:lines = @()
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    function Start-SmRig([string]$Pkg) {
        Start-TestRigJob -PackageFrom $Pkg -Seed 1 -Days 1 -Mode WarSails -Harness TestRig -Suite SM `
            -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -ClaimTimeoutSeconds 0.3 -TimeoutMinutes 0.5 `
            -ConfigPath $script:cfg -OutRoot $script:out -RetryDelaySeconds 0
    }
    It 'publishes the SM job (scenarios, module list) when the package holds the three suite modules only' {
        $pkg = Join-Path $script:t 'pkg'; New-ModuleFixture $pkg $smMods
        (Start-SmRig $pkg) | Should Be 0
        ($script:published.Job.modules -join ',') | Should Be ($script:smModules -join ',')
        $script:published.Job.runs[0].kind | Should Be 'scenarios'
        @($script:published.Job.runs[0].scenarios)[0] | Should Be $script:smId
    }
    It 'a package without SmithingSuite.Scenarios: exit 1 naming it, nothing published' {
        $pkg = Join-Path $script:t 'pkg'; New-ModuleFixture $pkg @('SmithingSuite', 'TestRig.Harness')
        (Start-SmRig $pkg) | Should Be 1
        ($script:lines -join "`n") | Should Match 'SmithingSuite\.Scenarios'
        $script:calls.Publish | Should Be 0
    }
}

# -Suite RIG: self-test suite. One job, three runs; each run is judged against its expected exitClass.

$script:rigModules = @(
    'Bannerlord.Harmony', 'Bannerlord.ButterLib', 'Bannerlord.UIExtenderEx', 'Bannerlord.MBOptionScreen',
    'Native', 'SandBoxCore', 'Sandbox', 'StoryMode', 'NavalDLC',
    'TestRig.Harness', 'TestRig.SelfTest')

Describe 'Get-RigModules -Suite RIG' {
    It 'is the exact RIG load order (WarSails): base, harness, self-test module; nothing else' {
        (Get-RigModules -Mode WarSails -Harness TestRig -Suite RIG) -join ',' | Should Be ($script:rigModules -join ',')
    }
    It 'NoDlc drops NavalDLC' {
        $m = @(Get-RigModules -Mode NoDlc -Harness TestRig -Suite RIG)
        ($m -contains 'NavalDLC') | Should Be $false
        ($m[-2..-1] -join ',') | Should Be 'TestRig.Harness,TestRig.SelfTest'
    }
}

Describe 'Resolve-RigSuiteSettings -Suite RIG' {
    It 'RIG alone: TestRig, WarSails, seed 1, 1 day' {
        $r = Resolve-RigSuiteSettings -Suite RIG -BoundParameters @('Suite') -Harness TestRig -Mode NoDlc -Seed 9 -Days 5
        $r.Harness | Should Be 'TestRig'
        $r.Mode | Should Be 'WarSails'
        $r.Seed | Should Be 1
        $r.Days | Should Be 1
    }
}

Describe 'Resolve-RigSuiteSettings -Suite RIG with -HardTimeoutMinutes' {
    It 'an explicit -HardTimeoutMinutes conflicts with the fixed per-run timeouts' {
        { Resolve-RigSuiteSettings -Suite RIG -BoundParameters @('Suite', 'HardTimeoutMinutes') -Harness TestRig -Mode WarSails -Seed 1 -Days 1 } | Should Throw 'HardTimeoutMinutes'
    }
    It 'other suites and the default value are unaffected' {
        { Resolve-RigSuiteSettings -Suite RIG -BoundParameters @('Suite') -Harness TestRig -Mode WarSails -Seed 1 -Days 1 } | Should Not Throw
        { Resolve-RigSuiteSettings -Suite L1 -BoundParameters @('Suite', 'HardTimeoutMinutes') -Harness TestRig -Mode WarSails -Seed 1 -Days 1 } | Should Not Throw
    }
}

Describe 'Invoke-TestRig.ps1 -Suite RIG -HardTimeoutMinutes (powershell -File)' {
    It 'is a usage error, exit 1 before the config is read' {
        $out = (& powershell -NoProfile -File $script:suiteScript -PackageFrom C:\nowhere -Suite RIG -HardTimeoutMinutes 9 2>&1 | Out-String)
        $LASTEXITCODE | Should Be 1
        $out | Should Match 'HardTimeoutMinutes'
        $out | Should Not Match 'Config not found'
    }
}

Describe 'Get-RigSuiteRuns and Get-RigSuiteTimeoutMinutes' {
    It 'RIG has the five runs with scenario, 5 minute hard timeout and expected exitClass' {
        $r = @(Get-RigSuiteRuns -Suite RIG)
        $r.Count | Should Be 5
        (($r | ForEach-Object { $_.RunId }) -join ',') | Should Be 'r1,r2,r3,r4,r5'
        (($r | ForEach-Object { @($_.Scenarios) -join '+' }) -join ',') | Should Be 'rig.selftest-throw,rig.selftest-hang,rig.selftest-pass,rig.selftest-exception-storm,rig.town-screen'
        (($r | ForEach-Object { $_.ExpectedExitClass }) -join ',') | Should Be 'Crashed,Hung,Completed,Completed,Completed'
        foreach ($x in $r) { $x.HardTimeoutMinutes | Should Be 5 }
    }
    It 'r1 and r2 carry a message pattern, r3 to r5 none' {
        $r = @(Get-RigSuiteRuns -Suite RIG)
        'Harness reported: 5.1 UnhandledException (terminating=True): System.InvalidOperationException: rig.selftest-throw' | Should MatchExactly $r[0].ExpectedMessagePattern
        'No Alive line in harness.log for 61 s (limit 60 s); last line: (none)' | Should MatchExactly $r[1].ExpectedMessagePattern
        $r[2].ExpectedMessagePattern | Should Be $null
        $r[3].ExpectedMessagePattern | Should Be $null
    }
    It 'only r4 lists own assemblies (TestRig.SelfTest), value checks and the classification timing report' {
        $r = @(Get-RigSuiteRuns -Suite RIG)
        foreach ($x in $r[0..2]) {
            @($x.OwnAssemblies).Count | Should Be 0
            @($x.ExpectedValues).Count | Should Be 0
            $x.ClassificationTiming | Should Be $false
        }
        (@($r[3].OwnAssemblies) -join ',') | Should BeExactly 'TestRig.SelfTest'
        (@($r[3].ExpectedValues | ForEach-Object { '{0}={1}' -f $_.Path, $_.Value }) -join ',') |
            Should BeExactly 'exceptions.own=10000,exceptions.classification.walks=1000,exceptions.classification.ownExact=False'
        $r[3].ExpectedValues[2].Value -is [bool] | Should Be $true
        $r[3].ClassificationTiming | Should Be $true
    }
    It 'L1, SM and no suite have no runs' {
        @(Get-RigSuiteRuns -Suite L1).Count | Should Be 0
        @(Get-RigSuiteRuns -Suite SM).Count | Should Be 0
        @(Get-RigSuiteRuns).Count | Should Be 0
    }
    It 'the overall deadline of RIG is sum(hard timeout + 2 min per run) + claim wait (rounded up) + 5 minutes' {
        # 5 x (5 + 2) + 2 (default 120 s) + 5
        Get-RigSuiteTimeoutMinutes -Suite RIG | Should Be 42
        Get-RigSuiteTimeoutMinutes -Suite RIG -ClaimTimeoutSeconds 90 | Should Be 42
        Get-RigSuiteTimeoutMinutes -Suite RIG -ClaimTimeoutSeconds 600 | Should Be 50
    }
    It 'the deadline of a suite with runs is never below sum of hard timeouts + 10 (the single-run default)' {
        Get-RigSuiteTimeoutMinutes -Suite RIG -ClaimTimeoutSeconds 0.001 | Should Be 41   # claim wait rounds up to 1 min
        (Get-RigSuiteTimeoutMinutes -Suite RIG -ClaimTimeoutSeconds 0.001) -ge (25 + 10) | Should Be $true
    }
    It 'RIG runs (kind scenarios) keep their hard timeout whatever -Days says' {
        foreach ($x in @(Get-RigSuiteRuns -Suite RIG -Days 90)) { $x.HardTimeoutMinutes | Should Be 5 }
        Get-RigSuiteTimeoutMinutes -Suite RIG -Days 90 | Should Be 42
    }
    It 'suites without runs have no suite deadline' {
        Get-RigSuiteTimeoutMinutes -Suite SM | Should Be $null
        Get-RigSuiteTimeoutMinutes -Suite L1 | Should Be $null
    }
}

Describe 'New-RigJobManifest -Suite RIG' {
    BeforeEach {
        $script:json = ConvertTo-RigJson (New-RigJobManifest -JobId '20261102-153000-a1b2' -CreatedUtc ([datetime]'2026-11-02T15:30:00Z').ToUniversalTime() `
                -PackageSha256 'ABC' -Seed 1 -Days 1 -Mode WarSails -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -Harness TestRig -Suite RIG)
        $script:o = $script:json | ConvertFrom-Json
    }
    It 'carries one job with five runs r1 to r5' {
        @($script:o.runs).Count | Should Be 5
        ((@($script:o.runs) | ForEach-Object { $_.runId }) -join ',') | Should Be 'r1,r2,r3,r4,r5'
    }
    It 'only r4 carries ownAssemblies, as a JSON array with the one id TestRig.SelfTest' {
        foreach ($run in @($script:o.runs)[0..2]) { ($run.PSObject.Properties.Name -contains 'ownAssemblies') | Should Be $false }
        $script:json | Should Match '"ownAssemblies":\s*\[\s*"TestRig\.SelfTest"\s*\]'
        @(@($script:o.runs)[3].ownAssemblies).Count | Should Be 1
    }
    It 'no other suite and no suite-less job carries ownAssemblies' {
        foreach ($s in $null, 'L1', 'L1-BASE', 'SM') {
            $p = @{ JobId = '20261102-153000-a1b2'; CreatedUtc = [datetime]'2026-11-02T15:30:00Z'; PackageSha256 = 'ABC'; Seed = 1; Days = 1
                Mode = 'WarSails'; StallMinutes = 5; BudgetMinutes = 60; HardTimeoutMinutes = 20; Harness = 'TestRig' }
            if ($s) { $p.Suite = $s }
            (ConvertTo-RigJson (New-RigJobManifest @p)) | Should Not Match 'ownAssemblies'
        }
    }
    It 'each run has kind scenarios, its scenario, hardTimeoutMinutes 5 and the shared settings' {
        $ids = 'rig.selftest-throw', 'rig.selftest-hang', 'rig.selftest-pass', 'rig.selftest-exception-storm'
        for ($i = 0; $i -lt 4; $i++) {
            $run = @($script:o.runs)[$i]
            $run.kind | Should Be 'scenarios'
            @($run.scenarios).Count | Should Be 1
            @($run.scenarios)[0] | Should Be $ids[$i]
            $run.hardTimeoutMinutes | Should Be 5
            $run.harness | Should Be 'TestRig'
            $run.seed | Should Be 1
            $run.days | Should Be 1
            $run.mode | Should Be 'WarSails'
            $run.stallMinutes | Should Be 5
            $run.budgetMinutes | Should Be 60
        }
    }
    It 'has the RIG module list' {
        ($script:o.modules -join ',') | Should Be ($script:rigModules -join ',')
    }
    It 'L1 and SM keep exactly one run r1 with the passed -HardTimeoutMinutes' {
        foreach ($s in 'L1', 'SM') {
            $j = (ConvertTo-RigJson (New-RigJobManifest -JobId '20261102-153000-a1b2' -CreatedUtc ([datetime]'2026-11-02T15:30:00Z').ToUniversalTime() `
                        -PackageSha256 'ABC' -Seed 1 -Days 1 -Mode WarSails -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -Harness TestRig -Suite $s)) | ConvertFrom-Json
            @($j.runs).Count | Should Be 1
            @($j.runs)[0].runId | Should Be 'r1'
            @($j.runs)[0].hardTimeoutMinutes | Should Be 20
        }
    }
}

Describe 'Resolve-RigExitCode with expectations (RIG)' {
    # The agent messages of a real r1 (watchdog crash; or the harness's own line) and r2.
    $script:crashMsg = 'Crash occurred (watchdog_log_5672.txt); last line: 12.3 FirstChance #1 [thread 1]: System.InvalidOperationException: rig.selftest-throw at TestRig.SelfTest.SelfTestSubModule.OnApplicationTick(Single dt) || caller stack: at TaleWorlds...'
    $script:harnessMsg = 'Harness reported: 12.4 UnhandledException (terminating=True): System.InvalidOperationException: rig.selftest-throw'
    $script:hungMsg = 'No Alive line in harness.log for 61 s (limit 60 s); last line: 30.0 scenario rig.selftest-hang started'
    function Rr($id, $cls, $ids = @(), $statuses = @(), $message = $null, $result = $null) {
        if ($null -eq $message) { $message = switch ($cls) { 'Crashed' { $script:crashMsg } 'Hung' { $script:hungMsg } default { $null } } }
        [pscustomobject]@{ runId = $id; kind = 'scenarios'; exitClass = $cls; daysReached = $null; scenarioIds = @($ids); scenarioStatuses = @($statuses); message = $message; result = $result }
    }
    # r4 as Publish-RigResult collects it from a run-result.json (Get-StormResultJson; arguments are passed on).
    function Storm {
        $json = Get-StormResultJson @args
        $result = $json | ConvertFrom-Json
        Rr r4 Completed @($result.scenarios | ForEach-Object { $_.id }) @($result.scenarios | ForEach-Object { $_.status }) $null $result
    }
    # The r1-r3 cases list only those runs: a good r4 and a good r5 (town screen) are added unless the case lists them itself.
    function Verdict($runs, $status = 'completed') {
        $all = @($runs)
        if (@($all | Where-Object { $_.runId -ceq 'r4' }).Count -eq 0) { $all += Storm }
        if (@($all | Where-Object { $_.runId -ceq 'r5' }).Count -eq 0) { $all += Rr r5 Completed 'rig.town-screen' 'Passed' }
        Resolve-RigExitCode -DoneStatus $status -Runs $all -Days 1 -Expectations @(Get-RigSuiteRuns -Suite RIG)
    }
    $good = { @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed'), (Storm), (Rr r5 Completed 'rig.town-screen' 'Passed')) }

    It 'every run meets its expectation -> 0 (a crashed run has no scenario results)' {
        Verdict (& $good) | Should Be 0
    }
    It 'a Crashed run without scenario results does not trip the all-scenarios-reported rule' {
        Verdict @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 0
    }
    It 'r1 ends Completed instead of Crashed -> 2' {
        Verdict @((Rr r1 Completed 'rig.selftest-throw' 'Passed'), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 2
    }
    It 'r2 ends HardTimeout instead of Hung -> 2 (hang detection failed, not a time-limit code)' {
        Verdict @((Rr r1 Crashed), (Rr r2 HardTimeout), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 2
    }
    It 'r3 Crashed instead of Completed -> 2' {
        Verdict @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 Crashed)) | Should Be 2
    }
    It 'a Completed-expected run with a Failed scenario -> 2' {
        Verdict @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Failed')) | Should Be 2
    }
    It 'a Completed-expected run with a Skipped or missing scenario -> 2' {
        Verdict @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Skipped')) | Should Be 2
        Verdict @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 Completed)) | Should Be 2
    }
    It 'a missing run -> 1' {
        Verdict @((Rr r1 Crashed), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 1
        Verdict @() | Should Be 1
    }
    It 'a done status other than completed -> 1 (aborted keeps 3)' {
        foreach ($s in 'blocked', 'rejected', 'failed', 'weird') { Verdict (& $good) $s | Should Be 1 }
        Verdict (& $good) 'aborted' | Should Be 3
    }
    It 'an infrastructure class (SetupError, LaunchFailed, CleanupFailed) in any run -> 1' {
        foreach ($c in 'SetupError', 'LaunchFailed', 'CleanupFailed') {
            Verdict @((Rr r1 $c), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 1
        }
    }
    It 'precedence: missing run (1) beats a mismatch (2)' {
        Verdict @((Rr r1 Completed 'rig.selftest-throw' 'Passed'), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 1
    }
    It 'r1 Crashed by the harness-reported UnhandledException of the self-test throw -> 0' {
        Verdict @((Rr r1 Crashed @() @() $script:harnessMsg), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 0
    }
    It 'r1 Crashed for another reason (watchdog crash whose last line is not the self-test throw) -> 2' {
        $other = 'Crash occurred (watchdog_log_5672.txt); last line: 3.0 FirstChance #1 [thread 7 bg]: System.NullReferenceException: x'
        Verdict @((Rr r1 Crashed @() @() $other), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 2
    }
    It 'r1 Crashed by a watchdog crash whose last line is a repeat of the self-test throw -> 0' {
        $repeat = 'Crash occurred (watchdog_log_5672.txt); last line: 12.4 FirstChance #2 (repeat) [thread 1]: System.InvalidOperationException: rig.selftest-throw @ TestRig.SelfTest.SelfTestSubModule.OnApplicationTick'
        Verdict @((Rr r1 Crashed @() @() $repeat), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 0
    }
    It 'r1 Crashed with a harness line that merely names the self-test scenario as the last line -> 2 (crash before the throw)' {
        $beforeThrow = "Crash occurred (watchdog_log_5672.txt); last line: 8.0 scenario rig.selftest-throw: check 'armed' passed"
        Verdict @((Rr r1 Crashed @() @() $beforeThrow), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 2
        $started = 'Crash occurred (watchdog_log_5672.txt); last line: 7.0 scenario rig.selftest-throw: started'
        Verdict @((Rr r1 Crashed @() @() $started), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 2
        # ScenarioRunner logs a failing dispose with the short type name; only the full name is the throw itself.
        $dispose = 'Crash occurred (watchdog_log_5672.txt); last line: 9.0 scenario rig.selftest-throw: dispose threw InvalidOperationException: rig.selftest-throw'
        Verdict @((Rr r1 Crashed @() @() $dispose), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 2
    }
    It 'r1 Crashed with the self-test id only in an unrelated message form -> 2' {
        Verdict @((Rr r1 Crashed @() @() 'something about rig.selftest-throw'), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 2
    }
    It 'r2 Hung without a message, or with another one -> 2' {
        Verdict @((Rr r1 Crashed), (Rr r2 Hung @() @() ''), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 2
        Verdict @((Rr r1 Crashed), (Rr r2 Hung @() @() 'hung for some reason'), (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 2
        $noMessage = [pscustomobject]@{ runId = 'r2'; kind = 'scenarios'; exitClass = 'Hung'; daysReached = $null; scenarioIds = @(); scenarioStatuses = @() }
        Verdict @((Rr r1 Crashed), $noMessage, (Rr r3 Completed 'rig.selftest-pass' 'Passed')) | Should Be 2
    }
    It '-ForceTimeout raises a clean result to 3' {
        Resolve-RigExitCode -DoneStatus completed -Runs (& $good) -Days 1 -Expectations @(Get-RigSuiteRuns -Suite RIG) -ForceTimeout | Should Be 3
    }
    It 'r3 (a scenarios run) Hung or HardTimeout instead of Completed -> 2 (only soak runs are inconclusive)' {
        Verdict @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 Hung)) | Should Be 2
        Verdict @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 HardTimeout)) | Should Be 2
    }
    It 'r4 storm: own 10000, walks 1000 and ownExact false -> 0; any other value -> 2' {
        Verdict (& $good) | Should Be 0
        Verdict @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed'), (Storm -Own 9999)) | Should Be 2
        Verdict @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed'), (Storm -Walks 999)) | Should Be 2
        Verdict @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed'), (Storm -OwnExact true)) | Should Be 2
    }
    It 'r4 storm: a missing or non-typed value is a rig error (1), also next to a mismatch' {
        $e = @(Get-RigSuiteRuns -Suite RIG)[3]
        Get-RigExpectationOutcome -Expectation $e -Run (Storm) -Days 1 | Should Be 'Met'
        Get-RigExpectationOutcome -Expectation $e -Run (Storm -NoExceptions) -Days 1 | Should Be 'RigError'
        Get-RigExpectationOutcome -Expectation $e -Run (Storm -Own '"10000"') -Days 1 | Should Be 'RigError'
        Get-RigExpectationOutcome -Expectation $e -Run (Storm -OwnExact '0') -Days 1 | Should Be 'RigError'
        Get-RigExpectationOutcome -Expectation $e -Run (Storm -Walks 'null') -Days 1 | Should Be 'RigError'
        Get-RigExpectationOutcome -Expectation $e -Run (Storm -Own 1 -OwnExact 'null') -Days 1 | Should Be 'RigError'
        Get-RigExpectationOutcome -Expectation $e -Run (Storm -Status Failed -NoExceptions) -Days 1 | Should Be 'RigError'
        Get-RigExpectationOutcome -Expectation $e -Run (Rr r4 Completed 'rig.selftest-exception-storm' 'Passed' $null ([ordered]@{})) -Days 1 | Should Be 'RigError'
        Verdict @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed'), (Storm -NoExceptions)) | Should Be 1
    }
    It 'r4 storm: a Failed storm scenario with the right values -> 2; r4 Crashed or Hung -> 2' {
        Verdict @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed'), (Storm -Status Failed)) | Should Be 2
        Verdict @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed'), (Rr r4 Crashed @() @() 'x')) | Should Be 2
        Verdict @((Rr r1 Crashed), (Rr r2 Hung), (Rr r3 Completed 'rig.selftest-pass' 'Passed'), (Rr r4 Hung)) | Should Be 2
    }
    It 'Get-RigExpectationOutcome requires -Days (no silent default of 1 day)' {
        $days = (Get-Command Get-RigExpectationOutcome).Parameters['Days']
        @($days.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should Be 1
    }
}

Describe 'Publish-RigResult -Suite RIG' {
    BeforeEach {
        $script:t = New-TempDir
        $script:id = '20261102-153000-a1b2'
        $script:rd = Join-Path $script:t $script:id
        New-Item -ItemType Directory -Path $script:rd | Out-Null
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    function Write-Done([string]$Status, [string[]]$Classes) {
        $runs = for ($i = 0; $i -lt $Classes.Count; $i++) { '{"runId":"r' + ($i + 1) + '","exitClass":"' + $Classes[$i] + '"}' }
        [IO.File]::WriteAllText((Join-Path $script:rd 'done.json'), ('{"schema":1,"jobId":"' + $script:id + '","status":"' + $Status + '","runs":[' + ($runs -join ',') + ']}'))
    }
    function Write-Run([string]$RunId, [string]$Json) {
        $d = Join-Path $script:rd $RunId
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'run-result.json'), $Json)
    }
    function Write-AgentRun([string]$RunId, $Message) {
        $d = Join-Path $script:rd $RunId
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $json = [ordered]@{ schema = 1; runId = $RunId; startedUtc = '2026-11-02T15:30:00Z'; endedUtc = '2026-11-02T15:31:00Z'; message = $Message } | ConvertTo-Json
        [IO.File]::WriteAllText((Join-Path $d 'agent-run.json'), $json)
    }
    # The agent messages a real r1 and r2 end with (see Get-RigSuiteRuns).
    function Write-GoodMessages {
        Write-AgentRun r1 'Crash occurred (watchdog_log_5672.txt); last line: 12.3 FirstChance #1 [thread 1]: System.InvalidOperationException: rig.selftest-throw'
        Write-AgentRun r2 'No Alive line in harness.log for 61 s (limit 60 s); last line: (none)'
    }
    $pass = '{"schema":1,"status":"Completed","scenarios":[{"id":"rig.selftest-pass","status":"Passed","seconds":4}],"checks":[]}'
    $town = '{"schema":1,"status":"Completed","scenarios":[{"id":"rig.town-screen","status":"Passed","seconds":9}],"checks":[]}'
    function Write-PassRuns { Write-Run r3 $pass; Write-Run r4 (Get-StormResultJson); Write-Run r5 $town }
    function Rig { Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -Suite RIG }

    It 'all runs meet their expectation: exit 0 and a row per run with expected and actual' {
        Write-Done completed @('Crashed', 'Hung', 'Completed', 'Completed', 'Completed'); Write-PassRuns; Write-GoodMessages
        (Rig) | Should Be 0
        @($script:lines | Where-Object { $_ -match '^r1 .*rig\.selftest-throw.*expected Crashed\s+actual Crashed\s+met' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match '^r2 .*rig\.selftest-hang.*expected Hung\s+actual Hung\s+met' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match '^r3 .*rig\.selftest-pass.*expected Completed\s+actual Completed\s+met' }).Count | Should Be 1
    }
    It 'one mismatch: exit 2 and the row says MISMATCH with expected and actual' {
        Write-Done completed @('Crashed', 'HardTimeout', 'Completed', 'Completed', 'Completed'); Write-PassRuns; Write-GoodMessages
        (Rig) | Should Be 2
        @($script:lines | Where-Object { $_ -match '^r2 .*expected Hung\s+actual HardTimeout\s+MISMATCH' }).Count | Should Be 1
    }
    It 'a Failed scenario in the Completed-expected run: exit 2' {
        Write-Done completed @('Crashed', 'Hung', 'Completed', 'Completed', 'Completed'); Write-Run r4 (Get-StormResultJson)
        Write-Run r3 '{"schema":1,"status":"Completed","scenarios":[{"id":"rig.selftest-pass","status":"Failed","seconds":4}],"checks":[{"name":"campaign","expected":"true","actual":"false","passed":false,"scenario":"rig.selftest-pass"}]}'
        (Rig) | Should Be 2
        @($script:lines | Where-Object { $_ -match 'campaign: expected true, actual false' }).Count | Should Be 1
    }
    It 'a missing run: exit 1 and the row says missing' {
        Write-Done completed @('Crashed', 'Hung');
        (Rig) | Should Be 1
        @($script:lines | Where-Object { $_ -match '^r3 .*expected Completed\s+actual -\s+missing' }).Count | Should Be 1
    }
    It 'job status failed: exit 1' {
        Write-Done failed @('Crashed', 'Hung', 'Completed'); Write-Run r3 $pass
        (Rig) | Should Be 1
    }
    It 'prints no placeholder soak row for a crashed run and sanitizes the reported exitClass' {
        Write-Done completed @('Crashed', 'Hu\u001bng', 'Completed'); Write-Run r3 $pass
        Rig | Out-Null
        @($script:lines | Where-Object { $_ -match 'soak' }).Count | Should Be 0
        @($script:lines | Where-Object { $_ -match '[\x00-\x1F\x7F]' }).Count | Should Be 0
    }
    It 'writes job-result.json with exitCode and suite RIG' {
        Write-Done completed @('Crashed', 'Hung', 'Completed', 'Completed', 'Completed'); Write-PassRuns; Write-GoodMessages
        Rig | Out-Null
        $o = Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json
        $o.suite | Should Be 'RIG'
        $o.exitCode | Should Be 0
        @($o.runs).Count | Should Be 5
    }
    It 'job-result.json records per run what it was judged against and the verdict' {
        Write-Done completed @('Crashed', 'HardTimeout', 'Completed', 'Completed', 'Completed'); Write-PassRuns; Write-GoodMessages
        Rig | Out-Null
        $runs = @((Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json).runs)
        $expectations = @(Get-RigSuiteRuns -Suite RIG)
        $runs[0].expected.exitClass | Should Be 'Crashed'
        $runs[0].expected.messagePattern | Should BeExactly $expectations[0].ExpectedMessagePattern
        $runs[0].verdict | Should Be 'Met'
        $runs[1].expected.exitClass | Should Be 'Hung'
        $runs[1].verdict | Should Be 'Mismatch'
        $runs[2].expected.exitClass | Should Be 'Completed'
        $runs[2].expected.messagePattern | Should Be $null
        $runs[2].verdict | Should Be 'Met'
        foreach ($r in $runs[0..2]) { @($r.expected.values).Count | Should Be 0 }
        $runs[3].expected.exitClass | Should Be 'Completed'
        (@($runs[3].expected.values | ForEach-Object { '{0}={1}' -f $_.name, $_.expected }) -join ',') |
            Should BeExactly 'exceptions.own=10000,exceptions.classification.walks=1000,exceptions.classification.ownExact=False'
        $runs[3].expected.values[2].expected -is [bool] | Should Be $true
        $runs[3].verdict | Should Be 'Met'
    }
    It 'r4 storm met: one line per value check and the R2 timing line below its row, no WARN; exit 0' {
        Write-Done completed @('Crashed', 'Hung', 'Completed', 'Completed', 'Completed'); Write-PassRuns; Write-GoodMessages
        (Rig) | Should Be 0
        $i = [array]::IndexOf($script:lines, @($script:lines | Where-Object { $_ -match '^r4 .*rig\.selftest-exception-storm.*expected Completed\s+actual Completed\s+met' })[0])
        $i -ge 0 | Should Be $true
        $script:lines[$i + 1] | Should BeExactly '    exceptions.own: expected 10000, actual 10000 met'
        $script:lines[$i + 2] | Should BeExactly '    exceptions.classification.walks: expected 1000, actual 1000 met'
        $script:lines[$i + 3] | Should BeExactly '    exceptions.classification.ownExact: expected false, actual false met'
        $script:lines[$i + 4] | Should BeExactly '    R2 timing: walk mean 0.420 ms (1000 walks); cache hit at most 6.7 us (mean of 9012 other exceptions)'
        @($script:lines | Where-Object { $_ -match '^WARN' }).Count | Should Be 0
    }
    It 'r4 storm slower than the R2 start values: WARN lines only, the exit code stays 0' {
        Write-Done completed @('Crashed', 'Hung', 'Completed', 'Completed', 'Completed'); Write-Run r3 $pass; Write-Run r5 $town; Write-GoodMessages
        Write-Run r4 (Get-StormResultJson -WalkMs 1500 -HandlerMs 2000)
        (Rig) | Should Be 0
        @($script:lines | Where-Object { $_ -ceq '    R2 timing: walk mean 1.500 ms (1000 walks); cache hit at most 55.5 us (mean of 9012 other exceptions)' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -ceq 'WARN r4 R2 walk mean 1.500 ms > 1 ms (start value, warning only)' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -ceq 'WARN r4 R2 cache hit at most 55.5 us > 50 us (start value, warning only)' }).Count | Should Be 1
    }
    It 'r4 storm with a wrong own count: exit 2, MISMATCH, the value line shows it; verdict Mismatch' {
        Write-Done completed @('Crashed', 'Hung', 'Completed', 'Completed', 'Completed'); Write-Run r3 $pass; Write-GoodMessages
        Write-Run r4 (Get-StormResultJson -Own 9990)
        (Rig) | Should Be 2
        @($script:lines | Where-Object { $_ -match '^r4 .*expected Completed\s+actual Completed\s+MISMATCH' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -ceq '    exceptions.own: expected 10000, actual 9990 MISMATCH' }).Count | Should Be 1
        (Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json).runs[3].verdict | Should Be 'Mismatch'
    }
    It 'r4 storm without the exceptions block: exit 1, ERROR, null values and timing not measured' {
        Write-Done completed @('Crashed', 'Hung', 'Completed', 'Completed', 'Completed'); Write-Run r3 $pass; Write-GoodMessages
        Write-Run r4 (Get-StormResultJson -NoExceptions)
        (Rig) | Should Be 1
        @($script:lines | Where-Object { $_ -match '^r4 .*expected Completed\s+actual Completed\s+ERROR' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -ceq '    exceptions.own: expected 10000, actual null ERROR' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -ceq '    R2 timing: not measured (exceptions.classification incomplete)' }).Count | Should Be 1
        (Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json).runs[3].verdict | Should Be 'RigError'
    }
    It 'r4 not Completed: no value lines (the exit class decides), the timing line still shows what was measured' {
        Write-Done completed @('Crashed', 'Hung', 'Completed', 'Crashed', 'Completed'); Write-Run r3 $pass; Write-Run r5 $town; Write-GoodMessages
        (Rig) | Should Be 2
        @($script:lines | Where-Object { $_ -match '^    exceptions\.' }).Count | Should Be 0
        @($script:lines | Where-Object { $_ -ceq '    R2 timing: not measured (exceptions.classification incomplete)' }).Count | Should Be 1
    }
    It 'a Crashed r1 whose message does not show the self-test throw: exit 2, MISMATCH and a line naming the message' {
        Write-Done completed @('Crashed', 'Hung', 'Completed', 'Completed', 'Completed'); Write-PassRuns; Write-GoodMessages
        Write-AgentRun r1 "Crash occurred (watchdog_log_1.txt); last line: 3.0 FirstChance #1 [Main]: System.NullReferenceException`r`nx"
        (Rig) | Should Be 2
        @($script:lines | Where-Object { $_ -match '^r1 .*expected Crashed\s+actual Crashed\s+MISMATCH' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match '^    message does not match .*rig\\.selftest-throw: Crash occurred \(watchdog_log_1\.txt\); last line: .*NullReferenceException' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match '[\x00-\x1F\x7F]' }).Count | Should Be 0
        (Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json).runs[0].verdict | Should Be 'Mismatch'
    }
    It 'a Hung r2 without agent-run.json: MISMATCH and the message shown as (none)' {
        Write-Done completed @('Crashed', 'Hung', 'Completed', 'Completed', 'Completed'); Write-PassRuns; Write-GoodMessages
        Remove-Item -LiteralPath (Join-Path $script:rd 'r2\agent-run.json')
        (Rig) | Should Be 2
        @($script:lines | Where-Object { $_ -match '^    message does not match \^No Alive line.*: \(none\)$' }).Count | Should Be 1
    }
    It 'a rejected job prints its status and the sanitized single-line message; exit stays 1' {
        [IO.File]::WriteAllText((Join-Path $script:rd 'done.json'), ('{"schema":1,"jobId":"' + $script:id + '","status":"rejected","message":"Module(s) not in the allowlist: TestRig.SelfTest.\r\nsecond\u001bline","runs":[]}'))
        (Rig) | Should Be 1
        @($script:lines | Where-Object { $_ -match '^job status: rejected - Module\(s\) not in the allowlist: TestRig\.SelfTest\.\s+second\s*line$' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match '[\x00-\x1F\x7F]' }).Count | Should Be 0
    }
    It 'a blocked job without message prints just the status' {
        Write-Done blocked @()
        (Rig) | Should Be 1
        @($script:lines | Where-Object { $_ -ceq 'job status: blocked' }).Count | Should Be 1
    }
    It 'an aborted job prints its status and keeps exit 3' {
        Write-Done aborted @('Crashed', 'Hung', 'Completed'); Write-Run r3 $pass
        (Rig) | Should Be 3
        @($script:lines | Where-Object { $_ -match '^job status: aborted' }).Count | Should Be 1
    }
    It 'a completed job prints no job status line' {
        Write-Done completed @('Crashed', 'Hung', 'Completed'); Write-Run r3 $pass
        Rig | Out-Null
        @($script:lines | Where-Object { $_ -match '^job status:' }).Count | Should Be 0
    }
    It 'without a suite a rejected job prints status and message too' {
        [IO.File]::WriteAllText((Join-Path $script:rd 'done.json'), ('{"schema":1,"jobId":"' + $script:id + '","status":"rejected","message":"bad package","runs":[]}'))
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -SkipChecks) | Should Be 1
        @($script:lines | Where-Object { $_ -ceq 'job status: rejected - bad package' }).Count | Should Be 1
    }
    It 'L1 still shows no expected/actual column and job-result.json has no expected/verdict' {
        Write-Done completed @('Completed'); Write-Run r1 ('{"schema":1,"status":"Completed","daysReached":3,"scenarios":' + (Get-L1ScenariosJson 3) + (Get-L1MeasuresJson) + '}')
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1 -ExpectedModules $script:l1Modules -SkipChecks) | Should Be 0
        # No expectation row ('<run> <suite>-<what> expected <class> actual ...'); the L1 verdict rows have their own shape.
        @($script:lines | Where-Object { $_ -match '^\S+\s+\S+\s+expected ' }).Count | Should Be 0
        $props = @((Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json).runs[0].PSObject.Properties.Name)
        $props -contains 'expected' | Should Be $false
        $props -contains 'verdict' | Should Be $false
    }
}

Describe 'Start-TestRigJob -Suite RIG' {
    BeforeEach {
        $script:t = New-TempDir
        $script:out = Join-Path $script:t 'out'
        $script:cfg = Join-Path $script:t 'runner.config.json'
        [IO.File]::WriteAllText($script:cfg, '{"host":"testpc","user":"rig","keyPath":"C:\\keys\\k","remoteQueueRoot":"C:\\TestRig\\queue"}')
        $script:published = $null
        $script:calls = @{ Publish = 0 }
        Mock Get-JobState { @() } -ParameterFilter { $OpenJobs }
        Mock Publish-Job {
            $script:calls.Publish++
            $script:published = @{ Job = (Get-Content -LiteralPath (Join-Path $JobDirectory 'job.json') -Raw | ConvertFrom-Json) }
        }
        Mock Write-Host { $script:lines += "$Object" }
        $script:lines = @()
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    function Start-RigSuite([string]$Pkg) {
        Start-TestRigJob -PackageFrom $Pkg -Seed 1 -Days 1 -Mode WarSails -Harness TestRig -Suite RIG `
            -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -ClaimTimeoutSeconds 0.3 -TimeoutMinutes 0.5 `
            -ConfigPath $script:cfg -OutRoot $script:out -RetryDelaySeconds 0
    }
    It 'publishes one job with five runs when the package holds the harness and the self-test module' {
        $pkg = Join-Path $script:t 'pkg'; New-ModuleFixture $pkg @('TestRig.Harness', 'TestRig.SelfTest')
        (Start-RigSuite $pkg) | Should Be 0
        @($script:published.Job.runs).Count | Should Be 5
        (@($script:published.Job.runs[3].ownAssemblies) -join ',') | Should BeExactly 'TestRig.SelfTest'
        ($script:published.Job.modules -join ',') | Should Be ($script:rigModules -join ',')
    }
    It 'a package without TestRig.SelfTest: exit 1 naming it, nothing published' {
        $pkg = Join-Path $script:t 'pkg'; New-ModuleFixture $pkg @('TestRig.Harness')
        (Start-RigSuite $pkg) | Should Be 1
        ($script:lines -join "`n") | Should Match 'TestRig\.SelfTest'
        $script:calls.Publish | Should Be 0
    }
}

# -Suite L1-BASE: vanilla baseline. One job, five soak runs with their own seeds; each must end Completed with enough days.

Describe 'Get-RigModules -Suite L1-BASE' {
    It 'is the L1 load order without the four mods and without scenario modules (WarSails)' {
        (Get-RigModules -Mode WarSails -Harness TestRig -Suite 'L1-BASE') -join ',' | Should Be ($script:l1BaseModules -join ',')
    }
}

Describe 'Get-RigSuiteRuns and Get-RigSuiteTimeoutMinutes -Suite L1-BASE' {
    It 'has five runs r1-r5 with seeds 1, 1, 1, 2, 3, no scenarios, 10 minute hard timeout, expected Completed' {
        $r = @(Get-RigSuiteRuns -Suite 'L1-BASE')
        (@($r | ForEach-Object { $_.RunId }) -join ',') | Should Be 'r1,r2,r3,r4,r5'
        (@($r | ForEach-Object { $_.Seed }) -join ',') | Should Be '1,1,1,2,3'
        foreach ($run in $r) {
            @($run.Scenarios).Count | Should Be 0
            $run.HardTimeoutMinutes | Should Be 10
            $run.ExpectedExitClass | Should Be 'Completed'
            $run.ExpectedMessagePattern | Should Be $null
        }
    }
    It 'RIG runs have no seed of their own' {
        foreach ($run in @(Get-RigSuiteRuns -Suite RIG)) { $run.Seed | Should Be $null }
    }
    It 'the overall deadline covers five runs: 5 x (10 + 2) + claim wait 2 + 5 = 67 minutes' {
        Get-RigSuiteTimeoutMinutes -Suite 'L1-BASE' | Should Be 67
        Get-RigSuiteTimeoutMinutes -Suite 'L1-BASE' -Days 30 | Should Be 67
        Get-RigSuiteTimeoutMinutes -Suite 'L1-BASE' -Days 3 | Should Be 67
    }
    It 'a longer -Days scales the per-run hard timeout: max(10, ceil(10 x days / 30)); the deadline follows' {
        foreach ($c in @(@(3, 10), @(30, 10), @(31, 11), @(45, 15), @(90, 30))) {
            foreach ($run in @(Get-RigSuiteRuns -Suite 'L1-BASE' -Days $c[0])) { $run.HardTimeoutMinutes | Should Be $c[1] }
        }
        Get-RigSuiteTimeoutMinutes -Suite 'L1-BASE' -Days 90 | Should Be 167   # 5 x (30 + 2) + 2 + 5
        Get-RigSuiteTimeoutMinutes -Suite 'L1-BASE' -Days 31 | Should Be 72    # 5 x (11 + 2) + 2 + 5
    }
}

Describe 'Resolve-RigSuiteSettings -Suite L1-BASE' {
    It 'L1-BASE alone: TestRig, WarSails, 30 days' {
        $r = Resolve-RigSuiteSettings -Suite 'L1-BASE' -BoundParameters @('Suite') -Harness TestRig -Mode NoDlc -Seed 1 -Days 1
        $r.Harness | Should Be 'TestRig'
        $r.Mode | Should Be 'WarSails'
        $r.Days | Should Be 30
    }
    It 'an explicit -Days wins' {
        (Resolve-RigSuiteSettings -Suite 'L1-BASE' -BoundParameters @('Suite', 'Days') -Harness TestRig -Mode WarSails -Seed 1 -Days 3).Days | Should Be 3
    }
    It 'an explicit -Seed or -HardTimeoutMinutes is a usage error' {
        { Resolve-RigSuiteSettings -Suite 'L1-BASE' -BoundParameters @('Suite', 'Seed') -Harness TestRig -Mode WarSails -Seed 2 -Days 30 } | Should Throw '-Seed conflicts'
        { Resolve-RigSuiteSettings -Suite 'L1-BASE' -BoundParameters @('Suite', 'HardTimeoutMinutes') -Harness TestRig -Mode WarSails -Seed 1 -Days 30 } | Should Throw 'HardTimeoutMinutes'
    }
    It '-Seed stays allowed for suites whose runs do not fix it (RIG, L1)' {
        { Resolve-RigSuiteSettings -Suite RIG -BoundParameters @('Suite', 'Seed') -Harness TestRig -Mode WarSails -Seed 2 -Days 1 } | Should Not Throw
        (Resolve-RigSuiteSettings -Suite L1 -BoundParameters @('Suite', 'Seed') -Harness TestRig -Mode WarSails -Seed 2 -Days 1).Seed | Should Be 2
    }
}

Describe 'New-RigJobManifest -Suite L1-BASE' {
    $script:baseJob = (ConvertTo-RigJson (New-RigJobManifest -JobId '20261103-120000-abcd' -CreatedUtc ([datetime]'2026-11-03T12:00:00Z') `
                -PackageSha256 'ABC' -Seed 9 -Days 30 -Mode WarSails -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -Harness TestRig -Suite 'L1-BASE')) | ConvertFrom-Json
    It 'writes each run with its own seed (not -Seed), the job days and the run hard timeout' {
        (@($script:baseJob.runs | ForEach-Object { $_.seed }) -join ',') | Should Be '1,1,1,2,3'
        (@($script:baseJob.runs | ForEach-Object { $_.days }) -join ',') | Should Be '30,30,30,30,30'
        (@($script:baseJob.runs | ForEach-Object { $_.hardTimeoutMinutes }) -join ',') | Should Be '10,10,10,10,10'
    }
    It 'a longer -Days writes the scaled hard timeout to every run (90 days: 30 minutes)' {
        $j = (ConvertTo-RigJson (New-RigJobManifest -JobId '20261103-120000-abcd' -CreatedUtc ([datetime]'2026-11-03T12:00:00Z') `
                    -PackageSha256 'ABC' -Seed 1 -Days 90 -Mode WarSails -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -Harness TestRig -Suite 'L1-BASE')) | ConvertFrom-Json
        (@($j.runs | ForEach-Object { $_.hardTimeoutMinutes }) -join ',') | Should Be '30,30,30,30,30'
    }
    It 'RIG runs still take -Seed' {
        $j = (ConvertTo-RigJson (New-RigJobManifest -JobId '20261103-120000-abcd' -CreatedUtc ([datetime]'2026-11-03T12:00:00Z') `
                    -PackageSha256 'ABC' -Seed 7 -Days 1 -Mode WarSails -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -Harness TestRig -Suite RIG)) | ConvertFrom-Json
        (@($j.runs | ForEach-Object { $_.seed }) -join ',') | Should Be '7,7,7,7,7'
    }
}

Describe 'Resolve-RigExitCode with soak expectations (L1-BASE)' {
    function Sr($id, $cls, $days = 30, $soakStatus = 'Passed') {
        [pscustomobject]@{ runId = $id; kind = 'soak'; exitClass = $cls; daysReached = $days; scenarioIds = @('soak'); scenarioStatuses = @($soakStatus); message = $null }
    }
    function Verdict($runs, [int]$Days = 30) {
        Resolve-RigExitCode -DoneStatus completed -Runs $runs -Days $Days -Expectations @(Get-RigSuiteRuns -Suite 'L1-BASE')
    }
    $good = { @('r1', 'r2', 'r3', 'r4', 'r5' | ForEach-Object { Sr $_ Completed }) }

    It 'five Completed runs with all days -> 0' {
        Verdict (& $good) | Should Be 0
    }
    It 'a Completed run with too few days or no daysReached -> 2' {
        $runs = & $good; $runs[3] = Sr r4 Completed 29
        Verdict $runs | Should Be 2
        $runs = & $good; $runs[3] = Sr r4 Completed $null
        Verdict $runs | Should Be 2
    }
    It 'a Completed run whose soak row is Failed -> 2, Error or unknown -> 1; Timeout/Skipped add nothing' {
        $runs = & $good; $runs[1] = Sr r2 Completed 30 'Failed'
        Verdict $runs | Should Be 2
        foreach ($s in 'Error', 'Weird') {
            $runs = & $good; $runs[1] = Sr r2 Completed 30 $s
            Verdict $runs | Should Be 1
        }
        $runs = & $good; $runs[1] = Sr r2 Completed 30 'Timeout'
        Verdict $runs | Should Be 0
    }
    It 'the days rule follows -Days (L1-BASE -Days 3)' {
        Verdict @('r1', 'r2', 'r3', 'r4', 'r5' | ForEach-Object { Sr $_ Completed 3 }) 3 | Should Be 0
    }
    It 'a Crashed run -> 2; a missing run -> 1' {
        $runs = & $good; $runs[0] = Sr r1 Crashed $null
        Verdict $runs | Should Be 2
        Verdict @((& $good)[0..3]) | Should Be 1
    }
    It 'a Hung, HardTimeout or Aborted run is inconclusive -> 3 (as without a suite); 1 > 3 > 2 stays' {
        foreach ($c in 'Hung', 'HardTimeout', 'Aborted') {
            $runs = & $good; $runs[4] = Sr r5 $c 12
            Verdict $runs | Should Be 3
            Get-RigExpectationOutcome -Expectation @(Get-RigSuiteRuns -Suite 'L1-BASE')[4] -Run $runs[4] -Days 30 | Should Be 'Inconclusive'
        }
        $runs = & $good; $runs[4] = Sr r5 Hung 12; $runs[0] = Sr r1 Crashed $null
        Verdict $runs | Should Be 3
        $runs = & $good; $runs[4] = Sr r5 Hung 12; $runs[0] = Sr r1 Completed 30 'Error'
        Verdict $runs | Should Be 1
        Verdict @(@((& $good)[0..2]) + @(Sr r4 HardTimeout 3)) | Should Be 1   # r5 missing
    }
    It 'a Hung, HardTimeout or Aborted run whose soak row is Error or unknown is a rig error -> 1 (as without a suite)' {
        foreach ($c in 'Hung', 'HardTimeout', 'Aborted') {
            foreach ($s in 'Error', 'Weird') {
                $runs = & $good; $runs[4] = Sr r5 $c 12 $s
                Verdict $runs | Should Be 1
                Get-RigExpectationOutcome -Expectation @(Get-RigSuiteRuns -Suite 'L1-BASE')[4] -Run $runs[4] -Days 30 | Should Be 'RigError'
            }
        }
        $runs = & $good; $runs[4] = Sr r5 HardTimeout 12 'Failed'
        Verdict $runs | Should Be 3
    }
    It 'every soak rule is checked: an Error row after a Failed one, or after too few days, is a rig error (1)' {
        $e = @(Get-RigSuiteRuns -Suite 'L1-BASE')[1]
        $run = [pscustomobject]@{ runId = 'r2'; kind = 'soak'; exitClass = 'Completed'; daysReached = 30; message = $null
            scenarioIds = @('soak', 'soak', 'soak'); scenarioStatuses = @('Failed', 'Passed', 'Error') }
        Get-RigExpectationOutcome -Expectation $e -Run $run -Days 30 | Should Be 'RigError'
        $runs = & $good; $runs[1] = $run
        Verdict $runs | Should Be 1
        $short = [pscustomobject]@{ runId = 'r2'; kind = 'soak'; exitClass = 'Completed'; daysReached = 12; message = $null
            scenarioIds = @('soak'); scenarioStatuses = @('Error') }
        Get-RigExpectationOutcome -Expectation $e -Run $short -Days 30 | Should Be 'RigError'
    }
}

Describe 'Publish-RigResult -Suite L1-BASE' {
    BeforeEach {
        $script:t = New-TempDir
        $script:id = '20261103-120000-b0b0'
        $script:rd = Join-Path $script:t $script:id
        New-Item -ItemType Directory -Path $script:rd | Out-Null
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
        $runs = 1..5 | ForEach-Object { '{"runId":"r' + $_ + '","exitClass":"Completed"}' }
        [IO.File]::WriteAllText((Join-Path $script:rd 'done.json'), ('{"schema":1,"jobId":"' + $script:id + '","status":"completed","runs":[' + ($runs -join ',') + ']}'))
        foreach ($i in 1..5) {
            $d = Join-Path $script:rd "r$i"
            New-Item -ItemType Directory -Path $d | Out-Null
            [IO.File]::WriteAllText((Join-Path $d 'run-result.json'), '{"schema":1,"status":"Completed","daysReached":30,"scenarios":[{"id":"soak","status":"Passed","seconds":120}]}')
        }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    It 'all five runs Completed with 30 days: exit 0, an expectation row and a soak row with the days per run' {
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 30 -Suite 'L1-BASE') | Should Be 0
        foreach ($i in 1..5) {
            @($script:lines | Where-Object { $_ -match "^r$i\s+L1-BASE-soak expected Completed\s+actual Completed\s+met" }).Count | Should Be 1
            @($script:lines | Where-Object { $_ -match "^r$i\s+L1-BASE-soak Passed\s+30/30 " }).Count | Should Be 1
        }
        @((Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json).runs | ForEach-Object { $_.verdict }) -join ',' |
            Should Be 'Met,Met,Met,Met,Met'
    }
    It 'a run that stopped short of the days: exit 2 and MISMATCH' {
        [IO.File]::WriteAllText((Join-Path $script:rd 'r2\run-result.json'), '{"schema":1,"status":"Completed","daysReached":12,"scenarios":[{"id":"soak","status":"Failed","seconds":50}],"checks":[{"name":"daysReached","expected":">=30","actual":"12","passed":false,"scenario":"soak"}]}')
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 30 -Suite 'L1-BASE') | Should Be 2
        @($script:lines | Where-Object { $_ -match '^r2\s+L1-BASE-soak expected Completed\s+actual Completed\s+MISMATCH' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match '^r2\s+L1-BASE-soak Failed\s+12/30 ' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match '^    daysReached: expected >=30, actual 12' }).Count | Should Be 1
    }
    It 'a crashed run without run-result.json still gets its soak row (days ?/30)' {
        [IO.File]::WriteAllText((Join-Path $script:rd 'done.json'), ('{"schema":1,"jobId":"' + $script:id + '","status":"completed","runs":[' +
                ((1..5 | ForEach-Object { '{"runId":"r' + $_ + '","exitClass":"' + $(if ($_ -eq 3) { 'Crashed' } else { 'Completed' }) + '"}' }) -join ',') + ']}'))
        Remove-Item -LiteralPath (Join-Path $script:rd 'r3\run-result.json')
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 30 -Suite 'L1-BASE') | Should Be 2
        @($script:lines | Where-Object { $_ -match '^r3\s+L1-BASE-soak expected Completed\s+actual Crashed\s+MISMATCH' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match '^r3\s+L1-BASE-soak \?\s+\?/30\s+Crashed' }).Count | Should Be 1
    }
    It 'a hung run: exit 3, the row says INCONCLUSIVE and job-result verdict Inconclusive' {
        [IO.File]::WriteAllText((Join-Path $script:rd 'done.json'), ('{"schema":1,"jobId":"' + $script:id + '","status":"completed","runs":[' +
                ((1..5 | ForEach-Object { '{"runId":"r' + $_ + '","exitClass":"' + $(if ($_ -eq 4) { 'Hung' } else { 'Completed' }) + '"}' }) -join ',') + ']}'))
        Remove-Item -LiteralPath (Join-Path $script:rd 'r4\run-result.json')
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 30 -Suite 'L1-BASE') | Should Be 3
        @($script:lines | Where-Object { $_ -match '^r4\s+L1-BASE-soak expected Completed\s+actual Hung\s+INCONCLUSIVE' }).Count | Should Be 1
        (Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json).runs[3].verdict | Should Be 'Inconclusive'
    }
}

Describe 'Start-TestRigJob -Suite L1-BASE' {
    BeforeEach {
        $script:t = New-TempDir
        $script:cfg = Join-Path $script:t 'runner.config.json'
        [IO.File]::WriteAllText($script:cfg, '{"host":"testpc","user":"rig","keyPath":"C:\\keys\\k","remoteQueueRoot":"C:\\TestRig\\queue"}')
        $script:published = $null
        Mock Get-JobState { @() } -ParameterFilter { $OpenJobs }
        Mock Publish-Job { $script:published = Get-Content -LiteralPath (Join-Path $JobDirectory 'job.json') -Raw | ConvertFrom-Json }
        Mock Write-Host { }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    It 'publishes five runs from a package that holds only the harness' {
        $pkg = Join-Path $script:t 'pkg'; New-ModuleFixture $pkg @('TestRig.Harness')
        (Start-TestRigJob -PackageFrom $pkg -Seed 1 -Days 30 -Mode WarSails -Harness TestRig -Suite 'L1-BASE' `
                -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -ClaimTimeoutSeconds 0.3 -TimeoutMinutes 0.5 `
                -ConfigPath $script:cfg -OutRoot (Join-Path $script:t 'out') -RetryDelaySeconds 0) | Should Be 0
        @($script:published.runs).Count | Should Be 5
        ($script:published.modules -join ',') | Should Be ($script:l1BaseModules -join ',')
    }
}

# -Suite L1 health bracket (F-S6-1): the four health scenario modules, runs[].health, and the structural verdict of the
# <id>@0 / <id>@<days> lines (threshold verdicts are #21).

Describe 'L1 health: suite, manifest and line ids' {
    function New-HealthManifest([string]$Suite) {
        $p = @{
            JobId = '20261103-153000-a1b2'; CreatedUtc = ([datetime]'2026-11-03T15:30:00Z').ToUniversalTime()
            PackageSha256 = 'ABC'; Seed = 1; Days = 30; Mode = 'WarSails'; StallMinutes = 5; BudgetMinutes = 60; HardTimeoutMinutes = 20
            Harness = 'TestRig'
        }
        if ($Suite) { $p.Suite = $Suite }
        $json = ConvertTo-RigJson (New-RigJobManifest @p)
        [pscustomobject]@{ Json = $json; Object = ($json | ConvertFrom-Json) }
    }
    It 'L1 loads the four scenario modules last, after the harness, in the order of their mods' {
        $m = @(Get-RigModules -Mode WarSails -Harness TestRig -Suite L1)
        ($m[-5..-1] -join ',') | Should Be ((@('TestRig.Harness') + $script:l1ScenarioModules) -join ',')
        ($m -contains 'Bannerlord.MBOptionScreen') | Should Be $true   # MCM v5, needed by CoherentWarAI
    }
    It 'L1 writes the four health ids to runs[].health as a JSON array (soak run, no scenarios field)' {
        $r = New-HealthManifest 'L1'
        (@($r.Object.runs[0].health) -join ',') | Should Be ($script:l1Health -join ',')
        $r.Object.runs[0].kind | Should Be 'soak'
        ($r.Object.runs[0].PSObject.Properties.Name -contains 'scenarios') | Should Be $false
        $r.Json | Should Match '"health":\s*\[\s*"coherentwarai\.health"'
    }
    It 'a suite with one health id writes runs[].health as a JSON array with that one id' {
        $script:RigSuites['ONE-HEALTH'] = @{ Harness = 'TestRig'; Mode = 'WarSails'; Seed = 1; Days = 1; Kind = 'soak'
            WithCoherentWarAI = $false; ExtraModules = @(); TailModules = @(); Health = @('x.health') }
        try {
            $r = New-HealthManifest 'ONE-HEALTH'
            $r.Json | Should Match '"health":\s*\[\s*"x\.health"\s*\]'
            @($r.Object.runs[0].health).Count | Should Be 1
        } finally { $script:RigSuites.Remove('ONE-HEALTH') }
        $script:RigSuites.ContainsKey('ONE-HEALTH') | Should Be $false
    }
    It 'no other suite and no suite-less job carries a health field' {
        foreach ($s in '', 'SM', 'RIG', 'L1-BASE') {
            foreach ($run in @((New-HealthManifest $s).Object.runs)) {
                ($run.PSObject.Properties.Name -contains 'health') | Should Be $false
            }
        }
    }
    It 'Get-RigHealthLineIds: every @0 line, then every @<days> line, in id order' {
        (@(Get-RigHealthLineIds -Health @('a.health', 'b.health') -Days 30) -join ',') | Should Be 'a.health@0,b.health@0,a.health@30,b.health@30'
        @(Get-RigHealthLineIds -Health @() -Days 30).Count | Should Be 0
    }
}

Describe 'Format-RigClassificationTiming' {
    function TimingOf($total, $walks, $walkMs, $handlerMs) {
        $result = [pscustomobject]@{ exceptions = [pscustomobject]@{ total = $total
            classification = [pscustomobject]@{ walks = $walks; walkMs = $walkMs; handlerMs = $handlerMs } } }
        Format-RigClassificationTiming -RunId r4 -Result $result
    }

    It 'no walks: the walk mean is n/a and no walk WARN' {
        $out = @(TimingOf 100 0 0 1)
        $out[0] | Should BeExactly '    R2 timing: walk mean n/a (0 walks); cache hit at most 10.0 us (mean of 100 other exceptions)'
        $out.Count | Should Be 1
    }
    It 'every exception walked: the cache hit bound is n/a and no cache WARN' {
        $out = @(TimingOf 100 100 50 9999)
        $out[0] | Should BeExactly '    R2 timing: walk mean 0.500 ms (100 walks); cache hit at most n/a (mean of 0 other exceptions)'
        $out.Count | Should Be 1
    }
    It 'exactly the start values (1 ms walk mean, 50 us cache hit) give no WARN (strict greater-than)' {
        $out = @(TimingOf 1100 100 100 105)
        $out[0] | Should BeExactly '    R2 timing: walk mean 1.000 ms (100 walks); cache hit at most 5.0 us (mean of 1000 other exceptions)'
        $out.Count | Should Be 1
        $out = @(TimingOf 1001 1 0.5 50.5)
        $out[0] | Should BeExactly '    R2 timing: walk mean 0.500 ms (1 walks); cache hit at most 50.0 us (mean of 1000 other exceptions)'
        $out.Count | Should Be 1
    }
    It 'a handlerMs below walkMs (rounding) clamps the cache hit bound at 0 instead of going negative' {
        $out = @(TimingOf 1000 100 50 49.99)
        $out[0] | Should BeExactly '    R2 timing: walk mean 0.500 ms (100 walks); cache hit at most 0.0 us (mean of 900 other exceptions)'
        $out.Count | Should Be 1
    }
}

Describe 'Get-RigHealthOutcome' {
    function New-HealthRun([string[]]$Ids, [string[]]$Statuses, [string[]]$Health = @('a.health')) {
        [pscustomobject]@{ requestedHealth = $Health; scenarioIds = $Ids; scenarioStatuses = $Statuses }
    }
    It 'Met when every expected line is Passed (statuses case-insensitive), or the run has no health ids' {
        Get-RigHealthOutcome -Run (New-HealthRun @('a.health@0', 'soak', 'a.health@3') @('Passed', 'Passed', 'passed')) -Days 3 | Should Be 'Met'
        Get-RigHealthOutcome -Run (New-HealthRun @('soak') @('Passed') @()) -Days 3 | Should Be 'Met'
        Get-RigHealthOutcome -Run ([pscustomobject]@{ scenarioIds = @('soak'); scenarioStatuses = @('Passed') }) -Days 3 | Should Be 'Met'
    }
    It 'Mismatch when a line is Failed and none is unchecked' {
        Get-RigHealthOutcome -Run (New-HealthRun @('a.health@0', 'soak', 'a.health@3') @('Passed', 'Passed', 'Failed')) -Days 3 | Should Be 'Mismatch'
    }
    It 'RigError when a line is missing, Skipped, Timeout, Error or unknown (also next to a Failed one)' {
        Get-RigHealthOutcome -Run (New-HealthRun @('a.health@0', 'soak') @('Passed', 'Passed')) -Days 3 | Should Be 'RigError'
        foreach ($st in 'Skipped', 'Timeout', 'Error', 'Bogus', '') {
            Get-RigHealthOutcome -Run (New-HealthRun @('a.health@0', 'soak', 'a.health@3') @('Passed', 'Passed', $st)) -Days 3 | Should Be 'RigError'
        }
        Get-RigHealthOutcome -Run (New-HealthRun @('a.health@0', 'soak') @('Failed', 'Passed')) -Days 3 | Should Be 'RigError'
    }
    It 'ids are case-sensitive and the @<days> line follows -Days' {
        Get-RigHealthOutcome -Run (New-HealthRun @('A.health@0', 'soak', 'a.health@3') @('Passed', 'Passed', 'Passed')) -Days 3 | Should Be 'RigError'
        Get-RigHealthOutcome -Run (New-HealthRun @('a.health@0', 'soak', 'a.health@3') @('Passed', 'Passed', 'Passed')) -Days 30 | Should Be 'RigError'
    }
    It 'a soak expectation (suite with Runs) judges the health lines too' {
        $e = [pscustomobject]@{ RunId = 'r1'; Scenarios = @(); ExpectedExitClass = 'Completed'; ExpectedMessagePattern = $null }
        $base = @{ runId = 'r1'; kind = 'soak'; exitClass = 'Completed'; daysReached = 3; requestedHealth = @('a.health') }
        $run = [pscustomobject]($base + @{ scenarioIds = @('a.health@0', 'soak', 'a.health@3'); scenarioStatuses = @('Passed', 'Passed', 'Passed') })
        Get-RigExpectationOutcome -Expectation $e -Run $run -Days 3 | Should Be 'Met'
        $run = [pscustomobject]($base + @{ scenarioIds = @('a.health@0', 'soak', 'a.health@3'); scenarioStatuses = @('Passed', 'Passed', 'Failed') })
        Get-RigExpectationOutcome -Expectation $e -Run $run -Days 3 | Should Be 'Mismatch'
        $run = [pscustomobject]($base + @{ scenarioIds = @('a.health@0', 'soak'); scenarioStatuses = @('Passed', 'Passed') })
        Get-RigExpectationOutcome -Expectation $e -Run $run -Days 3 | Should Be 'RigError'
        # A Failed @0 line does not hide the missing @<days> line.
        $run = [pscustomobject]($base + @{ scenarioIds = @('a.health@0', 'soak'); scenarioStatuses = @('Failed', 'Passed') })
        Get-RigExpectationOutcome -Expectation $e -Run $run -Days 3 | Should Be 'RigError'
    }
}

Describe 'Publish-RigResult -Suite L1 with health lines' {
    BeforeEach {
        $script:t = New-TempDir
        $script:id = '20261103-153000-a1b2'
        $script:rd = Join-Path $script:t $script:id
        New-Item -ItemType Directory -Path (Join-Path $script:rd 'r1') | Out-Null
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    function Write-Job([string]$ExitClass, [string]$RunResultJson) {
        [IO.File]::WriteAllText((Join-Path $script:rd 'done.json'), ('{"schema":1,"jobId":"' + $script:id + '","status":"completed","runs":[{"runId":"r1","exitClass":"' + $ExitClass + '"}]}'))
        if ($RunResultJson) { [IO.File]::WriteAllText((Join-Path $script:rd 'r1\run-result.json'), $RunResultJson) }
    }
    function New-Result([string]$Status, [string]$ScenariosJson, [string]$ChecksJson = '[]', [int]$DaysReached = 3) {
        '{"schema":1,"status":"' + $Status + '","daysReached":' + $DaysReached + ',"scenarios":' + $ScenariosJson + ',"checks":' + $ChecksJson + (Get-L1MeasuresJson) + '}'
    }
    function Get-JobResult { Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json }
    # The console rows of one result line (an array, also with one row).
    function Get-Row([string]$LineId) { , @($script:lines | Where-Object { $_ -match ('^r1\s+L1-' + [regex]::Escape($LineId) + ' ') }) }

    It 'every line Passed: exit 0, one row per health line (L1-<id>@0 / @<days>), job-result health with expected/actual' {
        Write-Job Completed (New-Result Completed (Get-L1ScenariosJson 3))
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1 -ExpectedModules $script:l1Modules -SkipChecks) | Should Be 0
        foreach ($h in $script:l1Health) {
            (Get-Row "$h@0").Count | Should Be 1
            (Get-Row "$h@3")[0] | Should Match 'Passed\s+3/3\s+Completed'
        }
        $health = @((Get-JobResult).runs[0].health)
        $health.Count | Should Be 8
        (@($health | ForEach-Object { $_.id }) -join ',') | Should Be (@(Get-RigHealthLineIds -Health $script:l1Health -Days 3) -join ',')
        foreach ($h in $health) { $h.expected | Should Be 'Passed'; $h.actual | Should Be 'Passed' }
    }
    It 'a Failed health line: exit 2, its failed check printed below its row, actual Failed in job-result' {
        $checks = '[{"name":"behavior registered","expected":"true","actual":"false","passed":false,"scenario":"autotrader.health@3"}]'
        Write-Job Completed (New-Result Completed (Get-L1ScenariosJson 3 @{ 'autotrader.health@3' = 'Failed' }) $checks)
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1 -ExpectedModules $script:l1Modules -SkipChecks) | Should Be 2
        $row = (Get-Row 'autotrader.health@3')[0]
        $row | Should Match 'Failed'
        $i = [array]::IndexOf($script:lines, $row)
        $script:lines[$i + 1] | Should Be '    behavior registered: expected true, actual false'
        (@((Get-JobResult).runs[0].health) | Where-Object { $_.id -eq 'autotrader.health@3' }).actual | Should Be 'Failed'
    }
    It 'a missing health line: exit 1, a row with status missing, actual null in job-result' {
        Write-Job Completed (New-Result Completed (Get-L1ScenariosJson 3 -Omit @('smithingsuite.health@3')))
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1 -ExpectedModules $script:l1Modules -SkipChecks) | Should Be 1
        (Get-Row 'smithingsuite.health@3')[0] | Should Match 'missing\s+3/3\s+Completed'
        $entry = @((Get-JobResult).runs[0].health) | Where-Object { $_.id -eq 'smithingsuite.health@3' }
        $entry.actual | Should Be $null
    }
    It 'a Skipped health line in a Completed run: exit 1 (that check did not run); a missing line beats a Failed one' {
        Write-Job Completed (New-Result Completed (Get-L1ScenariosJson 3 @{ 'companionsuite.health@3' = 'Skipped' }))
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1 -ExpectedModules $script:l1Modules -SkipChecks) | Should Be 1
        Write-Job Completed (New-Result Completed (Get-L1ScenariosJson 3 @{ 'companionsuite.health@3' = 'Failed' } -Omit @('autotrader.health@0')))
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1 -ExpectedModules $script:l1Modules -SkipChecks) | Should Be 1
    }
    It 'the expected @<days> lines follow -Days: @3 lines in a -Days 30 job are missing (exit 1)' {
        Write-Job Completed (New-Result Completed (Get-L1ScenariosJson 3) -DaysReached 30)
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 30 -Suite L1 -ExpectedModules $script:l1Modules -SkipChecks) | Should Be 1
        (Get-Row 'autotrader.health@30')[0] | Should Match 'missing'
    }
    It 'taint in health@0 by a throw (Error, rest Skipped, NotCompleted): exit 1 by the Error line' {
        $sc = Get-L1ScenariosJson 3 @{ 'coherentwarai.health@0' = 'Error' } -Status 'Skipped'
        Write-Job NotCompleted (New-Result Aborted $sc -DaysReached 0)
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1 -ExpectedModules $script:l1Modules -SkipChecks) | Should Be 1
        (Get-Row 'coherentwarai.health@0')[0] | Should Match 'Error'
        (Get-Row 'soak')[0] | Should Match 'Skipped'
    }
    It 'taint in health@0 by a timeout (Timeout, rest Skipped, NotCompleted): exit 2, the Skipped lines add no rig error' {
        $sc = Get-L1ScenariosJson 3 @{ 'coherentwarai.health@0' = 'Timeout' } -Status 'Skipped'
        Write-Job NotCompleted (New-Result Aborted $sc -DaysReached 0)
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1 -ExpectedModules $script:l1Modules -SkipChecks) | Should Be 2
    }
    It 'a Completed run with an empty scenarios list: exit 1 and a missing row per expected health line' {
        Write-Job Completed (New-Result Completed '[]')
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1 -ExpectedModules $script:l1Modules -SkipChecks) | Should Be 1
        foreach ($id in @(Get-RigHealthLineIds -Health $script:l1Health -Days 3)) {
            (Get-Row $id).Count | Should Be 1
            (Get-Row $id)[0] | Should Match 'missing\s+3/3\s+Completed'
        }
    }
    It 'a crashed run without run-result.json: exit 2, only its soak row (no missing health rows), health actual null' {
        Write-Job Crashed $null
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1 -ExpectedModules $script:l1Modules -SkipChecks) | Should Be 2
        @($script:lines | Where-Object { $_ -match '^r1 ' }).Count | Should Be 1
        @($script:lines | Where-Object { $_ -match 'missing' }).Count | Should Be 0
        $health = @((Get-JobResult).runs[0].health)
        $health.Count | Should Be 8
        foreach ($h in $health) { $h.actual | Should Be $null }
    }
    It 'a job without a health suite keeps job-result.json without a health field' {
        Write-Job Completed (New-Result Completed '[{"id":"soak","status":"Passed","seconds":1}]')
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -SkipChecks) | Should Be 0
        ((Get-JobResult).runs[0].PSObject.Properties.Name -contains 'health') | Should Be $false
    }
}

Describe 'Start-TestRigJob -Suite L1 package check' {
    BeforeEach {
        $script:t = New-TempDir
        $script:cfg = Join-Path $script:t 'runner.config.json'
        [IO.File]::WriteAllText($script:cfg, '{"host":"testpc","user":"rig","keyPath":"C:\\keys\\k","remoteQueueRoot":"C:\\TestRig\\queue"}')
        $script:published = $null
        $script:lines = @()
        Mock Get-JobState { @() } -ParameterFilter { $OpenJobs }
        Mock Publish-Job { $script:published = Get-Content -LiteralPath (Join-Path $JobDirectory 'job.json') -Raw | ConvertFrom-Json }
        Mock Write-Host { $script:lines += "$Object" }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    function Start-L1([string]$Pkg) {
        Start-TestRigJob -PackageFrom $Pkg -Seed 1 -Days 3 -Mode WarSails -Harness TestRig -Suite L1 `
            -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -ClaimTimeoutSeconds 0.3 -TimeoutMinutes 0.5 `
            -ConfigPath $script:cfg -OutRoot (Join-Path $script:t 'out') -RetryDelaySeconds 0
    }
    It 'a package without a health scenario module: exit 1 naming it, nothing published' {
        $pkg = Join-Path $script:t 'pkg'
        New-ModuleFixture $pkg @($l1Mods | Where-Object { $_ -ne 'AutoTraderSpeed.Scenarios' })
        (Start-L1 $pkg) | Should Be 1
        ($script:lines -join "`n") | Should Match 'AutoTraderSpeed\.Scenarios'
        $script:published | Should Be $null
    }
    It 'a full L1 package publishes runs[0].health with the four ids' {
        $pkg = Join-Path $script:t 'pkg'; New-ModuleFixture $pkg $l1Mods
        (Start-L1 $pkg) | Should Be 0
        (@($script:published.runs[0].health) -join ',') | Should Be ($script:l1Health -join ',')
    }
}

Describe 'Get-RigSuiteBuildProjects (the suite table drives the build projects)' {
    $base = 'SmithingSuite.Scenarios'
    $sixIds = 'CoherentWarAI,AutoTraderSpeed,SmithingSuite,CompanionManagementSuite,TestRig.Harness,SmithingSuite.Scenarios'

    # Snapshot taken before #25 (project lists as built by the hard-coded L1/RIG/L1-BASE special cases).
    It 'L1 builds the six plus three health scenario projects' {
        $r = @(Get-RigSuiteBuildProjects -WorkspaceRoot 'C:\ws' -Suite 'L1')
        (@($r | ForEach-Object { $_.ModuleId }) -join ',') | Should Be "$sixIds,CoherentWarAI.Scenarios,AutoTraderSpeed.Scenarios,CompanionManagementSuite.Scenarios"
        (@($r | ForEach-Object { $_.ProjectPath.Substring(6) }) -join '|') | Should Be ((
                'BannerlordCoherentWarAI\src\CoherentWarAI\CoherentWarAI.csproj',
                'BannerlordAutoTrader\AutoTrader\src\AutoTrader.csproj',
                'BannerlordSmithingSuite\src\SmithingSuite.csproj',
                'CompanionManagementSuite\src\CompanionSuite.csproj',
                'BannerlordTestRig\src\TestRig.Harness\TestRig.Harness.csproj',
                'BannerlordSmithingSuite\tests\InGame\SmithingSuite.Scenarios\SmithingSuite.Scenarios.csproj',
                'BannerlordCoherentWarAI\tests\InGame\CoherentWarAI.Scenarios\CoherentWarAI.Scenarios.csproj',
                'BannerlordAutoTrader\tests\InGame\AutoTraderSpeed.Scenarios\AutoTraderSpeed.Scenarios.csproj',
                'CompanionManagementSuite\tests\InGame\CompanionManagementSuite.Scenarios\CompanionManagementSuite.Scenarios.csproj') -join '|')
    }
    It 'SM builds the six (its scenario module is in the base set)' {
        (@(Get-RigSuiteBuildProjects -WorkspaceRoot 'C:\ws' -Suite 'SM' | ForEach-Object { $_.ModuleId }) -join ',') | Should Be $sixIds
    }
    It 'RIG builds the six plus TestRig.SelfTest' {
        $r = @(Get-RigSuiteBuildProjects -WorkspaceRoot 'C:\ws' -Suite 'RIG')
        (@($r | ForEach-Object { $_.ModuleId }) -join ',') | Should Be "$sixIds,TestRig.SelfTest"
        $r[6].Repo | Should Be 'BannerlordTestRig'
        $r[6].ProjectPath | Should Be 'C:\ws\BannerlordTestRig\src\TestRig.SelfTest\TestRig.SelfTest.csproj'
    }
    It 'CS, AT and CW1 build the six plus their one scenario module' {
        foreach ($case in @(@('CS', 'CompanionManagementSuite.Scenarios', 'CompanionManagementSuite'),
                @('AT', 'AutoTraderSpeed.Scenarios', 'BannerlordAutoTrader'), @('CW1', 'CoherentWarAI.Scenarios', 'BannerlordCoherentWarAI'))) {
            $r = @(Get-RigSuiteBuildProjects -WorkspaceRoot 'C:\ws' -Suite $case[0])
            (@($r | ForEach-Object { $_.ModuleId }) -join ',') | Should Be "$sixIds,$($case[1])"
            $r[6].Repo | Should Be $case[2]
        }
    }
    It 'L1-BASE builds only the harness' {
        $r = @(Get-RigSuiteBuildProjects -WorkspaceRoot 'C:\ws' -Suite 'L1-BASE')
        $r.Count | Should Be 1
        $r[0].ModuleId | Should Be 'TestRig.Harness'
    }
    It 'no suite builds the six' {
        (@(Get-RigSuiteBuildProjects -WorkspaceRoot 'C:\ws' | ForEach-Object { $_.ModuleId }) -join ',') | Should Be $sixIds
    }
    It 'a fake suite with TailModule X builds X' {
        $script:RigTailModuleProjects['Fake.Scenarios'] = @('FakeRepo', 'tests\Fake.Scenarios\Fake.Scenarios.csproj')
        $script:RigSuites['FAKE'] = @{ Harness = 'TestRig'; Mode = 'WarSails'; Seed = 1; Days = 1; Kind = 'scenarios'; Scenarios = @('fake.one')
            WithCoherentWarAI = $false; ExtraModules = @(); TailModules = @('Fake.Scenarios') }
        try {
            $r = @(Get-RigSuiteBuildProjects -WorkspaceRoot 'C:\ws' -Suite 'FAKE')
            $r.Count | Should Be 7
            $r[6].ModuleId | Should Be 'Fake.Scenarios'
            $r[6].Repo | Should Be 'FakeRepo'
        } finally {
            $script:RigSuites.Remove('FAKE')
            $script:RigTailModuleProjects.Remove('Fake.Scenarios')
        }
        $script:RigSuites.ContainsKey('FAKE') | Should Be $false
    }
    It 'throws for an unknown suite' {
        { Get-RigSuiteBuildProjects -WorkspaceRoot 'C:\ws' -Suite 'L2' } | Should Throw "Unknown suite 'L2'"
    }
    It 'every TailModule of every suite has a project (or is in the base set)' {
        foreach ($name in $script:RigSuites.Keys) {
            { Get-RigSuiteBuildProjects -WorkspaceRoot 'C:\ws' -Suite $name } | Should Not Throw
        }
    }
}

# -Suite CS / AT (S7, S8): scenario suites with one mod and its scenario module; -Suite CW1 (S10): twelve runs with a mode each.

$script:baseModules = @(
    'Bannerlord.Harmony', 'Bannerlord.ButterLib', 'Bannerlord.UIExtenderEx', 'Bannerlord.MBOptionScreen',
    'Native', 'SandBoxCore', 'Sandbox', 'StoryMode', 'NavalDLC')

Describe 'Suite CS and AT' {
    It 'CS: the exact module list, WarSails, seed 1, 1 day, kind scenarios, the three scenarios in this order' {
        $r = Resolve-RigSuiteSettings -Suite CS -BoundParameters @('Suite') -Harness TestRig -Mode NoDlc -Seed 9 -Days 5
        $r.Harness | Should Be 'TestRig'; $r.Mode | Should Be 'WarSails'; $r.Seed | Should Be 1; $r.Days | Should Be 1
        (Get-RigModules -Mode WarSails -Harness TestRig -Suite CS) -join ',' |
            Should Be (($script:baseModules + @('CompanionManagementSuite', 'TestRig.Harness', 'CompanionManagementSuite.Scenarios')) -join ',')
        Get-RigSuiteKind -Suite CS | Should Be 'scenarios'
        ($script:RigSuites['CS'].Scenarios -join ',') | Should Be 'companion.equip-now,companion.roles-apply,companion.development-guard'
        @(Get-RigSuiteRuns -Suite CS).Count | Should Be 0
    }
    It 'AT: the exact module list, WarSails, seed 1, 1 day, kind scenarios, the two scenarios in this order' {
        (Get-RigModules -Mode WarSails -Harness TestRig -Suite AT) -join ',' |
            Should Be (($script:baseModules + @('AutoTraderSpeed', 'TestRig.Harness', 'AutoTraderSpeed.Scenarios')) -join ',')
        Get-RigSuiteKind -Suite AT | Should Be 'scenarios'
        $script:RigSuites['AT'].Days | Should Be 1
        $script:RigSuites['AT'].Seed | Should Be 1
        ($script:RigSuites['AT'].Scenarios -join ',') | Should Be 'autotrader.warehouse-consign,autotrader.town-trade'
    }
    It 'CS and AT have no CoherentWarAI and write one run r1 with their scenarios' {
        foreach ($s in 'CS', 'AT') {
            (@(Get-RigModules -Mode WarSails -Harness TestRig -Suite $s) -contains 'CoherentWarAI') | Should Be $false
            $j = New-RigJobManifest -JobId '20261103-100000-a1b2' -CreatedUtc ([datetime]'2026-11-03T10:00:00Z').ToUniversalTime() -PackageSha256 'ABC' `
                -Seed 1 -Days 1 -Mode WarSails -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -Harness TestRig -Suite $s
            @($j.runs).Count | Should Be 1
            @($j.runs)[0].runId | Should Be 'r1'
            (@($j.runs)[0].scenarios -join ',') | Should Be ($script:RigSuites[$s].Scenarios -join ',')
        }
    }
}

Describe 'Suite X' {
    BeforeEach {
        $script:x = New-RigJobManifest -JobId '20261103-100000-a1b2' -CreatedUtc ([datetime]'2026-11-03T10:00:00Z').ToUniversalTime() `
            -PackageSha256 'ABC' -Seed 1 -Days 1 -Mode WarSails -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -Harness TestRig -Suite X
    }
    It 'loads the base, AutoTraderSpeed, CompanionManagementSuite, the harness, then CrossMod.Scenarios (no CoherentWarAI)' {
        ($script:x.modules -join ',') | Should Be (($script:baseModules + @('AutoTraderSpeed', 'CompanionManagementSuite', 'TestRig.Harness', 'CrossMod.Scenarios')) -join ',')
        ($script:x.modules -contains 'CoherentWarAI') | Should Be $false
        Get-RigSuiteKind -Suite X | Should Be 'scenarios'
    }
    It 'job.json has two runs: r1 done and r2 cancel, seed 1, 5 minutes, kind scenarios' {
        (@($script:x.runs | ForEach-Object { $_.runId }) -join ',') | Should Be 'r1,r2'
        (@($script:x.runs | ForEach-Object { @($_.scenarios) -join '+' }) -join ',') |
            Should Be 'crossmod.trade-with-autoequip.done,crossmod.trade-with-autoequip.cancel'
        foreach ($run in @($script:x.runs)) {
            $run.kind | Should Be 'scenarios'
            $run.harness | Should Be 'TestRig'
            $run.seed | Should Be 1
            $run.hardTimeoutMinutes | Should Be 5
        }
    }
    It 'every run expects Completed' {
        $runs = @(Get-RigSuiteRuns -Suite X)
        $runs.Count | Should Be 2
        foreach ($r in $runs) { $r.ExpectedExitClass | Should Be 'Completed' }
    }
    It 'each run fixes seed 1 (fresh campaign per variant): -Seed is a usage error' {
        foreach ($r in @(Get-RigSuiteRuns -Suite X)) { $r.Seed | Should Be 1 }
        { Resolve-RigSuiteSettings -Suite X -BoundParameters @('Suite', 'Seed') -Harness TestRig -Mode WarSails -Seed 2 -Days 1 } | Should Throw 'fixes the seed'
        { Resolve-RigSuiteSettings -Suite X -BoundParameters @('Suite') -Harness TestRig -Mode WarSails -Seed 1 -Days 1 } | Should Not Throw
    }
    It 'builds the six plus CrossMod.Scenarios from repo BannerlordTestRig' {
        $r = @(Get-RigSuiteBuildProjects -WorkspaceRoot 'C:\ws' -Suite 'X')
        $r.Count | Should Be 7
        $r[6].ModuleId | Should Be 'CrossMod.Scenarios'
        $r[6].Repo | Should Be 'BannerlordTestRig'
        $r[6].ProjectPath | Should Be 'C:\ws\BannerlordTestRig\scenarios\CrossMod\CrossMod.Scenarios\CrossMod.Scenarios.csproj'
    }
}

Describe 'Suite CW1' {
    BeforeEach {
        $script:cw = New-RigJobManifest -JobId '20261103-100000-a1b2' -CreatedUtc ([datetime]'2026-11-03T10:00:00Z').ToUniversalTime() `
            -PackageSha256 'ABC' -Seed 1 -Days 30 -Mode WarSails -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -Harness TestRig -Suite CW1
    }
    It 'loads only CoherentWarAI, the harness and CoherentWarAI.Scenarios' {
        ($script:cw.modules -join ',') | Should Be (($script:baseModules + @('CoherentWarAI', 'TestRig.Harness', 'CoherentWarAI.Scenarios')) -join ',')
        foreach ($mod in 'AutoTraderSpeed', 'SmithingSuite', 'CompanionManagementSuite') { ($script:cw.modules -contains $mod) | Should Be $false }
    }
    It 'job.json has the 18 runs r1-r18: seeds 1-3, per seed WarSails, FeatureOff, AllOff, AllOff, FeatureOff, WarSails, 30 days, 10 minutes' {
        (@($script:cw.runs | ForEach-Object { $_.runId }) -join ',') | Should Be ((1..18 | ForEach-Object { "r$_" }) -join ',')
        (@($script:cw.runs | ForEach-Object { $_.seed }) -join ',') | Should Be '1,1,1,1,1,1,2,2,2,2,2,2,3,3,3,3,3,3'
        (@($script:cw.runs | ForEach-Object { $_.mode }) -join ',') |
            Should Be (@('WarSails', 'FeatureOff', 'AllOff', 'AllOff', 'FeatureOff', 'WarSails') * 3 -join ',')
        foreach ($run in @($script:cw.runs)) {
            $run.kind | Should Be 'scenarios'
            $run.harness | Should Be 'TestRig'
            $run.days | Should Be 30
            $run.hardTimeoutMinutes | Should Be 10
            (@($run.scenarios) -join ',') | Should Be 'coherentwarai.ac25a-digest'
        }
    }
    It 'a suite without per-run modes keeps the job mode in every run (RIG with NoDlc)' {
        $j = New-RigJobManifest -JobId '20261103-100000-a1b2' -CreatedUtc ([datetime]'2026-11-03T10:00:00Z').ToUniversalTime() -PackageSha256 'ABC' `
            -Seed 1 -Days 1 -Mode NoDlc -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -Harness TestRig -Suite RIG
        foreach ($run in @($j.runs)) { $run.mode | Should Be 'NoDlc' }
    }
    It 'every run expects Completed; the deadline is 18 x (10 + 2) + claim wait + 5' {
        foreach ($x in @(Get-RigSuiteRuns -Suite CW1)) { $x.ExpectedExitClass | Should Be 'Completed' }
        Get-RigSuiteTimeoutMinutes -Suite CW1 | Should Be 223
    }
    It 'Get-RigSuiteRuns carries the run mode, $null for runs without one' {
        (@(Get-RigSuiteRuns -Suite CW1 | ForEach-Object { $_.Mode }) -join ',') |
            Should Be (@('WarSails', 'FeatureOff', 'AllOff', 'AllOff', 'FeatureOff', 'WarSails') * 3 -join ',')
        foreach ($x in @(Get-RigSuiteRuns -Suite RIG)) { $x.Mode | Should Be $null }
    }
    It 'an explicit -Mode is a usage error (the runs fix their modes); an explicit -Seed too' {
        { Resolve-RigSuiteSettings -Suite CW1 -BoundParameters @('Suite', 'Mode') -Harness TestRig -Mode WarSails -Seed 1 -Days 30 } | Should Throw '-Mode conflicts'
        { Resolve-RigSuiteSettings -Suite CW1 -BoundParameters @('Suite', 'Seed') -Harness TestRig -Mode WarSails -Seed 1 -Days 30 } | Should Throw '-Seed conflicts'
        { Resolve-RigSuiteSettings -Suite CW1 -BoundParameters @('Suite') -Harness TestRig -Mode WarSails -Seed 1 -Days 30 } | Should Not Throw
        (Resolve-RigSuiteSettings -Suite CW1 -BoundParameters @('Suite') -Harness TestRig -Mode NoDlc -Seed 9 -Days 5).Days | Should Be 30
    }
    It 'a -Days shorter than 30 keeps the 18 runs and their modes (smoke)' {
        $j = New-RigJobManifest -JobId '20261103-100000-a1b2' -CreatedUtc ([datetime]'2026-11-03T10:00:00Z').ToUniversalTime() -PackageSha256 'ABC' `
            -Seed 1 -Days 3 -Mode WarSails -StallMinutes 5 -BudgetMinutes 60 -HardTimeoutMinutes 20 -Harness TestRig -Suite CW1
        @($j.runs).Count | Should Be 18
        foreach ($run in @($j.runs)) { $run.days | Should Be 3 }
    }
    It 'a run mode with another module list than the job (NoDlc) is a usage error' {
        $script:RigSuites['MIXED'] = @{ Harness = 'TestRig'; Mode = 'WarSails'; Seed = 1; Days = 1; Kind = 'scenarios'
            WithCoherentWarAI = $false; ExtraModules = @(); TailModules = @()
            Runs = @(@{ RunId = 'r1'; Mode = 'WarSails'; Scenarios = @('x.y'); HardTimeoutMinutes = 5; ExpectedExitClass = 'Completed' },
                @{ RunId = 'r2'; Mode = 'NoDlc'; Scenarios = @('x.y'); HardTimeoutMinutes = 5; ExpectedExitClass = 'Completed' }) }
        try {
            { Resolve-RigSuiteSettings -Suite MIXED -BoundParameters @('Suite') -Harness TestRig -Mode WarSails -Seed 1 -Days 1 } | Should Throw 'NoDlc'
            $script:RigSuites['MIXED'].Runs = @(@{ RunId = 'r1'; Mode = 'FeatureOff'; Scenarios = @('x.y'); HardTimeoutMinutes = 5; ExpectedExitClass = 'Completed' },
                @{ RunId = 'r2'; Mode = 'AllOff'; Scenarios = @('x.y'); HardTimeoutMinutes = 5; ExpectedExitClass = 'Completed' })
            { Resolve-RigSuiteSettings -Suite MIXED -BoundParameters @('Suite') -Harness TestRig -Mode WarSails -Seed 1 -Days 1 } | Should Not Throw
        } finally { $script:RigSuites.Remove('MIXED') }
    }
}
