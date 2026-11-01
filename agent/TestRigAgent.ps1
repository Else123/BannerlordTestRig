<#
.SYNOPSIS
    Bannerlord test rig agent (job protocol schema 1, slice S1). Runs on the test PC.

.DESCRIPTION
    Polls <queueRoot>\jobs for jobs published by the runner, installs the job's package
    into the game, runs the soak harness, and writes the results back. The contract is
    docs\JOB-PROTOCOL.md. Windows PowerShell 5.1, self-contained: this single file is
    deployed alone (C:\TestRig\agent\).

    Single instance: the named mutex Global\BannerlordTestRigAgent. A second instance
    exits 0 with a message.

    The rig owns the game configuration on the test PC: BannerlordConfig.txt and the
    CoherentWarAI MCM json are patched in place, without backup or restore.

.PARAMETER ConfigPath
    agent.config.json. Default: agent.config.json next to this script.

.PARAMETER Once
    Process at most one job, then exit. Without it the agent polls forever.
#>
[CmdletBinding()]
param(
    # Default (agent.config.json next to this script) is resolved at the entry point: $PSScriptRoot is
    # empty in param defaults under powershell -File (PS 5.1).
    [string]$ConfigPath = '',
    [switch]$Once
)

$ErrorActionPreference = 'Stop'

$script:AgentLogPath = $null
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:MutexName = 'Global\BannerlordTestRigAgent'
$script:ValidModes = @('WarSails', 'NoDlc', 'FeatureOff')
$script:LaunchFailedSeconds = 30
$script:AbortCheckSeconds = 3
$script:DialogCheckSeconds = 1
$script:DialogStillOpenSeconds = 5   # a dialog still open this long after OK was sent is logged once
$script:GameWindowsInitError = $null   # set when compiling the Win32 helper failed; rethrown instead of recompiling
# Game dialogs the agent confirms with OK (exact, case-sensitive title). The engine shows this one on the
# first start after the active module list changed; unattended it blocks the run until HardTimeout.
$script:ConfirmableDialogTitles = @('Mod change detected')
$script:StopSliceMilliseconds = 5000   # Stop-ProcessTree waits in slices of at most this, with a heartbeat between
# Upper bounds per numeric run field (also keeps DateTime.AddMinutes from overflowing).
$script:RunNumberLimits = [ordered]@{ days = 3650; stallMinutes = 1440; budgetMinutes = 1440; hardTimeoutMinutes = 1440 }
# Vanilla and framework modules the rig never replaces, even if the config allowlists them.
$script:ProtectedModules = @('Native', 'SandBox', 'SandBoxCore', 'StoryMode', 'CustomBattle', 'BirthAndDeath', 'Multiplayer',
    'NavalDLC', 'Bannerlord.Harmony', 'Bannerlord.ButterLib', 'Bannerlord.UIExtenderEx', 'Bannerlord.MBOptionScreen')

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

function Get-UtcStamp {
    return [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Invariant)
}

function Write-AgentLog {
    # Never throws: logging must not break a job.
    param([string]$Message)
    $line = '{0} {1}' -f (Get-UtcStamp), $Message
    Write-Host $line
    if ($script:AgentLogPath) {
        try { [System.IO.File]::AppendAllText($script:AgentLogPath, $line + "`r`n", $script:Utf8NoBom) }
        catch { }
    }
}

function Write-JsonAtomic {
    # UTF-8 without BOM, <Path>.tmp first, then swap it in. File.Replace swaps in one step,
    # so the target is never missing (Move-Item -Force deletes it first). Retries briefly
    # because a reader (scp) may hold the old file open.
    param([string]$Path, $Object)
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 10), $script:Utf8NoBom)
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            # [NullString]::Value = no backup file (a plain $null would arrive as an empty path)
            if (Test-Path -LiteralPath $Path -PathType Leaf) { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) }
            else { [System.IO.File]::Move($tmp, $Path) }
            return
        }
        catch {
            if ($attempt -eq 5) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}

# --- UTF-8 / BOM-safe config editing (same approach as Run-SoakTest.ps1) -----

function Read-Utf8Text {
    # Strict UTF-8 (invalid bytes throw). A BOM is consumed by ReadAllText.
    param([string]$Path)
    $enc = New-Object System.Text.UTF8Encoding($false, $true)
    return [System.IO.File]::ReadAllText($Path, $enc)
}

function Write-Utf8Text {
    param([string]$Path, [string]$Text, [bool]$WithBom)
    $enc = New-Object System.Text.UTF8Encoding($WithBom)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Test-Utf8Bom {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function Get-NewLine {
    param([string]$Text)
    if ($Text.Contains("`r`n")) { return "`r`n" }
    if ($Text.Contains("`n")) { return "`n" }
    return "`r`n"
}

function Set-ConfigKeyValue {
    # Sets "Key=Value" in a key=value text; adds the line if the key is missing.
    param([string]$Text, [string]$Key, [string]$Value)
    $pattern = '(?m)^[ \t]*' + [regex]::Escape($Key) + '[ \t]*=[^\r\n]*'
    $replacement = "$Key=$Value"
    if ([regex]::IsMatch($Text, $pattern)) {
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement }
        return [regex]::Replace($Text, $pattern, $evaluator)
    }
    $nl = Get-NewLine $Text
    if ($Text.Length -gt 0 -and -not $Text.EndsWith("`n")) { $Text += $nl }
    return $Text + $replacement + $nl
}

function Set-JsonBoolProperty {
    # Text-level edit of a top-level boolean JSON property so that everything else in
    # the file (formatting, number formats, escapes) stays untouched.
    param([string]$Text, [string]$Name, [bool]$Value)
    $literal = if ($Value) { 'true' } else { 'false' }
    $quoted = '"' + $Name + '"'
    $existing = '(' + [regex]::Escape($quoted) + '\s*:\s*)(true|false)(?![\w])'
    if ([regex]::IsMatch($Text, $existing)) {
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + $literal }
        return (New-Object System.Text.RegularExpressions.Regex($existing)).Replace($Text, $evaluator, 1)
    }
    if ([regex]::IsMatch($Text, [regex]::Escape($quoted) + '\s*:')) {
        throw "JSON property $Name exists but is not a boolean literal - refusing to guess."
    }
    $open = $Text.IndexOf('{')
    if ($open -lt 0) { throw 'MCM JSON has no opening brace.' }
    $nl = Get-NewLine $Text
    $rest = $Text.Substring($open + 1)
    $comma = if ($rest -match '^\s*\}') { '' } else { ',' }
    return $Text.Substring(0, $open + 1) + $nl + '  ' + $quoted + ': ' + $literal + $comma + $Text.Substring($open + 1)
}

function Assert-JsonBools {
    param([string]$Text, [hashtable]$Expected)
    $obj = $Text | ConvertFrom-Json
    foreach ($name in $Expected.Keys) {
        $prop = $obj.PSObject.Properties[$name]
        if ($null -eq $prop -or $prop.Value -ne $Expected[$name]) {
            throw "MCM JSON check failed for $name (expected $($Expected[$name]))."
        }
    }
}

