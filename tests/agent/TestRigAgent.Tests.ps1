# Pester 3.4 tests for agent\TestRigAgent.ps1 (slice S1).
# Run:  powershell -NoProfile -Command "Invoke-Pester <repo>\tests\agent"
# The end-to-end tests start powershell.exe with fixtures\fake-game.ps1 as the "game".

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$agentScript = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'agent\TestRigAgent.ps1'
$fakeGame = Join-Path $here 'fixtures\fake-game.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

. $agentScript

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function New-Rig {
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $rig = @{
        Root       = $root
        Queue      = Join-Path $root 'queue'
        Work       = Join-Path $root 'work'
        Game       = Join-Path $root 'game'
        Docs       = Join-Path $root 'docs'
        ConfigPath = Join-Path $root 'agent.config.json'
    }
    foreach ($d in @((Join-Path $rig.Queue 'jobs'), (Join-Path $rig.Queue 'results'), $rig.Work, (Join-Path $rig.Game 'Modules'), $rig.Docs)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    $cfg = [ordered]@{
        queueRoot           = $rig.Queue
        workRoot            = $rig.Work
        gamePath            = $rig.Game
        gameExecutable      = $powershellExe
        gameArgumentsPrefix = ('-NoProfile -File "{0}" /singleplayer' -f $fakeGame)
        documentsRoot       = $rig.Docs
        pollSeconds         = 1
    }
    [System.IO.File]::WriteAllText($rig.ConfigPath, ($cfg | ConvertTo-Json -Depth 10), $utf8NoBom)
    return $rig
}

function New-ZipFile {
    param([string]$Path, [string[]]$Entries)
    $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($name in $Entries) {
            $entry = $zip.CreateEntry($name)
            $stream = $entry.Open()
            $bytes = [System.Text.Encoding]::ASCII.GetBytes("content of $name")
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Dispose()
        }
    }
    finally { $zip.Dispose() }
}

function New-TestJob {
    # Creates jobs\<jobId>\ with package.zip and job.json; returns the job folder.
    param(
        [hashtable]$Rig,
        [string]$JobId = '20261031-120000-aaaa',
        [string[]]$Entries = @('Modules/CoherentWarAI/SubModule.xml', 'Modules/CoherentWarAI/bin/Win64_Shipping_Client/CoherentWarAI.dll', 'Modules/CoherentWarAI.TestHarness/SubModule.xml'),
        [scriptblock]$Mutate = $null,
        [switch]$NoJobJson
    )
    $jobDir = Join-Path (Join-Path $Rig.Queue 'jobs') $JobId
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
    $zipPath = Join-Path $jobDir 'package.zip'
    New-ZipFile -Path $zipPath -Entries $Entries
    $job = [ordered]@{
        schema              = 1
        jobId               = $JobId
        createdUtc          = '2026-10-31T12:00:00Z'
        expectedGameVersion = $null
        package             = [ordered]@{ file = 'package.zip'; sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash }
        repos               = @()
        modules             = @('Bannerlord.Harmony', 'Native', 'NavalDLC', 'CoherentWarAI', 'CoherentWarAI.TestHarness')
        runs                = @([ordered]@{
                runId = 'r1'; kind = 'soak'; harness = 'CoherentWarAI'; seed = 7; days = 1; mode = 'WarSails'
                stallMinutes = 5; budgetMinutes = 60; hardTimeoutMinutes = 1
            })
    }
    if ($Mutate) { & $Mutate $job }
    if (-not $NoJobJson) {
        [System.IO.File]::WriteAllText((Join-Path $jobDir 'job.json'), ($job | ConvertTo-Json -Depth 10), $utf8NoBom)
    }
    return $jobDir
}

function Set-JobPackageWithValidXml {
    # Rewrites the job's package.zip with valid SubModule.xml files (CoherentWarAI with two DLLs, plus the
    # harness module) and updates the sha256 in job.json.
    param([string]$JobDir, [string]$HarnessModuleId = 'TestRig.Harness')
    $xml = {
        param($id, $dlls)
        '<Module><Name value="' + $id + '"/><SubModules>' + (($dlls | ForEach-Object { '<SubModule><Name>n</Name><DLLName value="' + $_ + '"/></SubModule>' }) -join '') + '</SubModules></Module>'
    }
    $zipPath = Join-Path $JobDir 'package.zip'
    Remove-Item -LiteralPath $zipPath -Force
    $z = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
    try {
        foreach ($e in @(
                @{ n = 'Modules/CoherentWarAI/SubModule.xml'; t = (& $xml 'CoherentWarAI' @('CoherentWarAI.dll', 'Extra.dll')) },
                @{ n = "Modules/$HarnessModuleId/SubModule.xml"; t = (& $xml $HarnessModuleId @("$HarnessModuleId.dll")) })) {
            $entry = $z.CreateEntry($e.n)
            $w = New-Object System.IO.StreamWriter($entry.Open(), $utf8NoBom)
            $w.Write($e.t); $w.Dispose()
        }
    }
    finally { $z.Dispose() }
    $jobFile = Join-Path $JobDir 'job.json'
    $j = [System.IO.File]::ReadAllText($jobFile) | ConvertFrom-Json
    $j.package.sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    [System.IO.File]::WriteAllText($jobFile, ($j | ConvertTo-Json -Depth 10), $utf8NoBom)
}

function New-TestRigHarnessJob {
    # A job for harness TestRig; its package and module list carry TestRig.Harness unless told otherwise.
    param([hashtable]$Rig, [string[]]$Entries = @('Modules/CoherentWarAI/SubModule.xml', 'Modules/TestRig.Harness/SubModule.xml'),
        [string[]]$Modules = @('Native', 'CoherentWarAI', 'TestRig.Harness'))
    $mutate = {
        param($j)
        $j['runs'][0]['harness'] = 'TestRig'
        $j['modules'] = $Modules
    }.GetNewClosure()
    return New-TestJob $Rig -Entries $Entries -Mutate $mutate
}

function Read-Done {
    param([hashtable]$Rig, [string]$JobId = '20261031-120000-aaaa')
    $path = Join-Path (Join-Path (Join-Path $Rig.Queue 'results') $JobId) 'done.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return [System.IO.File]::ReadAllText($path, $utf8NoBom) | ConvertFrom-Json
}

function Get-ValidJobObject {
    param([string]$JobId = '20261031-120000-aaaa')
    return ('{"schema":1,"jobId":"' + $JobId + '","createdUtc":"x","package":{"file":"package.zip","sha256":"' + ('A' * 64) + '"},"modules":["Native"],"runs":[{"runId":"r1","kind":"soak","harness":"CoherentWarAI","seed":1,"days":1,"mode":"WarSails","stallMinutes":5,"budgetMinutes":60,"hardTimeoutMinutes":20}]}') | ConvertFrom-Json
}

function Set-RigConfigValue {
    # Adds or replaces one top-level property of the rig's agent.config.json.
    param([hashtable]$Rig, [string]$Name, $Value)
    $raw = [System.IO.File]::ReadAllText($Rig.ConfigPath) | ConvertFrom-Json
    $raw | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    [System.IO.File]::WriteAllText($Rig.ConfigPath, ($raw | ConvertTo-Json -Depth 10), $utf8NoBom)
}

function Start-AbortWatcher {
    # Background job: creates <JobDir>\abort as soon as the fake game has started.
    param([hashtable]$Rig, [string]$JobDir)
    return Start-Job -ScriptBlock {
        param($watch, $target)
        $end = (Get-Date).AddSeconds(90)
        while (-not (Test-Path -LiteralPath $watch) -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 100 }
        New-Item -ItemType File -Path $target -Force | Out-Null
    } -ArgumentList (Join-Path $Rig.Docs 'fake-args.txt'), (Join-Path $JobDir 'abort')
}

function Stop-FakeGameLeftovers {
    # Best effort: no stray fake game (or its child) may outlive a test. Reads the PIDs the
    # agent and the fake game recorded under FAKEGAME_DOCS' parent. Only powershell processes are touched.
    if ([string]::IsNullOrEmpty($env:FAKEGAME_DOCS)) { return }
    $root = Split-Path -Parent $env:FAKEGAME_DOCS
    $pids = @()
    $childFile = Join-Path $env:FAKEGAME_DOCS 'child-pid.txt'
    if (Test-Path -LiteralPath $childFile) { $pids += [int](Get-Content -Raw -LiteralPath $childFile) }
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -Filter 'agent-run.json' -ErrorAction SilentlyContinue)) {
        $pids += [int]((Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json).pid)
    }
    foreach ($p in ($pids | Where-Object { $_ -gt 0 })) {
        $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq 'powershell') { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
    }
}

function Get-RigHarnessDir { param($Rig) return (Join-Path $Rig.Docs 'Mount and Blade II Bannerlord\CoherentWarAI\harness') }

function Add-SecondRun {
    param($j, [double]$HardTimeout = 1)
    $second = [ordered]@{}
    foreach ($k in $j['runs'][0].Keys) { $second[$k] = $j['runs'][0][$k] }
    $second['runId'] = 'r2'
    $j['runs'][0]['hardTimeoutMinutes'] = $HardTimeout
    $second['hardTimeoutMinutes'] = $HardTimeout
    $j['runs'] = @($j['runs'][0], $second)
}

function Get-ConfigFor {
    param([hashtable]$Rig)
    return Get-AgentConfig -Path $Rig.ConfigPath
}

