$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\runner\Invoke-TestRig.ps1')

# -Suite L1: harness TestRig, the four mods plus the vanilla/framework load order, scenario row prefix.

$script:l1Modules = @(
    'Bannerlord.Harmony', 'Bannerlord.ButterLib', 'Bannerlord.UIExtenderEx', 'Bannerlord.MBOptionScreen',
    'Native', 'SandBoxCore', 'Sandbox', 'StoryMode', 'NavalDLC',
    'CoherentWarAI', 'AutoTraderSpeed', 'SmithingSuite', 'CompanionManagementSuite', 'TestRig.Harness')
$script:suiteScript = Join-Path $here '..\..\runner\Invoke-TestRig.ps1'

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

$l1Mods = @('CoherentWarAI', 'AutoTraderSpeed', 'SmithingSuite', 'CompanionManagementSuite', 'TestRig.Harness')

Describe 'Get-RigModules -Suite L1' {
    It 'is the exact L1 load order (WarSails)' {
        (Get-RigModules -Mode WarSails -Harness TestRig -Suite L1) -join ',' | Should Be ($script:l1Modules -join ',')
    }
    It 'NoDlc drops NavalDLC and keeps the suite modules' {
        $m = @(Get-RigModules -Mode NoDlc -Harness TestRig -Suite L1)
        ($m -contains 'NavalDLC') | Should Be $false
        ($m[-4..-1] -join ',') | Should Be 'AutoTraderSpeed,SmithingSuite,CompanionManagementSuite,TestRig.Harness'
    }
    It 'without -Suite the list is unchanged' {
        (Get-RigModules -Mode WarSails -Harness TestRig) -join ',' | Should Be (($script:l1Modules | Where-Object { $_ -notin 'AutoTraderSpeed', 'SmithingSuite', 'CompanionManagementSuite' }) -join ',')
    }
    It 'rejects an unknown suite' {
        $err = $null
        try { Get-RigModules -Mode WarSails -Suite L2 } catch { $err = $_ }
        $err.FullyQualifiedErrorId | Should Match '^ParameterArgumentValidationError'
    }
}

Describe 'Resolve-RigSuiteSettings' {
    function Resolve-S([string]$Suite, [string[]]$Bound = @(), $Harness = 'CoherentWarAI', $Mode = 'WarSails', $Seed = 1, $Days = 1) {
        Resolve-RigSuiteSettings -Suite $Suite -BoundParameters $Bound -Harness $Harness -Mode $Mode -Seed $Seed -Days $Days
    }
    It 'without -Suite returns every value unchanged' {
        $r = Resolve-S -Suite '' -Bound @('Days') -Harness CoherentWarAI -Mode NoDlc -Seed 7 -Days 2
        $r.Harness | Should Be 'CoherentWarAI'
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
    It 'an explicit conflicting -Harness is a usage error' {
        { Resolve-S -Suite L1 -Bound @('Harness') -Harness CoherentWarAI } | Should Throw 'Harness'
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
        [IO.File]::WriteAllText((Join-Path $script:rd 'r1\run-result.json'), '{"schema":1,"status":"Completed","daysReached":3,"scenarios":[{"id":"soak","status":"Passed","seconds":25}]}')
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    function Get-JobResult { Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json }

    It 'prints the row as <Suite>-<scenario id> and records suite in job-result.json (raw ids kept)' {
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1) | Should Be 0
        @($script:lines | Where-Object { $_ -match '^r1 ' })[0] | Should Match 'L1-soak\s+Passed\s+3/3\s+Completed'
        (Get-JobResult).suite | Should Be 'L1'
        (Get-JobResult).runs[0].result.scenarios[0].id | Should Be 'soak'
    }
    It 'prefixes the fallback row of a result without scenarios too' {
        [IO.File]::WriteAllText((Join-Path $script:rd 'r1\run-result.json'), '{"schema":1,"status":"Completed","daysReached":3,"scenarios":[]}')
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3 -Suite L1) | Should Be 0
        @($script:lines | Where-Object { $_ -match '^r1 ' })[0] | Should Match 'L1-soak\s+Completed'
    }
    It 'without -Suite the row is unchanged and suite is null' {
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 3) | Should Be 0
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

    It 'exists with ValidateSet L1 only' {
        $param | Should Not BeNullOrEmpty
        $vs = @($param.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })
        $vs.Count | Should Be 1
        (@($vs[0].PositionalArguments | ForEach-Object { $_.Value }) -join ',') | Should Be 'L1'
    }
    It 'rejects an unknown suite' {
        $out = (& powershell -NoProfile -File $script:suiteScript -PackageFrom C:\nowhere -Suite L2 2>&1 | Out-String)
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match 'ParameterArgumentValidationError'
        $out | Should Not Match 'Config not found'
    }
    It 'a conflicting -Harness is a usage error, exit 1 before the config is read' {
        $out = (& powershell -NoProfile -File $script:suiteScript -PackageFrom C:\nowhere -Suite L1 -Harness CoherentWarAI 2>&1 | Out-String)
        $LASTEXITCODE | Should Be 1
        $out | Should Match 'Harness'
        $out | Should Match 'TestRig'
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
        It 'without -Suite the defaults stay (CoherentWarAI harness, 1 day)' {
            New-ModuleFixture $script:pkgDir @('CoherentWarAI.TestHarness')
            $j = Invoke-Captured @()
            $j.runs[0].harness | Should Be 'CoherentWarAI'
            $j.runs[0].days | Should Be 1
        }
    }
}
