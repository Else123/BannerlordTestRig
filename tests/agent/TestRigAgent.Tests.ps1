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
        [string[]]$Entries = @('Modules/CoherentWarAI/SubModule.xml', 'Modules/CoherentWarAI/bin/Win64_Shipping_Client/CoherentWarAI.dll'),
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

    It 'classifies an unknown harness as SetupError without launching' {
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $null = New-TestJob $rig -Mutate { param($j) $j['runs'][0]['harness'] = 'Other' }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'SetupError'
        Test-Path (Join-Path $rig.Docs 'fake-args.txt') | Should Be $false
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
        $p = Start-Process -FilePath $powershellExe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru
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
        $rec = Invoke-Run -Config (Get-ConfigFor $rig) -Context $ctx -Run $run -Modules @('Native') -RunIndex 1 -ResultsDir $resultsDir
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