Describe 'Get-AgentConfig' {
    It 'applies the documented defaults' {
        $rig = New-Rig
        $cfg = Get-ConfigFor $rig
        $cfg.pollSeconds | Should Be 1
        $cfg.gameArgumentsPrefix | Should Match 'singleplayer'
        $cfg.moduleAllowlist -contains 'CoherentWarAI' | Should Be $true
        $cfg.moduleAllowlist -contains '*.Scenarios' | Should Be $true
    }
    It 'defaults gameExecutable to the Win64_Shipping_Client path' {
        $rig = New-Rig
        $raw = [System.IO.File]::ReadAllText($rig.ConfigPath) | ConvertFrom-Json
        $raw.PSObject.Properties.Remove('gameExecutable')
        [System.IO.File]::WriteAllText($rig.ConfigPath, ($raw | ConvertTo-Json), $utf8NoBom)
        (Get-ConfigFor $rig).gameExecutable | Should Be (Join-Path $rig.Game 'bin\Win64_Shipping_Client\Bannerlord.exe')
    }
    It 'throws when queueRoot is missing' {
        $rig = New-Rig
        [System.IO.File]::WriteAllText($rig.ConfigPath, '{ "workRoot": "x", "gamePath": "y" }', $utf8NoBom)
        { Get-ConfigFor $rig } | Should Throw
    }
}

Describe 'Test-ModuleAllowed' {
    $list = @('CoherentWarAI', 'SmithingSuite', '*.Scenarios')
    It 'accepts listed ids case-insensitively' { Test-ModuleAllowed 'coherentwarai' $list | Should Be $true }
    It 'accepts the wildcard rule' { Test-ModuleAllowed 'Foo.Scenarios' $list | Should Be $true }
    It 'rejects other ids' { Test-ModuleAllowed 'Evil' $list | Should Be $false }
    It 'does not let the wildcard match a different suffix' { Test-ModuleAllowed 'Foo.ScenariosX' $list | Should Be $false }
}

Describe 'Get-NextJob (claim)' {
    It 'claims the oldest job first and renames job.json' {
        $rig = New-Rig
        $null = New-TestJob $rig '20261031-120000-aaaa'
        $null = New-TestJob $rig '20261031-110000-bbbb'
        $null = New-TestJob $rig '20261031-130000-cccc'
        $first = Get-NextJob -QueueRoot $rig.Queue
        $first.JobId | Should Be '20261031-110000-bbbb'
        Test-Path (Join-Path $first.Dir 'job.claimed.json') | Should Be $true
        Test-Path (Join-Path $first.Dir 'job.json') | Should Be $false
        (Get-NextJob -QueueRoot $rig.Queue).JobId | Should Be '20261031-120000-aaaa'
        (Get-NextJob -QueueRoot $rig.Queue).JobId | Should Be '20261031-130000-cccc'
        Get-NextJob -QueueRoot $rig.Queue | Should BeNullOrEmpty
    }
    It 'skips a job whose claim rename fails and takes the next one' {
        $rig = New-Rig
        $null = New-TestJob $rig '20261031-110000-bbbb'
        $null = New-TestJob $rig '20261031-120000-aaaa'
        Mock Invoke-ClaimMove { throw 'someone else won the race' } -ParameterFilter { $From -like '*bbbb*' }
        (Get-NextJob -QueueRoot $rig.Queue).JobId | Should Be '20261031-120000-aaaa'
    }
    It 'ignores withdrawn and already claimed jobs' {
        $rig = New-Rig
        $d1 = New-TestJob $rig '20261031-110000-bbbb'
        Rename-Item (Join-Path $d1 'job.json') 'job.withdrawn.json'
        $d2 = New-TestJob $rig '20261031-120000-aaaa'
        Rename-Item (Join-Path $d2 'job.json') 'job.claimed.json'
        Get-NextJob -QueueRoot $rig.Queue | Should BeNullOrEmpty
    }
}

Describe 'Test-JobSchema' {
    function Get-ValidJob {
        return ('{"schema":1,"jobId":"20261031-120000-aaaa","createdUtc":"x","package":{"file":"package.zip","sha256":"' + ('A' * 64) + '"},"modules":["Native"],"runs":[{"runId":"r1","kind":"soak","harness":"CoherentWarAI","seed":1,"days":1,"mode":"WarSails","stallMinutes":5,"budgetMinutes":60,"hardTimeoutMinutes":20}]}') | ConvertFrom-Json
    }
    It 'accepts a valid job' {
        @(Test-JobSchema (Get-ValidJob) '20261031-120000-aaaa').Count | Should Be 0
    }
    It 'rejects an unknown schema' {
        $j = Get-ValidJob; $j.schema = 2
        @(Test-JobSchema $j '20261031-120000-aaaa').Count | Should BeGreaterThan 0
    }
    It 'rejects a jobId that differs from the folder name' {
        @(Test-JobSchema (Get-ValidJob) '20261031-120000-ffff').Count | Should BeGreaterThan 0
    }
    It 'rejects a missing run field' {
        $j = Get-ValidJob; $j.runs[0].PSObject.Properties.Remove('seed')
        @(Test-JobSchema $j '20261031-120000-aaaa').Count | Should BeGreaterThan 0
    }
    It 'rejects a module name that could inject arguments' {
        $j = Get-ValidJob; $j.modules = @('Native', 'Evil *_MODULES_ /x')
        @(Test-JobSchema $j '20261031-120000-aaaa').Count | Should BeGreaterThan 0
    }
    It 'rejects a package file with a path' {
        $j = Get-ValidJob; $j.package.file = '..\package.zip'
        @(Test-JobSchema $j '20261031-120000-aaaa').Count | Should BeGreaterThan 0
    }
}

Describe 'run.cfg and launch arguments' {
    $run = [pscustomobject]@{ runId = 'r1'; seed = 7; days = 3; mode = 'NoDlc'; stallMinutes = 5; budgetMinutes = 60.5; hardTimeoutMinutes = 20 }
    It 'builds run.cfg with LF line endings and invariant numbers' {
        Get-RunCfgText $run | Should Be "seed=7`ndays=3`nmode=NoDlc`nstallMinutes=5`nbudgetMinutes=60.5`n"
    }
    It 'builds the _MODULES_ argument string' {
        Get-GameArguments -Prefix '/singleplayer' -Modules @('Bannerlord.Harmony', 'Native', 'CoherentWarAI') |
            Should Be '/singleplayer _MODULES_*Bannerlord.Harmony*Native*CoherentWarAI*_MODULES_'
    }
}

Describe 'Config patching' {
    It 'sets the three BannerlordConfig keys and keeps other lines and the BOM' {
        $rig = New-Rig
        $path = Join-Path $rig.Docs 'BannerlordConfig.txt'
        [System.IO.File]::WriteAllText($path, "Keep=1`r`nStopGameOnFocusLost=True`r`n", (New-Object System.Text.UTF8Encoding($true)))
        Set-BannerlordConfigValues $path
        $text = Read-Utf8Text $path
        $text | Should Match 'Keep=1'
        $text | Should Match 'StopGameOnFocusLost=False'
        $text | Should Match 'AutoSaveInterval=-1'
        $text | Should Match 'EnableTutorialHints=False'
        Test-Utf8Bom $path | Should Be $true
    }
    It 'writes the MCM json per feature flag' {
        $rig = New-Rig
        $path = Join-Path $rig.Docs 'mcm.json'
        Set-McmSettingsValues $path $false
        $o = Read-Utf8Text $path | ConvertFrom-Json
        $o.EnableChainOfCommand | Should Be $false
        $o.EnableNavalOrders | Should Be $false
        $o.EnableLogging | Should Be $true
        Set-McmSettingsValues $path $true
        (Read-Utf8Text $path | ConvertFrom-Json).EnableChainOfCommand | Should Be $true
    }
}

Describe 'Invoke-Job: rejection and preflight' {
    Mock Get-BannerlordProcess { return $null }

    It 'rejects an invalid job.json' {
        $rig = New-Rig
        $null = New-TestJob $rig -Mutate { param($j) $j['schema'] = 2 }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        $done.status | Should Be 'rejected'
        $done.schema | Should Be 1
    }
    It 'rejects a job.json that is not JSON' {
        $rig = New-Rig
        $dir = New-TestJob $rig
        [System.IO.File]::WriteAllText((Join-Path $dir 'job.json'), '{ not json', $utf8NoBom)
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).status | Should Be 'rejected'
    }
    It 'rejects a SHA-256 mismatch and installs nothing' {
        $rig = New-Rig
        $null = New-TestJob $rig -Mutate { param($j) $j['package']['sha256'] = ('0' * 64) }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).status | Should Be 'rejected'
        Test-Path (Join-Path $rig.Game 'Modules\CoherentWarAI') | Should Be $false
    }
    It 'rejects a non-allowlisted module before installing anything' {
        $rig = New-Rig
        $null = New-TestJob $rig -Entries @('Modules/CoherentWarAI/SubModule.xml', 'Modules/EvilMod/SubModule.xml')
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        $done.status | Should Be 'rejected'
        $done.message | Should Match 'EvilMod'
        Test-Path (Join-Path $rig.Game 'Modules\CoherentWarAI') | Should Be $false
        Test-Path (Join-Path $rig.Game 'Modules\EvilMod') | Should Be $false
    }
    It 'rejects a zip entry outside Modules\' {
        $rig = New-Rig
        $null = New-TestJob $rig -Entries @('Modules/CoherentWarAI/SubModule.xml', '../escape.txt')
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).status | Should Be 'rejected'
        Test-Path (Join-Path $rig.Game 'Modules\CoherentWarAI') | Should Be $false
    }
    It 'reports blocked when Bannerlord.exe is already running and installs nothing' {
        Mock Get-BannerlordProcess { return [pscustomobject]@{ Id = 4242 } }
        $rig = New-Rig
        $null = New-TestJob $rig
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).status | Should Be 'blocked'
        Test-Path (Join-Path $rig.Game 'Modules\CoherentWarAI') | Should Be $false
    }
    It 'reports blocked when gameExecutable is missing' {
        $rig = New-Rig
        $raw = [System.IO.File]::ReadAllText($rig.ConfigPath) | ConvertFrom-Json
        $raw.gameExecutable = Join-Path $rig.Root 'nope\Bannerlord.exe'
        [System.IO.File]::WriteAllText($rig.ConfigPath, ($raw | ConvertTo-Json), $utf8NoBom)
        $null = New-TestJob $rig
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).status | Should Be 'blocked'
    }
    It 'returns false when there is no job' {
        $rig = New-Rig
        Invoke-AgentCycle -Config (Get-ConfigFor $rig) | Should Be $false
    }
}