function Set-BannerlordConfigValues {
    # Creates the file if it does not exist (the rig owns the config).
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $bom = Test-Utf8Bom $Path
        $text = Read-Utf8Text $Path
    }
    else {
        $bom = $false
        $text = ''
    }
    $text = Set-ConfigKeyValue $text 'StopGameOnFocusLost' 'False'
    $text = Set-ConfigKeyValue $text 'AutoSaveInterval' '-1'
    $text = Set-ConfigKeyValue $text 'EnableTutorialHints' 'False'
    Write-Utf8Text $Path $text $bom
}

function Set-McmSettingsValues {
    # Creates the file with only the three keys if it does not exist.
    param([string]$Path, [bool]$FeatureOn)
    $expected = @{
        EnableChainOfCommand = $FeatureOn
        EnableNavalOrders    = $FeatureOn
        EnableLogging        = $true
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $bom = Test-Utf8Bom $Path
        $text = Read-Utf8Text $Path
    }
    else {
        $bom = $false
        $text = "{`r`n}`r`n"
    }
    foreach ($name in @('EnableChainOfCommand', 'EnableNavalOrders', 'EnableLogging')) {
        $text = Set-JsonBoolProperty $text $name $expected[$name]
    }
    Assert-JsonBools $text $expected   # never write invalid JSON: MCM would overwrite the file with defaults
    Write-Utf8Text $Path $text $bom
}

# --- Process helpers (taskkill approach from Run-SoakTest.ps1) ---------------

function Invoke-TaskKillTree {
    # "taskkill /PID <id> /T /F" through System.Diagnostics.Process so its stderr never
    # becomes a PowerShell error record. Returns the exit code, or -1. Never throws.
    # Waits in slices and calls $Heartbeat between them.
    param([int]$ProcessId, [scriptblock]$Heartbeat = $null)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'taskkill.exe'
        $psi.Arguments = "/PID $ProcessId /T /F"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $tk = [System.Diagnostics.Process]::Start($psi)
        if (-not (Wait-ProcessSliced -Process $tk -TotalMilliseconds 15000 -Heartbeat $Heartbeat)) { return -1 }
        return $tk.ExitCode
    }
    catch {
        return -1
    }
}

function Wait-ProcessSliced {
    # WaitForExit in slices of at most StopSliceMilliseconds; runs $Heartbeat after each
    # slice that did not end the wait, so a long wait never stalls the heartbeat.
    # A failing heartbeat is ignored. Returns $true if the process exited.
    param([System.Diagnostics.Process]$Process, [int]$TotalMilliseconds, [scriptblock]$Heartbeat = $null)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TotalMilliseconds)
    while ($true) {
        $remaining = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($Process.WaitForExit([Math]::Min($remaining, $script:StopSliceMilliseconds))) { return $true }
        if ($remaining -le $script:StopSliceMilliseconds) { return $false }
        if ($null -ne $Heartbeat) { try { & $Heartbeat } catch { } }
    }
}

function Stop-ProcessTree {
    # Kills the process and its children and waits for the exit. Never throws.
    # Returns $true if the process is gone afterwards. $Heartbeat (optional) runs at least
    # every StopSliceMilliseconds during the waits (the worst case is about 45 s in total).
    param([System.Diagnostics.Process]$Process, [int]$WaitMilliseconds = 15000, [scriptblock]$Heartbeat = $null)
    $ErrorActionPreference = 'Continue'
    if ($null -eq $Process) { return $true }
    try {
        if ($Process.HasExited) { return $true }
        [void](Invoke-TaskKillTree $Process.Id -Heartbeat $Heartbeat)
        if (-not (Wait-ProcessSliced -Process $Process -TotalMilliseconds $WaitMilliseconds -Heartbeat $Heartbeat)) {
            try { $Process.Kill() } catch { }
            [void](Wait-ProcessSliced -Process $Process -TotalMilliseconds $WaitMilliseconds -Heartbeat $Heartbeat)
        }
        return $Process.HasExited
    }
    catch {
        return $false
    }
}

