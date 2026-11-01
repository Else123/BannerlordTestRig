<#
.SYNOPSIS
    Test rig runner (slice S1): packs module folders, publishes a soak job to the test PC over SSH,
    optionally waits for the result and maps it to an exit code. Contract: docs/JOB-PROTOCOL.md.

.DESCRIPTION
    Default (build mode): builds the five mod projects with MSBuild into out\stage\<jobId>\Modules
    (never into the game folder; config key towerGamePath is only read and checked for changes),
    writes manifest.json (SHA-256 per file, git SHA and dirty flag per repo) next to package.zip and
    puts the repo states into job.json. Config: towerGamePath (required), msbuildPath (optional,
    default VS 2026 Build Tools). A build failure or a changed tower Modules folder exits with 1.
    -PackageFrom (diagnosis) skips the build: it is a folder that contains Modules\<ModuleId>\...
    Without -Wait the job is published, the jobId is printed and the script exits 0.
    With -Wait it polls until done.json exists and fetches the result to out\results\<jobId>\.
    Fetched files are data: they are only parsed, never executed.

    Exit codes: 0 all runs Completed with enough days; 1 rig/infrastructure error (blocked, rejected,
    failed, SetupError, LaunchFailed, CleanupFailed, transport error, open job); 2 test failure
    (NotCompleted, Crashed, too few days); 3 time limit or agent not responding (HardTimeout,
    Aborted, claim timeout, stale heartbeat, overall deadline). Precedence: 1 > 3 > 2 > 0.

.EXAMPLE
    .\runner\Invoke-TestRig.ps1 -Days 3 -Wait

.EXAMPLE
    .\runner\Invoke-TestRig.ps1 -PackageFrom C:\stage\pkg -Days 3 -Wait
#>
[CmdletBinding()]
param(
    [string]$PackageFrom,
    [int]$Seed = 1,
    [ValidateRange(1, [int]::MaxValue)][int]$Days = 1,
    [ValidateSet('WarSails', 'NoDlc', 'FeatureOff')][string]$Mode = 'WarSails',
    [ValidateSet('CoherentWarAI', 'TestRig')][string]$Harness = 'CoherentWarAI',
    [ValidateRange(1, [int]::MaxValue)][int]$StallMinutes = 5,
    [ValidateRange(1, [int]::MaxValue)][int]$BudgetMinutes = 60,
    [ValidateRange(1, [int]::MaxValue)][int]$HardTimeoutMinutes = 20,
    [ValidateRange(0.001, [double]::MaxValue)][double]$ClaimTimeoutSeconds = 120,
    [ValidateRange(0.001, [double]::MaxValue)][double]$TimeoutMinutes = ($HardTimeoutMinutes + 10),
    # Default (runner.config.json next to this script) is resolved in the body: $PSScriptRoot is empty
    # inside param() defaults when Windows PowerShell 5.1 runs the script via -File.
    [string]$ConfigPath = '',
    [switch]$Wait
)

. (Join-Path $PSScriptRoot 'Transport.Ssh.ps1')
. (Join-Path $PSScriptRoot 'Build-Package.ps1')

# Harness id -> module id of its in-game driver: the single mapping (lookups are case-insensitive).
$script:RigHarnessModules = [ordered]@{
    CoherentWarAI = 'CoherentWarAI.TestHarness'
    TestRig       = 'TestRig.Harness'
}
$script:DefaultMsBuildPath = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\MSBuild\Current\Bin\MSBuild.exe'

function Write-RigMessage {
    param([string]$Text)
    Write-Host $Text
}

function Get-RigConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config not found: $Path (copy runner.config.example.json to runner.config.json)."
    }
    $c = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in 'host', 'user', 'keyPath', 'remoteQueueRoot') {
        if (-not ($c.PSObject.Properties.Name -contains $k) -or [string]::IsNullOrWhiteSpace([string]$c.$k)) {
            throw "Config '$Path' is missing '$k'."
        }
    }
    # host/user end up in the ssh/scp command line: a leading '-' would be read as an ssh option
    # (e.g. -oProxyCommand=...), so only plain host names / addresses and account names are accepted.
    foreach ($k in 'host', 'user') {
        if ([string]$c.$k -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\z') {
            throw "Config '$Path': '$k' has an invalid value (allowed: letters, digits, '.', '_', '-', not starting with '-')."
        }
    }
    $c
}

function New-RigJobId {
    param(
        [datetime]$UtcNow = [datetime]::UtcNow,
        [string]$Suffix = ('{0:x4}' -f (Get-Random -Maximum 65536))
    )
    $UtcNow.ToUniversalTime().ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '-' + $Suffix
}