Describe 'Invoke-Job: end-to-end with a fake game' {
    Mock Get-BannerlordProcess { return $null }

    BeforeEach { $env:FAKEGAME_BEHAVIOR = 'complete' }
    AfterEach {
        Stop-FakeGameLeftovers
        Remove-Item Env:\FAKEGAME_BEHAVIOR -ErrorAction SilentlyContinue; Remove-Item Env:\FAKEGAME_DOCS -ErrorAction SilentlyContinue
        Remove-Item Env:\FAKEGAME_HARNESS -ErrorAction SilentlyContinue
        Remove-Item Env:\FAKEGAME_NOMODLOG -ErrorAction SilentlyContinue
    }

    It 'completes: installs, patches, runs, collects and writes done.json last' {
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $stale = Join-Path $rig.Game 'Modules\CoherentWarAI'
        New-Item -ItemType Directory -Path $stale -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $stale 'old.txt'), 'old', $utf8NoBom)
        $jobDir = New-TestJob $rig
        $harnessDir = Join-Path $rig.Docs 'Mount and Blade II Bannerlord\CoherentWarAI\harness'
        New-Item -ItemType Directory -Path $harnessDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $harnessDir 'result.txt'), 'status=Stale', $utf8NoBom)

        (Invoke-AgentCycle -Config (Get-ConfigFor $rig)) | Should Be $true

        $done = Read-Done $rig
        $done.status | Should Be 'completed'
        $done.runs[0].runId | Should Be 'r1'
        $done.runs[0].exitClass | Should Be 'Completed'

        $runDir = Join-Path $rig.Queue 'results\20261031-120000-aaaa\r1'
        $run = [System.IO.File]::ReadAllText((Join-Path $runDir 'agent-run.json')) | ConvertFrom-Json
        $run.exitClass | Should Be 'Completed'
        $run.pid | Should BeGreaterThan 0
        foreach ($name in @('result.txt', 'harness.log', 'CoherentWarAI.log')) {
            $run.artifacts -contains $name | Should Be $true
            Test-Path (Join-Path $runDir $name) | Should Be $true
        }
        (Get-Content -Raw (Join-Path $runDir 'result.txt')) | Should Match 'status=Completed'

        # install replaced the module
        Test-Path (Join-Path $stale 'old.txt') | Should Be $false
        Test-Path (Join-Path $stale 'SubModule.xml') | Should Be $true

        # what the fake game saw
        (Get-Content -Raw (Join-Path $rig.Docs 'fake-args.txt')).Trim() |
            Should Be '/singleplayer _MODULES_*Bannerlord.Harmony*Native*NavalDLC*CoherentWarAI*CoherentWarAI.TestHarness*_MODULES_'
        (Get-Content -Raw (Join-Path $rig.Docs 'fake-runcfg.txt')) | Should Match 'seed=7'

        # run.cfg removed after the run, configs patched
        Test-Path (Join-Path $harnessDir 'run.cfg') | Should Be $false
        $docs = Join-Path $rig.Docs 'Mount and Blade II Bannerlord'
        Read-Utf8Text (Join-Path $docs 'Configs\BannerlordConfig.txt') | Should Match 'AutoSaveInterval=-1'
        (Read-Utf8Text (Join-Path $docs 'Configs\ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json') | ConvertFrom-Json).EnableChainOfCommand | Should Be $true

        # done.json is the last thing written and no temp files remain
        $doneItem = Get-Item (Join-Path $rig.Queue 'results\20261031-120000-aaaa\done.json')
        $others = @(Get-ChildItem (Join-Path $rig.Queue 'results\20261031-120000-aaaa') -Recurse -File | Where-Object { $_.Name -ne 'done.json' })
        $others.Count | Should BeGreaterThan 0
        foreach ($f in $others) { $doneItem.LastWriteTimeUtc -ge $f.LastWriteTimeUtc | Should Be $true }
        $state = [System.IO.File]::ReadAllText((Join-Path $jobDir 'state.json')) | ConvertFrom-Json
        $state.state | Should Be 'finished'
        $doneItem.LastWriteTimeUtc -ge (Get-Item (Join-Path $jobDir 'state.json')).LastWriteTimeUtc | Should Be $true
        @(Get-ChildItem $rig.Queue -Recurse -Filter '*.tmp').Count | Should Be 0
        Test-Path (Join-Path $jobDir 'job.claimed.json') | Should Be $true
    }

    It 'turns the stale result.txt into NotCompleted when the game writes none' {
        $env:FAKEGAME_BEHAVIOR = 'noresult'
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $null = New-TestJob $rig
        $harnessDir = Join-Path $rig.Docs 'Mount and Blade II Bannerlord\CoherentWarAI\harness'
        New-Item -ItemType Directory -Path $harnessDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $harnessDir 'result.txt'), 'status=Completed', $utf8NoBom)
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'NotCompleted'
    }

    It 'classifies a long-running game as HardTimeout and kills it' {
        $env:FAKEGAME_BEHAVIOR = 'sleep'
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $null = New-TestJob $rig -Mutate { param($j) $j['runs'][0]['hardTimeoutMinutes'] = 0.05 }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        $done.status | Should Be 'completed'
        $done.runs[0].exitClass | Should Be 'HardTimeout'
        $run = Get-Content -Raw (Join-Path $rig.Queue 'results\20261031-120000-aaaa\r1\agent-run.json') | ConvertFrom-Json
        @(Get-Process -Id $run.pid -ErrorAction SilentlyContinue).Count | Should Be 0
        Test-Path (Join-Path $rig.Docs 'Mount and Blade II Bannerlord\CoherentWarAI\harness\run.cfg') | Should Be $false
    }

    It 'classifies the run Aborted when the abort file exists, kills the game and skips the rest' {
        $env:FAKEGAME_BEHAVIOR = 'sleep'
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $jobDir = New-TestJob $rig -Mutate {
            param($j)
            $second = [ordered]@{}
            foreach ($k in $j['runs'][0].Keys) { $second[$k] = $j['runs'][0][$k] }
            $second['runId'] = 'r2'
            $j['runs'] = @($j['runs'][0], $second)
        }
        # The abort file appears only once the game runs (abort is also checked before each launch).
        $watcher = Start-AbortWatcher -Rig $rig -JobDir $jobDir
        try { $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig) }
        finally { Remove-Job $watcher -Force }
        $done = Read-Done $rig
        $done.status | Should Be 'aborted'
        @($done.runs).Count | Should Be 1
        $done.runs[0].exitClass | Should Be 'Aborted'
        $run = Get-Content -Raw (Join-Path $rig.Queue 'results\20261031-120000-aaaa\r1\agent-run.json') | ConvertFrom-Json
        @(Get-Process -Id $run.pid -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    It 'accepts harness TestRig: run.cfg, run-result.json and harness.log live in the TestRig folder' {
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $env:FAKEGAME_HARNESS = 'TestRig'
        $null = New-TestRigHarnessJob $rig
        $docs = Join-Path $rig.Docs 'Mount and Blade II Bannerlord'

        (Invoke-AgentCycle -Config (Get-ConfigFor $rig)) | Should Be $true

        $done = Read-Done $rig
        $done.status | Should Be 'completed'
        $done.runs[0].exitClass | Should Be 'Completed'
        # the fake game read run.cfg from the TestRig folder; nothing was written to the other one
        (Get-Content -Raw (Join-Path $rig.Docs 'fake-runcfg.txt')) | Should Match 'seed=7'
        (Get-Content -Raw (Join-Path $rig.Docs 'fake-other-runcfg.txt')).Trim() | Should Be 'False'
        $runDir = Join-Path $rig.Queue 'results\20261031-120000-aaaa\r1'
        (Get-Content -Raw (Join-Path $runDir 'run-result.json')) | Should Match '"status":"Completed"'
        (Get-Content -Raw (Join-Path $runDir 'harness.log')) | Should Match 'harness started'
        $run = Get-Content -Raw (Join-Path $runDir 'agent-run.json') | ConvertFrom-Json
        $run.artifacts -contains 'run-result.json' | Should Be $true
        $run.artifacts -contains 'harness.log' | Should Be $true
        # run.cfg removed after the run, in both folders
        Test-Path (Join-Path $docs 'TestRig\harness\run.cfg') | Should Be $false
        Test-Path (Join-Path $docs 'CoherentWarAI\harness\run.cfg') | Should Be $false
    }

    It 'does not take a stale TestRig result.txt as this run result' {
        $env:FAKEGAME_BEHAVIOR = 'noresult'
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $env:FAKEGAME_HARNESS = 'TestRig'
        $null = New-TestRigHarnessJob $rig
        $trDir = Join-Path $rig.Docs 'Mount and Blade II Bannerlord\TestRig\harness'
        New-Item -ItemType Directory -Path $trDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $trDir 'result.txt'), 'status=Completed', $utf8NoBom)
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'NotCompleted'
    }

    It 'keeps CoherentWarAI behavior: run.cfg goes to the CoherentWarAI folder, nothing is created in TestRig' {
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $null = New-TestJob $rig
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'Completed'
        (Get-Content -Raw (Join-Path $rig.Docs 'fake-other-runcfg.txt')).Trim() | Should Be 'False'
        Test-Path (Join-Path $rig.Docs 'Mount and Blade II Bannerlord\TestRig') | Should Be $false
    }

    It 'classifies an unknown harness as SetupError without launching' {
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $null = New-TestJob $rig -Mutate { param($j) $j['runs'][0]['harness'] = 'Other' }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'SetupError'
        Test-Path (Join-Path $rig.Docs 'fake-args.txt') | Should Be $false
    }

    It 'classifies a TestRig run as SetupError without launching when TestRig.Harness is not in the package' {
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $env:FAKEGAME_HARNESS = 'TestRig'
        $null = New-TestRigHarnessJob $rig -Entries @('Modules/CoherentWarAI/SubModule.xml')
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'SetupError'
        $run = Get-Content -Raw (Join-Path $rig.Queue 'results\20261031-120000-aaaa\r1\agent-run.json') | ConvertFrom-Json
        $run.message | Should Match 'TestRig\.Harness'
        Test-Path (Join-Path $rig.Docs 'fake-args.txt') | Should Be $false
    }

    It 'classifies a TestRig run as SetupError without launching when TestRig.Harness is not in job.modules' {
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $env:FAKEGAME_HARNESS = 'TestRig'
        $null = New-TestRigHarnessJob $rig -Modules @('Native', 'CoherentWarAI')
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'SetupError'
        $run = Get-Content -Raw (Join-Path $rig.Queue 'results\20261031-120000-aaaa\r1\agent-run.json') | ConvertFrom-Json
        $run.message | Should Match 'TestRig\.Harness'
        Test-Path (Join-Path $rig.Docs 'fake-args.txt') | Should Be $false
    }

    It 'completes a TestRig run without CoherentWarAI.log (the mod log is not a harness artifact)' {
        $env:FAKEGAME_NOMODLOG = '1'
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $env:FAKEGAME_HARNESS = 'TestRig'
        $null = New-TestRigHarnessJob $rig
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'Completed'
        $run = Get-Content -Raw (Join-Path $rig.Queue 'results\20261031-120000-aaaa\r1\agent-run.json') | ConvertFrom-Json
        $run.artifacts -contains 'CoherentWarAI.log' | Should Be $false
        $run.artifacts -contains 'run-result.json' | Should Be $true
    }

    It 'processes one job with Invoke-AgentMain -Once' {
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $null = New-TestJob $rig
        Invoke-AgentMain -ConfigPath $rig.ConfigPath -Once
        (Read-Done $rig).status | Should Be 'completed'
        Test-Path (Join-Path $rig.Work 'agent.log') | Should Be $true
    }
}