function Get-BannerlordProcess {
    # Separate function so tests can mock it.
    return @(Get-Process -Name 'Bannerlord' -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

function Get-AgentConfig {
    param([string]$Path)
    $raw = (Read-Utf8Text $Path) | ConvertFrom-Json
    foreach ($key in @('queueRoot', 'workRoot', 'gamePath')) {
        if ([string]::IsNullOrWhiteSpace($raw.$key)) { throw "agent.config.json: '$key' is required." }
    }
    $cfg = [ordered]@{
        queueRoot           = [string]$raw.queueRoot
        workRoot            = [string]$raw.workRoot
        gamePath            = [string]$raw.gamePath
        gameExecutable      = [string]$raw.gameExecutable
        gameArgumentsPrefix = '/singleplayer'
        documentsRoot       = [string]$raw.documentsRoot
        pollSeconds         = 10
        heartbeatSeconds    = 10
        moduleAllowlist     = @('CoherentWarAI', 'CoherentWarAI.TestHarness', 'AutoTraderSpeed', 'SmithingSuite',
            'CompanionManagementSuite', 'TestRig.Harness', '*.Scenarios')
    }
    if ([string]::IsNullOrWhiteSpace($cfg.gameExecutable)) {
        $cfg.gameExecutable = Join-Path $cfg.gamePath 'bin\Win64_Shipping_Client\Bannerlord.exe'
    }
    if ($null -ne $raw.gameArgumentsPrefix) { $cfg.gameArgumentsPrefix = [string]$raw.gameArgumentsPrefix }
    if ([string]::IsNullOrWhiteSpace($cfg.documentsRoot)) {
        $cfg.documentsRoot = [Environment]::GetFolderPath('MyDocuments')
    }
    if ($null -ne $raw.pollSeconds) { $cfg.pollSeconds = [double]$raw.pollSeconds }
    if (-not ($cfg.pollSeconds -ge 1 -and $cfg.pollSeconds -le 300)) { throw "agent.config.json: 'pollSeconds' must be 1..300." }
    # Heartbeat interval; the contract wants a state.json write at least every 15 s. Tests lower it.
    if ($null -ne $raw.heartbeatSeconds) { $cfg.heartbeatSeconds = [double]$raw.heartbeatSeconds }
    if (-not ($cfg.heartbeatSeconds -ge 1 -and $cfg.heartbeatSeconds -le 15)) { throw "agent.config.json: 'heartbeatSeconds' must be 1..15." }
    if ($null -ne $raw.moduleAllowlist) { $cfg.moduleAllowlist = @($raw.moduleAllowlist | ForEach-Object { [string]$_ }) }
    return [pscustomobject]$cfg
}

function Test-ModuleProtected {
    param([string]$ModuleId)
    return ($script:ProtectedModules -contains $ModuleId)   # -contains is case-insensitive
}

function Test-ModuleAllowed {
    # The protected list wins over the allowlist.
    param([string]$ModuleId, [string[]]$Allowlist)
    if (Test-ModuleProtected $ModuleId) { return $false }
    foreach ($rule in $Allowlist) {
        if ($ModuleId -like $rule) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Queue: claim, job.json validation, state
# ---------------------------------------------------------------------------

function Invoke-ClaimMove {
    # Separate function so tests can simulate a lost race. Throws if the rename fails.
    param([string]$From, [string]$To)
    [System.IO.File]::Move($From, $To)
}

function Get-NextJob {
    # Claims the oldest job (job ids sort by age) by renaming job.json -> job.claimed.json.
    # A failed rename means someone else won: skip. Returns @{ JobId; Dir } or $null.
    param([string]$QueueRoot)
    $jobsRoot = Join-Path $QueueRoot 'jobs'
    if (-not (Test-Path -LiteralPath $jobsRoot -PathType Container)) { return $null }
    $dirs = @(Get-ChildItem -LiteralPath $jobsRoot -Directory | Sort-Object Name)
    foreach ($dir in $dirs) {
        $jobJson = Join-Path $dir.FullName 'job.json'
        if (-not (Test-Path -LiteralPath $jobJson -PathType Leaf)) { continue }
        try {
            Invoke-ClaimMove -From $jobJson -To (Join-Path $dir.FullName 'job.claimed.json')
        }
        catch {
            Write-AgentLog "Claim of $($dir.Name) failed, skipping: $($_.Exception.Message)"
            continue
        }
        return @{ JobId = $dir.Name; Dir = $dir.FullName }
    }
    return $null
}

function Test-IsNumber {
    param($Value)
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])
}

function Test-JobSchema {
    # Returns an array of error strings (empty = valid).
    param($Job, [string]$FolderName)
    $errors = @()
    if ($null -eq $Job) { return @('job.json is empty.') }
    if ($Job.schema -ne 1) { return @("Unknown schema '$($Job.schema)'.") }
    if ($Job.jobId -isnot [string] -or $Job.jobId -cnotmatch '\A[0-9]{8}-[0-9]{6}-[0-9a-f]{4}\z') { $errors += 'jobId is missing or malformed.' }
    elseif ($Job.jobId -ne $FolderName) { $errors += "jobId '$($Job.jobId)' does not match the folder '$FolderName'." }

    $file = $Job.package.file
    if ($file -isnot [string] -or $file -eq '' -or $file -cnotmatch '\A[A-Za-z0-9._-]+\.zip\z') { $errors += 'package.file must be a plain .zip file name.' }
    if ($Job.package.sha256 -isnot [string] -or $Job.package.sha256 -cnotmatch '\A[0-9A-Fa-f]{64}\z') { $errors += 'package.sha256 must be 64 hex characters.' }

    $modules = @($Job.modules)
    if ($null -eq $Job.modules -or $modules.Count -eq 0) { $errors += 'modules must be a non-empty array.' }
    foreach ($m in $modules) {
        if ($m -isnot [string] -or $m -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z') { $errors += "Invalid module name '$m'." }
    }

    $runs = @($Job.runs)
    if ($null -eq $Job.runs -or $runs.Count -eq 0) { $errors += 'runs must be a non-empty array.' }
    $seen = @{}
    foreach ($run in $runs) {
        if ($run.runId -isnot [string] -or $run.runId -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_-]*\z') { $errors += "Invalid runId '$($run.runId)'."; continue }
        if ($seen.ContainsKey($run.runId)) { $errors += "Duplicate runId '$($run.runId)'." }
        $seen[$run.runId] = $true
        foreach ($f in @('kind', 'harness', 'mode')) {
            if ($run.$f -isnot [string] -or $run.$f -eq '') { $errors += "Run $($run.runId): '$f' is required." }
        }
        if (-not (Test-IsNumber $run.seed)) { $errors += "Run $($run.runId): 'seed' must be a number." }
        foreach ($f in $script:RunNumberLimits.Keys) {
            $max = $script:RunNumberLimits[$f]
            if (-not (Test-IsNumber $run.$f) -or $run.$f -le 0 -or $run.$f -gt $max) { $errors += "Run $($run.runId): '$f' must be a number in (0, $max]." }
        }
    }
    return $errors
}

function Write-JobState {
    # Heartbeat: rewritten atomically, beat +1 per write. A failed write is only logged
    # (the next heartbeat retries).
    param(
        [hashtable]$Context,
        [string]$State,
        $RunId = $null,   # untyped on purpose: a [string] parameter would turn $null into '' (the contract says null)
        [int]$RunIndex = 0,
        $LastHarnessLine = $null,
        $Message = $null
    )
    $Context.Beat++
    $obj = [ordered]@{
        schema          = 1
        jobId           = $Context.JobId
        beat            = $Context.Beat
        state           = $State
        runId           = $RunId
        runIndex        = $RunIndex
        runCount        = $Context.RunCount
        updatedUtc      = Get-UtcStamp
        lastHarnessLine = $LastHarnessLine
        message         = $Message
    }
    try { Write-JsonAtomic (Join-Path $Context.JobDir 'state.json') $obj }
    catch { Write-AgentLog "state.json write failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# Package: validate, expand, install
# ---------------------------------------------------------------------------

function Get-PackageModuleIds {
    # Inspects the zip entries without extracting. Every entry must lie under
    # Modules/<ModuleId>/ (no '..', no rooted or drive paths). Returns @{ Ids; Errors }.
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ids = @()
    $errors = @()
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            $segments = @($name.Split('/') | Where-Object { $_ -ne '' })
            if ($name.StartsWith('/') -or $name.Contains(':') -or $segments -contains '..' -or $segments -contains '.') {
                $errors += "Unsafe path in package: $($entry.FullName)"
                continue
            }
            if ($segments.Count -eq 0) { continue }
            if ($segments[0] -ne 'Modules') {
                $errors += "Entry outside Modules\: $($entry.FullName)"
                continue
            }
            if ($segments.Count -lt 2) { continue }
            if ($segments[1] -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z') {
                $errors += "Invalid module folder name: $($segments[1])"
                continue
            }
            if ($ids -notcontains $segments[1]) { $ids += $segments[1] }
        }
    }
    finally { $zip.Dispose() }
    if ($ids.Count -eq 0 -and $errors.Count -eq 0) { $errors += 'Package contains no module.' }
    return @{ Ids = $ids; Errors = $errors }
}

function Expand-JobPackage {
    # Local copy, SHA-256 check, entry validation, allowlist check, extraction.
    # Nothing touches the game here. Returns @{ Ok; Message; PackageRoot; ModuleIds }.
    param($Config, $Job, [string]$JobDir)
    $jobWork = Join-Path $Config.workRoot $Job.jobId
    if (Test-Path -LiteralPath $jobWork) { Remove-Item -LiteralPath $jobWork -Recurse -Force }
    New-Item -ItemType Directory -Path $jobWork -Force | Out-Null
    $localZip = Join-Path $jobWork 'package.zip'
    # A missing or unreadable package, or a corrupt zip, is an invalid package: rejected, not failed.
    try {
        Copy-Item -LiteralPath (Join-Path $JobDir $Job.package.file) -Destination $localZip -Force
        $actual = (Get-FileHash -LiteralPath $localZip -Algorithm SHA256).Hash
        if ($actual -ne $Job.package.sha256) {
            return @{ Ok = $false; Message = "SHA-256 mismatch (expected $($Job.package.sha256), got $actual)." }
        }
        $inspection = Get-PackageModuleIds $localZip
    }
    catch {
        return @{ Ok = $false; Message = "Package unusable: $($_.Exception.Message)" }
    }
    if ($inspection.Errors.Count -gt 0) {
        return @{ Ok = $false; Message = ($inspection.Errors -join ' ') }
    }
    $protected = @($inspection.Ids | Where-Object { Test-ModuleProtected $_ })
    if ($protected.Count -gt 0) {
        return @{ Ok = $false; Message = "Protected module(s) must not be in the package: $($protected -join ', ')." }
    }
    $denied = @($inspection.Ids | Where-Object { -not (Test-ModuleAllowed $_ $Config.moduleAllowlist) })
    if ($denied.Count -gt 0) {
        return @{ Ok = $false; Message = "Module(s) not in the allowlist: $($denied -join ', ')." }
    }
    $packageRoot = Join-Path $jobWork 'package'
    Expand-Archive -LiteralPath $localZip -DestinationPath $packageRoot -Force
    return @{ Ok = $true; PackageRoot = $packageRoot; ModuleIds = $inspection.Ids }
}

function Get-PreflightError {
    # Returns a message if the job cannot start, else $null.
    param($Config)
    $running = @(Get-BannerlordProcess | Where-Object { $null -ne $_ })
    if ($running.Count -gt 0) { return 'Bannerlord.exe is already running.' }
    if (-not (Test-Path -LiteralPath $Config.gameExecutable -PathType Leaf)) {
        return "Game executable not found: $($Config.gameExecutable)"
    }
    return $null
}

function Get-ModulesDir {
    param($Config)
    return (Join-Path $Config.gamePath 'Modules')
}

function Install-JobModules {
    # Replaces <gamePath>\Modules\<id> for the (already allowlist-checked) ids.
    param($Config, [string]$PackageRoot, [string[]]$ModuleIds)
    $modulesDir = Get-ModulesDir $Config
    New-Item -ItemType Directory -Path $modulesDir -Force | Out-Null
    foreach ($id in $ModuleIds) {
        $target = Join-Path $modulesDir $id
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Copy-Item -LiteralPath (Join-Path (Join-Path $PackageRoot 'Modules') $id) -Destination $target -Recurse -Force
        Write-AgentLog "Installed module $id"
    }
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

# Harness id -> folder below the Bannerlord Documents folder and the module that drives it
# (the one place this mapping lives).
$script:Harnesses = [ordered]@{
    CoherentWarAI = @{ Folder = 'CoherentWarAI\harness'; Module = 'CoherentWarAI.TestHarness' }
    TestRig       = @{ Folder = 'TestRig\harness'; Module = 'TestRig.Harness' }
}

function Get-HarnessDir {
    # Returns $null for an unknown harness id.
    param($Config, [Parameter(Mandatory)][AllowEmptyString()][string]$Harness)
    if (-not $script:Harnesses.Contains($Harness)) { return $null }
    return (Join-Path $Config.documentsRoot ('Mount and Blade II Bannerlord\' + $script:Harnesses[$Harness].Folder))
}

function Get-RunCfgText {
    # ownAssemblies is written only when given: the CoherentWarAI harness rejects unknown keys.
    param($Run, [string[]]$OwnAssemblies = @())
    $lines = @(
        ('seed=' + [System.Convert]::ToString($Run.seed, $script:Invariant)),
        ('days=' + [System.Convert]::ToString($Run.days, $script:Invariant)),
        ('mode=' + $Run.mode),
        ('stallMinutes=' + [System.Convert]::ToString($Run.stallMinutes, $script:Invariant)),
        ('budgetMinutes=' + [System.Convert]::ToString($Run.budgetMinutes, $script:Invariant))
    )
    if (@($OwnAssemblies).Count -gt 0) { $lines += ('ownAssemblies=' + (@($OwnAssemblies) -join ',')) }
    return ($lines -join "`n") + "`n"
}

function Get-OwnAssemblyNames {
    # Simple DLL names (no .dll) of every non-harness module, from its installed SubModule.xml:
    # SubModules/SubModule/DLLName/@value. Order kept, case-insensitive de-duplication.
    # A module whose SubModule.xml is missing or unparseable is skipped and logged.
    param([string]$ModulesDir, [string[]]$ModuleIds, [string[]]$HarnessModuleIds)
    $names = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($ModuleIds)) {
        if (@($HarnessModuleIds) -contains $id) { continue }
        $xmlPath = Join-Path (Join-Path $ModulesDir $id) 'SubModule.xml'
        try {
            $doc = New-Object System.Xml.XmlDocument
            $doc.XmlResolver = $null
            $doc.LoadXml((Read-Utf8Text $xmlPath))
            foreach ($node in $doc.SelectNodes('/Module/SubModules/SubModule/DLLName/@value')) {
                $name = [System.Text.RegularExpressions.Regex]::Replace($node.Value.Trim(), '\.dll\z', '', 'IgnoreCase')
                if ($name -eq '') { continue }
                if ($name -notmatch '\A[A-Za-z0-9_.-]+\z') {
                    # Would corrupt run.cfg (key=value lines, comma-separated list). Log it printable-only.
                    Write-AgentLog "ownAssemblies: skipping invalid DLL name '$($name -replace '[^\x20-\x7E]', '?')' in module ${id}"
                    continue
                }
                if ($seen.Add($name)) { $names.Add($name) }
            }
        }
        catch { Write-AgentLog "ownAssemblies: skipping module ${id}: $($_.Exception.Message)" }
    }
    return $names.ToArray()
}

function Get-GameArguments {
    param([string]$Prefix, [string[]]$Modules)
    return $Prefix + ' _MODULES_*' + ($Modules -join '*') + '*_MODULES_'
}

function Get-LastLogLine {
    # Last non-empty line of a log the game may still be writing. Returns $null if the
    # file is missing or unreadable. Reads only the tail.
    param([string]$Path)
    try {
        $fs = New-Object System.IO.FileStream($Path, 'Open', 'Read', 'ReadWrite,Delete')
        try {
            $length = [Math]::Min($fs.Length, 8192)
            $null = $fs.Seek(-$length, 'End')
            $buffer = New-Object byte[] $length
            $read = $fs.Read($buffer, 0, $length)
            $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        }
        finally { $fs.Dispose() }
        $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
        if ($lines.Count -eq 0) { return $null }
        return $lines[$lines.Count - 1].Trim()
    }
    catch { return $null }
}

function Get-ResultStatus {
    # status of the harness result in $HarnessDir: run-result.json (TestRig harness) if present,
    # else result.txt (CoherentWarAI harness). Unreadable or invalid run-result.json = no result
    # (logged, no fallback). Returns $null if there is no usable status.
    param([string]$HarnessDir)
    $jsonPath = Join-Path $HarnessDir 'run-result.json'
    if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
        try {
            $json = Read-Utf8Text $jsonPath | ConvertFrom-Json
            if ($null -eq $json -or $json -isnot [System.Management.Automation.PSCustomObject]) { throw 'top level is not a JSON object' }
            $status = $json.status
            if ($status -is [string] -and $status -ne '') { return $status }
            Write-AgentLog 'run-result.json has no status; treating the run as having no result.'
        }
        catch { Write-AgentLog "run-result.json is unreadable or invalid; treating the run as having no result: $($_.Exception.Message)" }
        return $null
    }
    $txtPath = Join-Path $HarnessDir 'result.txt'
    if (-not (Test-Path -LiteralPath $txtPath -PathType Leaf)) { return $null }
    try {
        foreach ($line in (Read-Utf8Text $txtPath) -split "`r?`n") {
            if ($line -match '^\s*status\s*=\s*(.+?)\s*$') { return $Matches[1] }
        }
    }
    catch { }
    return $null
}

function Copy-RunArtifacts {
    # Copies each existing source written since $Since. Never throws; returns the names copied.
    param([hashtable[]]$Copies, [datetime]$Since, [string]$TargetDir)
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    $copied = @()
    foreach ($c in $Copies) {
        try {
            if (-not (Test-Path -LiteralPath $c.Source -PathType Leaf)) { continue }
            if ((Get-Item -LiteralPath $c.Source).LastWriteTimeUtc -lt $Since) {
                Write-AgentLog "Not written by this run, not copied: $($c.Source)"
                continue
            }
            Copy-Item -LiteralPath $c.Source -Destination (Join-Path $TargetDir $c.Name) -Force
            $copied += $c.Name
        }
        catch { Write-AgentLog "Could not copy $($c.Source): $($_.Exception.Message)" }
    }
    return $copied
}

# ---------------------------------------------------------------------------
# Game dialogs (Win32)
# ---------------------------------------------------------------------------

$script:GameWindowsSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace BannerlordTestRig
{
    public static class GameWindows
    {
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

        [DllImport("user32.dll")]
        private static extern IntPtr GetDlgItem(IntPtr hDlg, int controlId);

        [DllImport("user32.dll")]
        private static extern int GetDlgCtrlID(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWindowEnabled(IntPtr hWnd);

        // GetWindowLong, not GetWindowLongPtr: GWL_STYLE is a 32-bit value on x86 and x64 alike, and
        // user32 exports GetWindowLongW on both, while GetWindowLongPtrW exists only in 64-bit user32.
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
        private static extern int GetWindowLong(IntPtr hWnd, int index);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        private const string DialogClass = "#32770";
        private const int IDOK = 1;
        private const uint WM_COMMAND = 0x0111;
        private const int BN_CLICKED = 0;
        private const int GWL_STYLE = -16;
        private const int BS_TYPEMASK = 0xF;
        private const int BS_PUSHBUTTON = 0;
        private const int BS_DEFPUSHBUTTON = 1;

        // Visible top-level windows of class #32770 owned by the process.
        public static IntPtr[] FindVisibleDialogs(int processId)
        {
            var found = new List<IntPtr>();
            EnumWindowsProc callback = (hWnd, lParam) =>
            {
                uint owner;
                GetWindowThreadProcessId(hWnd, out owner);
                if (owner == (uint)processId && IsWindowVisible(hWnd))
                {
                    var className = new StringBuilder(256);
                    GetClassName(hWnd, className, className.Capacity);
                    if (className.ToString() == DialogClass) { found.Add(hWnd); }
                }
                return true;
            };
            EnumWindows(callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            return found.ToArray();
        }

        // For a window of another process this reads the stored caption without sending it a message,
        // so a hung game cannot block the agent here.
        public static string GetTitle(IntPtr hWnd)
        {
            var text = new StringBuilder(512);
            GetWindowText(hWnd, text, text.Capacity);
            return text.ToString();
        }

        private static bool IsPushButton(IntPtr hWnd)
        {
            var className = new StringBuilder(256);
            GetClassName(hWnd, className, className.Capacity);
            if (className.ToString() != "Button") { return false; }
            int type = GetWindowLong(hWnd, GWL_STYLE) & BS_TYPEMASK;   // excludes check boxes, radio buttons, group boxes
            return type == BS_PUSHBUTTON || type == BS_DEFPUSHBUTTON;
        }

        // The OK button: the IDOK control, else the dialog's only push button. A MB_OK message box has a
        // single "OK" button whose control id is IDCANCEL, not IDOK (measured on Windows 11; the engine's
        // dialog, measured 2026-11-01 on v1.4.8, is confirmed via this single-button rule).
        // The button must be visible and enabled, as for a user's click.
        private static IntPtr FindOkButton(IntPtr dialog, out int controlId)
        {
            controlId = IDOK;
            IntPtr okButton = GetDlgItem(dialog, IDOK);
            if (okButton == IntPtr.Zero)
            {
                var pushButtons = new List<IntPtr>();
                EnumWindowsProc callback = (hWnd, lParam) =>
                {
                    if (IsPushButton(hWnd)) { pushButtons.Add(hWnd); }
                    return true;
                };
                EnumChildWindows(dialog, callback, IntPtr.Zero);
                GC.KeepAlive(callback);
                if (pushButtons.Count != 1) { return IntPtr.Zero; }
                okButton = pushButtons[0];
                controlId = GetDlgCtrlID(okButton);
            }
            if (!IsWindowVisible(okButton) || !IsWindowEnabled(okButton)) { return IntPtr.Zero; }
            return okButton;
        }

        // Delivers what a click on OK delivers to the dialog: WM_COMMAND(<button id>, BN_CLICKED) from the button.
        // Posted, not sent: never waits for the game and needs no focus or foreground.
        // Locked session: expected to work (PostMessage needs no focus), not yet measured.
        // Returns null when OK was sent, else the reason it was not.
        public static string ClickOk(IntPtr dialog)
        {
            int controlId;
            IntPtr okButton = FindOkButton(dialog, out controlId);
            if (okButton == IntPtr.Zero) { return "no OK button"; }
            IntPtr wParam = new IntPtr((BN_CLICKED << 16) | (controlId & 0xFFFF));
            if (!PostMessage(dialog, WM_COMMAND, wParam, okButton))
            {
                return "PostMessage failed (error " + Marshal.GetLastWin32Error() + ")";
            }
            return null;
        }
    }
}
'@

function Initialize-GameWindows {
    # Add-Type once per session: adding the same type a second time fails. A failed compile is kept and
    # rethrown, so it is not retried on every dialog check. Parameters exist for the tests.
    param([string]$TypeName = 'BannerlordTestRig.GameWindows', [string]$Source = $script:GameWindowsSource)
    if ($TypeName -as [type]) { return }
    if ($null -ne $script:GameWindowsInitError) { throw $script:GameWindowsInitError }
    try { Add-Type -TypeDefinition $Source }
    catch {
        $script:GameWindowsInitError = $_.Exception
        throw
    }
}

function Get-GameDialogs {
    # Visible standard dialogs (#32770) of the process, as objects with Handle and Title.
    param([int]$ProcessId)
    Initialize-GameWindows
    foreach ($handle in [BannerlordTestRig.GameWindows]::FindVisibleDialogs($ProcessId)) {
        [pscustomobject]@{ Handle = $handle; Title = [BannerlordTestRig.GameWindows]::GetTitle($handle) }
    }
}

function Confirm-KnownGameDialog {
    # Sends OK to the dialog. Returns $null when OK was sent, else the reason it was not.
    param($Dialog)
    Initialize-GameWindows
    return [BannerlordTestRig.GameWindows]::ClickOk($Dialog.Handle)
}

function Invoke-GameDialogCheck {
    # One look at the game's dialogs: sends OK to the known titles (once per dialog window), logs any
    # other title once per run, and logs once if a dialog is still open DialogStillOpenSeconds after OK.
    # Never throws: a failing check must not end the supervision.
    # $State is per run: @{ Handled = @{}; Seen = @{}; FailureLogged = $false }.
    param([int]$ProcessId, [hashtable]$State, $Record)
    try {
        foreach ($dialog in @(Get-GameDialogs -ProcessId $ProcessId)) {
            $handleKey = [string]$dialog.Handle
            $handled = $State.Handled[$handleKey]
            if ($null -ne $handled) {   # OK was sent (or could not be) already; never a second time
                if ($null -ne $handled.OkSentUtc -and -not $handled.StillOpenLogged -and
                    ([DateTime]::UtcNow - $handled.OkSentUtc).TotalSeconds -ge $script:DialogStillOpenSeconds) {
                    $handled.StillOpenLogged = $true
                    Write-AgentLog "Dialog '$($dialog.Title)' still open after confirm"
                }
                continue
            }
            if ($script:ConfirmableDialogTitles -ccontains $dialog.Title) {
                $handled = @{ OkSentUtc = $null; StillOpenLogged = $false }
                $State.Handled[$handleKey] = $handled
                $failure = Confirm-KnownGameDialog -Dialog $dialog
                if ($null -eq $failure) {
                    $handled.OkSentUtc = [DateTime]::UtcNow
                    Write-AgentLog "Dismissed dialog '$($dialog.Title)' (pid $ProcessId)."
                    $Record.dismissedDialogs = @($Record.dismissedDialogs) + $dialog.Title
                }
                else { Write-AgentLog "Could not confirm dialog '$($dialog.Title)': $failure" }
            }
            elseif (-not $State.Seen.ContainsKey($dialog.Title)) {
                $State.Seen[$dialog.Title] = $true
                Write-AgentLog "Game dialog seen: '$($dialog.Title)'"
            }
        }
    }
    catch {
        if (-not $State.FailureLogged) {
            $State.FailureLogged = $true
            Write-AgentLog "Dialog check failed (supervision continues): $($_.Exception.Message)"
        }
    }
}

function Invoke-Run {
    # One run: patch configs, write run.cfg, launch, supervise, classify, collect.
    # Writes results\<jobId>\<runId>\agent-run.json and returns it as a hashtable.
    param($Config, [hashtable]$Context, $Run, [string[]]$Modules, [string[]]$PackageModuleIds = @(), [int]$RunIndex, [string]$ResultsDir)

    $runId = $Run.runId
    $runDir = Join-Path $ResultsDir $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $docs = Join-Path $Config.documentsRoot 'Mount and Blade II Bannerlord'
    $configsDir = Join-Path $docs 'Configs'
    $mcmPath = Join-Path $configsDir 'ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json'
    $modLogDir = Join-Path $docs 'CoherentWarAI'
    $harnessDir = Get-HarnessDir $Config ([string]$Run.harness)   # $null for an unknown harness (rejected below)
    $runCfgPath = $resultPath = $runResultPath = $harnessLogPath = $null
    if ($harnessDir) {
        $runCfgPath = Join-Path $harnessDir 'run.cfg'
        $resultPath = Join-Path $harnessDir 'result.txt'
        $runResultPath = Join-Path $harnessDir 'run-result.json'
        $harnessLogPath = Join-Path $harnessDir 'harness.log'
    }
    $engineLogDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Mount and Blade II Bannerlord\logs'

    $record = [ordered]@{
        schema = 1; runId = $runId; exitClass = 'SetupError'; pid = $null
        startedUtc = (Get-UtcStamp); endedUtc = $null; artifacts = @(); baselineRestored = $null; message = $null
        dismissedDialogs = @()
    }
    $process = $null
    $runCfgTouched = $false
    $startedAt = [DateTime]::UtcNow
    $aborted = $false
    $timedOut = $false
    $killFailed = $false
    $superviseError = $null
    $deadline = $null

    try {
        if (-not $harnessDir) { throw [System.InvalidOperationException]("Unknown harness '$($Run.harness)'.") }
        # The harness module must be in this job's package and load order; otherwise the game would
        # start without it, or with a stale copy installed by an earlier job.
        $harnessModule = $script:Harnesses[[string]$Run.harness].Module
        if (@($PackageModuleIds) -notcontains $harnessModule) { throw [System.InvalidOperationException]("Harness module '$harnessModule' is not in the package.") }
        if (@($Modules) -notcontains $harnessModule) { throw [System.InvalidOperationException]("Harness module '$harnessModule' is not in job.modules.") }
        if ($script:ValidModes -notcontains $Run.mode) { throw [System.InvalidOperationException]("Unknown mode '$($Run.mode)'.") }

        Write-JobState -Context $Context -State 'installing' -RunId $runId -RunIndex $RunIndex
        New-Item -ItemType Directory -Path $configsDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path $mcmPath) -Force | Out-Null
        Set-BannerlordConfigValues (Join-Path $configsDir 'BannerlordConfig.txt')
        Set-McmSettingsValues $mcmPath ($Run.mode -ne 'FeatureOff')

        New-Item -ItemType Directory -Path $harnessDir -Force | Out-Null
        foreach ($stale in @($resultPath, $runResultPath, ($runResultPath + '.tmp'), $harnessLogPath)) {
            if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
        }
        $ownAssemblies = @()
        if ([string]$Run.harness -eq 'TestRig') {
            $ownAssemblies = @(Get-OwnAssemblyNames -ModulesDir (Get-ModulesDir $Config) `
                -ModuleIds $PackageModuleIds -HarnessModuleIds @($script:Harnesses.Values | ForEach-Object { $_.Module }))
        }
        $runCfgTouched = $true   # before the write: a partial file must be deleted too
        Write-Utf8Text $runCfgPath (Get-RunCfgText $Run -OwnAssemblies $ownAssemblies) $false

        # Compile the Win32 helper here, not inside the supervision. Not fatal: the run goes on without dialog handling.
        try { Initialize-GameWindows }
        catch { Write-AgentLog "Game dialog check unavailable: $($_.Exception.Message)" }
        $arguments = Get-GameArguments -Prefix $Config.gameArgumentsPrefix -Modules $Modules
        Write-AgentLog "Launching: $($Config.gameExecutable) $arguments"
        $startedAt = [DateTime]::UtcNow
        $record.startedUtc = Get-UtcStamp
        # Everything that can throw happens before Start-Process; after it only the supervision try below runs.
        $deadline = $startedAt.AddMinutes([double]$Run.hardTimeoutMinutes)
        $process = Start-Process -FilePath $Config.gameExecutable -ArgumentList $arguments `
            -WorkingDirectory (Split-Path $Config.gameExecutable) -PassThru -NoNewWindow
    }
    catch {
        $record.message = $_.Exception.Message
        Write-AgentLog "Run $runId setup failed: $($record.message)"
    }

    if ($null -ne $process) {
        $abortFile = Join-Path $Context.JobDir 'abort'
        $nextAbortCheck = $startedAt
        $nextBeat = $startedAt
        $nextDialogCheck = $startedAt
        $dialogState = @{ Handled = @{}; Seen = @{}; FailureLogged = $false }
        try {
            $null = $process.Handle   # keep the handle so ExitCode stays readable
            $record.pid = $process.Id
            while ($true) {
                $now = [DateTime]::UtcNow
                if ($now -ge $nextAbortCheck) {
                    if (Test-Path -LiteralPath $abortFile) { $aborted = $true; $Context.AbortSeen = $true; break }   # kept apart from exitClass: CleanupFailed overrides it
                    $nextAbortCheck = $now.AddSeconds($script:AbortCheckSeconds)
                }
                if ($now -ge $nextDialogCheck) {
                    Invoke-GameDialogCheck -ProcessId $process.Id -State $dialogState -Record $record
                    $nextDialogCheck = $now.AddSeconds($script:DialogCheckSeconds)
                }
                if ($now -ge $nextBeat) {
                    Write-JobState -Context $Context -State 'running' -RunId $runId -RunIndex $RunIndex `
                        -LastHarnessLine (Get-LastLogLine $harnessLogPath)
                    $nextBeat = $now.AddSeconds($Config.heartbeatSeconds)
                }
                if ($process.WaitForExit(250)) { break }
                if ([DateTime]::UtcNow -ge $deadline) { $timedOut = $true; break }
            }
        }
        catch {
            $superviseError = "Supervision failed: $($_.Exception.Message)"
            Write-AgentLog "Run $runId $superviseError"
        }
        finally {
            # Whatever happened above, the game must not outlive this block.
            $stillRunning = $true
            try { $stillRunning = -not $process.HasExited } catch { }
            if ($stillRunning) {
                if ($aborted) { Write-AgentLog "Abort requested - killing the game (process tree)." }
                elseif ($timedOut) { Write-AgentLog "Hard timeout after $($Run.hardTimeoutMinutes) min - killing the game (process tree)." }
                $stopBeat = {
                    Write-JobState -Context $Context -State 'running' -RunId $runId -RunIndex $RunIndex -Message 'stopping game'
                }   # no closure: it runs in the dynamic scope of Invoke-Run and sees these variables and the script functions
                if (-not (Stop-ProcessTree $process -Heartbeat $stopBeat)) { $killFailed = $true }
            }
        }
    }

    # run.cfg must not outlive the run
    $runCfgRemoved = $true
    if ($runCfgTouched) {
        try { if (Test-Path -LiteralPath $runCfgPath) { Remove-Item -LiteralPath $runCfgPath -Force } }
        catch { $runCfgRemoved = $false; Write-AgentLog "Could not remove run.cfg: $($_.Exception.Message)" }
    }

    if ($null -ne $process) {
        $elapsedSeconds = ([DateTime]::UtcNow - $startedAt).TotalSeconds
        $status = if ($harnessDir) { Get-ResultStatus $harnessDir } else { $null }
        if ($killFailed -or -not $runCfgRemoved) {
            $record.exitClass = 'CleanupFailed'
            $record.message = 'The game could not be stopped or run.cfg could not be removed.'
        }
        elseif ($aborted) { $record.exitClass = 'Aborted' }
        elseif ($null -ne $superviseError) { $record.exitClass = 'SetupError'; $record.message = $superviseError }
        elseif ($timedOut) { $record.exitClass = 'HardTimeout' }
        elseif ($status -eq 'Completed') { $record.exitClass = 'Completed' }
        elseif ($elapsedSeconds -lt $script:LaunchFailedSeconds -and -not (Test-Path -LiteralPath $harnessLogPath)) {
            $record.exitClass = 'LaunchFailed'
        }
        else { $record.exitClass = 'NotCompleted' }
    }
    elseif (-not $runCfgRemoved) {
        $record.exitClass = 'CleanupFailed'
    }

    # artifacts
    Write-JobState -Context $Context -State 'collecting' -RunId $runId -RunIndex $RunIndex
    $copies = @()
    if ($harnessDir) {
        $copies += @{ Name = 'run-result.json'; Source = $runResultPath }
        $copies += @{ Name = 'result.txt'; Source = $resultPath }
        $copies += @{ Name = 'harness.log'; Source = $harnessLogPath }
    }
    $copies += @{ Name = 'CoherentWarAI.log'; Source = (Join-Path $modLogDir 'CoherentWarAI.log') }
    if ($null -ne $process) {
        $copies += @{ Name = "rgl_log_$($process.Id).txt"; Source = (Join-Path $engineLogDir "rgl_log_$($process.Id).txt") }
        $copies += @{ Name = "rgl_log_errors_$($process.Id).txt"; Source = (Join-Path $engineLogDir "rgl_log_errors_$($process.Id).txt") }
    }
    $record.artifacts = @(Copy-RunArtifacts -Copies $copies -Since $startedAt.AddSeconds(-2) -TargetDir $runDir)
    $record.endedUtc = Get-UtcStamp
    Write-JsonAtomic (Join-Path $runDir 'agent-run.json') $record
    Write-AgentLog "Run $runId finished: $($record.exitClass)"
    return $record
}

# ---------------------------------------------------------------------------
# Job and loop
# ---------------------------------------------------------------------------

function New-Outcome {
    param([string]$Status, $Message = $null, $Runs = @())   # $Message untyped: $null must stay $null
    return @{ Status = $Status; Message = $Message; Runs = @($Runs) }
}

function Invoke-JobSteps {
    # Everything between claim and done.json. Returns an outcome (Status, Message, Runs).
    param($Config, [hashtable]$Context)

    Write-JobState -Context $Context -State 'claimed'
    $claimed = Join-Path $Context.JobDir 'job.claimed.json'
    try { $job = (Read-Utf8Text $claimed) | ConvertFrom-Json }
    catch { return New-Outcome 'rejected' "job.json is not valid JSON: $($_.Exception.Message)" }

    $errors = @(Test-JobSchema $job $Context.JobId)
    if ($errors.Count -gt 0) { return New-Outcome 'rejected' ($errors -join ' ') }
    $Context.RunCount = @($job.runs).Count

    $package = Expand-JobPackage -Config $Config -Job $job -JobDir $Context.JobDir
    if (-not $package.Ok) { return New-Outcome 'rejected' $package.Message }

    $blocked = Get-PreflightError $Config
    if ($blocked) { return New-Outcome 'blocked' $blocked }

    $abortFile = Join-Path $Context.JobDir 'abort'
    $total = @($job.runs).Count
    if (Test-Path -LiteralPath $abortFile) {
        $Context.AbortSeen = $true
        return New-Outcome 'aborted' "Abort requested before the install; $total run(s) not executed."
    }

    Write-JobState -Context $Context -State 'installing'
    Install-JobModules -Config $Config -PackageRoot $package.PackageRoot -ModuleIds $package.ModuleIds

    $summaries = @()
    $message = $null
    $cleanupFailed = $false
    $index = 0
    foreach ($run in @($job.runs)) {
        if (Test-Path -LiteralPath $abortFile) {
            $Context.AbortSeen = $true
            $message = "Abort requested; $($total - $summaries.Count) run(s) not executed."
            break
        }
        $index++
        $record = Invoke-Run -Config $Config -Context $Context -Run $run -Modules @($job.modules) -PackageModuleIds @($package.ModuleIds) `
            -RunIndex $index -ResultsDir $Context.ResultsDir
        $summaries += @{ runId = $record.runId; exitClass = $record.exitClass }
        # CleanupFailed: the game may still be running or run.cfg is left behind - never launch another one.
        if ($record.exitClass -eq 'CleanupFailed') {
            $cleanupFailed = $true
            $message = "Run $($record.runId): the game could not be stopped or run.cfg could not be removed; $($total - $summaries.Count) run(s) not executed."
            break
        }
        if ($Context.AbortSeen) { break }
    }
    # An abort seen anywhere wins; exitClass CleanupFailed stays in the run summary (the runner maps it to exit 1).
    $status = if ($Context.AbortSeen) { 'aborted' } elseif ($cleanupFailed) { 'failed' } else { 'completed' }
    return New-Outcome $status $message $summaries
}

function Invoke-Job {
    # Never throws. Always ends with done.json (written atomically, last).
    param($Config, [hashtable]$Job)
    $context = @{
        JobId      = $Job.JobId
        JobDir     = $Job.Dir
        ResultsDir = Join-Path (Join-Path $Config.queueRoot 'results') $Job.JobId
        Beat       = 0
        RunCount   = 0
        AbortSeen  = $false
    }
    Write-AgentLog "Job $($Job.JobId) claimed."
    try {
        New-Item -ItemType Directory -Path $context.ResultsDir -Force | Out-Null
        $outcome = Invoke-JobSteps -Config $Config -Context $context
    }
    catch {
        Write-AgentLog "Job $($Job.JobId) failed: $($_.Exception.Message)"
        $outcome = New-Outcome 'failed' $_.Exception.Message
    }
    try {
        Write-JobState -Context $context -State 'finished' -Message $outcome.Message
        $done = [ordered]@{
            schema      = 1
            jobId       = $Job.JobId
            status      = $outcome.Status
            finishedUtc = Get-UtcStamp
            runs        = @($outcome.Runs)
            message     = $outcome.Message
        }
        New-Item -ItemType Directory -Path $context.ResultsDir -Force | Out-Null
        Write-JsonAtomic (Join-Path $context.ResultsDir 'done.json') $done
        Write-AgentLog "Job $($Job.JobId) done: $($outcome.Status)"
    }
    catch {
        Write-AgentLog "Job $($Job.JobId): done.json could not be written: $($_.Exception.Message)"
    }
}

function Resolve-OrphanedJobs {
    # Startup recovery (the caller holds the mutex, so no job is active). A job.claimed.json
    # without results\<id>\done.json belongs to an agent that died mid-job: finish it as
    # failed so the runner stops waiting, and remove a harness run.cfg the dead run left behind.
    param($Config)
    $jobsRoot = Join-Path $Config.queueRoot 'jobs'
    if (-not (Test-Path -LiteralPath $jobsRoot -PathType Container)) { return }
    $orphans = 0
    foreach ($dir in @(Get-ChildItem -LiteralPath $jobsRoot -Directory | Sort-Object Name)) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'job.claimed.json') -PathType Leaf)) { continue }
        $resultsDir = Join-Path (Join-Path $Config.queueRoot 'results') $dir.Name
        $donePath = Join-Path $resultsDir 'done.json'
        if (Test-Path -LiteralPath $donePath -PathType Leaf) { continue }
        $orphans++
        New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
        $done = [ordered]@{
            schema      = 1
            jobId       = $dir.Name
            status      = 'failed'
            finishedUtc = Get-UtcStamp
            runs        = @()
            message     = 'agent restarted during job'
        }
        Write-JsonAtomic $donePath $done
        Write-AgentLog "Orphaned job $($dir.Name) (claimed, no done.json): finished as failed."
    }
    if ($orphans -gt 0) {
        foreach ($harness in $script:Harnesses.Keys) {
            $runCfg = Join-Path (Get-HarnessDir $Config $harness) 'run.cfg'
            if (Test-Path -LiteralPath $runCfg) {
                Remove-Item -LiteralPath $runCfg -Force
                Write-AgentLog "Removed leftover harness run.cfg: $runCfg"
            }
        }
    }
}

function Invoke-AgentCycle {
    # One poll: claim and process the oldest job. Returns $true if a job was handled.
    # Never throws.
    param($Config)
    try {
        $job = Get-NextJob -QueueRoot $Config.queueRoot
        if ($null -eq $job) { return $false }
        Invoke-Job -Config $Config -Job $job
        return $true
    }
    catch {
        Write-AgentLog "Unexpected error in poll cycle: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-AgentMain {
    # Returns the process exit code.
    param([string]$ConfigPath, [switch]$Once)
    try {
        $config = Get-AgentConfig -Path $ConfigPath
        New-Item -ItemType Directory -Path $config.workRoot -Force | Out-Null
        $script:AgentLogPath = Join-Path $config.workRoot 'agent.log'
    }
    catch {
        Write-Host "Agent configuration error: $($_.Exception.Message)"
        return 1
    }

    $mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $owned = $true }   # previous agent died
        if (-not $owned) {
            Write-AgentLog "Another agent instance holds $($script:MutexName) - exiting."
            return 0
        }
        Write-AgentLog "Agent started (queue $($config.queueRoot), once=$([bool]$Once))."
        try { Resolve-OrphanedJobs -Config $config }
        catch { Write-AgentLog "Orphan recovery failed: $($_.Exception.Message)" }
        while ($true) {
            $handled = Invoke-AgentCycle -Config $config
            if ($Once) { break }
            if (-not $handled) { Start-Sleep -Milliseconds ([int]($config.pollSeconds * 1000)) }
        }
        return 0
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'agent.config.json' }
    exit (Invoke-AgentMain -ConfigPath $ConfigPath -Once:$Once)
}
