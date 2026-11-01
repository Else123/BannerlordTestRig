# Pester 3.4 tests for agent\TestRigAgent.ps1 (slice S1).
# Run:  powershell -NoProfile -Command "Invoke-Pester <repo>\tests\agent"
# The end-to-end tests start a renamed copy of powershell.exe with fixtures\fake-game.ps1 as the "game".

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$agentScript = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'agent\TestRigAgent.ps1'
$fakeGame = Join-Path $here 'fixtures\fake-game.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# The agent stops every process named like gameExecutable that started after a launch. Under its own name the fake game
# (and every process it starts as a stray or child) is the only such process: the developer's shells and tool hooks,
# all named powershell, are never touched. The copy is cached and refreshed when powershell.exe changes.
$fakeGameName = 'TestRigFakeGame'
$fakeGameExe = Join-Path $env:TEMP "BannerlordTestRig\$fakeGameName.exe"
$fakeGameSource = Get-Item -LiteralPath $powershellExe
$fakeGameCopy = Get-Item -LiteralPath $fakeGameExe -ErrorAction SilentlyContinue
if ($null -eq $fakeGameCopy -or $fakeGameCopy.Length -ne $fakeGameSource.Length -or
        $fakeGameCopy.VersionInfo.FileVersion -ne $fakeGameSource.VersionInfo.FileVersion) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $fakeGameExe) -Force | Out-Null
    Copy-Item -LiteralPath $powershellExe -Destination $fakeGameExe -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

. $agentScript
# Save-TestRigBaseline.ps1 dot-sources the agent again and adds its own functions (no exit when dot-sourced).
. (Join-Path (Split-Path -Parent $agentScript) 'Save-TestRigBaseline.ps1')

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
        Baseline   = Join-Path $root 'baseline'   # the default baselineRoot: <parent of workRoot>\baseline
        Workshop   = Join-Path $root 'workshop'
        EngineLogs = Join-Path $root 'enginelogs'
    }
    # The game's documents folder exists on a real rig (the agent refuses to create it).
    foreach ($d in @((Join-Path $rig.Queue 'jobs'), (Join-Path $rig.Queue 'results'), $rig.Work, (Join-Path $rig.Game 'Modules'),
            (Join-Path $rig.Docs 'Mount and Blade II Bannerlord'), $rig.Workshop, $rig.EngineLogs)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    $cfg = [ordered]@{
        queueRoot           = $rig.Queue
        workRoot            = $rig.Work
        gamePath            = $rig.Game
        gameExecutable      = $fakeGameExe
        gameArgumentsPrefix = ('-NoProfile -File "{0}" /singleplayer' -f $fakeGame)
        documentsRoot       = $rig.Docs
        pollSeconds         = 1
        workshopRoot        = $rig.Workshop
        engineLogDir        = $rig.EngineLogs
    }
    [System.IO.File]::WriteAllText($rig.ConfigPath, ($cfg | ConvertTo-Json -Depth 10), $utf8NoBom)
    # Baseline: BannerlordConfig.txt and the CoherentWarAI MCM json (feature flags off, so the per-run patch is visible).
    Write-RigFile (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt') "Keep=1`r`nAutoSaveInterval=5`r`n"
    Write-RigFile (Join-Path $rig.Baseline 'Configs\ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json') '{ "EnableChainOfCommand": false, "EnableNavalOrders": false, "EnableLogging": false, "Other": 3 }'
    # The modules every test job needs besides its package: Native and NavalDLC in the game, Harmony in the workshop.
    New-SubModuleXml (Join-Path $rig.Game 'Modules\Native') 'Native' 'v1.4.8'
    New-SubModuleXml (Join-Path $rig.Game 'Modules\NavalDLC') 'NavalDLC' 'v1.4.8'
    New-SubModuleXml (Join-Path $rig.Workshop '2859188632') 'Bannerlord.Harmony' 'v2.4.2.248'
    return $rig
}

function Write-RigFile {
    param([string]$Path, [string]$Text)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function New-SubModuleXml {
    # <Dir>\SubModule.xml with <Id value> and, unless $Version is empty, <Version value>.
    param([string]$Dir, [string]$Id, [string]$Version = '')
    $versionXml = if ($Version) { '<Version value="' + $Version + '"/>' } else { '' }
    Write-RigFile (Join-Path $Dir 'SubModule.xml') ('<?xml version="1.0" encoding="utf-8"?><Module><Name value="' + $Id + '"/><Id value="' + $Id + '"/>' + $versionXml + '</Module>')
}

function Set-RigGameVersion {
    param([hashtable]$Rig, [string]$Version)
    Write-RigFile (Join-Path $Rig.Game 'bin\Win64_Shipping_Client\Version.xml') ('<?xml version="1.0" encoding="utf-8"?><Version><Singleplayer Value="' + $Version + '"/></Version>')
}

function Get-Sha256 { param([string]$Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

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
    # agent and the fake game recorded under FAKEGAME_DOCS' parent. Only fake game processes are touched.
    if ([string]::IsNullOrEmpty($env:FAKEGAME_DOCS)) { return }
    $root = Split-Path -Parent $env:FAKEGAME_DOCS
    $pids = @()
    foreach ($name in @('child-pid.txt', 'stray-pid.txt')) {
        $pidFile = Join-Path $env:FAKEGAME_DOCS $name
        if (Test-Path -LiteralPath $pidFile) { $pids += [int](Get-Content -Raw -LiteralPath $pidFile) }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -Filter 'agent-run.json' -ErrorAction SilentlyContinue)) {
        $pids += [int]((Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json).pid)
    }
    foreach ($p in ($pids | Where-Object { $_ -gt 0 })) {
        $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq $fakeGameName) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
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
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }

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
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }

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

        # run.cfg removed after the run; the game saw the baseline with the per-run patch on top
        Test-Path (Join-Path $harnessDir 'run.cfg') | Should Be $false
        $seenConfig = Read-Utf8Text (Join-Path $rig.Docs 'fake-bannerlordconfig.txt')
        $seenConfig | Should Match 'Keep=1'
        $seenConfig | Should Match 'AutoSaveInterval=-1'
        $seenMcm = Read-Utf8Text (Join-Path $rig.Docs 'fake-mcm.json') | ConvertFrom-Json
        $seenMcm.EnableChainOfCommand | Should Be $true
        $seenMcm.Other | Should Be 3
        # after the job the configs equal the baseline again
        $docs = Join-Path $rig.Docs 'Mount and Blade II Bannerlord'
        Get-Sha256 (Join-Path $docs 'Configs\BannerlordConfig.txt') | Should Be (Get-Sha256 (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt'))
        Get-Sha256 (Join-Path $docs 'Configs\ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json') |
            Should Be (Get-Sha256 (Join-Path $rig.Baseline 'Configs\ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json'))
        $done.baselineRestored | Should Be $true
        $done.baselineError | Should Be $null

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
        $done.baselineRestored | Should Be $true   # restored after the job although a run was skipped
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
        # A stale copy from an earlier job passes the job-level module check; the run must still refuse it.
        New-SubModuleXml (Join-Path $rig.Game 'Modules\TestRig.Harness') 'TestRig.Harness' 'v0.0.1'
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
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }
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
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }

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
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }

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
        # the game's own Native (created by New-Rig) is untouched
        Read-Utf8Text (Join-Path $rig.Game 'Modules\Native\SubModule.xml') | Should Match '<Id value="Native"/>'
        Test-Path (Join-Path $rig.Game 'Modules\CoherentWarAI') | Should Be $false
    }

}

Describe 'Invoke-Run: supervision failure after launch (C1)' {
    Mock Get-BannerlordProcess { return $null }
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }

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
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }

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
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }

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
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }

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
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }

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

# ---------------------------------------------------------------------------
# Slice S7: baseline, preflight, versions, watchdog crash detection
# ---------------------------------------------------------------------------

function Get-RigDocsPath { param([hashtable]$Rig, [string]$Relative) return (Join-Path (Join-Path $Rig.Docs 'Mount and Blade II Bannerlord') $Relative) }

function Read-RunRecord {
    param([hashtable]$Rig, [string]$RunId = 'r1')
    return (Get-Content -Raw (Join-Path $Rig.Queue "results\20261031-120000-aaaa\$RunId\agent-run.json") | ConvertFrom-Json)
}