Describe 'Get-ResultStatus: run-result.json with result.txt fallback' {
    BeforeEach {
        $script:hd = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:hd -Force | Out-Null
        $script:logged = @()
        Mock Write-AgentLog { $script:logged += $Message }
    }
    function Set-HarnessFile([string]$Name, [string]$Text) { [System.IO.File]::WriteAllText((Join-Path $script:hd $Name), $Text, $utf8NoBom) }

    It 'reads status from run-result.json' {
        Set-HarnessFile 'run-result.json' '{"schema":1,"status":"Completed","daysReached":1}'
        Get-ResultStatus $script:hd | Should Be 'Completed'
    }
    It 'prefers run-result.json over result.txt' {
        Set-HarnessFile 'run-result.json' '{"schema":1,"status":"Aborted"}'
        Set-HarnessFile 'result.txt' 'status=Completed'
        Get-ResultStatus $script:hd | Should Be 'Aborted'
    }
    It 'falls back to result.txt when there is no run-result.json' {
        Set-HarnessFile 'result.txt' "status=Completed`r`ndaysReached=1`r`n"
        Get-ResultStatus $script:hd | Should Be 'Completed'
    }
    It 'falls back to result.txt with CRLF line endings' {
        Set-HarnessFile 'result.txt' "daysReached=1`r`nstatus=Aborted`r`n"
        Get-ResultStatus $script:hd | Should Be 'Aborted'
    }
    It 'falls back to result.txt with LF-only line endings (no CR)' {
        Set-HarnessFile 'result.txt' "daysReached=1`nstatus=Aborted`ndetail=x`n"
        Get-ResultStatus $script:hd | Should Be 'Aborted'
    }
    foreach ($case in @(
            @{ Name = 'an array'; Json = '[{"status":"Completed"}]' },
            @{ Name = 'an empty array'; Json = '[]' },
            @{ Name = 'a number'; Json = '5' },
            @{ Name = 'a string'; Json = '"Completed"' },
            @{ Name = 'null'; Json = 'null' })) {
        It ('treats a run-result.json whose top level is ' + $case.Name + ' as no result (no fallback) and logs once') {
            Set-HarnessFile 'run-result.json' $case.Json
            Set-HarnessFile 'result.txt' 'status=Completed'
            Get-ResultStatus $script:hd | Should Be $null
            @($script:logged | Where-Object { $_ -match 'run-result\.json' }).Count | Should Be 1
        }
    }
    It 'returns null when neither file exists' {
        Get-ResultStatus $script:hd | Should Be $null
    }
    It 'treats invalid JSON as no result (no fallback to result.txt) and logs once' {
        Set-HarnessFile 'run-result.json' '{ not json'
        Set-HarnessFile 'result.txt' 'status=Completed'
        Get-ResultStatus $script:hd | Should Be $null
        @($script:logged | Where-Object { $_ -match 'run-result\.json' }).Count | Should Be 1
    }
    It 'treats JSON without a status string as no result (no fallback to result.txt)' {
        Set-HarnessFile 'run-result.json' '{"schema":1,"status":null}'
        Set-HarnessFile 'result.txt' 'status=Completed'
        Get-ResultStatus $script:hd | Should Be $null
    }
    foreach ($json in @('{"schema":1,"status":5}', '{"schema":1,"status":true}', '{"schema":1,"status":""}', '{"schema":1}')) {
        It "treats run-result.json $json as no result (no fallback to result.txt)" {
            Set-HarnessFile 'run-result.json' $json
            Set-HarnessFile 'result.txt' 'status=Completed'
            Get-ResultStatus $script:hd | Should Be $null
        }
    }
}

Describe 'ownAssemblies for run.cfg' {
    function New-ModuleXml([string]$Root, [string]$Id, [string[]]$Dlls, [string]$Raw = $null) {
        $d = Join-Path $Root $Id
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        if (-not $Raw) {
            $subs = ($Dlls | ForEach-Object { '<SubModule><Name>x</Name><DLLName value="' + $_ + '"/></SubModule>' }) -join ''
            $Raw = '<Module><Name value="' + $Id + '"/><SubModules>' + $subs + '</SubModules></Module>'
        }
        [System.IO.File]::WriteAllText((Join-Path $d 'SubModule.xml'), $Raw, $utf8NoBom)
    }
    BeforeEach {
        $script:mods = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:mods -Force | Out-Null
        $script:logged = @()
        Mock Write-AgentLog { $script:logged += $Message }
    }
    $run = [pscustomobject]@{ runId = 'r1'; seed = 7; days = 3; mode = 'NoDlc'; stallMinutes = 5; budgetMinutes = 60; hardTimeoutMinutes = 20 }

    It 'strips .dll, keeps order, de-duplicates case-insensitively across modules' {
        New-ModuleXml $script:mods 'A' @('Alpha.dll', 'Beta.DLL')
        New-ModuleXml $script:mods 'B' @('alpha.dll', 'Gamma')
        (Get-OwnAssemblyNames -ModulesDir $script:mods -ModuleIds @('A', 'B') -HarnessModuleIds @('TestRig.Harness')) -join ',' | Should Be 'Alpha,Beta,Gamma'
    }
    It 'excludes harness modules' {
        New-ModuleXml $script:mods 'A' @('Alpha.dll')
        New-ModuleXml $script:mods 'TestRig.Harness' @('TestRig.Harness.dll')
        New-ModuleXml $script:mods 'CoherentWarAI.TestHarness' @('CoherentWarAI.TestHarness.dll')
        (Get-OwnAssemblyNames -ModulesDir $script:mods -ModuleIds @('A', 'TestRig.Harness', 'CoherentWarAI.TestHarness') -HarnessModuleIds @('CoherentWarAI.TestHarness', 'TestRig.Harness')) -join ',' | Should Be 'Alpha'
    }
    It 'skips a module with missing or unparseable SubModule.xml and logs it' {
        New-ModuleXml $script:mods 'Bad' @() '<Module><unclosed>'
        New-ModuleXml $script:mods 'Good' @('Good.dll')
        $r = @(Get-OwnAssemblyNames -ModulesDir $script:mods -ModuleIds @('Missing', 'Bad', 'Good') -HarnessModuleIds @())
        ($r -join ',') | Should Be 'Good'
        @($script:logged | Where-Object { $_ -match 'Missing' }).Count | Should Be 1
        @($script:logged | Where-Object { $_ -match 'Bad' }).Count | Should Be 1
    }
    It 'returns an empty list for a module without DLLName' {
        New-ModuleXml $script:mods 'DataOnly' @()
        @(Get-OwnAssemblyNames -ModulesDir $script:mods -ModuleIds @('DataOnly') -HarnessModuleIds @()).Count | Should Be 0
    }
    It 'skips DLL names that would corrupt run.cfg, logs one line each, and keeps valid names' {
        New-ModuleXml $script:mods 'A' @('Bad,Name.dll', 'x=y.dll', 'Good.dll', 'Sp ace.dll', 'Uml&#228;ut.dll')
        $r = @(Get-OwnAssemblyNames -ModulesDir $script:mods -ModuleIds @('A') -HarnessModuleIds @())
        ($r -join ',') | Should Be 'Good'
        @($script:logged | Where-Object { $_ -match 'Bad,Name' }).Count | Should Be 1
        @($script:logged | Where-Object { $_ -match 'x=y' }).Count | Should Be 1
        @($script:logged | Where-Object { $_ -match 'ownAssemblies' }).Count | Should Be 4
    }
    It 'skips a DLL name containing a line break' {
        New-ModuleXml $script:mods 'A' @('Evil&#10;injected=1.dll', 'Good.dll')
        $r = @(Get-OwnAssemblyNames -ModulesDir $script:mods -ModuleIds @('A') -HarnessModuleIds @())
        ($r -join ',') | Should Be 'Good'
        @($script:logged).Count | Should Be 1
    }
    It 'adds the ownAssemblies line to run.cfg only when names are given' {
        Get-RunCfgText $run -OwnAssemblies @('A', 'B') | Should Be "seed=7`ndays=3`nmode=NoDlc`nstallMinutes=5`nbudgetMinutes=60`nownAssemblies=A,B`n"
        Get-RunCfgText $run -OwnAssemblies @() | Should Be "seed=7`ndays=3`nmode=NoDlc`nstallMinutes=5`nbudgetMinutes=60`n"
        Get-RunCfgText $run | Should Be "seed=7`ndays=3`nmode=NoDlc`nstallMinutes=5`nbudgetMinutes=60`n"
    }
}