# Module load order as in Run-SoakTest.ps1 (BannerlordCoherentWarAI).
function Get-RigModules {
    param(
        [Parameter(Mandatory)][ValidateSet('WarSails', 'NoDlc', 'FeatureOff')][string]$Mode,
        [ValidateSet('CoherentWarAI', 'TestRig')][string]$Harness = 'CoherentWarAI'
    )
    $modules = @('Bannerlord.Harmony', 'Bannerlord.ButterLib', 'Bannerlord.UIExtenderEx', 'Bannerlord.MBOptionScreen', 'Native', 'SandBoxCore', 'Sandbox', 'StoryMode')
    if ($Mode -ne 'NoDlc') { $modules += 'NavalDLC' }
    $modules + @('CoherentWarAI', $script:RigHarnessModules[$Harness])
}

function Get-RigHarnessName {
    # The canonical spelling of a harness id (the key in $script:RigHarnessModules).
    param([Parameter(Mandatory)][string]$Harness)
    $script:RigHarnessModules.Keys | Where-Object { $_ -eq $Harness } | Select-Object -First 1
}

# Zips <PackageFrom>\Modules\** with entry names "Modules/<id>/..." (forward slashes).
function New-RigPackage {
    param(
        [Parameter(Mandatory)][string]$PackageFrom,
        [Parameter(Mandatory)][string]$ZipPath
    )
    # Not [IO.Path]::GetFullPath: that resolves relative paths against the process CWD, which differs from $PWD.
    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackageFrom).TrimEnd('\')
    $modulesDir = Join-Path $root 'Modules'
    if (-not (Test-Path -LiteralPath $modulesDir -PathType Container)) {
        throw "No 'Modules' folder in package source: $root"
    }
    $files = @(Get-ChildItem -LiteralPath $modulesDir -Recurse -File -Force -ErrorAction Stop)   # -Force: hidden files belong in the package
    if ($files.Count -eq 0) { throw "Package source has no files under $modulesDir" }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $stream = [IO.File]::Open($ZipPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite)
    try {
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in $files) {
                $entry = $f.FullName.Substring($root.Length + 1) -replace '\\', '/'
                $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal)
            }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }
    [pscustomobject]@{ ZipPath = $ZipPath; Sha256 = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash }
}

function New-RigJobManifest {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][datetime]$CreatedUtc,
        [Parameter(Mandatory)][string]$PackageSha256,
        [Parameter(Mandatory)][int]$Seed,
        [Parameter(Mandatory)][int]$Days,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][int]$StallMinutes,
        [Parameter(Mandatory)][int]$BudgetMinutes,
        [Parameter(Mandatory)][int]$HardTimeoutMinutes,
        [object[]]$Repos = @(),   # build mode: repo states (name, sha, dirty); empty with -PackageFrom
        [ValidateSet('CoherentWarAI', 'TestRig')][string]$Harness = 'CoherentWarAI',
        [AllowNull()][AllowEmptyString()][string]$ExpectedGameVersion   # tower game version; $null/empty = not checked
    )
    [ordered]@{
        schema              = 1
        jobId               = $JobId
        createdUtc          = $CreatedUtc.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        expectedGameVersion = if ([string]::IsNullOrWhiteSpace($ExpectedGameVersion)) { $null } else { $ExpectedGameVersion }
        package             = [ordered]@{ file = 'package.zip'; sha256 = $PackageSha256 }
        repos               = @($Repos)
        modules             = @(Get-RigModules -Mode $Mode -Harness $Harness)
        runs                = @(
            [ordered]@{
                runId              = 'r1'
                kind               = 'soak'
                harness            = $Harness
                seed               = $Seed
                days               = $Days
                mode               = $Mode
                stallMinutes       = $StallMinutes
                budgetMinutes      = $BudgetMinutes
                hardTimeoutMinutes = $HardTimeoutMinutes
            }
        )
    }
}

function ConvertTo-RigJson {
    param([Parameter(Mandatory)]$InputObject)
    ConvertTo-Json -InputObject $InputObject -Depth 10
}

# UTF-8 without BOM, as the contract requires.
function Write-RigJsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$InputObject
    )
    [IO.File]::WriteAllText($Path, (ConvertTo-RigJson $InputObject), (New-Object Text.UTF8Encoding($false)))
}

# result.txt is "key=value" per line; anything else is ignored.
function ConvertFrom-RigResultText {
    param([string]$Text)
    $h = [ordered]@{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*([A-Za-z0-9_.-]+)=(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() }
    }
    $h
}