Describe 'Get-AgentConfig: baselineRoot, engineLogDir, workshopRoot' {
    It 'defaults baselineRoot to <parent of workRoot>\baseline, engineLogDir to ProgramData and workshopRoot to the steamapps workshop' {
        $rig = New-Rig
        $raw = [System.IO.File]::ReadAllText($rig.ConfigPath) | ConvertFrom-Json
        $raw.PSObject.Properties.Remove('engineLogDir')
        $raw.PSObject.Properties.Remove('workshopRoot')
        $raw.gamePath = 'C:\SteamX\steamapps\common\Mount & Blade II Bannerlord'
        [System.IO.File]::WriteAllText($rig.ConfigPath, ($raw | ConvertTo-Json), $utf8NoBom)
        $cfg = Get-ConfigFor $rig
        $cfg.baselineRoot | Should Be $rig.Baseline
        $cfg.engineLogDir | Should Be (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Mount and Blade II Bannerlord\logs')
        $cfg.workshopRoot | Should Be 'C:\SteamX\steamapps\workshop\content\261550'
    }
    It 'takes baselineRoot, engineLogDir and workshopRoot from the config' {
        $rig = New-Rig
        Set-RigConfigValue $rig 'baselineRoot' 'C:\Elsewhere\base'
        $cfg = Get-ConfigFor $rig
        $cfg.baselineRoot | Should Be 'C:\Elsewhere\base'
        $cfg.engineLogDir | Should Be $rig.EngineLogs
        $cfg.workshopRoot | Should Be $rig.Workshop
    }
}

Describe 'Restore-TestRigBaseline' {
    It 'copies the baseline, deletes extra files in the managed MCM folders only and returns the SHA-256 per file' {
        $rig = New-Rig
        $smithing = 'Configs\ModSettings\Global\SmithingSuite\SmithingSuite_v1.json'
        Write-RigFile (Join-Path $rig.Baseline $smithing) '{ "a": 1 }'
        Write-RigFile (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') 'Changed=1'
        Write-RigFile (Get-RigDocsPath $rig 'Configs\ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json') '{ "EnableChainOfCommand": true }'
        Write-RigFile (Get-RigDocsPath $rig 'Configs\ModSettings\Global\CoherentWarAI\old\stale.json') '{}'
        Write-RigFile (Get-RigDocsPath $rig 'Configs\ModSettings\Global\AutoTraderSpeed\AutoTraderSpeed_v3.json') '{}'
        Write-RigFile (Get-RigDocsPath $rig 'Configs\ModSettings\Global\CompanionManagementSuite\CompanionManagementSuite_v1.json') '{}'
        $untouched = @('Configs\ModSettings\Global\OtherMod\OtherMod.json', 'Configs\engine_config.txt', 'Configs\LauncherData.xml', 'ModLogs\x.log')
        foreach ($rel in $untouched) { Write-RigFile (Get-RigDocsPath $rig $rel) "keep $rel" }

        $r = Restore-TestRigBaseline -Config (Get-ConfigFor $rig)

        $r.Ok | Should Be $true
        $r.Error | Should Be $null
        $restored = @('Configs\BannerlordConfig.txt', 'Configs\ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json', $smithing)
        foreach ($rel in $restored) {
            $expected = Get-Sha256 (Join-Path $rig.Baseline $rel)
            Get-Sha256 (Get-RigDocsPath $rig $rel) | Should Be $expected
            $r.Sha256[$rel.Replace('\', '/')] | Should Be $expected
        }
        @($r.Sha256.Keys).Count | Should Be 3
        Test-Path (Get-RigDocsPath $rig 'Configs\ModSettings\Global\CoherentWarAI\old') | Should Be $false
        Test-Path (Get-RigDocsPath $rig 'Configs\ModSettings\Global\AutoTraderSpeed\AutoTraderSpeed_v3.json') | Should Be $false
        Test-Path (Get-RigDocsPath $rig 'Configs\ModSettings\Global\CompanionManagementSuite\CompanionManagementSuite_v1.json') | Should Be $false
        foreach ($rel in $untouched) { Read-Utf8Text (Get-RigDocsPath $rig $rel) | Should Be "keep $rel" }
    }
    It 'fails without touching anything when the baseline has no BannerlordConfig.txt' {
        $rig = New-Rig
        Remove-Item -LiteralPath (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt')
        Write-RigFile (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') 'Changed=1'
        Write-RigFile (Get-RigDocsPath $rig 'Configs\ModSettings\Global\AutoTraderSpeed\AutoTraderSpeed_v3.json') '{}'
        $r = Restore-TestRigBaseline -Config (Get-ConfigFor $rig)
        $r.Ok | Should Be $false
        $r.Error | Should Match 'BannerlordConfig\.txt'
        Read-Utf8Text (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') | Should Be 'Changed=1'
        Test-Path (Get-RigDocsPath $rig 'Configs\ModSettings\Global\AutoTraderSpeed\AutoTraderSpeed_v3.json') | Should Be $true
    }
    Context 'with a copy that does not arrive' {
        It 'fails when a restored file does not match the baseline SHA-256' {
            Mock Copy-BaselineFile { }   # nothing is copied: the old content stays
            $rig = New-Rig
            Write-RigFile (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') 'Changed=1'
            $r = Restore-TestRigBaseline -Config (Get-ConfigFor $rig)
            $r.Ok | Should Be $false
            $r.Error | Should Match 'SHA-256'
        }
    }
    Context 'with a failing copy' {
        It 'never throws and reports the error' {
            Mock Copy-BaselineFile { throw 'disk full' }
            $rig = New-Rig
            $r = Restore-TestRigBaseline -Config (Get-ConfigFor $rig)
            $r.Ok | Should Be $false
            $r.Error | Should Match 'disk full'
        }
    }
}

Describe 'Get-JobPreflight: game version, steam, required modules, versions' {
    Mock Get-BannerlordProcess { return $null }
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }

    function New-PreflightJob {
        param([string[]]$Modules = @('Bannerlord.Harmony', 'Native', 'NavalDLC', 'CoherentWarAI'), $Expected = $null)
        return [pscustomobject]@{ modules = $Modules; expectedGameVersion = $Expected }
    }
    function Invoke-TestPreflight {
        param([hashtable]$Rig, $Job)
        $packageRoot = Join-Path $Rig.Root 'pkg'
        New-SubModuleXml (Join-Path $packageRoot 'Modules\CoherentWarAI') 'CoherentWarAI' 'v0.3.0'
        return Get-JobPreflight -Config (Get-ConfigFor $Rig) -Job $Job -PackageRoot $packageRoot -PackageModuleIds @('CoherentWarAI')
    }
    function Format-ModuleVersions { param($List) return ((@($List) | ForEach-Object { '{0}={1}@{2}' -f $_.id, $_.version, $_.source }) -join ';') }

    It 'passes and collects the versions in job.modules order with their source' {
        $rig = New-Rig; Set-RigGameVersion $rig 'v1.4.8'
        $r = Invoke-TestPreflight $rig (New-PreflightJob -Expected 'v1.4.8')
        $r.Error | Should Be $null
        $r.GameVersion | Should Be 'v1.4.8'
        Format-ModuleVersions $r.ModuleVersions |
            Should Be 'Bannerlord.Harmony=v2.4.2.248@workshop;Native=v1.4.8@game;NavalDLC=v1.4.8@game;CoherentWarAI=v0.3.0@package'
    }
    It 'reports a null version for a SubModule.xml without <Version>' {
        $rig = New-Rig
        New-SubModuleXml (Join-Path $rig.Game 'Modules\SandBox') 'SandBox'
        $r = Invoke-TestPreflight $rig (New-PreflightJob -Modules @('SandBox', 'CoherentWarAI'))
        $r.Error | Should Be $null
        $first = @($r.ModuleVersions)[0]
        $first.id | Should Be 'SandBox'
        $first.source | Should Be 'game'
        $first.version | Should Be $null
    }
    It 'blocks on a game version mismatch and names both versions' {
        $rig = New-Rig; Set-RigGameVersion $rig 'v1.4.8'
        $r = Invoke-TestPreflight $rig (New-PreflightJob -Expected 'v1.4.9')
        $r.Error | Should Match 'v1\.4\.9'
        $r.Error | Should Match 'v1\.4\.8'
    }
    It 'blocks when expectedGameVersion is set and Version.xml is missing' {
        $rig = New-Rig
        $r = Invoke-TestPreflight $rig (New-PreflightJob -Expected 'v1.4.8')
        $r.Error | Should Match 'Version\.xml'
    }
    It 'blocks when expectedGameVersion is set and Version.xml is unreadable' {
        $rig = New-Rig
        Write-RigFile (Join-Path $rig.Game 'bin\Win64_Shipping_Client\Version.xml') '<Version><Singleplayer'
        $r = Invoke-TestPreflight $rig (New-PreflightJob -Expected 'v1.4.8')
        $r.Error | Should Match 'Version\.xml'
    }
    It 'does not check the game version when expectedGameVersion is null and logs one line' {
        Mock Write-AgentLog { }
        $rig = New-Rig
        $r = Invoke-TestPreflight $rig (New-PreflightJob -Expected $null)
        $r.Error | Should Be $null
        $r.GameVersion | Should Be $null
        Assert-MockCalled Write-AgentLog -Scope It -Exactly -Times 1 -ParameterFilter { $Message -match 'expectedGameVersion' }
    }
    It 'blocks when required modules are in neither the game nor the workshop and lists every missing id' {
        $rig = New-Rig
        $r = Invoke-TestPreflight $rig (New-PreflightJob -Modules @('Native', 'Foo.Missing', 'CoherentWarAI', 'Bar.Missing'))
        $r.Error | Should Match 'Foo\.Missing'
        $r.Error | Should Match 'Bar\.Missing'
        $r.Error | Should Not Match 'Native'
    }
    It 'finds a workshop module by its <Id value>, not by the folder name' {
        $rig = New-Rig
        New-SubModuleXml (Join-Path $rig.Workshop '2859232415') 'Bannerlord.UIExtenderEx' 'v3.0.3'
        New-SubModuleXml (Join-Path $rig.Workshop 'Bannerlord.ButterLib') 'Something.Else' 'v1'
        $ok = Invoke-TestPreflight $rig (New-PreflightJob -Modules @('Bannerlord.UIExtenderEx', 'CoherentWarAI'))
        $ok.Error | Should Be $null
        Format-ModuleVersions $ok.ModuleVersions | Should Be 'Bannerlord.UIExtenderEx=v3.0.3@workshop;CoherentWarAI=v0.3.0@package'
        $missing = Invoke-TestPreflight $rig (New-PreflightJob -Modules @('Bannerlord.ButterLib', 'CoherentWarAI'))
        $missing.Error | Should Match 'Bannerlord\.ButterLib'
    }
    Context 'without Steam' {
        Mock Get-SteamProcess { return $null }
        It 'blocks when no steam process runs' {
            $rig = New-Rig
            $r = Invoke-TestPreflight $rig (New-PreflightJob)
            $r.Error | Should Match 'steam'
        }
    }
}

Describe 'Invoke-Job: preflight and versions end-to-end' {
    Mock Get-BannerlordProcess { return $null }
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }
    BeforeEach { $env:FAKEGAME_BEHAVIOR = 'complete' }
    AfterEach {
        Stop-FakeGameLeftovers
        Remove-Item Env:\FAKEGAME_BEHAVIOR -ErrorAction SilentlyContinue; Remove-Item Env:\FAKEGAME_DOCS -ErrorAction SilentlyContinue
    }

    It 'writes gameVersion and moduleVersions into agent-run.json' {
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        Set-RigGameVersion $rig 'v1.4.8'
        $null = New-TestJob $rig -Mutate { param($j) $j['expectedGameVersion'] = 'v1.4.8' }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'Completed'
        $run = Read-RunRecord $rig
        $run.gameVersion | Should Be 'v1.4.8'
        (@($run.moduleVersions) | ForEach-Object { '{0}@{1}' -f $_.id, $_.source }) -join ';' |
            Should Be 'Bannerlord.Harmony@workshop;Native@game;NavalDLC@game;CoherentWarAI@package;CoherentWarAI.TestHarness@package'
        @($run.moduleVersions)[0].version | Should Be 'v2.4.2.248'
    }
    It 'blocks a version mismatch before installing anything and does not touch the configs' {
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        Set-RigGameVersion $rig 'v1.4.8'
        $null = New-TestJob $rig -Mutate { param($j) $j['expectedGameVersion'] = 'v1.5.0' }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        $done.status | Should Be 'blocked'
        $done.message | Should Match 'v1\.5\.0'
        $done.baselineRestored | Should Be $null
        $done.baselineError | Should Be $null
        Test-Path (Join-Path $rig.Game 'Modules\CoherentWarAI') | Should Be $false
        Test-Path (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') | Should Be $false
    }
    It 'blocks a job whose module is missing in the game and the workshop' {
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        Remove-Item -LiteralPath (Join-Path $rig.Workshop '2859188632') -Recurse -Force
        $null = New-TestJob $rig
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        $done.status | Should Be 'blocked'
        $done.message | Should Match 'Bannerlord\.Harmony'
    }
}

Describe 'Invoke-Job: baseline end-to-end' {
    Mock Get-BannerlordProcess { return $null }
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }
    BeforeEach { $env:FAKEGAME_BEHAVIOR = 'complete' }
    AfterEach {
        Stop-FakeGameLeftovers
        Remove-Item Env:\FAKEGAME_BEHAVIOR -ErrorAction SilentlyContinue; Remove-Item Env:\FAKEGAME_DOCS -ErrorAction SilentlyContinue
    }

    It 'restores the baseline before each run and records baselineRestored and baselineSha256' {
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        Write-RigFile (Get-RigDocsPath $rig 'Configs\ModSettings\Global\AutoTraderSpeed\stale.json') '{}'
        $null = New-TestJob $rig -Mutate { param($j) Add-SecondRun $j }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        @($done.runs | ForEach-Object { $_.exitClass }) -join ',' | Should Be 'Completed,Completed'
        # what the game of the last run saw: only the baseline MCM file, patched
        (Get-Content -Raw (Join-Path $rig.Docs 'fake-mcm-files.txt')).Trim() | Should Be 'CoherentWarAI\CoherentWarAI_v1.json'
        foreach ($runId in @('r1', 'r2')) {
            $run = Read-RunRecord $rig $runId
            $run.baselineRestored | Should Be $true
            $run.baselineSha256.'Configs/BannerlordConfig.txt' | Should Be (Get-Sha256 (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt'))
            $run.baselineSha256.'Configs/ModSettings/Global/CoherentWarAI/CoherentWarAI_v1.json' |
                Should Be (Get-Sha256 (Join-Path $rig.Baseline 'Configs\ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json'))
        }
        $done.baselineRestored | Should Be $true
        Test-Path (Get-RigDocsPath $rig 'Configs\ModSettings\Global\AutoTraderSpeed\stale.json') | Should Be $false
    }
    It 'ends the run SetupError without launching when the baseline is missing, and reports the failed after-job restore' {
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        Remove-Item -LiteralPath $rig.Baseline -Recurse -Force
        $null = New-TestJob $rig
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        $done.status | Should Be 'completed'
        $done.runs[0].exitClass | Should Be 'SetupError'
        $done.baselineRestored | Should Be $false
        $done.baselineError | Should Match 'BannerlordConfig\.txt'
        $run = Read-RunRecord $rig
        $run.baselineRestored | Should Be $false
        $run.baselineSha256 | Should Be $null
        $run.message | Should Match 'aseline'
        Test-Path (Join-Path $rig.Docs 'fake-args.txt') | Should Be $false
        Test-Path (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') | Should Be $false
    }
}

Describe 'Find-CrashedWatchdogLog' {
    BeforeEach {
        $script:logs = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:logs -Force | Out-Null
    }
    function Write-Watchdog([int]$ProcessId, [string]$Text) { Write-RigFile (Join-Path $script:logs "watchdog_log_$ProcessId.txt") $Text }
    function Add-Watchdog([int]$ProcessId, [string]$Text) { [System.IO.File]::AppendAllText((Join-Path $script:logs "watchdog_log_$ProcessId.txt"), $Text, $utf8NoBom) }

    It 'finds the log of the launched pid' {
        Write-Watchdog 100 "start`r`nCrash occurred`r`n"
        (Find-CrashedWatchdogLog -LogsDir $script:logs -ProcessId 100 -Snapshot @{}).Name | Should Be 'watchdog_log_100.txt'
    }
    It 'returns null when no log says "Crash occurred"' {
        Write-Watchdog 100 "start`r`nall fine`r`n"
        Find-CrashedWatchdogLog -LogsDir $script:logs -ProcessId 100 -Snapshot @{} | Should Be $null
    }
    It 'falls back to another watchdog log that is new since the launch' {
        Write-Watchdog 200 'Crash occurred'
        (Find-CrashedWatchdogLog -LogsDir $script:logs -ProcessId 100 -Snapshot @{}).Name | Should Be 'watchdog_log_200.txt'
    }
    It 'ignores a crash log of another pid that existed at the launch' {
        Write-Watchdog 200 'Crash occurred'
        $snapshot = Get-WatchdogLogSnapshot -LogsDir $script:logs
        Find-CrashedWatchdogLog -LogsDir $script:logs -ProcessId 100 -Snapshot $snapshot | Should Be $null
    }
    It 'ignores an old crash log that only gets a line without a crash appended after the launch (W3)' {
        Write-Watchdog 200 "Crash occurred`r`n"
        $snapshot = Get-WatchdogLogSnapshot -LogsDir $script:logs
        Add-Watchdog 200 "watchdog still running`r`n"
        Find-CrashedWatchdogLog -LogsDir $script:logs -ProcessId 100 -Snapshot $snapshot | Should Be $null
    }
    It 'finds "Crash occurred" appended after the launch to a log that existed then (W3)' {
        Write-Watchdog 100 "watchdog started`r`n"
        $snapshot = Get-WatchdogLogSnapshot -LogsDir $script:logs
        Add-Watchdog 100 "Crash occurred`r`n"
        (Find-CrashedWatchdogLog -LogsDir $script:logs -ProcessId 100 -Snapshot $snapshot).Name | Should Be 'watchdog_log_100.txt'
    }
    It 'reads a log that became shorter than at the launch as a new one (replaced) (W3)' {
        Write-Watchdog 100 ("old content`r`n" * 20)
        $snapshot = Get-WatchdogLogSnapshot -LogsDir $script:logs
        Write-Watchdog 100 "Crash occurred`r`n"
        (Find-CrashedWatchdogLog -LogsDir $script:logs -ProcessId 100 -Snapshot $snapshot).Name | Should Be 'watchdog_log_100.txt'
    }
    It 'sees text appended to a log held open for writing, whose listed length is stale (V1)' {
        Write-Watchdog 100 "watchdog started`r`n"
        $snapshot = Get-WatchdogLogSnapshot -LogsDir $script:logs
        $fs = New-Object System.IO.FileStream((Join-Path $script:logs 'watchdog_log_100.txt'), 'Append', 'Write', 'ReadWrite')
        try {
            $bytes = [System.Text.Encoding]::ASCII.GetBytes("Crash occurred`r`n")
            $fs.Write($bytes, 0, $bytes.Length); $fs.Flush()
            (Find-CrashedWatchdogLog -LogsDir $script:logs -ProcessId 100 -Snapshot $snapshot).Name | Should Be 'watchdog_log_100.txt'
        }
        finally { $fs.Dispose() }
    }
    It 'reads a log the watchdog still holds open for writing' {
        $path = Join-Path $script:logs 'watchdog_log_100.txt'
        $fs = New-Object System.IO.FileStream($path, 'Create', 'Write', 'ReadWrite')
        try {
            $bytes = [System.Text.Encoding]::ASCII.GetBytes("Crash occurred`r`n")
            $fs.Write($bytes, 0, $bytes.Length); $fs.Flush()
            (Find-CrashedWatchdogLog -LogsDir $script:logs -ProcessId 100 -Snapshot @{}).Name | Should Be 'watchdog_log_100.txt'
        }
        finally { $fs.Dispose() }
    }
    It 'returns null for a missing folder' {
        Find-CrashedWatchdogLog -LogsDir (Join-Path $script:logs 'nope') -ProcessId 100 -Snapshot @{} | Should Be $null
    }
}

Describe 'Invoke-Run: watchdog crash detection end-to-end' {
    Mock Get-BannerlordProcess { return $null }
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }
    AfterEach {
        Stop-FakeGameLeftovers
        Remove-Item Env:\FAKEGAME_BEHAVIOR -ErrorAction SilentlyContinue; Remove-Item Env:\FAKEGAME_DOCS -ErrorAction SilentlyContinue
        Remove-Item Env:\FAKEGAME_ENGINELOGS -ErrorAction SilentlyContinue
    }
    function Start-CrashRig([string]$Behavior) {
        $env:FAKEGAME_BEHAVIOR = $Behavior
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $env:FAKEGAME_ENGINELOGS = $rig.EngineLogs
        $null = New-TestJob $rig   # hardTimeoutMinutes = 1
        return $rig
    }

    It 'detects "Crash occurred" while the game hangs, kills it at once and classifies Crashed' {
        $rig = Start-CrashRig 'crash'
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $watch.Elapsed.TotalSeconds | Should BeLessThan 30
        $done = Read-Done $rig
        $done.status | Should Be 'completed'
        $done.runs[0].exitClass | Should Be 'Crashed'
        $run = Read-RunRecord $rig
        $run.message | Should Match 'Crash occurred'
        @(Get-Process -Id $run.pid -ErrorAction SilentlyContinue).Count | Should Be 0
        $name = "watchdog_log_$($run.pid).txt"
        $run.artifacts -contains $name | Should Be $true
        (Get-Content -Raw (Join-Path $rig.Queue "results\20261031-120000-aaaa\r1\$name")) | Should Match 'Crash occurred'
    }
    It 'classifies Crashed by the final check when the game exits right after the crash' {
        $rig = Start-CrashRig 'crashexit'
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'Crashed'
        $run = Read-RunRecord $rig
        $run.artifacts -contains "watchdog_log_$($run.pid).txt" | Should Be $true
    }
    It 'copies the watchdog log of a run without a crash and keeps Completed' {
        $rig = Start-CrashRig 'complete'
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'Completed'
        $run = Read-RunRecord $rig
        $run.artifacts -contains "watchdog_log_$($run.pid).txt" | Should Be $true
    }
}

Describe 'Save-TestRigBaseline.ps1' {
    $saveScript = Join-Path (Split-Path -Parent $agentScript) 'Save-TestRigBaseline.ps1'
    function Invoke-Save {
        param([hashtable]$Rig, [switch]$Force)
        $argList = @('-NoProfile', '-File', $saveScript, '-ConfigPath', $Rig.ConfigPath)
        if ($Force) { $argList += '-Force' }
        $out = (& $powershellExe @argList 2>&1 | Out-String)
        return @{ Code = $LASTEXITCODE; Out = $out }
    }
    function New-SaveRig {
        $rig = New-Rig
        Remove-Item -LiteralPath $rig.Baseline -Recurse -Force
        Write-RigFile (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') "Live=1`r`n"
        Write-RigFile (Get-RigDocsPath $rig 'Configs\ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json') '{ "EnableLogging": true }'
        Write-RigFile (Get-RigDocsPath $rig 'Configs\ModSettings\Global\CompanionManagementSuite\sub\x.json') '{}'
        Write-RigFile (Get-RigDocsPath $rig 'Configs\ModSettings\Global\OtherMod\o.json') '{}'
        Write-RigFile (Get-RigDocsPath $rig 'Configs\engine_config.txt') 'engine'
        return $rig
    }

    It 'copies BannerlordConfig.txt and the managed MCM folders and prints each file with its SHA-256' {
        $rig = New-SaveRig
        $r = Invoke-Save $rig
        $r.Code | Should Be 0
        foreach ($rel in @('Configs\BannerlordConfig.txt', 'Configs\ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json',
                'Configs\ModSettings\Global\CompanionManagementSuite\sub\x.json')) {
            $hash = Get-Sha256 (Join-Path $rig.Baseline $rel)
            $hash | Should Be (Get-Sha256 (Get-RigDocsPath $rig $rel))
            $r.Out | Should Match ([regex]::Escape($rel.Replace('\', '/')) + '\s+' + $hash)
        }
        Test-Path (Join-Path $rig.Baseline 'Configs\ModSettings\Global\OtherMod') | Should Be $false
        Test-Path (Join-Path $rig.Baseline 'Configs\engine_config.txt') | Should Be $false
        # the agent accepts what the script saved
        (Restore-TestRigBaseline -Config (Get-ConfigFor $rig)).Ok | Should Be $true
    }
    It 'refuses to overwrite an existing baseline without -Force' {
        $rig = New-SaveRig
        (Invoke-Save $rig).Code | Should Be 0
        Write-RigFile (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') 'Live=2'
        $r = Invoke-Save $rig
        $r.Code | Should Be 1
        $r.Out | Should Match 'Force'
        Read-Utf8Text (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt') | Should Be "Live=1`r`n"
    }
    It 'replaces the baseline with -Force: files gone from the documents tree are gone from the baseline' {
        $rig = New-SaveRig
        (Invoke-Save $rig).Code | Should Be 0
        Remove-Item -LiteralPath (Get-RigDocsPath $rig 'Configs\ModSettings\Global\CompanionManagementSuite') -Recurse -Force
        Write-RigFile (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') 'Live=2'
        (Invoke-Save $rig -Force).Code | Should Be 0
        Read-Utf8Text (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt') | Should Be 'Live=2'
        Test-Path (Join-Path $rig.Baseline 'Configs\ModSettings\Global\CompanionManagementSuite') | Should Be $false
    }
    It 'fails when the documents tree has no BannerlordConfig.txt' {
        $rig = New-SaveRig
        Remove-Item -LiteralPath (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt')
        $r = Invoke-Save $rig
        $r.Code | Should Be 1
        Test-Path (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt') | Should Be $false
    }
    It 'refuses a baselineRoot in the documents tree, even with -Force, and leaves the game configs alone (K1)' {
        $rig = New-SaveRig
        Set-RigConfigValue $rig 'baselineRoot' (Join-Path $rig.Docs 'Mount and Blade II Bannerlord')
        $r = Invoke-Save $rig -Force
        $r.Code | Should Be 1
        $r.Out | Should Match 'baselineRoot'
        Read-Utf8Text (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') | Should Be "Live=1`r`n"
        Test-Path (Get-RigDocsPath $rig 'Configs\ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json') | Should Be $true
    }
    It 'keeps the old baseline when -Force cannot complete the new one (K1)' {
        $rig = New-SaveRig
        (Invoke-Save $rig).Code | Should Be 0
        Write-RigFile (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') 'Live=2'
        $locked = Get-RigDocsPath $rig 'Configs\ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json'
        $fs = [System.IO.File]::Open($locked, 'Open', 'ReadWrite', 'None')   # unreadable for the script
        try { $r = Invoke-Save $rig -Force }
        finally { $fs.Dispose() }
        $r.Code | Should Be 1
        Read-Utf8Text (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt') | Should Be "Live=1`r`n"
        Test-Path (Join-Path $rig.Baseline 'Configs\ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json') | Should Be $true
        Test-Path (Join-Path $rig.Baseline 'Configs.new') | Should Be $false
    }
    It 'refuses while Bannerlord is running (S8)' {
        $rig = New-SaveRig
        $exe = Join-Path $rig.Root 'Bannerlord.exe'   # any process named Bannerlord: a copy of ping that waits
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\ping.exe') -Destination $exe
        $game = Start-Process -FilePath $exe -ArgumentList '-n', '60', '127.0.0.1' -PassThru -WindowStyle Hidden
        try { $r = Invoke-Save $rig }
        finally { if (-not $game.HasExited) { $game.Kill() }; $null = $game.WaitForExit(10000) }
        $r.Code | Should Be 1
        $r.Out | Should Match 'Bannerlord'
        Test-Path (Join-Path $rig.Baseline 'Configs') | Should Be $false
    }
    It 'marks the saved baseline with .testrig-baseline, which a restore never copies into the game documents (W1)' {
        $rig = New-SaveRig
        (Invoke-Save $rig).Code | Should Be 0
        Test-Path -LiteralPath (Join-Path $rig.Baseline 'Configs\.testrig-baseline') -PathType Leaf | Should Be $true
        (Restore-TestRigBaseline -Config (Get-ConfigFor $rig)).Ok | Should Be $true
        Test-Path -LiteralPath (Get-RigDocsPath $rig 'Configs\.testrig-baseline') | Should Be $false
    }
    It 'refuses -Force on an existing Configs without the .testrig-baseline marker and leaves it intact (W1)' {
        $rig = New-SaveRig
        Write-RigFile (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt') 'Old=1'
        Write-RigFile (Join-Path $rig.Baseline 'Configs\engine_config.txt') 'not a baseline file'
        $r = Invoke-Save $rig -Force
        $r.Code | Should Be 1
        $r.Out | Should Match 'testrig-baseline'
        Read-Utf8Text (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt') | Should Be 'Old=1'
        Test-Path -LiteralPath (Join-Path $rig.Baseline 'Configs\engine_config.txt') | Should Be $true
        Test-Path -LiteralPath (Join-Path $rig.Baseline 'Configs.new') | Should Be $false
    }
    It 'refuses -Force through a baselineRoot junction to the game documents folder and leaves the game configs alone (W1)' {
        $rig = New-SaveRig
        $link = Join-Path $rig.Root 'baseline-link'
        $null = cmd /c mklink /J "$link" "$(Join-Path $rig.Docs 'Mount and Blade II Bannerlord')"
        try {
            Set-RigConfigValue $rig 'baselineRoot' $link
            $r = Invoke-Save $rig -Force
            $r.Code | Should Be 1
            $r.Out | Should Match 'baselineRoot'
            Read-Utf8Text (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') | Should Be "Live=1`r`n"
            Test-Path -LiteralPath (Get-RigDocsPath $rig 'Configs\engine_config.txt') | Should Be $true
            Test-Path -LiteralPath (Get-RigDocsPath $rig 'Configs\ModSettings\Global\OtherMod\o.json') | Should Be $true
        }
        finally { if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link) } }   # the junction only, never its target
    }
    It 'puts back a Configs.old that an interrupted swap left without Configs' {
        $rig = New-SaveRig
        (Invoke-Save $rig).Code | Should Be 0
        [System.IO.Directory]::Move((Join-Path $rig.Baseline 'Configs'), (Join-Path $rig.Baseline 'Configs.old'))
        Write-RigFile (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') 'Live=2'
        $r = Invoke-Save $rig
        $r.Code | Should Be 1
        $r.Out | Should Match 'Force'
        Read-Utf8Text (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt') | Should Be "Live=1`r`n"
        Test-Path -LiteralPath (Join-Path $rig.Baseline 'Configs.old') | Should Be $false
    }
    It 'refuses while the agent holds the config lock, also with -Force (W4)' {
        $rig = New-SaveRig
        $mutex = New-Object System.Threading.Mutex($false, 'Global\BannerlordTestRigConfig')
        $null = $mutex.WaitOne(0)
        try { $r = Invoke-Save $rig -Force }
        finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
        $r.Code | Should Be 1
        $r.Out | Should Match 'job'
        Test-Path (Join-Path $rig.Baseline 'Configs') | Should Be $false
    }
    It 'refuses while a restore is pending, also with -Force, and says how to clear it (W4)' {
        $rig = New-SaveRig
        (Invoke-Save $rig).Code | Should Be 0
        Write-RigFile (Join-Path $rig.Work 'restore-pending') 'job'
        Write-RigFile (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') 'AutoSaveInterval=-1'
        $r = Invoke-Save $rig -Force
        $r.Code | Should Be 1
        $r.Out | Should Match 'restore-pending'
        $r.Out | Should Match 'restart the agent'
        Read-Utf8Text (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt') | Should Be "Live=1`r`n"
    }
}

Describe 'Save-TestRigBaseline: swap rollback (in-process)' {
    Mock Get-BannerlordProcess { return $null }
    function New-SwapRig {
        $rig = New-Rig
        Remove-Item -LiteralPath $rig.Baseline -Recurse -Force
        Write-RigFile (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') 'Live=1'
        return $rig
    }

    Context 'when the second rename (Configs.new -> Configs) fails' {
        Mock Move-BaselineFolder { throw 'simulated rename failure' } -ParameterFilter { $From -like '*\Configs.new' }
        It 'puts the previous baseline back and removes the staging folder' {
            $rig = New-SwapRig
            # the previous baseline, as an earlier save left it
            Write-RigFile (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt') 'Live=1'
            Write-RigFile (Join-Path $rig.Baseline 'Configs\.testrig-baseline') 'marker'
            Write-RigFile (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') 'Live=2'
            Save-TestRigBaseline -Path $rig.ConfigPath -Overwrite $true | Should Be 1
            Assert-MockCalled Move-BaselineFolder -Scope It -Exactly -Times 1 -ParameterFilter { $From -like '*\Configs.new' }
            Read-Utf8Text (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt') | Should Be 'Live=1'
            Test-Path -LiteralPath (Join-Path $rig.Baseline 'Configs\.testrig-baseline') | Should Be $true
            Test-Path -LiteralPath (Join-Path $rig.Baseline 'Configs.old') | Should Be $false
            Test-Path -LiteralPath (Join-Path $rig.Baseline 'Configs.new') | Should Be $false
        }
    }
}

# --- Review fixes ---------------------------------------------------------------

Describe 'Get-AgentConfig: path rules for workRoot, documentsRoot and baselineRoot (K1)' {
    function Get-DocsDir { param([hashtable]$Rig) return (Join-Path $Rig.Docs 'Mount and Blade II Bannerlord') }

    It 'rejects a baselineRoot equal to the game documents folder' {
        $rig = New-Rig; Set-RigConfigValue $rig 'baselineRoot' (Get-DocsDir $rig)
        { Get-ConfigFor $rig } | Should Throw 'baselineRoot'
    }
    It 'rejects a baselineRoot inside the game documents folder (a managed MCM folder)' {
        $rig = New-Rig; Set-RigConfigValue $rig 'baselineRoot' (Join-Path (Get-DocsDir $rig) 'Configs\ModSettings\Global\CoherentWarAI')
        { Get-ConfigFor $rig } | Should Throw 'baselineRoot'
    }
    It 'rejects a baselineRoot that contains the game documents folder, also when written differently' {
        $rig = New-Rig; Set-RigConfigValue $rig 'baselineRoot' ($rig.Docs.ToUpperInvariant() + '\.\')
        { Get-ConfigFor $rig } | Should Throw 'baselineRoot'
    }
    It 'accepts a sibling whose name starts like the documents folder and stores normalized paths' {
        $rig = New-Rig
        Set-RigConfigValue $rig 'baselineRoot' ((Get-DocsDir $rig) + ' baseline\x\..\')
        Set-RigConfigValue $rig 'workRoot' ($rig.Work + '\')
        $cfg = Get-ConfigFor $rig
        $cfg.baselineRoot | Should Be ((Get-DocsDir $rig) + ' baseline')
        $cfg.workRoot | Should Be $rig.Work
        $cfg.documentsRoot | Should Be $rig.Docs
    }
    It 'rejects relative and drive-relative workRoot, documentsRoot and baselineRoot' {
        foreach ($case in @(@('workRoot', 'work'), @('documentsRoot', '\docs'), @('baselineRoot', 'C:baseline'))) {
            $rig = New-Rig; Set-RigConfigValue $rig $case[0] $case[1]
            { Get-ConfigFor $rig } | Should Throw $case[0]
        }
    }
}

Describe 'Restore-TestRigBaseline: documents folder, empty folders, reparse points (S1, S3)' {
    It 'fails without creating anything when the game documents folder does not exist (S1)' {
        $rig = New-Rig
        $docsDir = Join-Path $rig.Docs 'Mount and Blade II Bannerlord'
        Remove-Item -LiteralPath $docsDir -Recurse -Force
        $r = Restore-TestRigBaseline -Config (Get-ConfigFor $rig)
        $r.Ok | Should Be $false
        $r.Error | Should Match 'documentsRoot wrong\?'
        Test-Path -LiteralPath $docsDir | Should Be $false
    }
    It 'keeps empty folders in a managed MCM folder that exist in the baseline and removes the others' {
        $rig = New-Rig
        New-Item -ItemType Directory -Path (Join-Path $rig.Baseline 'Configs\ModSettings\Global\SmithingSuite\presets') -Force | Out-Null
        $kept = Get-RigDocsPath $rig 'Configs\ModSettings\Global\SmithingSuite\presets'
        $gone = Get-RigDocsPath $rig 'Configs\ModSettings\Global\SmithingSuite\other'
        foreach ($d in @($kept, $gone)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        (Restore-TestRigBaseline -Config (Get-ConfigFor $rig)).Ok | Should Be $true
        Test-Path -LiteralPath $kept -PathType Container | Should Be $true
        Test-Path -LiteralPath $gone | Should Be $false
    }
    It 'treats a junction inside a managed MCM folder as an error and deletes nothing (S3)' {
        $rig = New-Rig
        $outside = Join-Path $rig.Root 'outside'
        Write-RigFile (Join-Path $outside 'precious.json') '{}'
        $stale = Get-RigDocsPath $rig 'Configs\ModSettings\Global\AutoTraderSpeed\stale.json'
        Write-RigFile $stale '{}'
        $link = Get-RigDocsPath $rig 'Configs\ModSettings\Global\CoherentWarAI\linked'
        New-Item -ItemType Directory -Path (Split-Path -Parent $link) -Force | Out-Null
        $null = cmd /c mklink /J "$link" "$outside"
        try {
            (Get-Item -LiteralPath $link -Force).Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) | Should Be $true
            $r = Restore-TestRigBaseline -Config (Get-ConfigFor $rig)
            $r.Ok | Should Be $false
            $r.Error | Should Match 'reparse point'
            $r.Error | Should Match 'Nothing was changed'
            Test-Path -LiteralPath (Join-Path $outside 'precious.json') | Should Be $true
            Test-Path -LiteralPath $stale | Should Be $true
        }
        finally { if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link) } }   # removes the junction only, never its target
    }
    It 'treats a managed MCM folder that is itself a junction as an error (S3)' {
        $rig = New-Rig
        $outside = Join-Path $rig.Root 'outside'
        Write-RigFile (Join-Path $outside 'precious.json') '{}'
        $link = Get-RigDocsPath $rig 'Configs\ModSettings\Global\SmithingSuite'
        New-Item -ItemType Directory -Path (Split-Path -Parent $link) -Force | Out-Null
        $null = cmd /c mklink /J "$link" "$outside"
        try {
            $r = Restore-TestRigBaseline -Config (Get-ConfigFor $rig)
            $r.Ok | Should Be $false
            $r.Error | Should Match 'reparse point'
            Test-Path -LiteralPath (Join-Path $outside 'precious.json') | Should Be $true
        }
        finally { if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link) } }
    }
}

Describe 'Read-XmlFile: a path that is not a valid URI (S2)' {
    It 'reads a SubModule.xml in a folder whose name contains # and %20' {
        $dir = Join-Path $TestDrive 'a#b%20c'
        New-SubModuleXml $dir 'X.Mod' 'v1.2'
        (Get-SubModuleInfo (Join-Path $dir 'SubModule.xml')).Version | Should Be 'v1.2'
    }
}

Describe 'Get-JobPreflight: expectedGameVersion type and check order' {
    Mock Get-BannerlordProcess { return $null }
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }
    function Invoke-OrderPreflight {
        param([hashtable]$Rig, $Expected, [string[]]$Modules = @('Native'))
        $job = [pscustomobject]@{ modules = $Modules; expectedGameVersion = $Expected }
        return Get-JobPreflight -Config (Get-ConfigFor $Rig) -Job $job -PackageRoot (Join-Path $Rig.Root 'pkg') -PackageModuleIds @()
    }
    function New-OrderRig {
        # every check fails: exe missing, version mismatch (v9 expected), module missing
        $rig = New-Rig; Set-RigGameVersion $rig 'v1.4.8'
        Set-RigConfigValue $rig 'gameExecutable' (Join-Path $rig.Root 'missing\Bannerlord.exe')
        return $rig
    }

    It 'blocks a non-string expectedGameVersion' {
        $rig = New-Rig; Set-RigGameVersion $rig 'v1.4.8'
        (Invoke-OrderPreflight $rig 1.48).Error | Should Match 'expectedGameVersion must be a string'
    }
    It 'reports a version mismatch before missing modules' {
        $rig = New-Rig; Set-RigGameVersion $rig 'v1.4.8'
        $r = Invoke-OrderPreflight $rig 'v9' @('Foo.Missing')
        $r.Error | Should Match 'does not match'
        $r.Error | Should Not Match 'Foo\.Missing'
    }
    Context 'with Bannerlord running and no Steam' {
        Mock Get-BannerlordProcess { return [pscustomobject]@{ Id = 4242 } }
        Mock Get-SteamProcess { return $null }
        It 'reports the running game first' {
            (Invoke-OrderPreflight (New-OrderRig) 'v9' @('Foo.Missing')).Error | Should Match 'already running'
        }
    }
    Context 'without Steam' {
        Mock Get-SteamProcess { return $null }
        It 'reports a missing game executable before a missing Steam' {
            (Invoke-OrderPreflight (New-OrderRig) 'v9' @('Foo.Missing')).Error | Should Match 'Game executable not found'
        }
        It 'reports a missing Steam before a version mismatch and missing modules' {
            $rig = New-Rig; Set-RigGameVersion $rig 'v1.4.8'
            (Invoke-OrderPreflight $rig 'v9' @('Foo.Missing')).Error | Should Match 'steam'
        }
    }
}

Describe 'Find-CrashedWatchdogLog: launch time for the own log (W1, S5)' {
    BeforeEach {
        $script:logs = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:logs -Force | Out-Null
    }
    function Write-Watchdog([int]$ProcessId, [string]$Text) { Write-RigFile (Join-Path $script:logs "watchdog_log_$ProcessId.txt") $Text }

    It 'ignores a stale own log from an earlier crash under a reused PID' {
        Write-Watchdog 100 "Crash occurred`r`n"
        $snapshot = Get-WatchdogLogSnapshot -LogsDir $script:logs
        Find-CrashedWatchdogLog -LogsDir $script:logs -ProcessId 100 -Snapshot $snapshot | Should Be $null
    }
    Context 'counting the reads' {
        Mock Test-WatchdogCrash { return $false }
        It 'reads the own log once and not again in the fallback' {
            Write-Watchdog 100 'fine'
            Write-Watchdog 200 'fine'
            $null = Find-CrashedWatchdogLog -LogsDir $script:logs -ProcessId 100 -Snapshot @{}
            Assert-MockCalled Test-WatchdogCrash -Scope It -Exactly -Times 1 -ParameterFilter { $Path -like '*watchdog_log_100.txt' }
            Assert-MockCalled Test-WatchdogCrash -Scope It -Exactly -Times 1 -ParameterFilter { $Path -like '*watchdog_log_200.txt' }
        }
    }
}

Describe 'Stop-StrayGameProcesses (W2)' {
    function Start-Sleeper { return (Start-Process -FilePath $fakeGameExe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -WindowStyle Hidden) }

    Context 'with a game process started since the launch' {
        $since = [DateTime]::UtcNow.AddSeconds(-1)
        $script:stray = Start-Sleeper
        Mock Get-GameProcess { return (Get-Process -Id $script:stray.Id -ErrorAction SilentlyContinue) } -ParameterFilter { $Name -eq $fakeGameName }
        It 'stops it and reports success' {
            try {
                Stop-StrayGameProcesses -GameName $fakeGameName -Since $since -ExcludeId 0 | Should Be $true
                $script:stray.WaitForExit(10000) | Should Be $true
            }
            finally { if (-not $script:stray.HasExited) { $script:stray.Kill() } }
        }
    }
    Context 'with a game process started before the launch' {
        $script:old = Start-Sleeper
        Start-Sleep -Milliseconds 500
        $since = [DateTime]::UtcNow
        Mock Get-GameProcess { return (Get-Process -Id $script:old.Id -ErrorAction SilentlyContinue) }
        It 'leaves it alone' {
            try {
                Stop-StrayGameProcesses -GameName $fakeGameName -Since $since -ExcludeId 0 | Should Be $true
                $script:old.HasExited | Should Be $false
            }
            finally { if (-not $script:old.HasExited) { $script:old.Kill() } }
        }
    }
    Context 'when a stray process cannot be stopped' {
        $since = [DateTime]::UtcNow.AddSeconds(-1)
        $script:stuck = Start-Sleeper
        Mock Get-GameProcess { return (Get-Process -Id $script:stuck.Id -ErrorAction SilentlyContinue) }
        Mock Stop-ProcessTree { return $false }
        It 'reports failure' {
            try { Stop-StrayGameProcesses -GameName $fakeGameName -Since $since -ExcludeId 0 | Should Be $false }
            finally { if (-not $script:stuck.HasExited) { $script:stuck.Kill() } }
        }
    }
    Context 'with a game process whose start time is unreadable (W2)' {
        Mock Get-GameProcess {
            $p = [pscustomobject]@{ Id = 999999; ProcessName = 'Bannerlord' }
            $p | Add-Member -MemberType ScriptProperty -Name StartTime -Value { throw 'Access is denied' }
            return $p
        }
        Mock Stop-ProcessTree { return $true }
        It 'does not stop it and reports failure' {
            Stop-StrayGameProcesses -GameName 'Bannerlord' -Since ([DateTime]::UtcNow) -ExcludeId 0 | Should Be $false
            Assert-MockCalled Stop-ProcessTree -Scope It -Exactly -Times 0
        }
    }
    Context 'looking up the game processes (K1)' {
        Mock Get-GameProcess { return $null }
        It 'asks only for processes named like the game executable' {
            Stop-StrayGameProcesses -GameName 'Bannerlord' -Since ([DateTime]::UtcNow) -ExcludeId 0 | Should Be $true
            Assert-MockCalled Get-GameProcess -Scope It -ParameterFilter { $Name -ne 'Bannerlord' } -Exactly -Times 0
            Assert-MockCalled Get-GameProcess -Scope It -ParameterFilter { $Name -eq 'Bannerlord' }
        }
    }
}

Describe 'Invoke-Run: crash just after the exit and relaunched games (S4, W2)' {
    Mock Get-BannerlordProcess { return $null }
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }
    AfterEach {
        Stop-FakeGameLeftovers
        Remove-Item Env:\FAKEGAME_BEHAVIOR -ErrorAction SilentlyContinue; Remove-Item Env:\FAKEGAME_DOCS -ErrorAction SilentlyContinue
        Remove-Item Env:\FAKEGAME_ENGINELOGS -ErrorAction SilentlyContinue
    }
    function Start-CrashRig([string]$Behavior) {
        $env:FAKEGAME_BEHAVIOR = $Behavior
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        $env:FAKEGAME_ENGINELOGS = $rig.EngineLogs
        $null = New-TestJob $rig
        return $rig
    }

    It 'classifies Crashed when "Crash occurred" reaches the log just after the game exited (S4)' {
        $rig = Start-CrashRig 'crashlate'
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'Crashed'
    }
    It 'stops the relaunched game named by the crash log and classifies Crashed (W2)' {
        $rig = Start-CrashRig 'relaunch'
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        $done.runs[0].exitClass | Should Be 'Crashed'
        $strayPid = [int](Get-Content -Raw (Join-Path $rig.Docs 'stray-pid.txt'))
        Start-Sleep -Milliseconds 500
        @(Get-Process -Id $strayPid -ErrorAction SilentlyContinue).Count | Should Be 0
        (Read-RunRecord $rig).artifacts -contains "watchdog_log_$strayPid.txt" | Should Be $true
    }
    Context 'when the relaunched game cannot be stopped' {
        Mock Stop-ProcessTree { return $false }
        It 'ends the run CleanupFailed and the job failed (W2)' {
            $rig = Start-CrashRig 'relaunch'
            $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
            $done = Read-Done $rig
            $done.runs[0].exitClass | Should Be 'CleanupFailed'
            $done.status | Should Be 'failed'
        }
    }
}

Describe 'Invoke-Job: no baseline restore while Bannerlord still runs (W3)' {
    # Bannerlord "runs" once the fake game has started: the preflight before the launch sees none.
    Mock Get-BannerlordProcess {
        if ($env:FAKEGAME_DOCS -and (Test-Path -LiteralPath (Join-Path $env:FAKEGAME_DOCS 'fake-args.txt'))) { return [pscustomobject]@{ Id = 4242 } }
    }
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }
    AfterEach {
        Stop-FakeGameLeftovers
        Remove-Item Env:\FAKEGAME_BEHAVIOR -ErrorAction SilentlyContinue; Remove-Item Env:\FAKEGAME_DOCS -ErrorAction SilentlyContinue
    }

    It 'skips the after-job restore and reports it in done.json' {
        $env:FAKEGAME_BEHAVIOR = 'complete'
        $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
        $null = New-TestJob $rig
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        $done.runs[0].exitClass | Should Be 'Completed'
        $done.baselineRestored | Should Be $false
        $done.baselineError | Should Be 'Bannerlord still running'
        # the run's patch is still in place
        Get-Sha256 (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') | Should Not Be (Get-Sha256 (Join-Path $rig.Baseline 'Configs\BannerlordConfig.txt'))
    }
}

Describe 'Copy-RunArtifacts: a log the game still holds open (W4)' {
    It 'copies a file another handle holds open for writing' {
        $dir = Join-Path $TestDrive 'w4'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $source = Join-Path $dir 'watchdog_log_1.txt'
        $fs = New-Object System.IO.FileStream($source, 'Create', 'Write', 'ReadWrite')
        try {
            $bytes = [System.Text.Encoding]::ASCII.GetBytes("Crash occurred`r`n")
            $fs.Write($bytes, 0, $bytes.Length); $fs.Flush()
            $copied = @(Copy-RunArtifacts -Copies @(@{ Name = 'watchdog_log_1.txt'; Source = $source }) -Since ([DateTime]::UtcNow.AddMinutes(-1)) -TargetDir (Join-Path $dir 'out'))
            $copied -contains 'watchdog_log_1.txt' | Should Be $true
            [System.IO.File]::ReadAllText((Join-Path $dir 'out\watchdog_log_1.txt')) | Should Be "Crash occurred`r`n"
        }
        finally { $fs.Dispose() }
    }
}

Describe 'Invoke-Run: moduleVersions is always a JSON array (W5)' {
    function Invoke-SetupErrorRun {
        param([hashtable]$Rig, $ModuleVersions)
        $results = Join-Path $Rig.Root 'w5results'
        $context = @{ JobId = 'j'; JobDir = $Rig.Root; ResultsDir = $results; Beat = 0; RunCount = 1; AbortSeen = $false
            ConfigTouched = $false; GameVersion = 'v1.4.8'; ModuleVersions = $ModuleVersions }
        $run = [pscustomobject]@{ runId = 'r1'; harness = 'NoSuchHarness'; mode = 'WarSails' }   # SetupError before anything is touched
        $null = Invoke-Run -Config (Get-ConfigFor $Rig) -Context $context -Run $run -Modules @('Native') -RunIndex 1 -ResultsDir $results
        return [System.IO.File]::ReadAllText((Join-Path $results 'r1\agent-run.json'))
    }

    It 'writes an empty array for no module' {
        Invoke-SetupErrorRun (New-Rig) @() | Should Match '"moduleVersions":\s*\[\s*\]'
    }
    It 'writes a one-element array for one module' {
        $json = Invoke-SetupErrorRun (New-Rig) @([ordered]@{ id = 'Native'; version = 'v1.4.8'; source = 'game' })
        $json | Should Match '"moduleVersions":\s*\[\s*\{'
        @(($json | ConvertFrom-Json).moduleVersions)[0].id | Should Be 'Native'
    }
}

Describe 'Resolve-OrphanedJobs: done.json shape (S7)' {
    It 'writes baselineRestored and baselineError as null' {
        $rig = New-Rig
        $dir = New-TestJob $rig
        Rename-Item (Join-Path $dir 'job.json') 'job.claimed.json'
        Resolve-OrphanedJobs -Config (Get-ConfigFor $rig)
        $text = [System.IO.File]::ReadAllText((Join-Path $rig.Queue 'results\20261031-120000-aaaa\done.json'))
        $text | Should Match '"baselineRestored":\s*null'
        $text | Should Match '"baselineError":\s*null'
    }
}

# --- Review fixes, wave 6 (K1, W1-W4, V2, V3) -------------------------------------

function Clear-FakeGameEnvironment {
    Stop-FakeGameLeftovers
    foreach ($name in @('FAKEGAME_BEHAVIOR', 'FAKEGAME_DOCS', 'FAKEGAME_ENGINELOGS')) { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
}

function Start-FakeGameRig {
    # A rig with a one-run job for the fake game behavior; the fake game writes its watchdog log into the rig's engineLogDir.
    param([string]$Behavior, [scriptblock]$Mutate = $null)
    $env:FAKEGAME_BEHAVIOR = $Behavior
    $rig = New-Rig
    $env:FAKEGAME_DOCS = $rig.Docs
    $env:FAKEGAME_ENGINELOGS = $rig.EngineLogs
    $null = New-TestJob $rig -Mutate $Mutate
    return $rig
}

function Get-StrayProcess {
    # The process the fake game started outside its tree (PID in <docs>\<file>), or $null once it is gone.
    param([hashtable]$Rig, [string]$File = 'stray-pid.txt')
    $path = Join-Path $Rig.Docs $File
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Process -Id ([int](Get-Content -Raw -LiteralPath $path)) -ErrorAction SilentlyContinue)
}

Describe 'Invoke-Run: a crash log naming the PID of another program (K1)' {
    Mock Get-BannerlordProcess { return $null }
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }
    AfterEach { Clear-FakeGameEnvironment }

    It 'classifies Crashed but leaves a process with another name alone, although it started after the launch' {
        $rig = Start-FakeGameRig 'crashforeign'
        try {
            $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
            (Read-Done $rig).runs[0].exitClass | Should Be 'Crashed'
            $foreign = Get-StrayProcess $rig 'foreign-pid.txt'
            $foreign | Should Not Be $null
            $foreign.ProcessName | Should Be 'PING'
        }
        finally {
            $foreign = Get-StrayProcess $rig 'foreign-pid.txt'
            if ($foreign -and $foreign.ProcessName -eq 'PING') { Stop-Process -Id $foreign.Id -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Invoke-Run: stray game processes after every run (W2)' {
    Mock Get-BannerlordProcess { return $null }
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }
    AfterEach { Clear-FakeGameEnvironment }

    It 'stops a game relaunched outside the tree after a normal exit and keeps Completed' {
        $rig = Start-FakeGameRig 'relaunchexit'
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'Completed'
        Start-Sleep -Milliseconds 500
        Get-StrayProcess $rig | Should Be $null
    }
    It 'stops a game relaunched outside the tree after a hard timeout' {
        $rig = Start-FakeGameRig 'relaunchsleep' { param($j) $j['runs'][0]['hardTimeoutMinutes'] = 0.05 }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[0].exitClass | Should Be 'HardTimeout'
        Start-Sleep -Milliseconds 500
        Get-StrayProcess $rig | Should Be $null
    }
    Context 'with a game process whose start time is unreadable' {
        Mock Get-GameProcess {
            $p = [pscustomobject]@{ Id = 999999; ProcessName = $fakeGameName }
            $p | Add-Member -MemberType ScriptProperty -Name StartTime -Value { throw 'Access is denied' }
            return $p
        }
        It 'ends the run CleanupFailed and the job failed' {
            $rig = Start-FakeGameRig 'complete'
            $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
            $done = Read-Done $rig
            $done.runs[0].exitClass | Should Be 'CleanupFailed'
            $done.status | Should Be 'failed'
        }
    }
}

Describe 'Invoke-Run: watchdog logs of an earlier run (W3)' {
    Mock Get-BannerlordProcess { return $null }
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }
    AfterEach { Clear-FakeGameEnvironment }

    It 'does not classify run 2 Crashed when the watchdog of run 1 still writes to its crash log after run 2 launched' {
        $rig = Start-FakeGameRig 'crashfirst' { param($j) Add-SecondRun $j }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        $done = Read-Done $rig
        $done.runs[0].exitClass | Should Be 'Crashed'
        $done.runs[1].exitClass | Should Be 'Completed'
    }
}

Describe 'Invoke-Run: missing engineLogDir (V2)' {
    Mock Get-BannerlordProcess { return $null }
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }
    AfterEach { Clear-FakeGameEnvironment }
    Mock Write-AgentLog { }

    It 'logs once per run that crash detection cannot see the watchdog logs' {
        $env:FAKEGAME_BEHAVIOR = 'complete'
        $rig = New-Rig
        $env:FAKEGAME_DOCS = $rig.Docs
        Remove-Item -LiteralPath $rig.EngineLogs -Recurse -Force
        $null = New-TestJob $rig -Mutate { param($j) Add-SecondRun $j }
        $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
        (Read-Done $rig).runs[1].exitClass | Should Be 'Completed'
        Assert-MockCalled Write-AgentLog -Scope It -Exactly -Times 2 -ParameterFilter { $Message -like '*engineLogDir*does not exist*' }
    }
}

Describe 'Config lock and restore-pending marker (W4)' {
    Mock Get-SteamProcess { return [pscustomobject]@{ Id = 1 } }
    AfterEach { Clear-FakeGameEnvironment }
    function Test-ConfigLockFree {
        # Tries the config mutex from another process; $true if it was free.
        $job = Start-Job -ScriptBlock {
            $m = New-Object System.Threading.Mutex($false, 'Global\BannerlordTestRigConfig')
            try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
            if ($got) { $m.ReleaseMutex() }
            $m.Dispose()
            $got
        }
        try { return [bool]($job | Wait-Job -Timeout 60 | Receive-Job) }
        finally { Remove-Job $job -Force }
    }
    function Get-MarkerPath { param([hashtable]$Rig) return (Join-Path $Rig.Work 'restore-pending') }
    function Test-DocsAtBaseline {
        param([hashtable]$Rig)
        return ((Get-Sha256 (Get-RigDocsPath $Rig 'Configs\BannerlordConfig.txt')) -eq (Get-Sha256 (Join-Path $Rig.Baseline 'Configs\BannerlordConfig.txt')))
    }

    Context 'during a job' {
        Mock Get-BannerlordProcess { return $null }
        Mock Invoke-JobSteps {
            $script:lockFreeDuringJob = Test-ConfigLockFree
            return New-Outcome 'completed'
        }
        It 'holds the config lock for the whole job and releases it afterwards' {
            $script:lockFreeDuringJob = $null
            $rig = New-Rig
            $null = New-TestJob $rig
            (Invoke-AgentCycle -Config (Get-ConfigFor $rig)) | Should Be $true
            $script:lockFreeDuringJob | Should Be $false
            Test-ConfigLockFree | Should Be $true
        }
    }
    Context 'while Save-TestRigBaseline.ps1 holds the config lock' {
        Mock Get-BannerlordProcess { return $null }
        It 'claims no job in this poll' {
            $rig = New-Rig
            $jobDir = New-TestJob $rig
            $signal = Join-Path $rig.Root 'lock-held.txt'
            $holder = Start-Job -ScriptBlock {
                param($signal)
                $m = New-Object System.Threading.Mutex($false, 'Global\BannerlordTestRigConfig')
                $null = $m.WaitOne(0)
                [System.IO.File]::WriteAllText($signal, 'held')
                Start-Sleep -Seconds 30
                $m.ReleaseMutex()
            } -ArgumentList $signal
            try {
                $end = (Get-Date).AddSeconds(60)
                while (-not (Test-Path -LiteralPath $signal) -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 100 }
                (Invoke-AgentCycle -Config (Get-ConfigFor $rig)) | Should Be $false
                Test-Path -LiteralPath (Join-Path $jobDir 'job.json') | Should Be $true
            }
            finally { Remove-Job $holder -Force }
        }
    }
    Context 'with the game still running after the job' {
        # Bannerlord "runs" once the fake game has started: the preflight before the launch sees none.
        Mock Get-BannerlordProcess {
            if ($env:FAKEGAME_DOCS -and (Test-Path -LiteralPath (Join-Path $env:FAKEGAME_DOCS 'fake-args.txt'))) { return [pscustomobject]@{ Id = 4242 } }
        }
        It 'leaves the restore-pending marker when the after-job restore is skipped' {
            $env:FAKEGAME_BEHAVIOR = 'complete'
            $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
            $null = New-TestJob $rig
            $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
            (Read-Done $rig).baselineRestored | Should Be $false
            Test-Path -LiteralPath (Get-MarkerPath $rig) -PathType Leaf | Should Be $true
        }
    }
    Context 'with no game running' {
        Mock Get-BannerlordProcess { return $null }
        It 'removes the marker after the successful after-job restore' {
            $env:FAKEGAME_BEHAVIOR = 'complete'
            $rig = New-Rig; $env:FAKEGAME_DOCS = $rig.Docs
            $null = New-TestJob $rig
            $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
            (Read-Done $rig).baselineRestored | Should Be $true
            Test-Path -LiteralPath (Get-MarkerPath $rig) | Should Be $false
        }
        It 'restores a pending baseline after a rejected job and removes the marker' {
            $rig = New-Rig
            Write-RigFile (Get-MarkerPath $rig) 'earlier job'
            Write-RigFile (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') 'AutoSaveInterval=-1'
            $null = New-TestJob $rig -Mutate { param($j) $j['schema'] = 2 }
            $null = Invoke-AgentCycle -Config (Get-ConfigFor $rig)
            $done = Read-Done $rig
            $done.status | Should Be 'rejected'
            $done.baselineRestored | Should Be $true
            Test-DocsAtBaseline $rig | Should Be $true
            Test-Path -LiteralPath (Get-MarkerPath $rig) | Should Be $false
        }
        It 'restores a pending baseline at startup (agent died mid-job) and removes the marker' {
            $rig = New-Rig
            Write-RigFile (Get-MarkerPath $rig) 'earlier job'
            Write-RigFile (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') 'AutoSaveInterval=-1'
            Invoke-AgentMain -ConfigPath $rig.ConfigPath -Once | Should Be 0
            Test-DocsAtBaseline $rig | Should Be $true
            Test-Path -LiteralPath (Get-MarkerPath $rig) | Should Be $false
        }
    }
}

Describe 'Get-AgentConfig: aliases of the game documents folder as baselineRoot (W1)' {
    It 'rejects the \\?\ and \\.\ forms of a folder' {
        foreach ($prefix in @('\\?\', '\\.\')) {
            $rig = New-Rig; Set-RigConfigValue $rig 'baselineRoot' ($prefix + $rig.Baseline)
            { Get-ConfigFor $rig } | Should Throw 'baselineRoot'
        }
    }
    It 'rejects a baselineRoot that is a junction' {
        $rig = New-Rig
        $link = Join-Path $rig.Root 'baseline-link'
        $null = cmd /c mklink /J "$link" "$(Join-Path $rig.Docs 'Mount and Blade II Bannerlord')"
        try {
            Set-RigConfigValue $rig 'baselineRoot' $link
            { Get-ConfigFor $rig } | Should Throw 'junction'
        }
        finally { if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link) } }
    }
    It 'rejects a baselineRoot below a junction, also when the baselineRoot itself does not exist yet' {
        $rig = New-Rig
        $link = Join-Path $rig.Root 'docs-link'
        $null = cmd /c mklink /J "$link" "$($rig.Docs)"
        try {
            Set-RigConfigValue $rig 'baselineRoot' (Join-Path $link 'Mount and Blade II Bannerlord\new-baseline')
            { Get-ConfigFor $rig } | Should Throw 'junction'
        }
        finally { if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link) } }
    }
}

Describe 'Restore-TestRigBaseline: reparse points on the baseline side and after the copy (V3)' {
    It 'fails on a junction in the baseline and changes nothing' {
        $rig = New-Rig
        $outside = Join-Path $rig.Root 'outside'
        Write-RigFile (Join-Path $outside 'precious.json') '{}'
        $stale = Get-RigDocsPath $rig 'Configs\ModSettings\Global\SmithingSuite\stale.json'
        Write-RigFile $stale '{}'
        $link = Join-Path $rig.Baseline 'Configs\ModSettings\Global\AutoTraderSpeed'
        $null = cmd /c mklink /J "$link" "$outside"
        try {
            $r = Restore-TestRigBaseline -Config (Get-ConfigFor $rig)
            $r.Ok | Should Be $false
            $r.Error | Should Match 'reparse point'
            $r.Error | Should Match 'Nothing was changed'
            Test-Path -LiteralPath $stale | Should Be $true
            Test-Path -LiteralPath (Get-RigDocsPath $rig 'Configs\BannerlordConfig.txt') | Should Be $false
            Test-Path -LiteralPath (Join-Path $outside 'precious.json') | Should Be $true
        }
        finally { if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link) } }
    }
    Context 'with a junction that appears in the documents tree during the copy' {
        Mock Copy-BaselineFile {
            [System.IO.File]::Copy($Source, $Destination, $true)
            $link = Join-Path (Split-Path -Parent $Destination) 'appeared'
            if ($Destination -like '*CoherentWarAI_v1.json' -and -not (Test-Path -LiteralPath $link)) {
                $null = cmd /c mklink /J "$link" "$script:v3Outside"
            }
        }
        It 'fails and does not claim that nothing was changed' {
            $rig = New-Rig
            $script:v3Outside = Join-Path $rig.Root 'outside'
            New-Item -ItemType Directory -Path $script:v3Outside -Force | Out-Null
            $link = Get-RigDocsPath $rig 'Configs\ModSettings\Global\CoherentWarAI\appeared'
            try {
                $r = Restore-TestRigBaseline -Config (Get-ConfigFor $rig)
                $r.Ok | Should Be $false
                $r.Error | Should Match 'reparse point'
                $r.Error | Should Not Match 'Nothing was changed'
            }
            finally { if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link) } }
        }
    }
}