Describe 'Invoke-Job: run-result.json end-to-end with a fake game' {
    Mock Get-BannerlordProcess { return $null }
    BeforeEach { $env:FAKEGAME_BEHAVIOR = 'complete' }
    AfterEach {
        Stop-FakeGameLeftovers
        Remove-Item Env:\FAKEGAME_BEHAVIOR -ErrorAction SilentlyContinue; Remove-Item Env:\FAKEGAME_DOCS -ErrorAction SilentlyContinue
        Remove-Item Env:\FAKEGAME_HARNESS -ErrorAction SilentlyContinue
    }
    function Get-TrDir($rig) { Join-Path $rig.Docs 'Mount and Blade II Bannerlord\TestRig\harness' }
    function Get-RunDir($rig) { Join-Path $rig.Queue 'results\20261031-120000-aaaa\r1' }
    function Start-TrRig([string]$Behavior = 'complete') {
        $env:FAKEGAME_BEHAVIOR = $Behavior
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $env:FAKEGAME_HARNESS = 'TestRig'
        $null = New-TestRigHarnessJob $rig
        return $rig
    }

    It 'completes a TestRig run from run-result.json and collects it' {
        $rig = Start-TrRig
        (Invoke-AgentCycle -Config (Get-ConfigFor $rig)) | Should Be $true
        (Read-Done $rig).runs[0].exitClass | Should Be 'Completed'
        $json = Get-Content -Raw (Join-Path (Get-RunDir $rig) 'run-result.json') | ConvertFrom-Json
        $json.status | Should Be 'Completed'
        $json.scenarios[0].id | Should Be 'soak'
        $run = Get-Content -Raw (Join-Path (Get-RunDir $rig) 'agent-run.json') | ConvertFrom-Json
        $run.artifacts -contains 'run-result.json' | Should Be $true
        $run.artifacts -contains 'result.txt' | Should Be $false
        Test-Path (Join-Path (Get-TrDir $rig) 'run-result.json.tmp') | Should Be $false
    }
    It 'falls back to result.txt for a TestRig run without run-result.json' {
        $rig = Start-TrRig 'txtonly'
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'Completed'
        $run = Get-Content -Raw (Join-Path (Get-RunDir $rig) 'agent-run.json') | ConvertFrom-Json
        $run.artifacts -contains 'result.txt' | Should Be $true
        $run.artifacts -contains 'run-result.json' | Should Be $false
    }
    It 'classifies invalid run-result.json as NotCompleted' {
        $rig = Start-TrRig 'badjson'
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'NotCompleted'
    }
    It 'clears a stale run-result.json, run-result.json.tmp and result.txt before the launch' {
        $rig = Start-TrRig 'noresult'
        $trDir = Get-TrDir $rig
        New-Item -ItemType Directory -Path $trDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $trDir 'run-result.json'), '{"schema":1,"status":"Completed"}', $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $trDir 'run-result.json.tmp'), '{', $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $trDir 'result.txt'), 'status=Completed', $utf8NoBom)
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'NotCompleted'
        Test-Path (Join-Path $trDir 'run-result.json') | Should Be $false
        Test-Path (Join-Path $trDir 'run-result.json.tmp') | Should Be $false
    }
    It 'writes ownAssemblies from the installed SubModule.xml of non-harness modules (TestRig only)' {
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $env:FAKEGAME_HARNESS = 'TestRig'
        $jobDir = New-TestRigHarnessJob $rig
        Set-JobPackageWithValidXml $jobDir

        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'Completed'
        (Get-Content -Raw (Join-Path $rig.Docs 'fake-ownassemblies.txt')).Trim() | Should Be 'ownAssemblies=CoherentWarAI,Extra'
    }
    It 'does not give the CoherentWarAI harness an ownAssemblies line' {
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        # Valid SubModule.xml with DLLs: without the harness choice, ownAssemblies=CoherentWarAI,Extra would be written.
        $jobDir = New-TestJob $rig
        Set-JobPackageWithValidXml $jobDir -HarnessModuleId 'CoherentWarAI.TestHarness'
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'Completed'
        (Get-Content -Raw (Join-Path $rig.Docs 'fake-runcfg.txt')) | Should Not Match 'ownAssemblies'
        [System.IO.File]::ReadAllText((Join-Path $rig.Docs 'fake-ownassemblies.txt')) | Should Be ''
    }
}

Describe 'Invoke-Job: unexpected errors' {
    Mock Get-BannerlordProcess { return $null }

    It 'reports failed with the message when an unexpected error occurs' {
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $null = New-TestJob $rig
        Mock Install-JobModules { throw 'disk exploded' }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        $done.status | Should Be 'failed'
        $done.message | Should Match 'disk exploded'
    }
}

# ---------------------------------------------------------------------------
# Review hardening (C1, C2, W1-W4, S1-S7 and test gaps)
# ---------------------------------------------------------------------------

Describe 'Test-JobSchema: bounds, strict patterns, package file' {
    $id = '20261031-120000-aaaa'
    It 'accepts the upper bounds (C1)' {
        $j = Get-ValidJobObject
        $j.runs[0].hardTimeoutMinutes = 1440; $j.runs[0].stallMinutes = 1440; $j.runs[0].budgetMinutes = 1440; $j.runs[0].days = 3650
        @(Test-JobSchema $j $id).Count | Should Be 0
    }
    It 'rejects hardTimeoutMinutes = 10000000000 (C1)' {
        $j = Get-ValidJobObject; $j.runs[0].hardTimeoutMinutes = 10000000000
        @(Test-JobSchema $j $id).Count | Should BeGreaterThan 0
    }
    It 'rejects hardTimeoutMinutes = 1441 (C1)' {
        $j = Get-ValidJobObject; $j.runs[0].hardTimeoutMinutes = 1441
        @(Test-JobSchema $j $id).Count | Should BeGreaterThan 0
    }
    It 'rejects stallMinutes = 1441 (C1)' {
        $j = Get-ValidJobObject; $j.runs[0].stallMinutes = 1441
        @(Test-JobSchema $j $id).Count | Should BeGreaterThan 0
    }
    It 'rejects budgetMinutes = 1441 (C1)' {
        $j = Get-ValidJobObject; $j.runs[0].budgetMinutes = 1441
        @(Test-JobSchema $j $id).Count | Should BeGreaterThan 0
    }
    It 'rejects days = 3651 (C1)' {
        $j = Get-ValidJobObject; $j.runs[0].days = 3651
        @(Test-JobSchema $j $id).Count | Should BeGreaterThan 0
    }
    It 'rejects a jobId with a trailing newline (S1)' {
        $j = Get-ValidJobObject; $j.jobId = "$id`n"
        @(Test-JobSchema $j "$id`n").Count | Should BeGreaterThan 0
    }
    It 'rejects a runId with a trailing newline (S1)' {
        $j = Get-ValidJobObject; $j.runs[0].runId = "r1`n"
        @(Test-JobSchema $j $id).Count | Should BeGreaterThan 0
    }
    It 'rejects a module name with a trailing newline (S1)' {
        $j = Get-ValidJobObject; $j.modules = @("Native`n")
        @(Test-JobSchema $j $id).Count | Should BeGreaterThan 0
    }
    It 'rejects a sha256 with a trailing newline (S1)' {
        $j = Get-ValidJobObject; $j.package.sha256 = ('A' * 64) + "`n"
        @(Test-JobSchema $j $id).Count | Should BeGreaterThan 0
    }
    It 'rejects package.file = ".." (S2)' {
        $j = Get-ValidJobObject; $j.package.file = '..'
        @(Test-JobSchema $j $id).Count | Should BeGreaterThan 0
    }
    It 'rejects a package.file that is not a .zip (S2)' {
        $j = Get-ValidJobObject; $j.package.file = 'package.txt'
        @(Test-JobSchema $j $id).Count | Should BeGreaterThan 0
    }
}