# Reads the harness result of one run folder: run-result.json (TestRig harness) if present, else
# result.txt (CoherentWarAI harness). Invalid or unreadable run-result.json = no result (no fallback),
# so a half-written file is never mixed with an older result.txt.
# Returns Status, DaysReached, Scenarios (@{ Id; Status } per scenario, JSON only) and Result (for job-result.json).
function Read-RigRunResult {
    param([Parameter(Mandatory)][string]$RunDir)
    $info = [ordered]@{ Status = $null; DaysReached = $null; Scenarios = @(); Result = [ordered]@{} }
    $jsonFile = Join-Path $RunDir 'run-result.json'
    $txtFile = Join-Path $RunDir 'result.txt'
    if (Test-Path -LiteralPath $jsonFile) {
        try {
            $json = [IO.File]::ReadAllText($jsonFile, (New-Object Text.UTF8Encoding($false, $true))) | ConvertFrom-Json
            if ($null -eq $json -or $json -isnot [System.Management.Automation.PSCustomObject]) { throw 'not a JSON object' }
        } catch {
            Write-RigMessage "WARNING: $jsonFile is unreadable or invalid JSON; treating the run as having no result. $($_.Exception.Message)"
            return $info
        }
        $info.Result = $json
        if ($json.status -is [string] -and $json.status -ne '') { $info.Status = $json.status }
        $parsed = 0
        if ($null -ne $json.daysReached -and [int]::TryParse([string]$json.daysReached, [ref]$parsed)) { $info.DaysReached = $parsed }
        $info.Scenarios = @($json.scenarios | Where-Object { $null -ne $_ } | ForEach-Object {
                [pscustomobject]@{ Id = [string]$_.id; Status = [string]$_.status }
            })
        return $info
    }
    if (Test-Path -LiteralPath $txtFile) {
        $result = ConvertFrom-RigResultText ([IO.File]::ReadAllText($txtFile))
        $info.Result = $result
        if ($result.Contains('status')) { $info.Status = $result['status'] }
        $parsed = 0
        if ($result.Contains('daysReached') -and [int]::TryParse($result['daysReached'], [ref]$parsed)) { $info.DaysReached = $parsed }
    }
    $info
}