Describe 'Get-PackageModuleIds: zip-slip variants' {
    function Get-ZipErrorCount {
        param([string[]]$Entries)
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.zip')
        New-ZipFile -Path $path -Entries $Entries
        return @((Get-PackageModuleIds $path).Errors).Count
    }
    It 'flags Modules/CoherentWarAI/../../x' {
        Get-ZipErrorCount @('Modules/CoherentWarAI/SubModule.xml', 'Modules/CoherentWarAI/../../x') | Should BeGreaterThan 0
    }
    It 'flags an absolute path' {
        Get-ZipErrorCount @('Modules/CoherentWarAI/SubModule.xml', '/abs') | Should BeGreaterThan 0
    }
    It 'flags a drive path' {
        Get-ZipErrorCount @('Modules/CoherentWarAI/SubModule.xml', 'C:/x') | Should BeGreaterThan 0
    }
    It 'flags backslash traversal' {
        Get-ZipErrorCount @('Modules/CoherentWarAI/SubModule.xml', 'Modules\CoherentWarAI\..\..\x') | Should BeGreaterThan 0
    }
}

Describe 'Test-ModuleAllowed: protected vanilla modules (S5)' {
    foreach ($name in @('Native', 'SandBox', 'SandBoxCore', 'StoryMode', 'CustomBattle', 'BirthAndDeath', 'Multiplayer', 'NavalDLC',
            'Bannerlord.Harmony', 'Bannerlord.ButterLib', 'Bannerlord.UIExtenderEx', 'Bannerlord.MBOptionScreen')) {
        It "never allows $name, even when allowlisted" {
            Test-ModuleAllowed $name @($name, '*') | Should Be $false
        }
    }
    It 'matches protected names case-insensitively' {
        Test-ModuleAllowed 'native' @('*') | Should Be $false
    }
}

Describe 'Get-AgentConfig: validation (S6)' {
    It 'rejects pollSeconds 0' {
        $rig = New-Rig; Set-RigConfigValue $rig 'pollSeconds' 0
        { Get-ConfigFor $rig } | Should Throw
    }
    It 'rejects pollSeconds 301' {
        $rig = New-Rig; Set-RigConfigValue $rig 'pollSeconds' 301
        { Get-ConfigFor $rig } | Should Throw
    }
    It 'rejects a non-numeric pollSeconds' {
        $rig = New-Rig; Set-RigConfigValue $rig 'pollSeconds' 'soon'
        { Get-ConfigFor $rig } | Should Throw
    }
    It 'accepts the bounds 1 and 300' {
        $rig = New-Rig
        Set-RigConfigValue $rig 'pollSeconds' 300
        (Get-ConfigFor $rig).pollSeconds | Should Be 300
        Set-RigConfigValue $rig 'pollSeconds' 1
        (Get-ConfigFor $rig).pollSeconds | Should Be 1
    }
    It 'makes Invoke-AgentMain return 1 on a config error' {
        $rig = New-Rig; Set-RigConfigValue $rig 'pollSeconds' 0
        Invoke-AgentMain -ConfigPath $rig.ConfigPath -Once | Should Be 1
    }
    It 'defaults heartbeatSeconds to 10 and rejects values outside 1..15' {
        $rig = New-Rig
        (Get-ConfigFor $rig).heartbeatSeconds | Should Be 10
        Set-RigConfigValue $rig 'heartbeatSeconds' 16
        { Get-ConfigFor $rig } | Should Throw
        Set-RigConfigValue $rig 'heartbeatSeconds' 0
        { Get-ConfigFor $rig } | Should Throw
    }
}

Describe 'Write-JsonAtomic (W1)' {
    # Order matters: the Move-Item mock in the second test stays active until the end of the Describe.
    It 'creates a missing target' {
        $p = Join-Path $TestDrive 'fresh.json'
        Write-JsonAtomic $p @{ a = 3 }
        ((Get-Content -Raw -LiteralPath $p) | ConvertFrom-Json).a | Should Be 3
    }
    It 'replaces an existing file without Move-Item (no window without the target)' {
        $p = Join-Path $TestDrive 'atomic.json'
        Write-JsonAtomic $p @{ a = 1 }
        Mock Move-Item { throw 'Move-Item -Force deletes the target first' }
        Write-JsonAtomic $p @{ a = 2 }
        ((Get-Content -Raw -LiteralPath $p) | ConvertFrom-Json).a | Should Be 2
        Test-Path -LiteralPath ($p + '.tmp') | Should Be $false
    }
}

Describe 'Stop-ProcessTree heartbeat (W2)' {
    It 'calls the heartbeat between wait slices while the game does not exit' {
        Mock Invoke-TaskKillTree { return 0 }   # taskkill does nothing: the wait must slice
        $p = Start-Process -FilePath $powershellExe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -NoNewWindow
        try {
            $counter = @{ n = 0 }
            $result = Stop-ProcessTree $p -WaitMilliseconds 7000 -Heartbeat { $counter.n++ }.GetNewClosure()
            $counter.n | Should BeGreaterThan 0
            $result | Should Be $true
        }
        finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Resolve-OrphanedJobs at startup (W3)' {
    It 'writes done.json failed for a claimed job without done.json, removes run.cfg and logs both' {
        $rig = New-Rig
        $dirA = New-TestJob $rig '20261031-110000-bbbb'
        Rename-Item (Join-Path $dirA 'job.json') 'job.claimed.json'
        $dirB = New-TestJob $rig '20261031-120000-aaaa'
        Rename-Item (Join-Path $dirB 'job.json') 'job.claimed.json'
        $resB = Join-Path $rig.Queue 'results\20261031-120000-aaaa'
        New-Item -ItemType Directory -Path $resB -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $resB 'done.json'), '{"schema":1,"status":"completed"}', $utf8NoBom)
        $harnessDir = Join-Path $rig.Docs 'Mount and Blade II Bannerlord\CoherentWarAI\harness'
        New-Item -ItemType Directory -Path $harnessDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $harnessDir 'run.cfg'), 'seed=1', $utf8NoBom)

        Invoke-AgentMain -ConfigPath $rig.ConfigPath -Once | Should Be 0

        $doneA = Read-Done $rig '20261031-110000-bbbb'
        $doneA.status | Should Be 'failed'
        $doneA.message | Should Be 'agent restarted during job'
        $doneA.schema | Should Be 1
        $doneA.jobId | Should Be '20261031-110000-bbbb'
        (Read-Done $rig '20261031-120000-aaaa').status | Should Be 'completed'
        Test-Path (Join-Path $harnessDir 'run.cfg') | Should Be $false
        $log = Get-Content -Raw (Join-Path $rig.Work 'agent.log')
        $log | Should Match '20261031-110000-bbbb'
        $log | Should Match 'run\.cfg'
    }

    It 'removes a leftover run.cfg from the TestRig folder too' {
        $rig = New-Rig
        $dirA = New-TestJob $rig '20261031-110000-bbbb'
        Rename-Item (Join-Path $dirA 'job.json') 'job.claimed.json'
        $trDir = Join-Path $rig.Docs 'Mount and Blade II Bannerlord\TestRig\harness'
        New-Item -ItemType Directory -Path $trDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $trDir 'run.cfg'), 'seed=1', $utf8NoBom)

        Invoke-AgentMain -ConfigPath $rig.ConfigPath -Once | Should Be 0

        Test-Path (Join-Path $trDir 'run.cfg') | Should Be $false
        (Get-Content -Raw (Join-Path $rig.Work 'agent.log')) | Should Match 'Removed leftover harness run\.cfg'
    }

    It 'removes leftover run.cfg files from both folders in one startup' {
        $rig = New-Rig
        $dirA = New-TestJob $rig '20261031-110000-bbbb'
        Rename-Item (Join-Path $dirA 'job.json') 'job.claimed.json'
        $docs = Join-Path $rig.Docs 'Mount and Blade II Bannerlord'
        $dirs = @((Join-Path $docs 'CoherentWarAI\harness'), (Join-Path $docs 'TestRig\harness'))
        foreach ($d in $dirs) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $d 'run.cfg'), 'seed=1', $utf8NoBom)
        }

        Invoke-AgentMain -ConfigPath $rig.ConfigPath -Once | Should Be 0

        foreach ($d in $dirs) { Test-Path (Join-Path $d 'run.cfg') | Should Be $false }
    }
}

Describe 'Invoke-Job: hardening end-to-end' {
    Mock Get-BannerlordProcess { return $null }

    BeforeEach { $env:FAKEGAME_BEHAVIOR = 'complete' }
    AfterEach {
        Stop-FakeGameLeftovers
        Remove-Item Env:\FAKEGAME_BEHAVIOR -ErrorAction SilentlyContinue; Remove-Item Env:\FAKEGAME_DOCS -ErrorAction SilentlyContinue
    }

    It 'rejects hardTimeoutMinutes = 10000000000 without launching (C1)' {
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        $null = New-TestJob $rig -Mutate { param($j) $j['runs'][0]['hardTimeoutMinutes'] = 10000000000 }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).status | Should Be 'rejected'
        Test-Path (Join-Path $rig.Docs 'fake-args.txt') | Should Be $false
    }

    It 'fails the run before Start-Process when the deadline cannot be computed (C1)' {
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        $run = [pscustomobject]@{ runId = 'r1'; kind = 'soak'; harness = 'CoherentWarAI'; seed = 1; days = 1; mode = 'WarSails'
            stallMinutes = 5; budgetMinutes = 60; hardTimeoutMinutes = 10000000000 }
        $resultsDir = Join-Path $rig.Root 'res'
        $ctx = @{ JobId = '20261031-120000-aaaa'; JobDir = $rig.Root; ResultsDir = $resultsDir; Beat = 0; RunCount = 1 }
        $rec = Invoke-Run -Config (Get-ConfigFor $rig) -Context $ctx -Run $run -Modules @('Native', 'CoherentWarAI.TestHarness') -PackageModuleIds @('CoherentWarAI.TestHarness') -RunIndex 1 -ResultsDir $resultsDir
        $rec.exitClass | Should Be 'SetupError'
        Test-Path (Join-Path $rig.Docs 'fake-args.txt') | Should Be $false
        Test-Path (Join-Path (Get-RigHarnessDir $rig) 'run.cfg') | Should Be $false
    }

    It 'kills the whole process tree on HardTimeout: parent and child are gone' {
        $env:FAKEGAME_BEHAVIOR = 'child'
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        $null = New-TestJob $rig -Mutate { param($j) $j['runs'][0]['hardTimeoutMinutes'] = 0.2 }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        $done.runs[0].exitClass | Should Be 'HardTimeout'
        $childFile = Join-Path $rig.Docs 'child-pid.txt'
        Test-Path $childFile | Should Be $true
        $childPid = [int](Get-Content -Raw $childFile)
        $run = Get-Content -Raw (Join-Path $rig.Queue 'results\20261031-120000-aaaa\r1\agent-run.json') | ConvertFrom-Json
        @(Get-Process -Id $run.pid -ErrorAction SilentlyContinue).Count | Should Be 0
        @(Get-Process -Id $childPid -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    It 'rises the heartbeat beat during a run with an injected 1 s interval' {
        $env:FAKEGAME_BEHAVIOR = 'slow'
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        Set-RigConfigValue $rig 'heartbeatSeconds' 1
        $jobDir = New-TestJob $rig
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).status | Should Be 'completed'
        $state = [System.IO.File]::ReadAllText((Join-Path $jobDir 'state.json')) | ConvertFrom-Json
        # claimed + installing x2 + collecting + finished = 5 writes; the 6+ s run adds at least 5 running beats
        $state.beat | Should BeGreaterThan 9
    }

    It 'writes JSON without BOM and null (not empty strings) for absent values (W4)' {
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        $jobDir = New-TestJob $rig
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $resultsDir = Join-Path $rig.Queue 'results\20261031-120000-aaaa'
        foreach ($f in @((Join-Path $resultsDir 'done.json'), (Join-Path $jobDir 'state.json'), (Join-Path $resultsDir 'r1\agent-run.json'))) {
            $bytes = [System.IO.File]::ReadAllBytes($f)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $false
        }
        $stateText = [System.IO.File]::ReadAllText((Join-Path $jobDir 'state.json'))
        $stateText | Should Match '"runId":\s*null'
        $stateText | Should Match '"message":\s*null'
        $stateText | Should Not Match '"runId":\s*""'
        [System.IO.File]::ReadAllText((Join-Path $resultsDir 'done.json')) | Should Match '"message":\s*null'
    }

    It 'rejects a missing package.zip (S3)' {
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        $jobDir = New-TestJob $rig
        Remove-Item (Join-Path $jobDir 'package.zip')
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).status | Should Be 'rejected'
    }

    It 'rejects a corrupt package.zip with a matching hash (S3)' {
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        $jobDir = New-TestJob $rig
        $zip = Join-Path $jobDir 'package.zip'
        [System.IO.File]::WriteAllText($zip, 'this is not a zip file', $utf8NoBom)
        $job = [System.IO.File]::ReadAllText((Join-Path $jobDir 'job.json')) | ConvertFrom-Json
        $job.package.sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        [System.IO.File]::WriteAllText((Join-Path $jobDir 'job.json'), ($job | ConvertTo-Json -Depth 10), $utf8NoBom)
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).status | Should Be 'rejected'
    }

    It 'finishes aborted without installing or launching when abort exists before the job starts (S4)' {
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        $jobDir = New-TestJob $rig
        New-Item -ItemType File -Path (Join-Path $jobDir 'abort') | Out-Null
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        $done.status | Should Be 'aborted'
        @($done.runs).Count | Should Be 0
        Test-Path (Join-Path $rig.Docs 'fake-args.txt') | Should Be $false
        Test-Path (Join-Path $rig.Game 'Modules\CoherentWarAI') | Should Be $false
    }

    It 'rejects a protected vanilla module in the package even if the config allowlists it (S5)' {
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        Set-RigConfigValue $rig 'moduleAllowlist' @('CoherentWarAI', 'Native')
        $null = New-TestJob $rig -Entries @('Modules/CoherentWarAI/SubModule.xml', 'Modules/Native/SubModule.xml')
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        $done.status | Should Be 'rejected'
        $done.message | Should Match 'Native'
        Test-Path (Join-Path $rig.Game 'Modules\Native') | Should Be $false
        Test-Path (Join-Path $rig.Game 'Modules\CoherentWarAI') | Should Be $false
    }

}

Describe 'Invoke-Run: supervision failure after launch (C1)' {
    Mock Get-BannerlordProcess { return $null }

    BeforeEach { $env:FAKEGAME_BEHAVIOR = 'complete' }
    AfterEach {
        Stop-FakeGameLeftovers
        Remove-Item Env:\FAKEGAME_BEHAVIOR -ErrorAction SilentlyContinue; Remove-Item Env:\FAKEGAME_DOCS -ErrorAction SilentlyContinue
    }

    It 'kills the game and removes run.cfg when supervision throws after launch (C1)' {
        $env:FAKEGAME_BEHAVIOR = 'sleep'
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        $null = New-TestJob $rig
        Mock Get-LastLogLine { throw 'boom' }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        @($done.runs).Count | Should Be 1
        $run = Get-Content -Raw (Join-Path $rig.Queue 'results\20261031-120000-aaaa\r1\agent-run.json') | ConvertFrom-Json
        @(Get-Process -Id $run.pid -ErrorAction SilentlyContinue).Count | Should Be 0
        Test-Path (Join-Path (Get-RigHarnessDir $rig) 'run.cfg') | Should Be $false
    }
}

Describe 'Invoke-Job: failed kill stops the job (C2)' {
    Mock Get-BannerlordProcess { return $null }

    BeforeEach { $env:FAKEGAME_BEHAVIOR = 'complete' }
    AfterEach {
        Stop-FakeGameLeftovers
        Remove-Item Env:\FAKEGAME_BEHAVIOR -ErrorAction SilentlyContinue; Remove-Item Env:\FAKEGAME_DOCS -ErrorAction SilentlyContinue
    }

    It 'stops the job after an abort whose kill failed: aborted + CleanupFailed, no second game (C2)' {
        $env:FAKEGAME_BEHAVIOR = 'sleep'
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        $jobDir = New-TestJob $rig -Mutate { param($j) Add-SecondRun $j }
        Mock Stop-ProcessTree { try { $Process.Kill() } catch { }; return $false }
        $watcher = Start-AbortWatcher -Rig $rig -JobDir $jobDir
        try { $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig) }
        finally { Remove-Job $watcher -Force }
        $done = Read-Done $rig
        $done.status | Should Be 'aborted'
        @($done.runs).Count | Should Be 1
        $done.runs[0].exitClass | Should Be 'CleanupFailed'
    }


    It 'stops the job after a HardTimeout whose kill failed: no second game, CleanupFailed (C2)' {
        $env:FAKEGAME_BEHAVIOR = 'sleep'
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        $null = New-TestJob $rig -Mutate { param($j) Add-SecondRun $j 0.05 }
        Mock Stop-ProcessTree { try { $Process.Kill() } catch { }; return $false }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        @($done.runs).Count | Should Be 1
        $done.runs[0].exitClass | Should Be 'CleanupFailed'
        $done.status | Should Be 'failed'
    }
}

Describe 'Invoke-Job: state names (S7)' {
    Mock Get-BannerlordProcess { return $null }

    BeforeEach { $env:FAKEGAME_BEHAVIOR = 'complete' }
    AfterEach {
        Stop-FakeGameLeftovers
        Remove-Item Env:\FAKEGAME_BEHAVIOR -ErrorAction SilentlyContinue; Remove-Item Env:\FAKEGAME_DOCS -ErrorAction SilentlyContinue
    }

    It 'never reports the state "preflight" and uses installing during per-run setup (S7)' {
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        $null = New-TestJob $rig
        Mock Write-JobState { }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        Assert-MockCalled Write-JobState -Exactly -Times 0 -ParameterFilter { $State -eq 'preflight' }
        Assert-MockCalled Write-JobState -Exactly -Times 2 -ParameterFilter { $State -eq 'installing' }
    }
}

Describe 'TestRigAgent.ps1 run via powershell -File without -ConfigPath (PS 5.1)' {
    It 'finds agent.config.json next to the script ($PSScriptRoot is empty in param defaults)' {
        # This is exactly how the scheduled task starts the agent.
        $rig = New-Rig
        $d = Join-Path $rig.Root 'agentdir'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Copy-Item -LiteralPath $agentScript -Destination $d
        Copy-Item -LiteralPath $rig.ConfigPath -Destination (Join-Path $d 'agent.config.json')
        $out = (& $powershellExe -NoProfile -File (Join-Path $d 'TestRigAgent.ps1') -Once 2>&1 | Out-String)
        $LASTEXITCODE | Should Be 0
        $out | Should Not Match 'Join-Path'
        (Get-Content -LiteralPath (Join-Path $rig.Work 'agent.log') -Raw) | Should Match 'Agent started'
    }
}