# Loads an XML file as data: no DTD, no external resolver. Throws on unreadable or malformed XML.
function Read-RigXmlFile {
    param([Parameter(Mandatory)][string]$Path)
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        try {
            $doc = New-Object Xml.XmlDocument
            $doc.XmlResolver = $null
            $doc.Load($reader)
            $doc
        } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

# Game version of the tower install: <Version><Singleplayer Value="v1.4.8"/></Version> in
# <towerGamePath>\bin\Win64_Shipping_Client\Version.xml. Throws with a clear message when it cannot be read.
function Get-RigTowerGameVersion {
    param([Parameter(Mandatory)][string]$TowerGamePath)
    $file = Join-Path $TowerGamePath 'bin\Win64_Shipping_Client\Version.xml'
    try { $doc = Read-RigXmlFile -Path $file } catch {
        throw "Cannot read the tower game version from '$file' (Version.xml): $($_.Exception.Message)"
    }
    $node = $doc.SelectSingleNode('/Version/Singleplayer/@Value')
    if ($null -eq $node -or [string]::IsNullOrWhiteSpace($node.Value)) {
        throw "Version.xml '$file' has no <Singleplayer Value=...> entry."
    }
    $node.Value.Trim()
}

# Scans the tower workshop folder <steamapps>\workshop\content\261550\*\SubModule.xml once (steamapps = two levels
# above the game folder). Returns Versions (module id -> version, '' = no Version element) and Duplicates (ids that
# occur in several folders with different versions). With duplicates the copy with the newest SubModule.xml
# LastWriteTime wins; equal times are decided by folder name, ascending.
function Get-RigTowerWorkshopIndex {
    param([Parameter(Mandatory)][string]$TowerGamePath)
    $versions = @{}
    $duplicates = New-Object System.Collections.Generic.List[string]
    $steamApps = Split-Path -Parent (Split-Path -Parent $TowerGamePath.TrimEnd('\'))
    $workshop = if ($steamApps) { Join-Path $steamApps 'workshop\content\261550' } else { $null }
    if ($workshop -and (Test-Path -LiteralPath $workshop -PathType Container)) {
        $copies = @{}   # id -> list of @{ Folder; Written; Version }
        foreach ($d in Get-ChildItem -LiteralPath $workshop -Directory -ErrorAction SilentlyContinue) {
            $file = Join-Path $d.FullName 'SubModule.xml'
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
            try { $doc = Read-RigXmlFile -Path $file } catch { continue }
            $id = $doc.SelectSingleNode('/Module/Id/@value')
            if ($null -eq $id -or [string]::IsNullOrWhiteSpace($id.Value)) { continue }
            $ver = $doc.SelectSingleNode('/Module/Version/@value')
            if (-not $copies.ContainsKey($id.Value)) { $copies[$id.Value] = New-Object System.Collections.Generic.List[object] }
            $copies[$id.Value].Add([pscustomobject]@{
                    Folder = $d.Name; Written = (Get-Item -LiteralPath $file).LastWriteTimeUtc
                    Version = $(if ($null -ne $ver) { $ver.Value.Trim() } else { '' })
                })
        }
        foreach ($id in $copies.Keys) {
            $ordered = @($copies[$id] | Sort-Object -Property @{ Expression = 'Written'; Descending = $true }, @{ Expression = 'Folder'; Descending = $false })
            $versions[$id] = $ordered[0].Version
            if (@($ordered | ForEach-Object { $_.Version } | Select-Object -Unique).Count -gt 1) { $duplicates.Add($id) }
        }
    }
    [pscustomobject]@{ Versions = $versions; Duplicates = $duplicates.ToArray() }
}

# Version of module $ModuleId on the tower. $Source says where the .20 copy came from: 'workshop' looks in the tower
# workshop first, anything else in <game>\Modules\<id>\SubModule.xml first; the other place is the fallback.
# $Cache (one per job) holds the workshop index so the folder is scanned at most once.
# Returns $null when the module is not on the tower, '' when it is there without a Version.
function Get-RigTowerModuleVersion {
    param(
        [Parameter(Mandatory)][string]$TowerGamePath,
        [Parameter(Mandatory)][string]$ModuleId,
        [string]$Source = '',
        [hashtable]$Cache = @{}
    )
    # The id comes from fetched data and ends up in a path: plain module ids only.
    if ($ModuleId -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*\z') { return $null }
    $places = if ($Source -eq 'workshop') { 'workshop', 'game' } else { 'game', 'workshop' }
    foreach ($place in $places) {
        if ($place -eq 'workshop') {
            if (-not $Cache.ContainsKey('WorkshopIndex')) { $Cache['WorkshopIndex'] = Get-RigTowerWorkshopIndex -TowerGamePath $TowerGamePath }
            if ($Cache['WorkshopIndex'].Versions.ContainsKey($ModuleId)) { return $Cache['WorkshopIndex'].Versions[$ModuleId] }
            continue
        }
        $file = Join-Path $TowerGamePath "Modules\$ModuleId\SubModule.xml"
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        try { $doc = Read-RigXmlFile -Path $file } catch { continue }
        $id = $doc.SelectSingleNode('/Module/Id/@value')
        if ($null -eq $id -or $id.Value -cne $ModuleId) { continue }
        $ver = $doc.SelectSingleNode('/Module/Version/@value')
        return $(if ($null -ne $ver) { $ver.Value.Trim() } else { '' })
    }
    $null
}

# Warning lines (warning only, never an exit code) for versions the .20 agent reports that differ from the tower:
# the game version and modules with source game/workshop. Each distinct value / (id, version) is compared once.
# Runs without gameVersion/moduleVersions (old agent) contribute nothing. Throws if the tower game version is unreadable.
function Get-RigVersionWarnings {
    param(
        [Parameter(Mandatory)][string]$TowerGamePath,
        [object[]]$Runs
    )
    $warnings = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $towerGame = $null
    $towerModules = @{}
    $cache = @{}   # shared tower workshop index: scanned at most once per job
    foreach ($run in @($Runs | Where-Object { $null -ne $_ })) {
        $gameVersion = if ($run.PSObject.Properties.Name -contains 'gameVersion') { $run.gameVersion } else { $null }
        if ($gameVersion -is [string] -and $gameVersion -ne '' -and $seen.Add("game|$gameVersion")) {
            if ($null -eq $towerGame) { $towerGame = Get-RigTowerGameVersion -TowerGamePath $TowerGamePath }
            if ($gameVersion -cne $towerGame) { $warnings.Add("WARN version differs: game tower $towerGame, .20 $gameVersion") }
        }
        $modules = if ($run.PSObject.Properties.Name -contains 'moduleVersions') { @($run.moduleVersions) } else { @() }
        foreach ($m in $modules) {
            if ($m -isnot [System.Management.Automation.PSCustomObject]) { continue }
            $id = $m.id
            $version = $m.version
            if ($id -isnot [string] -or $id -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*\z') { continue }
            if ($m.source -notin 'game', 'workshop') { continue }
            if ($version -isnot [string] -or $version -eq '') { continue }
            if (-not $seen.Add("module|$($m.source)|$id|$version")) { continue }
            $lookupKey = "$($m.source)|$id"
            if (-not $towerModules.ContainsKey($lookupKey)) {
                $towerModules[$lookupKey] = Get-RigTowerModuleVersion -TowerGamePath $TowerGamePath -ModuleId $id -Source $m.source -Cache $cache
                if ($cache.ContainsKey('WorkshopIndex') -and $cache['WorkshopIndex'].Duplicates -contains $id -and $seen.Add("dup|$id")) {
                    $warnings.Add("WARN duplicate workshop id $id on tower")
                }
            }
            $tower = $towerModules[$lookupKey]
            if ($null -eq $tower) { $warnings.Add("WARN version differs: $id tower missing, .20 $version") }
            elseif ($tower -eq '') { $warnings.Add("WARN version differs: $id tower unknown, .20 $version") }
            elseif ($tower -cne $version) { $warnings.Add("WARN version differs: $id tower $tower, .20 $version") }
        }
    }
    $warnings.ToArray()   # callers wrap in @(): zero or one warning must not collapse
}

# Exit code of one finished job. Per run: the exitClass maps to 0/1/2/3 (see below); additionally a scenario
# (run-result.json) with status Failed counts as 2; Passed/Timeout/Skipped add nothing; Error and any
# unknown or non-string status count as 1.
# Across everything: 1 > 3 > 2 > 0, so an Error scenario wins over any other code, and Failed (2) is the weakest.
function Resolve-RigExitCode {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$DoneStatus,
        [object[]]$Runs,
        [Parameter(Mandatory)][int]$Days,
        [switch]$ForceTimeout   # the runner itself hit a time limit (e.g. overall deadline)
    )
    $runList = @($Runs)
    $codes = New-Object System.Collections.Generic.List[int]
    switch ($DoneStatus) {
        'completed' { if ($runList.Count -eq 0) { $codes.Add(1) } }
        'aborted' { $codes.Add(3) }
        default { $codes.Add(1) }   # blocked, rejected, failed and anything unknown
    }
    foreach ($r in $runList) {
        switch ($r.exitClass) {
            'Completed' {
                if ($null -eq $r.daysReached -or [int]$r.daysReached -lt $Days) { $codes.Add(2) }
            }
            { $_ -in 'NotCompleted', 'Crashed' } { $codes.Add(2) }
            { $_ -in 'HardTimeout', 'Aborted' } { $codes.Add(3) }
            default { $codes.Add(1) }   # SetupError, LaunchFailed, CleanupFailed, unknown
        }
        # No scenarioStatuses property (or $null) = no scenarios; a $null element inside the array is an unknown status.
        $scenarioStatuses = @(if ($null -ne $r.scenarioStatuses) { $r.scenarioStatuses })
        foreach ($scenarioStatus in $scenarioStatuses) {
            if ($scenarioStatus -isnot [string]) { $codes.Add(1) }
            elseif ($scenarioStatus -in 'Passed', 'Timeout', 'Skipped') { }
            elseif ($scenarioStatus -eq 'Failed') { $codes.Add(2) }
            else { $codes.Add(1) }   # Error and anything unknown
        }
    }
    if ($ForceTimeout) { $codes.Add(3) }
    foreach ($c in 1, 3, 2) { if ($codes.Contains($c)) { return $c } }
    0
}

function Format-RigRunLine {
    param(
        [string]$RunId, [string]$Kind, [string]$Status,
        $DaysReached, [int]$Days, [string]$ExitClass,
        $Duration, [string]$Path
    )
    $st = if ($Status) { $Status } else { '?' }
    $reached = if ($null -ne $DaysReached) { [string]$DaysReached } else { '?' }
    $dur = if ($null -ne $Duration) { '{0}m{1:00}s' -f [int][math]::Floor($Duration.TotalMinutes), $Duration.Seconds } else { '?' }
    '{0,-6} {1,-6} {2,-12} {3,-7} {4,-13} {5,-8} {6}' -f $RunId, $Kind, $st, "$reached/$Days", $ExitClass, $dur, $Path
}

# Runs $Action, retrying on any error (transient transport problems). Backoff: DelaySeconds * attempt.
# The last error is rethrown.
function Invoke-RigWithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$Attempts = 3,
        [double]$DelaySeconds = 2
    )
    for ($try = 1; ; $try++) {
        try { return (& $Action) } catch {
            if ($try -ge $Attempts) { throw }
            Start-Sleep -Milliseconds ([int]($DelaySeconds * 1000 * $try))
        }
    }
}

# Returns -> 'Done' | 'ClaimTimeout' | 'WithdrawPending' | 'StaleHeartbeat' | 'DeadlineDone' | 'Deadline'
#
# Claim timeout: the withdraw (rename job.json) can also fail because job.json is merely held open
# (antivirus, indexer). Only job.claimed.json proves a claim. If job.json is still there, the withdraw
# is retried on the following polls, at most $MaxWithdrawAttempts times in total (default 5, about 25 s
# at a 5 s poll): locks of that kind clear within seconds, and an unbounded retry would hide a stuck
# queue. When the budget is used up the result is 'WithdrawPending' (job.json may still be pending).
# A transient transport error is retried inside each poll (Invoke-RigWithRetry); the stale-heartbeat
# clock is wall time since the last observed beat change, so failed attempts neither reset nor pause it.
function Wait-RigJob {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][double]$ClaimTimeoutSeconds,
        [Parameter(Mandatory)][double]$StaleSeconds,
        [Parameter(Mandatory)][double]$OverallSeconds,
        [Parameter(Mandatory)][double]$PollSeconds,
        [Parameter(Mandatory)][double]$AbortWaitSeconds,
        [double]$RetryDelaySeconds = 2,
        [int]$MaxWithdrawAttempts = 5
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $claimSeen = $false
    $lastBeat = $null
    $beatSince = $null
    $withdrawAttempts = 0
    $pollMs = [int][math]::Max(1, $PollSeconds * 1000)
    while ($true) {
        $st = Invoke-RigWithRetry -DelaySeconds $RetryDelaySeconds -Action { Get-JobState -Target $Target -JobId $JobId }
        if ($st.done) { return 'Done' }

        if ($sw.Elapsed.TotalSeconds -ge $OverallSeconds) {
            Send-JobAbort -Target $Target -JobId $JobId
            $abortSw = [Diagnostics.Stopwatch]::StartNew()
            while ($abortSw.Elapsed.TotalSeconds -lt $AbortWaitSeconds) {
                Start-Sleep -Milliseconds $pollMs
                if ((Invoke-RigWithRetry -DelaySeconds $RetryDelaySeconds -Action { Get-JobState -Target $Target -JobId $JobId }).done) { return 'DeadlineDone' }
            }
            return 'Deadline'
        }

        $claimed = $claimSeen -or $st.claimed -or ($null -ne $st.state)
        if (-not $claimed -and $st.jobJson -and $sw.Elapsed.TotalSeconds -ge $ClaimTimeoutSeconds) {
            $withdrawAttempts++
            $w = Send-JobAbort -Target $Target -JobId $JobId -Withdraw
            if ($w.withdrawn) { return 'ClaimTimeout' }
            if ($w.claimed) {
                $claimed = $true   # the rename lost the race: the agent claimed the job just now
            } elseif ($withdrawAttempts -ge $MaxWithdrawAttempts) {
                return 'WithdrawPending'
            }
        }
        if ($claimed) {
            $claimSeen = $true
            $beat = if ($null -ne $st.state) { $st.state.beat } else { $null }
            $now = $sw.Elapsed.TotalSeconds
            # Once a beat was seen, a missing state.json (e.g. caught mid-write) is not a beat change.
            $beatChanged = ($null -eq $beatSince) -or ($null -ne $beat -and $beat -ne $lastBeat)
            if ($beatChanged) {
                $lastBeat = $beat
                $beatSince = $now
            } elseif (($now - $beatSince) -ge $StaleSeconds) {
                return 'StaleHeartbeat'
            }
        }
        Start-Sleep -Milliseconds $pollMs
    }
}

# Reads the fetched result folder (data only), prints one line per run, writes job-result.json.
# Returns the exit code.
function Publish-RigResult {
    param(
        [Parameter(Mandatory)][string]$ResultDir,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][int]$Days,
        [string]$TowerGamePath,   # when set, versions reported by the agent are compared with the tower (warnings only)
        [switch]$ForceTimeout
    )
    $doneFile = Join-Path $ResultDir 'done.json'
    if (-not (Test-Path -LiteralPath $doneFile)) { throw "done.json missing in fetched result: $ResultDir" }
    $done = Get-Content -LiteralPath $doneFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$done.jobId -cne $JobId) {
        throw "done.json belongs to another job (expected '$JobId', found '$($done.jobId)')."
    }
    $doneStatus = [string]$done.status
    if ([string]::IsNullOrWhiteSpace($doneStatus)) {
        Write-RigMessage "ERROR: done.json has no 'status'; treating the job as failed."
        $doneStatus = ''
    }
    # @($null) would be one bogus run; a missing/null runs list is an empty list (and says so).
    $doneRuns = @($done.runs | Where-Object { $null -ne $_ })
    if ($null -eq $done.runs) { Write-RigMessage "WARNING: done.json has no 'runs' list; treating it as empty." }

    $runs = @()
    $lines = @()
    foreach ($dr in $doneRuns) {
        $runId = [string]$dr.runId
        if ($runId -cnotmatch '^[A-Za-z0-9_-]+\z') { throw "Invalid runId in done.json: '$runId'" }
        $runDir = Join-Path $ResultDir $runId

        $rr = Read-RigRunResult -RunDir $runDir
        $daysReached = $rr.DaysReached

        $duration = $null
        $ar = $null
        $agentRun = Join-Path $runDir 'agent-run.json'
        if (Test-Path -LiteralPath $agentRun) {
            try {
                $ar = Get-Content -LiteralPath $agentRun -Raw -Encoding UTF8 | ConvertFrom-Json
                $duration = ([datetime]$ar.endedUtc) - ([datetime]$ar.startedUtc)
            } catch { $duration = $null }
        }
        # .20 versions (agent >= version-reporting): absent in older agents = $null
        $arProps = if ($ar -is [System.Management.Automation.PSCustomObject]) { $ar.PSObject.Properties.Name } else { @() }
        $gameVersion = if ($arProps -contains 'gameVersion') { $ar.gameVersion } else { $null }
        # Explicit assignment: `$x = if (...) { @(...) }` would unroll 0 elements to $null and 1 to a scalar (not a JSON array).
        $moduleVersions = $null
        if ($arProps -contains 'moduleVersions' -and $null -ne $ar.moduleVersions) { $moduleVersions = @($ar.moduleVersions) }

        $runs += [pscustomobject]@{
            runId = $runId; kind = 'soak'; exitClass = [string]$dr.exitClass; daysReached = $daysReached; result = $rr.Result
            scenarioStatuses = @($rr.Scenarios | ForEach-Object { $_.Status })
            gameVersion = $gameVersion; moduleVersions = $moduleVersions
        }
        # result.txt: one line per run (kind 'soak'); run-result.json: one line per scenario
        $lineSources = if ($rr.Scenarios.Count -gt 0) { $rr.Scenarios } else { @([pscustomobject]@{ Id = 'soak'; Status = $rr.Status }) }
        foreach ($sc in $lineSources) {
            $lines += Format-RigRunLine -RunId $runId -Kind $sc.Id -Status $sc.Status -DaysReached $daysReached -Days $Days `
                -ExitClass ([string]$dr.exitClass) -Duration $duration -Path $runDir
        }
    }
    $lines | ForEach-Object { Write-RigMessage $_ }

    $versionWarnings = @()
    if (-not [string]::IsNullOrWhiteSpace($TowerGamePath)) {
        try { $versionWarnings = @(Get-RigVersionWarnings -TowerGamePath $TowerGamePath -Runs $runs) } catch {
            Write-RigMessage "WARN version check skipped: $($_.Exception.Message)"
        }
    }
    $versionWarnings | ForEach-Object { Write-RigMessage $_ }

    $code = Resolve-RigExitCode -DoneStatus $doneStatus -Runs $runs -Days $Days -ForceTimeout:$ForceTimeout
    Write-RigJsonFile -Path (Join-Path $ResultDir 'job-result.json') -InputObject ([ordered]@{
            jobId    = $JobId
            status   = if ($doneStatus) { $doneStatus } else { $null }
            exitCode = $code
            runs     = @($runs | ForEach-Object {
                    [ordered]@{
                        runId = $_.runId; exitClass = $_.exitClass; result = $_.result
                        gameVersion = $_.gameVersion; moduleVersions = $_.moduleVersions
                    }
                })
            versionWarnings = $versionWarnings
        })
    $code
}

function Start-TestRigJob {
    param(
        [string]$PackageFrom,
        [int]$Seed, [int]$Days, [string]$Mode,
        [int]$StallMinutes, [int]$BudgetMinutes, [int]$HardTimeoutMinutes,
        [ValidateSet('CoherentWarAI', 'TestRig')][string]$Harness = 'CoherentWarAI',
        [double]$ClaimTimeoutSeconds, [double]$TimeoutMinutes,
        [string]$ConfigPath,
        [string]$OutRoot,
        [string]$WorkspaceRoot,   # folder that contains the mod repos; default: parent folder of this repo
        [switch]$Wait,
        [double]$PollSeconds = 5,
        [double]$StaleSeconds = 120,
        [double]$AbortWaitSeconds = 60,
        [double]$RetryDelaySeconds = 2,
        [int]$MaxWithdrawAttempts = 5
    )
    try {
        $Harness = Get-RigHarnessName $Harness   # canonical casing for job.json
        $target = Get-RigConfig -Path $ConfigPath
        $buildMode = -not $PackageFrom
        if (-not $buildMode) {
            $harnessModule = $script:RigHarnessModules[$Harness]
            if (-not (Test-Path -LiteralPath (Join-Path $PackageFrom "Modules\$harnessModule") -PathType Container)) {
                throw "Package source '$PackageFrom' has no Modules\$harnessModule (needed by -Harness $Harness)."
            }
        }
        if ($buildMode) {
            if ([string]::IsNullOrWhiteSpace([string]$target.towerGamePath)) {
                throw "Config '$ConfigPath' is missing 'towerGamePath' (needed to build; that game folder is only read, never written)."
            }
            $msbuildPath = if ([string]::IsNullOrWhiteSpace([string]$target.msbuildPath)) { $script:DefaultMsBuildPath } else { [string]$target.msbuildPath }
            if (-not $WorkspaceRoot) { $WorkspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
        }

        # Game version the job expects: the tower install's Version.xml (unreadable = abort before anything is built or published).
        $towerGamePath = [string]$target.towerGamePath
        $expectedGameVersion = $null
        if ([string]::IsNullOrWhiteSpace($towerGamePath)) {
            Write-RigMessage "WARN towerGamePath is not configured: game version and module versions not checked."
        } else {
            $expectedGameVersion = Get-RigTowerGameVersion -TowerGamePath $towerGamePath
        }

        $open = @(Invoke-RigWithRetry -DelaySeconds $RetryDelaySeconds -Action { Get-JobState -Target $target -OpenJobs })
        if ($open.Count -gt 0) {
            Write-RigMessage "ERROR: job '$($open -join ', ')' is still open on the test PC. Refusing to publish (clean up manually if it is stuck)."
            return 1
        }

        $jobId = New-RigJobId
        $jobDir = Join-Path (Join-Path $OutRoot 'jobs') $jobId
        $null = New-Item -ItemType Directory -Path $jobDir -Force
        $repos = @()
        if ($buildMode) {
            $stageDir = Join-Path (Join-Path $OutRoot 'stage') $jobId
            $build = Invoke-RigBuildPackage -WorkspaceRoot $WorkspaceRoot -StageDir $stageDir `
                -TowerGamePath ([string]$target.towerGamePath) -MsBuildPath $msbuildPath
            Write-RigMessage "build: staged in $stageDir; tower Modules unchanged"
            Copy-Item -LiteralPath $build.ManifestPath -Destination (Join-Path $jobDir 'manifest.json') -ErrorAction Stop
            $repos = @($build.Repos)
            $PackageFrom = $stageDir
        }
        $pkg = New-RigPackage -PackageFrom $PackageFrom -ZipPath (Join-Path $jobDir 'package.zip')
        $manifest = New-RigJobManifest -JobId $jobId -CreatedUtc ([datetime]::UtcNow) -PackageSha256 $pkg.Sha256 `
            -Seed $Seed -Days $Days -Mode $Mode -StallMinutes $StallMinutes -BudgetMinutes $BudgetMinutes -HardTimeoutMinutes $HardTimeoutMinutes `
            -Repos $repos -Harness $Harness -ExpectedGameVersion $expectedGameVersion
        Write-RigJsonFile -Path (Join-Path $jobDir 'job.json') -InputObject $manifest

        Publish-Job -Target $target -JobId $jobId -JobDirectory $jobDir
        Write-RigMessage "jobId: $jobId"
        if (-not $Wait) { return 0 }

        $outcome = Wait-RigJob -Target $target -JobId $jobId -ClaimTimeoutSeconds $ClaimTimeoutSeconds -StaleSeconds $StaleSeconds `
            -OverallSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds -AbortWaitSeconds $AbortWaitSeconds `
            -RetryDelaySeconds $RetryDelaySeconds -MaxWithdrawAttempts $MaxWithdrawAttempts
        switch ($outcome) {
            'ClaimTimeout' { Write-RigMessage "ERROR: agent offline - job $jobId was not claimed within $ClaimTimeoutSeconds s and has been withdrawn."; return 3 }
            'WithdrawPending' {
                Write-RigMessage "ERROR: job $jobId was not claimed within $ClaimTimeoutSeconds s, but job.json could not be withdrawn after $MaxWithdrawAttempts attempts: job.json may still be pending on the test PC and the agent could still run it. Check $($target.remoteQueueRoot)\jobs\$jobId."
                return 3
            }
            'StaleHeartbeat' {
                try { Send-JobAbort -Target $target -JobId $jobId } catch { Write-RigMessage "WARNING: could not send abort for job ${jobId}: $($_.Exception.Message)" }
                Write-RigMessage "ERROR: agent not responding - heartbeat of job $jobId did not change for $StaleSeconds s."
                return 3
            }
            'Deadline' { Write-RigMessage "ERROR: overall timeout; abort sent for job $jobId but no done.json appeared within $AbortWaitSeconds s."; return 3 }
        }
        $forceTimeout = ($outcome -eq 'DeadlineDone')
        if ($forceTimeout) { Write-RigMessage "WARNING: overall timeout; job $jobId was aborted." }

        $localDir = Invoke-RigWithRetry -DelaySeconds $RetryDelaySeconds -Action {
            Receive-JobResult -Target $target -JobId $jobId -DestinationRoot (Join-Path $OutRoot 'results')
        }
        return (Publish-RigResult -ResultDir $localDir -JobId $jobId -Days $Days -TowerGamePath $towerGamePath -ForceTimeout:$forceTimeout)
    } catch {
        Write-RigMessage "ERROR: $($_.Exception.Message)"
        return 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'runner.config.json' }
    $code = Start-TestRigJob -PackageFrom $PackageFrom -Seed $Seed -Days $Days -Mode $Mode `
        -StallMinutes $StallMinutes -BudgetMinutes $BudgetMinutes -HardTimeoutMinutes $HardTimeoutMinutes -Harness $Harness `
        -ClaimTimeoutSeconds $ClaimTimeoutSeconds -TimeoutMinutes $TimeoutMinutes `
        -ConfigPath $ConfigPath -OutRoot (Join-Path (Split-Path -Parent $PSScriptRoot) 'out') `
        -WorkspaceRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -Wait:$Wait
    exit $code
}