Describe 'Invoke-Run: game dialogs during supervision' {
    Mock Get-BannerlordProcess { return $null }

    BeforeEach { $env:FAKEGAME_BEHAVIOR = 'complete' }
    AfterEach {
        Stop-FakeGameLeftovers
        Remove-Item Env:\FAKEGAME_BEHAVIOR -ErrorAction SilentlyContinue; Remove-Item Env:\FAKEGAME_DOCS -ErrorAction SilentlyContinue
    }

    function Read-AgentRun { param($Rig) return (Get-Content -Raw (Join-Path $Rig.Queue 'results\20261031-120000-aaaa\r1\agent-run.json') | ConvertFrom-Json) }

    # Separate Contexts: in Pester 3.4 a Mock made in an It stays active until its block ends.
    Context 'with a mocked dialog search' {
        It 'confirms a "Mod change detected" dialog once and never another title (mocked)' {
            $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
            $null = New-TestJob $rig
            Mock Write-AgentLog { }
            Mock Get-GameDialogs {
                return @([pscustomobject]@{ Handle = [IntPtr]101; Title = 'Mod change detected' },
                    [pscustomobject]@{ Handle = [IntPtr]102; Title = 'Some other dialog' })
            }
            Mock Confirm-KnownGameDialog { }   # no failure reason: OK was sent
            $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
            (Read-Done $rig).runs[0].exitClass | Should Be 'Completed'
            Assert-MockCalled Confirm-KnownGameDialog -Scope It -Exactly -Times 1 -ParameterFilter { $Dialog.Title -ceq 'Mod change detected' }
            Assert-MockCalled Confirm-KnownGameDialog -Scope It -Exactly -Times 0 -ParameterFilter { $Dialog.Title -ne 'Mod change detected' }
            Assert-MockCalled Write-AgentLog -Scope It -Exactly -Times 1 -ParameterFilter { $Message -match "^Dismissed dialog 'Mod change detected' \(pid \d+\)\.$" }
            Assert-MockCalled Write-AgentLog -Scope It -Exactly -Times 1 -ParameterFilter { $Message -eq "Game dialog seen: 'Some other dialog'" }
            @((Read-AgentRun $rig).dismissedDialogs) | Should Be @('Mod change detected')
        }

        It 'does not confirm a title that differs only in case (mocked)' {
            $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
            $null = New-TestJob $rig
            Mock Get-GameDialogs { return @([pscustomobject]@{ Handle = [IntPtr]103; Title = 'mod change detected' }) }
            Mock Confirm-KnownGameDialog { }
            $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
            Assert-MockCalled Get-GameDialogs -Scope It -Times 1   # the dialog was looked at
            Assert-MockCalled Confirm-KnownGameDialog -Scope It -Exactly -Times 0
        }

        It 'logs the reason once when OK cannot be sent and records no dismissal (mocked)' {
            $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
            $null = New-TestJob $rig
            Mock Write-AgentLog { }
            Mock Get-GameDialogs { return @([pscustomobject]@{ Handle = [IntPtr]104; Title = 'Mod change detected' }) }
            Mock Confirm-KnownGameDialog { return 'PostMessage failed (error 5)' }
            $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
            Assert-MockCalled Confirm-KnownGameDialog -Scope It -Exactly -Times 1
            Assert-MockCalled Write-AgentLog -Scope It -Exactly -Times 1 -ParameterFilter { $Message -eq "Could not confirm dialog 'Mod change detected': PostMessage failed (error 5)" }
            Assert-MockCalled Write-AgentLog -Scope It -Exactly -Times 0 -ParameterFilter { $Message -like 'Dismissed dialog*' }
            @((Read-AgentRun $rig).dismissedDialogs).Count | Should Be 0
        }

        It 'logs once when a dialog is still open 5 s after OK was sent (mocked)' {
            $env:FAKEGAME_BEHAVIOR = 'slow'
            $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
            $null = New-TestJob $rig
            Mock Write-AgentLog { }
            Mock Get-GameDialogs { return @([pscustomobject]@{ Handle = [IntPtr]105; Title = 'Mod change detected' }) }
            Mock Confirm-KnownGameDialog { }
            $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
            Assert-MockCalled Confirm-KnownGameDialog -Scope It -Exactly -Times 1
            Assert-MockCalled Write-AgentLog -Scope It -Exactly -Times 1 -ParameterFilter { $Message -eq "Dialog 'Mod change detected' still open after confirm" }
        }

        It 'keeps supervising when the dialog check throws, and logs the failure once' {
            $env:FAKEGAME_BEHAVIOR = 'slow'
            $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
            $null = New-TestJob $rig
            Mock Write-AgentLog { }
            Mock Get-GameDialogs { throw 'enum failed' }
            $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
            (Read-Done $rig).runs[0].exitClass | Should Be 'Completed'
            Assert-MockCalled Get-GameDialogs -Scope It -Times 2   # checked again after the failure
            Assert-MockCalled Write-AgentLog -Scope It -Exactly -Times 1 -ParameterFilter { $Message -like '*Dialog check failed*enum failed*' }
        }
    }

    # These tests show a real message box on the desktop for a moment (the fake game's); the agent or
    # the kill tree closes it. Without an interactive desktop there is no window to find, so they are skipped.
    $noDesktop = -not [Environment]::UserInteractive
    if ($noDesktop) { Write-Warning 'Skipping the real message box tests: the session is not interactive.' }

    Context 'end-to-end with a real message box' {
        foreach ($case in @(
                @{ Behavior = 'modchange'; Buttons = 'OK (single-button rule)' },
                @{ Behavior = 'modchangeokcancel'; Buttons = 'OK/Cancel (IDOK)' })) {
            It "sends OK to a real 'Mod change detected' message box with $($case.Buttons) and completes (end-to-end)" -Skip:$noDesktop {
                $env:FAKEGAME_BEHAVIOR = $case.Behavior
                $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
                $null = New-TestJob $rig -Mutate { param($j) $j['runs'][0]['hardTimeoutMinutes'] = 0.5 }
                Mock Write-AgentLog { }
                $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
                (Read-Done $rig).runs[0].exitClass | Should Be 'Completed'
                Assert-MockCalled Write-AgentLog -Scope It -Exactly -Times 1 -ParameterFilter { $Message -match "^Dismissed dialog 'Mod change detected' \(pid \d+\)\.$" }
                $raw = Get-Content -Raw (Join-Path $rig.Queue 'results\20261031-120000-aaaa\r1\agent-run.json')
                $raw | Should Match '"dismissedDialogs":\s*\[\s*"Mod change detected"\s*\]'
            }
        }

        It 'does not press a button of a Yes/No box with the known title: HardTimeout, one failure line (end-to-end)' -Skip:$noDesktop {
            $env:FAKEGAME_BEHAVIOR = 'modchangeyesno'
            $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
            $null = New-TestJob $rig -Mutate { param($j) $j['runs'][0]['hardTimeoutMinutes'] = 0.1 }
            Mock Write-AgentLog { }
            $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
            (Read-Done $rig).runs[0].exitClass | Should Be 'HardTimeout'
            Assert-MockCalled Write-AgentLog -Scope It -Exactly -Times 1 -ParameterFilter { $Message -like "Could not confirm dialog 'Mod change detected'*" }
            Assert-MockCalled Write-AgentLog -Scope It -Exactly -Times 0 -ParameterFilter { $Message -like 'Dismissed dialog*' }
            $run = Read-AgentRun $rig
            @($run.dismissedDialogs).Count | Should Be 0
            @(Get-Process -Id $run.pid -ErrorAction SilentlyContinue).Count | Should Be 0
        }

        It 'leaves a real dialog with another title alone: HardTimeout, title logged once (end-to-end)' -Skip:$noDesktop {
            $env:FAKEGAME_BEHAVIOR = 'otherdialog'
            $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
            $null = New-TestJob $rig -Mutate { param($j) $j['runs'][0]['hardTimeoutMinutes'] = 0.1 }
            Mock Write-AgentLog { }
            $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
            (Read-Done $rig).runs[0].exitClass | Should Be 'HardTimeout'
            Assert-MockCalled Write-AgentLog -Scope It -Exactly -Times 1 -ParameterFilter { $Message -eq "Game dialog seen: 'Some other dialog'" }
            Assert-MockCalled Write-AgentLog -Scope It -Exactly -Times 0 -ParameterFilter { $Message -like 'Dismissed dialog*' }
            $run = Read-AgentRun $rig
            @($run.dismissedDialogs).Count | Should Be 0
            @(Get-Process -Id $run.pid -ErrorAction SilentlyContinue).Count | Should Be 0
        }
    }
}

Describe 'Initialize-GameWindows: failed compile is cached (W3)' {
    Mock Get-BannerlordProcess { return $null }

    # Own Context: the Add-Type mock would otherwise stay active for the next It (Pester 3.4) and break the package check.
    Context 'with a failing Add-Type' {
        It 'attempts Add-Type only once and rethrows the cached error on later calls' {
            Mock Add-Type { throw 'compile failed' }
            try {
                foreach ($attempt in 1..3) {
                    { Initialize-GameWindows -TypeName 'BannerlordTestRig.NotLoaded' -Source 'broken' } | Should Throw 'compile failed'
                }
                Assert-MockCalled Add-Type -Scope It -Exactly -Times 1
            }
            finally { $script:GameWindowsInitError = $null }   # the real type must still load in later tests
        }
    }

    It 'is called once before launch, so a failed compile is logged and the run still completes' {
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs; $env:FAKEGAME_BEHAVIOR = 'complete'
        try {
            $null = New-TestJob $rig
            Mock Write-AgentLog { }
            Mock Initialize-GameWindows { throw 'compile failed' }
            $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
            (Read-Done $rig).runs[0].exitClass | Should Be 'Completed'
            Assert-MockCalled Write-AgentLog -Scope It -Exactly -Times 1 -ParameterFilter { $Message -eq 'Game dialog check unavailable: compile failed' }
        }
        finally {
            Stop-FakeGameLeftovers
            Remove-Item Env:\FAKEGAME_BEHAVIOR -ErrorAction SilentlyContinue; Remove-Item Env:\FAKEGAME_DOCS -ErrorAction SilentlyContinue
        }
    }
}
