<#
.SYNOPSIS
    Bannerlord test rig agent (job protocol schema 1, slice S1). Runs on the test PC.

.DESCRIPTION
    Polls <queueRoot>\jobs for jobs published by the runner, installs the job's package
    into the game, runs the soak harness, and writes the results back. The contract is
    docs\JOB-PROTOCOL.md. Windows PowerShell 5.1, self-contained: this file runs alone
    (C:\TestRig\agent\); Save-TestRigBaseline.ps1 next to it dot-sources it.

    Single instance: the named mutex Global\BannerlordTestRigAgent. A second instance
    exits 0 with a message. While it claims and runs a job the agent also holds the named mutex
    Global\BannerlordTestRigConfig, which Save-TestRigBaseline.ps1 needs.

    The rig owns the game configuration on the test PC. Before each run the agent restores
    the baseline (<baselineRoot>, recorded by Save-TestRigBaseline.ps1: BannerlordConfig.txt
    and the MCM folders of the rig's mods) and then patches BannerlordConfig.txt and the
    CoherentWarAI MCM json for the run; after the job it restores the baseline again.

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
# Held by the agent while it claims and runs a job and by Save-TestRigBaseline.ps1 while it saves: the two never
# change the game configuration or the baseline at the same time. Global\ because Save typically runs over SSH while
# the agent runs in the console session.
$script:ConfigMutexName = 'Global\BannerlordTestRigConfig'
# <workRoot>\<this>: written before a job first changes the game configuration, deleted only after a successful restore
# of the baseline. While it exists Save-TestRigBaseline.ps1 refuses (the documents may still hold the run patch).
$script:RestorePendingFile = 'restore-pending'
$script:ValidModes = @('WarSails', 'NoDlc', 'FeatureOff', 'ChainOff')
$script:LaunchFailedSeconds = 30
$script:AbortCheckSeconds = 3
$script:DialogCheckSeconds = 1
$script:CrashCheckSeconds = 1   # how often the supervision looks for "Crash occurred" in the watchdog log
$script:HarnessLogCheckSeconds = 1   # how often the supervision reads the growth of harness.log
# TestRig harness only: no new "<seconds> Alive: ..." line in harness.log for longer than this = Hung. The harness writes
# one every 10 s from the main thread (largest gap measured in a real run: 14.5 s).
$script:SilenceSeconds = 60
$script:SilenceStatusRetries = 2   # passes a result that cannot be read (being replaced) is re-checked before Hung
# After an UnhandledException line the harness still writes its final run-result.json (unhandled:<phase>, exception
# counts, also a rewrite of a result that was final already); the agent waits at most this long for that result (or the
# exit) before it kills the game.
$script:UnhandledResultGraceSeconds = 5
$script:HarnessLogReadMaxBytes = 1048576   # most one growth read takes in; an unterminated chunk this large is dropped as one line
$script:MessageLineMaxChars = 200   # harness.log lines quoted in a run message are cut to this
$script:FinalCrashCheckSeconds = 2  # after the game exited on its own, the watchdog may still write "Crash occurred"
$script:DialogStillOpenSeconds = 5   # a dialog still open this long after OK was sent is logged once
$script:GameWindowsInitError = $null   # set when compiling the Win32 helper failed; rethrown instead of recompiling
# Game dialogs the agent confirms with OK (exact, case-sensitive title). The engine shows this one on the
# first start after the active module list changed; unattended it blocks the run until HardTimeout.
$script:ConfirmableDialogTitles = @('Mod change detected')
# Game dialogs the agent answers with No (exact, case-sensitive title). The engine asks this on the start after a run
# it did not end itself ("Game shut down unexpectedly on previous session. Would you like to enable safe mode?").
# Reset-EngineSafelyExited normally prevents it; this is the fallback.
$script:DeclinedDialogTitles = @('Safe Mode')
$script:StopSliceMilliseconds = 5000   # Stop-ProcessTree waits in slices of at most this, with a heartbeat between
# Logs of the other mods, collected per run like CoherentWarAI.log (a missing one is not an error). RelativePath is below
# <documentsRoot>\Mount and Blade II Bannerlord, where each mod writes it: AutoTraderSpeed via EngineFilePaths.ConfigsPath
# (AutoTrader\src\AutoTraderHelpers.cs), SmithingSuite (src\Integration\SmithingLog.cs), CompanionManagementSuite
# (src\Diagnostics\SuiteLog.cs).
$script:ModLogFiles = @(
    @{ Name = 'AutoTrader.log'; RelativePath = 'Configs\AutoTrader.log' },
    @{ Name = 'smithingsuite.log'; RelativePath = 'SmithingSuite\smithingsuite.log' },
    @{ Name = 'companion-suite.log'; RelativePath = 'CompanionManagementSuite\companion-suite.log' }
)
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
    # Creates the file with only the four keys if it does not exist. $Mode is the run's job.json mode:
    # WarSails and NoDlc: every feature on.
    # FeatureOff: only the marshal doctrine (army lock) off; chain of command and naval orders stay on,
    #   so naval orders bind lords the same way in both arms of a comparison.
    # ChainOff: chain of command and naval orders off, the doctrine on (pre-chain-of-command baseline of AC25a,
    #   doctrine only).
    # Logging stays on in every mode (the command log is read by the suite checks).
    param([string]$Path, [ValidateSet('WarSails', 'NoDlc', 'FeatureOff', 'ChainOff')][string]$Mode)
    $chainOff = $Mode -eq 'ChainOff'
    $expected = @{
        EnableMarshalDoctrine = $Mode -ne 'FeatureOff'
        EnableChainOfCommand  = -not $chainOff
        EnableNavalOrders     = -not $chainOff
        EnableLogging         = $true
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $bom = Test-Utf8Bom $Path
        $text = Read-Utf8Text $Path
    }
    else {
        $bom = $false
        $text = "{`r`n}`r`n"
    }
    foreach ($name in @('EnableMarshalDoctrine', 'EnableChainOfCommand', 'EnableNavalOrders', 'EnableLogging')) {
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

function Get-SteamProcess {
    # Separate function so tests can mock it.
    return @(Get-Process -Name 'steam' -ErrorAction SilentlyContinue)
}

function Get-GameProcess {
    # Processes named $Name (the game executable's file name without .exe). Separate function so tests can mock it.
    param([string]$Name)
    return @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
}

function Enter-ConfigLock {
    # Takes the mutex ConfigMutexName without waiting. Returns the held mutex (release it with Exit-ConfigLock), or $null
    # if another process holds it. An abandoned mutex (its holder died) counts as taken.
    $mutex = New-Object System.Threading.Mutex($false, $script:ConfigMutexName)
    $owned = $false
    try { $owned = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        $mutex.Dispose()
        return $null
    }
    return $mutex
}

function Exit-ConfigLock {
    param($Mutex)
    if ($null -eq $Mutex) { return }
    $Mutex.ReleaseMutex()
    $Mutex.Dispose()
}

function Get-RestorePendingPath {
    param($Config)
    return (Join-Path $Config.workRoot $script:RestorePendingFile)
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

function Resolve-ConfigFolder {
    # Normalized absolute form of a folder from agent.config.json (no trailing separator except at a drive root).
    # Only X:\... and \\server\share\... are accepted: a relative path, a drive-relative 'C:x' or a rooted '\x'
    # (which [IO.Path]::IsPathRooted accepts) would depend on the agent's working directory or drive.
    # The device and long-path forms \\?\... and \\.\... are rejected too: GetFullPath passes them through unchanged, so
    # they would slip past the textual overlap check as another spelling of a local folder.
    param([string]$Key, [string]$Path)
    if ($Path -notmatch '^([A-Za-z]:[\\/]|[\\/]{2}[^\\/])') { throw "agent.config.json: '$Key' must be an absolute path (X:\... or \\server\share\...), got '$Path'." }
    if ($Path -match '^[\\/]{2}[?.][\\/]') { throw "agent.config.json: '$Key' must not use the \\?\ or \\.\ form, got '$Path'." }
    try { $full = [System.IO.Path]::GetFullPath($Path) }
    catch { throw "agent.config.json: '$Key' is not a valid path ('$Path'): $($_.Exception.Message)" }
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

function Test-FolderOverlap {
    # True if two normalized absolute folders are the same or one lies inside the other (case-insensitive,
    # whole path segments: C:\a\b does not lie inside C:\a\bc).
    param([string]$A, [string]$B)
    $a = $A.TrimEnd('\') + '\'
    $b = $B.TrimEnd('\') + '\'
    return ($a.StartsWith($b, [System.StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a, [System.StringComparison]::OrdinalIgnoreCase))
}

function Assert-NoReparsePointOnPath {
    # Throws if $Path or any of its existing ancestors is a reparse point (junction, symbolic link, mount point): through
    # one the folder could be the game's documents folder under another name, which the textual overlap check cannot see.
    # Parts that do not exist yet are skipped.
    param([string]$Key, [string]$Path)
    $current = $Path
    while (-not [string]::IsNullOrEmpty($current)) {
        $attributes = $null
        try { $attributes = [System.IO.File]::GetAttributes($current) }   # the link itself, not its target
        catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { }
        if ($null -ne $attributes -and ($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "agent.config.json: '$Key' ($Path) must not be or lie below a junction or symbolic link ($current)."
        }
        $current = [System.IO.Path]::GetDirectoryName($current)
    }
}

function Get-AgentConfig {
    param([string]$Path)
    $raw = (Read-Utf8Text $Path) | ConvertFrom-Json
    foreach ($key in @('queueRoot', 'workRoot', 'gamePath')) {
        if ([string]::IsNullOrWhiteSpace($raw.$key)) { throw "agent.config.json: '$key' is required." }
    }
    $cfg = [ordered]@{
        queueRoot           = [string]$raw.queueRoot
        workRoot            = Resolve-ConfigFolder 'workRoot' ([string]$raw.workRoot)
        gamePath            = [string]$raw.gamePath
        gameExecutable      = [string]$raw.gameExecutable
        gameArgumentsPrefix = '/singleplayer'
        documentsRoot       = [string]$raw.documentsRoot
        baselineRoot        = [string]$raw.baselineRoot
        engineLogDir        = [string]$raw.engineLogDir
        workshopRoot        = [string]$raw.workshopRoot
        pollSeconds         = 10
        heartbeatSeconds    = 10
        moduleAllowlist     = @('CoherentWarAI', 'AutoTraderSpeed', 'SmithingSuite',
            'CompanionManagementSuite', 'TestRig.Harness', 'TestRig.SelfTest', '*.Scenarios')
    }
    if ([string]::IsNullOrWhiteSpace($cfg.gameExecutable)) {
        $cfg.gameExecutable = Join-Path $cfg.gamePath 'bin\Win64_Shipping_Client\Bannerlord.exe'
    }
    if ($null -ne $raw.gameArgumentsPrefix) { $cfg.gameArgumentsPrefix = [string]$raw.gameArgumentsPrefix }
    if ([string]::IsNullOrWhiteSpace($cfg.documentsRoot)) {
        $cfg.documentsRoot = [Environment]::GetFolderPath('MyDocuments')
    }
    $cfg.documentsRoot = Resolve-ConfigFolder 'documentsRoot' $cfg.documentsRoot
    if ([string]::IsNullOrWhiteSpace($cfg.baselineRoot)) {
        # <parent of workRoot>\baseline, e.g. C:\TestRig\work -> C:\TestRig\baseline
        $workParent = [System.IO.Path]::GetDirectoryName($cfg.workRoot)
        if ([string]::IsNullOrEmpty($workParent)) { throw "agent.config.json: 'baselineRoot' is required when workRoot has no parent folder." }
        $cfg.baselineRoot = [System.IO.Path]::Combine($workParent, 'baseline')
    }
    $cfg.baselineRoot = Resolve-ConfigFolder 'baselineRoot' $cfg.baselineRoot
    # Restore and Save-TestRigBaseline.ps1 delete inside <baselineRoot>\Configs and inside the game's documents
    # folder: the two trees must never overlap.
    $gameDocs = Join-Path $cfg.documentsRoot 'Mount and Blade II Bannerlord'
    if (Test-FolderOverlap $cfg.baselineRoot $gameDocs) {
        throw "agent.config.json: 'baselineRoot' ($($cfg.baselineRoot)) must not be, contain or lie inside the game's documents folder ($gameDocs)."
    }
    Assert-NoReparsePointOnPath 'baselineRoot' $cfg.baselineRoot
    if ([string]::IsNullOrWhiteSpace($cfg.engineLogDir)) {
        $cfg.engineLogDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Mount and Blade II Bannerlord\logs'
    }
    if ([string]::IsNullOrWhiteSpace($cfg.workshopRoot)) {
        # gamePath is <steamapps>\common\<game>; the workshop items of Bannerlord (app 261550) live in <steamapps>\workshop.
        $common = [System.IO.Path]::GetDirectoryName($cfg.gamePath.TrimEnd('\', '/'))
        $steamapps = if ($common) { [System.IO.Path]::GetDirectoryName($common) } else { $null }
        $cfg.workshopRoot = if ($steamapps) { [System.IO.Path]::Combine($steamapps, 'workshop\content\261550') } else { $null }
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

function Test-ScenarioIdList {
    # Errors for the run field $Field ('scenarios', 'health' or 'ownAssemblies'), which must be a non-empty array of
    # unique ids (case-insensitive; [A-Za-z0-9._-]+: they are written to a comma-separated run.cfg line).
    param([string]$RunLabel, [string]$Field, $Run)
    $list = $null
    if ($Run.PSObject.Properties.Name -contains $Field) { $list = $Run.$Field }   # not `$x = if`: that unrolls a one-element array to a scalar
    if ($list -isnot [System.Array] -or $list.Count -eq 0) { return @("${RunLabel}: '$Field' must be a non-empty array of ids.") }
    $errs = @()
    $seenIds = @{}
    foreach ($sid in $list) {
        if ($sid -isnot [string] -or $sid -cnotmatch '\A[A-Za-z0-9._-]+\z') { $errs += "${RunLabel}: invalid id '$sid' in '$Field' (allowed: letters, digits, '.', '_', '-')."; continue }
        if ($seenIds.ContainsKey($sid)) { $errs += "${RunLabel}: duplicate id '$sid' in '$Field'." }
        $seenIds[$sid] = $true
    }
    return $errs
}

function Test-RunKindSchema {
    # kind is 'soak' or 'scenarios'. A scenarios run needs a non-empty scenarios array of unique ids; a soak run has
    # none. A soak run may carry 'health' (the health bracket, F-S6-1): a non-empty array of unique ids; a scenarios
    # run never does. Ids: see Test-ScenarioIdList.
    param($Run)
    $errs = @()
    $id = "Run $($Run.runId)"
    $names = $Run.PSObject.Properties.Name
    $hasScenarios = $names -contains 'scenarios'
    $hasHealth = $names -contains 'health'
    if ($Run.kind -isnot [string] -or $Run.kind -eq '') { return $errs }   # reported as required by the caller
    if ($names -contains 'ownAssemblies') {   # any kind
        $errs += @(Test-ScenarioIdList -RunLabel $id -Field 'ownAssemblies' -Run $Run)
    }
    if ($Run.kind -ceq 'soak') {
        if ($hasScenarios) { $errs += "${id}: 'scenarios' is only allowed for kind 'scenarios'." }
        if ($hasHealth) { $errs += @(Test-ScenarioIdList -RunLabel $id -Field 'health' -Run $Run) }
        return $errs
    }
    if ($Run.kind -cne 'scenarios') { return @("${id}: unknown kind '$($Run.kind)' (allowed: soak, scenarios).") }
    if ($hasHealth) { $errs += "${id}: 'health' is only allowed for kind 'soak'." }
    return @($errs + @(Test-ScenarioIdList -RunLabel $id -Field 'scenarios' -Run $Run))
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
        if ($run.harness -is [string] -and $run.harness -ne '' -and $run.harness -cne 'TestRig') {
            $errors += "Run $($run.runId): harness '$($run.harness)' is not supported (only 'TestRig')."
        }
        $errors += @(Test-RunKindSchema $run)
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

function Get-ModulesDir {
    param($Config)
    return (Join-Path $Config.gamePath 'Modules')
}

# --- Preflight: processes, game version, required modules ---------------------

function Read-XmlFile {
    # Parses an XML file without DTD processing or external resolution; the encoding comes from the BOM
    # or the XML declaration. Throws if the file is missing or not well-formed. The file is opened as a stream:
    # XmlReader.Create(string) would take the path as a URI.
    param([string]$Path)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $reader = [System.Xml.XmlReader]::Create($stream, $settings)
        try {
            $doc = New-Object System.Xml.XmlDocument
            $doc.XmlResolver = $null
            $doc.Load($reader)
            return , $doc
        }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-SubModuleInfo {
    # @{ Id; Version } of a SubModule.xml (<Id value>, <Version value>; $null when absent). Throws if unreadable.
    param([string]$Path)
    $doc = Read-XmlFile $Path
    $id = $doc.SelectSingleNode('/Module/Id/@value')
    $version = $doc.SelectSingleNode('/Module/Version/@value')
    $info = @{ Id = $null; Version = $null }
    if ($null -ne $id) { $info.Id = $id.Value }
    if ($null -ne $version) { $info.Version = $version.Value }
    return $info
}

function Get-GameVersion {
    # Singleplayer version from <gamePath>\bin\Win64_Shipping_Client\Version.xml
    # (<Version><Singleplayer Value="v1.4.8"/>). Throws if the file is missing, unreadable or has no version.
    param($Config)
    $path = Join-Path $Config.gamePath 'bin\Win64_Shipping_Client\Version.xml'
    try {
        $node = (Read-XmlFile $path).SelectSingleNode('/Version/Singleplayer/@Value')
        if ($null -eq $node -or [string]::IsNullOrWhiteSpace($node.Value)) { throw 'no Singleplayer version' }
        return $node.Value.Trim()
    }
    catch { throw "Version.xml unreadable ($path): $($_.Exception.Message)" }
}

function Get-WorkshopModules {
    # Module id (case-insensitive) -> @{ Id; Version } of every <WorkshopRoot>\<item>\SubModule.xml. The id
    # comes from the file, not from the item folder name. An unreadable SubModule.xml is skipped (logged).
    param([string]$WorkshopRoot)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($WorkshopRoot) -or -not (Test-Path -LiteralPath $WorkshopRoot -PathType Container)) { return $map }
    foreach ($item in @(Get-ChildItem -LiteralPath $WorkshopRoot -Directory)) {
        $xmlPath = Join-Path $item.FullName 'SubModule.xml'
        if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) { continue }
        try { $info = Get-SubModuleInfo $xmlPath }
        catch {
            Write-AgentLog "Workshop item $($item.Name): SubModule.xml unreadable, skipped: $($_.Exception.Message)"
            continue
        }
        if ($info.Id -and -not $map.ContainsKey($info.Id)) { $map[$info.Id] = $info }
    }
    return $map
}

function Get-ModuleVersionOrNull {
    param([string]$SubModulePath)
    try { return (Get-SubModuleInfo $SubModulePath).Version }
    catch { return $null }
}

function Get-JobPreflight {
    # Job-level checks before anything is installed, plus the versions every agent-run.json reports.
    # Returns @{ Error = message if the job cannot start, else $null; GameVersion; ModuleVersions } where
    # ModuleVersions lists [ordered]@{ id; version; source = package|game|workshop } in job.modules order.
    param($Config, $Job, [string]$PackageRoot, [string[]]$PackageModuleIds = @())
    $result = @{ Error = $null; GameVersion = $null; ModuleVersions = @() }

    $running = @(Get-BannerlordProcess | Where-Object { $null -ne $_ })
    if ($running.Count -gt 0) { $result.Error = 'Bannerlord.exe is already running.'; return $result }
    if (-not (Test-Path -LiteralPath $Config.gameExecutable -PathType Leaf)) {
        $result.Error = "Game executable not found: $($Config.gameExecutable)"
        return $result
    }
    $steam = @(Get-SteamProcess | Where-Object { $null -ne $_ })
    if ($steam.Count -eq 0) { $result.Error = 'steam.exe is not running.'; return $result }

    $versionError = $null
    try { $result.GameVersion = Get-GameVersion $Config }
    catch { $versionError = $_.Exception.Message }
    $expected = $Job.expectedGameVersion
    if ($null -eq $expected -or ($expected -is [string] -and $expected -eq '')) {
        $found = if ($null -ne $result.GameVersion) { $result.GameVersion } else { "unknown: $versionError" }
        Write-AgentLog "expectedGameVersion is null: game version not checked (installed: $found)."
    }
    elseif ($expected -isnot [string]) {
        $result.Error = 'expectedGameVersion must be a string or null.'
        return $result
    }
    elseif ($null -ne $versionError) {
        $result.Error = "Game version cannot be checked against expectedGameVersion ${expected}: $versionError"
        return $result
    }
    elseif ($result.GameVersion -cne $expected) {
        $result.Error = "Game version $($result.GameVersion) does not match expectedGameVersion $expected."
        return $result
    }

    # Every module of the load order must exist: from the package, else <gamePath>\Modules, else the workshop.
    $modulesDir = Get-ModulesDir $Config
    $workshop = $null   # read on first need only
    $versions = @()
    $missing = @()
    foreach ($id in @($Job.modules)) {
        $gameXml = Join-Path (Join-Path $modulesDir $id) 'SubModule.xml'
        if (@($PackageModuleIds) -contains $id) {
            $source = 'package'
            $version = Get-ModuleVersionOrNull (Join-Path (Join-Path (Join-Path $PackageRoot 'Modules') $id) 'SubModule.xml')
        }
        elseif (Test-Path -LiteralPath $gameXml -PathType Leaf) {
            $source = 'game'
            $version = Get-ModuleVersionOrNull $gameXml
        }
        else {
            if ($null -eq $workshop) { $workshop = Get-WorkshopModules $Config.workshopRoot }
            if (-not $workshop.ContainsKey($id)) { $missing += $id; continue }
            $source = 'workshop'
            $version = $workshop[$id].Version
        }
        $versions += [ordered]@{ id = $id; version = $version; source = $source }
    }
    if ($missing.Count -gt 0) {
        $result.Error = "Module(s) of job.modules not found in the package, the game's Modules folder or the workshop: $($missing -join ', ')."
        return $result
    }
    $result.ModuleVersions = $versions
    $gameText = if ($null -ne $result.GameVersion) { $result.GameVersion } else { 'unknown' }
    Write-AgentLog ("Versions: game $gameText; " + (($versions | ForEach-Object { '{0} {1} ({2})' -f $_.id, $_.version, $_.source }) -join ', '))
    return $result
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
# Baseline: the rig's game configuration, restored before each run and after the job
# ---------------------------------------------------------------------------

# The MCM global-settings folders (FolderName of each mod's settings class) the baseline manages, below
# Configs\ModSettings\Global\. Save-TestRigBaseline.ps1 uses the same list.
$script:BaselineMcmFolders = @('CoherentWarAI', 'AutoTraderSpeed', 'SmithingSuite', 'CompanionManagementSuite')
$script:BaselineConfigFile = 'Configs\BannerlordConfig.txt'
$script:BaselineMcmRoot = 'Configs\ModSettings\Global'
# <baselineRoot>\Configs\<this>: written by Save-TestRigBaseline.ps1 into every baseline it records. Save replaces or
# deletes a folder only if it carries this file; the restore neither needs it nor copies it (it is not a managed file).
$script:BaselineMarkerFile = '.testrig-baseline'

function Assert-NoReparsePoint {
    # Throws if $Item (FileSystemInfo) is a junction, symbolic link or other reparse point: restore and save
    # never follow one, so nothing outside the managed tree can be deleted or overwritten through it.
    param($Item)
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse point (junction or symbolic link) in the managed configuration: $($Item.FullName); remove it by hand."
    }
}

function Add-ManagedFolderFiles {
    # Adds the files below $Dir (relative to $RelDir) to $Files, walking the tree by hand so that a reparse
    # point anywhere is reported instead of followed.
    param([string]$Dir, [string]$RelDir, $Files)
    foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force)) {
        Assert-NoReparsePoint $item
        $rel = Join-Path $RelDir $item.Name
        if ($item.PSIsContainer) { Add-ManagedFolderFiles -Dir $item.FullName -RelDir $rel -Files $Files }
        else { $Files.Add($rel) }
    }
}

function Get-ManagedConfigFiles {
    # Relative paths (backslashes) of the managed files that exist below $Root: Configs\BannerlordConfig.txt and
    # every file in the managed MCM folders. $Root has the layout of <MyDocuments>\Mount and Blade II Bannerlord;
    # the baseline folder mirrors it. Throws if Configs, Configs\ModSettings, Configs\ModSettings\Global, the
    # config file or anything in a managed MCM folder (the folder itself included) is a reparse point.
    param([string]$Root)
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($rel in @('Configs', 'Configs\ModSettings', $script:BaselineMcmRoot, $script:BaselineConfigFile)) {
        $path = Join-Path $Root $rel
        if (Test-Path -LiteralPath $path) { Assert-NoReparsePoint (Get-Item -LiteralPath $path -Force) }
    }
    if (Test-Path -LiteralPath (Join-Path $Root $script:BaselineConfigFile) -PathType Leaf) { $files.Add($script:BaselineConfigFile) }
    foreach ($folder in $script:BaselineMcmFolders) {
        $relDir = Join-Path $script:BaselineMcmRoot $folder
        $dir = Join-Path $Root $relDir
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $dirItem = Get-Item -LiteralPath $dir -Force
        Assert-NoReparsePoint $dirItem
        if ($dirItem.PSIsContainer) { Add-ManagedFolderFiles -Dir $dir -RelDir $relDir -Files $files }
    }
    return $files.ToArray()
}

function Copy-BaselineFile {
    # Separate function so tests can simulate a copy that fails or does not arrive.
    param([string]$Source, [string]$Destination)
    [System.IO.File]::Copy($Source, $Destination, $true)
}

function Remove-UnmanagedMcmLeftovers {
    # Deletes every file in the managed MCM folders below $Docs that is not in $Wanted, then every folder
    # there (the managed folder itself included) that is empty and does not exist in the baseline.
    param([string]$Docs, [string]$BaselineRoot, $Wanted)
    foreach ($rel in @(Get-ManagedConfigFiles $Docs)) {
        if (-not $Wanted.Contains($rel)) { Remove-Item -LiteralPath (Join-Path $Docs $rel) -Force }
    }
    $fullDocs = (Get-Item -LiteralPath $Docs).FullName.TrimEnd('\')
    foreach ($folder in $script:BaselineMcmFolders) {
        $dir = Join-Path $Docs (Join-Path $script:BaselineMcmRoot $folder)
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $dirs = @(Get-ChildItem -LiteralPath $dir -Recurse -Directory -Force | Sort-Object { $_.FullName.Length } -Descending)
        $dirs += Get-Item -LiteralPath $dir
        foreach ($d in $dirs) {
            $rel = $d.FullName.Substring($fullDocs.Length + 1)
            if (Test-Path -LiteralPath (Join-Path $BaselineRoot $rel) -PathType Container) { continue }
            if (@(Get-ChildItem -LiteralPath $d.FullName -Force).Count -eq 0) { Remove-Item -LiteralPath $d.FullName -Force }
        }
    }
}

function Restore-TestRigBaseline {
    # Makes the managed configuration in the documents tree equal to the baseline: deletes what the baseline
    # does not have in the managed MCM folders, copies BannerlordConfig.txt and the baseline's MCM files, then
    # checks the SHA-256 of every copied file and that no other file is left in the managed folders. Touches
    # nothing else (engine_config.txt, LauncherData.xml, other mods' folders, logs). Never throws.
    # Returns @{ Ok; Error; Sha256 } - Sha256: relative path with forward slashes -> SHA-256 (uppercase hex),
    # $null unless Ok. The error says whether the documents tree was already changed when the restore failed.
    param($Config)
    $changing = $false
    try {
        $baselineRoot = $Config.baselineRoot
        $baselineConfig = Join-Path $baselineRoot $script:BaselineConfigFile
        if (-not (Test-Path -LiteralPath $baselineConfig -PathType Leaf)) {
            throw "Baseline missing: $baselineConfig not found (record it with Save-TestRigBaseline.ps1)."
        }
        $docs = Join-Path $Config.documentsRoot 'Mount and Blade II Bannerlord'
        # Never created here: on the rig the game made it, so a missing one means a wrong path.
        if (-not (Test-Path -LiteralPath $docs -PathType Container)) { throw "Game documents folder not found: $docs (documentsRoot wrong?)." }
        $wanted = @(Get-ManagedConfigFiles $baselineRoot)
        $wantedSet = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($rel in $wanted) { [void]$wantedSet.Add($rel) }
        $null = Get-ManagedConfigFiles $docs   # throws on a reparse point before anything is changed

        $changing = $true
        Remove-UnmanagedMcmLeftovers -Docs $docs -BaselineRoot $baselineRoot -Wanted $wantedSet
        foreach ($rel in $wanted) {
            $target = Join-Path $docs $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-BaselineFile -Source (Join-Path $baselineRoot $rel) -Destination $target
        }

        $sha = [ordered]@{}
        foreach ($rel in $wanted) {
            $expected = (Get-FileHash -LiteralPath (Join-Path $baselineRoot $rel) -Algorithm SHA256).Hash
            $target = Join-Path $docs $rel
            $actual = if (Test-Path -LiteralPath $target -PathType Leaf) { (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash } else { 'missing' }
            if ($actual -ne $expected) { throw "Baseline check failed: SHA-256 of $target is $actual, expected $expected." }
            $sha[$rel.Replace('\', '/')] = $expected
        }
        $left = @(Get-ManagedConfigFiles $docs | Where-Object { -not $wantedSet.Contains($_) })
        if ($left.Count -gt 0) { throw "Baseline check failed: file(s) not in the baseline left behind: $($left -join ', ')." }
        return @{ Ok = $true; Error = $null; Sha256 = $sha }
    }
    catch {
        $state = if ($changing) { 'The managed configuration may be partly restored.' } else { 'Nothing was changed.' }
        return @{ Ok = $false; Error = "$($_.Exception.Message) $state"; Sha256 = $null }
    }
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

# Harness id -> folder below the Bannerlord Documents folder and the module that drives it
# (the one place this mapping lives). TestRig is the only harness a job may name (Test-JobSchema).
$script:Harnesses = [ordered]@{
    TestRig = @{ Folder = 'TestRig\harness'; Module = 'TestRig.Harness' }
}

function Get-HarnessDir {
    # Returns $null for an unknown harness id.
    param($Config, [Parameter(Mandatory)][AllowEmptyString()][string]$Harness)
    if (-not $script:Harnesses.Contains($Harness)) { return $null }
    return (Join-Path $Config.documentsRoot ('Mount and Blade II Bannerlord\' + $script:Harnesses[$Harness].Folder))
}

function Test-RunHasOwnAssemblies {
    # True when the run carries an explicit runs[].ownAssemblies list (the job schema guarantees
    # a non-empty array of unique ids without ',' or line breaks).
    param($Run)
    return ($Run.PSObject.Properties.Name -contains 'ownAssemblies' -and @($Run.ownAssemblies).Count -gt 0)
}

function Get-RunCfgText {
    # ownAssemblies is written only when given. scenarios is written only for kind 'scenarios', and health only for
    # kind 'soak' (the job schema guarantees ids without ',' or line breaks, and never both keys).
    param($Run, [string[]]$OwnAssemblies = @())
    $lines = @(
        ('seed=' + [System.Convert]::ToString($Run.seed, $script:Invariant)),
        ('days=' + [System.Convert]::ToString($Run.days, $script:Invariant)),
        ('mode=' + $Run.mode),
        ('stallMinutes=' + [System.Convert]::ToString($Run.stallMinutes, $script:Invariant)),
        ('budgetMinutes=' + [System.Convert]::ToString($Run.budgetMinutes, $script:Invariant))
    )
    if ($Run.kind -ceq 'scenarios' -and @($Run.scenarios).Count -gt 0) {
        $lines += ('scenarios=' + (@($Run.scenarios) -join ','))
    }
    if ($Run.kind -ceq 'soak' -and $Run.PSObject.Properties.Name -contains 'health' -and @($Run.health).Count -gt 0) {
        $lines += ('health=' + (@($Run.health) -join ','))
    }
    if (Test-RunHasOwnAssemblies $Run) { $OwnAssemblies = @($Run.ownAssemblies) }   # the job's explicit list wins over the derived one
    if (@($OwnAssemblies).Count -gt 0) { $lines += ('ownAssemblies=' + (@($OwnAssemblies) -join ',')) }
    return ($lines -join "`n") + "`n"
}

function Get-OwnAssemblyNames {
    # Simple DLL names (no .dll) of every module that is neither a harness nor a scenario module, from its installed
    # SubModule.xml: SubModules/SubModule/DLLName/@value. A scenario module is one whose SubModule.xml lists a
    # harness module under DependedModules/DependedModule/@Id. Order kept, case-insensitive de-duplication.
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
            $dependsOnHarness = $false
            foreach ($dep in $doc.SelectNodes('/Module/DependedModules/DependedModule/@Id')) {
                if (@($HarnessModuleIds) -contains $dep.Value) { $dependsOnHarness = $true }
            }
            if ($dependsOnHarness) { continue }
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
    # Last non-empty line of a log the game may still be writing, skipping the harness's "Alive:" beat lines (the
    # last Alive line only if the tail holds nothing else). Returns $null if the file is missing or unreadable.
    # Reads only the tail.
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
        $lines = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        if ($lines.Count -eq 0) { return $null }
        $progress = @($lines | Where-Object { -not (Test-AliveLine $_) })
        if ($progress.Count -gt 0) { return $progress[$progress.Count - 1] }
        return $lines[$lines.Count - 1]
    }
    catch { return $null }
}

function Test-AliveLine {
    # A harness.log line is "<seconds> <text>"; the TestRig harness's main-thread beat has text starting with "Alive:".
    param([string]$Line)
    return $Line -cmatch '\A\d+(\.\d+)? Alive:'
}

function Read-HarnessLogGrowth {
    # The complete lines a log gained since the last call; $State.Position (bytes) is advanced past them. Never
    # reads the file from the start again. A partial last line stays unread until its line break arrives (so a
    # multi-byte character is never split either). A file that does not exist yet, is locked or got shorter
    # yields no lines (shorter: reading starts over). Never throws.
    param([string]$Path, [hashtable]$State)
    $lines = New-Object System.Collections.Generic.List[string]
    try {
        $fs = New-Object System.IO.FileStream($Path, 'Open', 'Read', 'ReadWrite,Delete')
        try {
            if ($fs.Length -lt $State.Position) { $State.Position = [long]0 }
            $count = [int][Math]::Min($fs.Length - $State.Position, [long]$script:HarnessLogReadMaxBytes)
            if ($count -gt 0) {
                $null = $fs.Seek($State.Position, 'Begin')
                $buffer = New-Object byte[] $count
                $read = 0
                while ($read -lt $count) {
                    $n = $fs.Read($buffer, $read, $count - $read)
                    if ($n -le 0) { break }
                    $read += $n
                }
                $end = -1   # index of the last line break; -1: none
                if ($read -gt 0) { $end = [Array]::LastIndexOf($buffer, [byte]10, $read - 1) }
                if ($end -lt 0 -and $read -eq $script:HarnessLogReadMaxBytes) { $end = $read - 1 }   # no line break in a full chunk
                if ($end -ge 0) {
                    $State.Position += $end + 1
                    $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $end + 1)
                    foreach ($line in ($text -split "`r?`n")) {
                        if ($line -ne '') { $lines.Add($line) }
                    }
                }
            }
        }
        finally { $fs.Dispose() }
    }
    catch { }
    return $lines.ToArray()
}

function Test-UnhandledExceptionLine {
    # A harness.log line is "<seconds> <text>"; only text that starts with UnhandledException counts. A FirstChance
    # line that merely mentions the word does not.
    param([string]$Line)
    return $Line -cmatch '\A\d+(\.\d+)? UnhandledException(\W|\z)'
}

function Find-UnhandledExceptionLine {
    # The first UnhandledException line of $Lines, ready for a run message (Format-LogLineForMessage); $null if none.
    param([string[]]$Lines)
    foreach ($line in @($Lines)) {
        if (Test-UnhandledExceptionLine $line) { return (Format-LogLineForMessage $line) }
    }
    return $null
}

function Read-StreamBytes {
    # Every byte of $Stream from its current position to the end, as one byte[] (also when empty).
    param([System.IO.Stream]$Stream)
    $bytes = New-Object byte[] ([int]($Stream.Length - $Stream.Position))
    $read = 0
    while ($read -lt $bytes.Length) {
        $n = $Stream.Read($bytes, $read, $bytes.Length - $read)
        if ($n -le 0) { break }
        $read += $n
    }
    if ($read -lt $bytes.Length) { [Array]::Resize([ref]$bytes, $read) }
    return , $bytes
}

function Find-SafelyExitedZero {
    # The "safely_exited = 0" lines of engine_config.txt bytes; group 1 of each match is the 0, its Index the byte offset
    # (Latin-1 maps every byte to exactly one char, so a char index is the byte index for any ASCII-compatible file).
    param([byte[]]$Bytes)
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString($Bytes)
    return , [regex]::Matches($text, '(?m)^(?:\xEF\xBB\xBF)?[ \t]*safely_exited[ \t]*=[ \t]*(0)[ \t]*\r?$')
}

function Reset-EngineSafelyExited {
    # The engine writes "safely_exited = 0" into engine_config.txt when it starts and 1 only on a clean exit. After a
    # run the agent had to kill, the 0 stays and the next start blocks on the native "Safe Mode" question. Sets exactly
    # that digit to 1: one byte is written in place, every other byte (encoding, BOM, line endings) stays as it is. A
    # missing file or no such line: nothing happens. While a Bannerlord process runs the file is the game's: the reset
    # is skipped (logged). A shared read-only look comes first, so a file without a 0 (also a read-only one) is never
    # opened for writing. Only on a 0 the file is opened exclusively and read again: the write is decided on those
    # bytes, so nothing changes the file in between. Never throws: a failure is logged and the launch goes on.
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
        if (@(Get-BannerlordProcess | Where-Object { $null -ne $_ }).Count -gt 0) {
            Write-AgentLog "Bannerlord is running: safely_exited in $Path is left as it is."
            return
        }
        $probe = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $probeMatches = Find-SafelyExitedZero (Read-StreamBytes $probe) }
        finally { $probe.Dispose() }
        if ($probeMatches.Count -eq 0) { return }
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $found = Find-SafelyExitedZero (Read-StreamBytes $fs)
            if ($found.Count -eq 0) { return }
            foreach ($m in $found) {
                $null = $fs.Seek($m.Groups[1].Index, [System.IO.SeekOrigin]::Begin)
                $fs.WriteByte([byte][char]'1')
            }
            $fs.Flush($true)
        }
        finally { $fs.Dispose() }
        Write-AgentLog "engine_config.txt: safely_exited was 0 (previous run did not exit cleanly) - set to 1, so the game does not ask for Safe Mode."
    }
    catch { Write-AgentLog "Could not reset safely_exited in $Path (launching anyway): $($_.Exception.Message)" }
}

function Format-LogLineForMessage {
    # One printable-ASCII line of bounded length, for run messages and agent.log.
    param([string]$Line)
    $text = ($Line -replace '[^\x20-\x7E]', ' ' -replace ' {2,}', ' ').Trim()
    if ($text.Length -gt $script:MessageLineMaxChars) { $text = $text.Substring(0, $script:MessageLineMaxChars - 3) + '...' }
    return $text
}

# --- Watchdog crash detection (ported from BannerlordCoherentWarAI tools\Run-SoakTest.ps1) ---

function Test-WatchdogCrash {
    # True if the TaleWorlds watchdog log at $Path reports a crash in the text from byte $Offset on (all of it if the
    # file is shorter now). The watchdog keeps the file open, hence FileShare.ReadWrite (and Delete). Never throws.
    param([string]$Path, [long]$Offset = 0)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        $reader = New-Object System.IO.StreamReader($fs)
        try {
            if ($Offset -gt 0 -and $Offset -le $fs.Length) { $null = $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin) }
            $text = $reader.ReadToEnd()
        }
        finally { $reader.Dispose() }   # disposes the stream too
        return $text.Contains('Crash occurred')
    }
    catch {
        return $false
    }
}

function Get-WatchdogLogSnapshot {
    # Name -> length of every watchdog log in $LogsDir, taken right before the launch; empty if the folder does not
    # exist. Lengths from refreshed FileInfo: for a file another process holds open, Get-ChildItem reports the length
    # of the directory entry, which lags behind (measured: 7 instead of 5009 bytes after an append).
    param([string]$LogsDir)
    $snapshot = @{}   # case-insensitive keys, like the file names
    if (-not (Test-Path -LiteralPath $LogsDir -PathType Container)) { return $snapshot }
    foreach ($f in @(Get-ChildItem -LiteralPath $LogsDir -Filter 'watchdog_log_*.txt' -File)) {
        $f.Refresh()
        $snapshot[$f.Name] = $f.Length
    }
    return $snapshot
}

function Find-CrashedWatchdogLog {
    # The watchdog log reporting "Crash occurred" for this run: first the one of the launched process
    # (watchdog_log_<pid>.txt, same PID as rgl_log_<pid>.txt), else - after a relaunch under another PID - any other
    # watchdog log, newest first. Returns its FileInfo or $null. Never throws.
    # Only text written since the launch counts. $Snapshot (Get-WatchdogLogSnapshot) holds the length of every log
    # that existed at the launch: such a log counts only with the bytes beyond that length - so neither a crash log of
    # an earlier run that its watchdog still writes to, nor an old log under a reused PID reports a crash - while a log
    # not in the snapshot counts whole. A log shorter than its snapshot length was replaced: from then on it counts
    # whole (its entry is set to 0). The snapshot replaces the former LastWriteTimeUtc check: that admitted an old log
    # whole as soon as anyone touched it, and Get-ChildItem reports a stale time for a file still held open.
    param([string]$LogsDir, [int]$ProcessId, [hashtable]$Snapshot)
    try {
        if (-not (Test-Path -LiteralPath $LogsDir -PathType Container)) { return $null }
        $ownName = "watchdog_log_$ProcessId.txt"
        $logs = @(Get-ChildItem -LiteralPath $LogsDir -Filter 'watchdog_log_*.txt' -File)
        foreach ($f in $logs) { $f.Refresh() }   # current length and time, see Get-WatchdogLogSnapshot
        $ordered = @($logs | Where-Object { $_.Name -eq $ownName }) +
            @($logs | Where-Object { $_.Name -ne $ownName } | Sort-Object LastWriteTimeUtc -Descending)
        foreach ($f in $ordered) {
            $offset = 0
            if ($Snapshot.ContainsKey($f.Name)) {
                $offset = [long]$Snapshot[$f.Name]
                if ($f.Length -lt $offset) {
                    $Snapshot[$f.Name] = 0
                    $offset = 0
                }
                elseif ($f.Length -eq $offset) { continue }   # nothing written since the launch
            }
            if (Test-WatchdogCrash -Path $f.FullName -Offset $offset) { return $f }
        }
    }
    catch { }
    return $null
}

function Stop-StrayGameProcesses {
    # After every launched run: stops game processes outside the launched process tree - a game that relaunched
    # itself under another PID would otherwise keep running into the next run or the restore (after a crash: with its
    # crash dialog open). Candidates are only processes named $GameName (the game executable's name without .exe), and
    # of those only the ones started at or after $Since (UTC), the launch: a game that was running before is left alone
    # (the job preflight refuses to start while one runs), and so is any other program, whatever PID a log names.
    # $ExcludeId (the launched process) is left to its own kill.
    # Returns $true only if afterwards no such process started at or after $Since is alive. A process of that name whose
    # start time cannot be read (e.g. access denied) is not stopped and makes the result $false: it may be this run's game.
    # $Heartbeat as in Stop-ProcessTree. Never throws.
    param([string]$GameName, [datetime]$Since, [int]$ExcludeId, [scriptblock]$Heartbeat = $null)
    $allStopped = $true
    # First pass stops; the second only checks, so a game that relaunched once more during the first pass counts too.
    foreach ($checkOnly in @($false, $true)) {
        try { $found = @(Get-GameProcess -Name $GameName | Where-Object { $null -ne $_ -and $_.Id -ne $ExcludeId }) }
        catch {
            Write-AgentLog "Looking for stray game processes failed: $($_.Exception.Message)"
            return $false
        }
        foreach ($p in $found) {
            $gone = $false
            try { $gone = [bool]$p.HasExited } catch { }
            if ($gone) { continue }
            try { $startedUtc = $p.StartTime.ToUniversalTime() }
            catch {
                $allStopped = $false
                if (-not $checkOnly) { Write-AgentLog "Game process $($p.Id) ($($p.ProcessName)): start time unreadable, not stopped (counts as not stopped): $($_.Exception.Message)" }
                continue
            }
            if ($startedUtc -lt $Since) { continue }
            if ($checkOnly) {
                $allStopped = $false
                Write-AgentLog "Game process $($p.Id) ($($p.ProcessName)) is still running after the sweep."
                continue
            }
            Write-AgentLog "Stopping stray game process $($p.Id) ($($p.ProcessName)), started $($startedUtc.ToString('o'))."
            if (-not (Stop-ProcessTree $p -Heartbeat $Heartbeat)) {
                $allStopped = $false
                Write-AgentLog "Stray game process $($p.Id) could not be stopped."
            }
        }
    }
    return $allStopped
}

function Get-ResultStatus {
    # status of the harness result in $HarnessDir: run-result.json. Missing, unreadable or invalid run-result.json = no
    # result (an unreadable or invalid one is logged). Returns $null if there is no usable status.
    param([string]$HarnessDir)
    $jsonPath = Join-Path $HarnessDir 'run-result.json'
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) { return $null }
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

function Copy-SharedFile {
    # Copies a file another process may still hold open for writing or deleting (the watchdog and rgl logs of a
    # game that is still shutting down): FileShare.ReadWrite and Delete on the source. Overwrites the target.
    param([string]$Source, [string]$Destination)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $in = New-Object System.IO.FileStream($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $out = New-Object System.IO.FileStream($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $in.CopyTo($out) }
        finally { $out.Dispose() }
    }
    finally { $in.Dispose() }
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
            Copy-SharedFile -Source $c.Source -Destination (Join-Path $TargetDir $c.Name)
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
        private const int IDNO = 7;
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
            return PostClick(dialog, okButton, controlId);
        }

        // The same for the No button of a Yes/No message box: the IDNO control, whatever its caption's language.
        public static string ClickNo(IntPtr dialog)
        {
            IntPtr noButton = GetDlgItem(dialog, IDNO);
            if (noButton == IntPtr.Zero || !IsWindowVisible(noButton) || !IsWindowEnabled(noButton)) { return "no No button"; }
            return PostClick(dialog, noButton, IDNO);
        }

        private static string PostClick(IntPtr dialog, IntPtr button, int controlId)
        {
            IntPtr wParam = new IntPtr((BN_CLICKED << 16) | (controlId & 0xFFFF));
            if (!PostMessage(dialog, WM_COMMAND, wParam, button))
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
    # Sends OK (or, with -Answer No, No) to the dialog. Returns $null when it was sent, else the reason it was not.
    param($Dialog, [ValidateSet('OK', 'No')][string]$Answer = 'OK')
    Initialize-GameWindows
    if ($Answer -eq 'No') { return [BannerlordTestRig.GameWindows]::ClickNo($Dialog.Handle) }
    return [BannerlordTestRig.GameWindows]::ClickOk($Dialog.Handle)
}

function Invoke-GameDialogCheck {
    # One look at the game's dialogs: sends OK (ConfirmableDialogTitles) or No (DeclinedDialogTitles) to the known
    # titles (once per dialog window), logs any other title once per run, and logs once if a dialog is still open
    # DialogStillOpenSeconds after the answer. $State.Open is set to the dialogs this look found that block the game:
    # @{ Title; Status = 'not answered' | 'answer failed' | 'still open after answer' } (Get-OpenDialogSummary).
    # Never throws: a failing check must not end the supervision (and leaves $State.Open as the last look found it).
    # $State is per run: @{ Handled = @{}; Seen = @{}; Open = @(); FailureLogged = $false }.
    param([int]$ProcessId, [hashtable]$State, $Record)
    try {
        $open = @()
        foreach ($dialog in @(Get-GameDialogs -ProcessId $ProcessId)) {
            $handleKey = [string]$dialog.Handle
            $handled = $State.Handled[$handleKey]
            if ($null -ne $handled) {   # OK was sent (or could not be) already; never a second time
                if ($null -eq $handled.OkSentUtc) { $open += @{ Title = $dialog.Title; Status = 'answer failed' } }
                elseif (([DateTime]::UtcNow - $handled.OkSentUtc).TotalSeconds -ge $script:DialogStillOpenSeconds) {
                    $open += @{ Title = $dialog.Title; Status = 'still open after answer' }
                    if (-not $handled.StillOpenLogged) {
                        $handled.StillOpenLogged = $true
                        Write-AgentLog "Dialog '$($dialog.Title)' still open after confirm"
                    }
                }
                continue
            }
            $answer = $null
            if ($script:ConfirmableDialogTitles -ccontains $dialog.Title) { $answer = 'OK' }
            elseif ($script:DeclinedDialogTitles -ccontains $dialog.Title) { $answer = 'No' }
            if ($null -ne $answer) {
                $handled = @{ Title = $dialog.Title; OkSentUtc = $null; StillOpenLogged = $false }
                $State.Handled[$handleKey] = $handled
                $failure = Confirm-KnownGameDialog -Dialog $dialog -Answer $answer
                if ($null -eq $failure) {
                    $handled.OkSentUtc = [DateTime]::UtcNow
                    $with = if ($answer -eq 'OK') { '' } else { " with $answer" }
                    Write-AgentLog "Dismissed dialog '$($dialog.Title)'$with (pid $ProcessId)."
                    $Record.dismissedDialogs = @($Record.dismissedDialogs) + $dialog.Title
                }
                else {
                    Write-AgentLog "Could not confirm dialog '$($dialog.Title)': $failure"
                    $open += @{ Title = $dialog.Title; Status = 'answer failed' }
                }
            }
            else {
                $open += @{ Title = $dialog.Title; Status = 'not answered' }
                if (-not $State.Seen.ContainsKey($dialog.Title)) {
                    $State.Seen[$dialog.Title] = $true
                    Write-AgentLog "Game dialog seen: '$($dialog.Title)'"
                }
            }
        }
        $State.Open = $open
    }
    catch {
        if (-not $State.FailureLogged) {
            $State.FailureLogged = $true
            Write-AgentLog "Dialog check failed (supervision continues): $($_.Exception.Message)"
        }
    }
}

function Get-OpenDialogSummary {
    # The dialogs the last successful look of Invoke-GameDialogCheck found open and blocking, one entry each (sorted,
    # distinct), e.g. "'Safe Mode' (answer failed)". A dialog answered less than DialogStillOpenSeconds before that look
    # is not listed (it may be closing). $State as there.
    param([hashtable]$State)
    $entries = @($State.Open | Where-Object { $null -ne $_ } |
        ForEach-Object { "'$(Format-LogLineForMessage $_.Title)' ($($_.Status))" })
    return @($entries | Sort-Object -Unique)
}

function Wait-HarnessFinalResult {
    # After an UnhandledException line: waits up to $Seconds until $Process exited or the harness result in $HarnessDir
    # was written after $SinceUtc (the moment the line was read) and has a final status (other than Running), so the
    # result the harness writes after that line is not lost to the kill. A final result from before the line (a run that
    # completed, then crashed while shutting down) does not end the wait: the harness rewrites it with the updated
    # exception counts. Tradeoff (deliberate): the harness rewrites the result milliseconds after the UnhandledException
    # line, i.e. usually before the agent's read ($SinceUtc), so in practice the wait ends on process exit or after the
    # full grace. That is the safe direction: never an early kill, at most $Seconds (5 s) of waiting. Never throws.
    param($Process, [string]$HarnessDir, [double]$Seconds, [DateTime]$SinceUtc)
    try {
        $jsonPath = Join-Path $HarnessDir 'run-result.json'
        $until = [DateTime]::UtcNow.AddSeconds($Seconds)
        while ([DateTime]::UtcNow -lt $until) {
            if ($Process.WaitForExit(250)) { return }
            $result = Get-Item -LiteralPath $jsonPath -ErrorAction SilentlyContinue
            if ($null -eq $result -or $result.LastWriteTimeUtc -le $SinceUtc) { continue }
            $status = Get-ResultStatus $HarnessDir
            if ($null -ne $status -and $status -ne 'Running') { return }
        }
    }
    catch { Write-AgentLog "Waiting for the harness result failed: $($_.Exception.Message)" }
}

function Invoke-Run {
    # One run: restore the baseline, patch configs, write run.cfg, launch, supervise, classify, collect.
    # Writes results\<jobId>\<runId>\agent-run.json and returns it as a hashtable.
    # $Context.GameVersion / $Context.ModuleVersions (from the preflight) go into agent-run.json.
    param($Config, [hashtable]$Context, $Run, [string[]]$Modules, [string[]]$PackageModuleIds = @(), [int]$RunIndex, [string]$ResultsDir)

    $runId = $Run.runId
    $runDir = Join-Path $ResultsDir $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $docs = Join-Path $Config.documentsRoot 'Mount and Blade II Bannerlord'
    $configsDir = Join-Path $docs 'Configs'
    $mcmPath = Join-Path $configsDir 'ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json'
    $modLogDir = Join-Path $docs 'CoherentWarAI'
    $harnessDir = Get-HarnessDir $Config ([string]$Run.harness)   # $null for an unsupported harness (rejected below)
    $runCfgPath = $runResultPath = $harnessLogPath = $null
    if ($harnessDir) {
        $runCfgPath = Join-Path $harnessDir 'run.cfg'
        $runResultPath = Join-Path $harnessDir 'run-result.json'
        $harnessLogPath = Join-Path $harnessDir 'harness.log'
    }
    $engineLogDir = $Config.engineLogDir
    # Assigned in the branch, not as "$x = if ...": that form unrolls the array (0 entries -> $null, 1 -> the entry).
    $moduleVersions = @()
    if ($null -ne $Context.ModuleVersions) { $moduleVersions = @($Context.ModuleVersions) }

    $record = [ordered]@{
        schema = 1; runId = $runId; exitClass = 'SetupError'; pid = $null
        startedUtc = (Get-UtcStamp); endedUtc = $null; artifacts = @()
        baselineRestored = $false; baselineSha256 = $null; gameVersion = $Context.GameVersion; moduleVersions = $moduleVersions
        message = $null; dismissedDialogs = @()
    }
    $process = $null
    $runCfgTouched = $false
    $startedAt = [DateTime]::UtcNow
    $aborted = $false
    $timedOut = $false
    $crashed = $false
    $crashLog = $null
    $crashLine = $null   # the harness.log UnhandledException line (sanitized) that ended the run
    $hung = $false
    $silentSeconds = 0
    $lastHarnessLine = $null   # the last harness.log line read that is not an Alive line
    $killFailed = $false
    $superviseError = $null
    $deadline = $null
    $watchdogSnapshot = @{}
    $gameName = $null

    try {
        if (-not $harnessDir) { throw [System.InvalidOperationException]("Harness '$($Run.harness)' is not supported (only 'TestRig').") }
        # The harness module must be in this job's package and load order; otherwise the game would
        # start without it, or with a stale copy installed by an earlier job.
        $harnessModule = $script:Harnesses[[string]$Run.harness].Module
        if (@($PackageModuleIds) -notcontains $harnessModule) { throw [System.InvalidOperationException]("Harness module '$harnessModule' is not in the package.") }
        if (@($Modules) -notcontains $harnessModule) { throw [System.InvalidOperationException]("Harness module '$harnessModule' is not in job.modules.") }
        if ($script:ValidModes -notcontains $Run.mode) { throw [System.InvalidOperationException]("Unknown mode '$($Run.mode)'.") }

        Write-JobState -Context $Context -State 'installing' -RunId $runId -RunIndex $RunIndex
        # Before the first change to the documents tree; a failed write ends the run here, before anything is changed.
        [System.IO.File]::WriteAllText((Get-RestorePendingPath $Config), "job $($Context.JobId), run $runId, $(Get-UtcStamp)`n", $script:Utf8NoBom)
        $Context.ConfigTouched = $true   # from here on the job ends with a restore of the baseline
        $baseline = Restore-TestRigBaseline -Config $Config
        if (-not $baseline.Ok) { throw [System.InvalidOperationException]("Baseline restore failed: $($baseline.Error)") }
        $record.baselineRestored = $true
        $record.baselineSha256 = $baseline.Sha256
        Write-AgentLog "Baseline restored ($(@($baseline.Sha256.Keys).Count) file(s))."
        New-Item -ItemType Directory -Path $configsDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path $mcmPath) -Force | Out-Null
        Set-BannerlordConfigValues (Join-Path $configsDir 'BannerlordConfig.txt')
        Set-McmSettingsValues $mcmPath $Run.mode

        New-Item -ItemType Directory -Path $harnessDir -Force | Out-Null
        foreach ($stale in @($runResultPath, ($runResultPath + '.tmp'), $harnessLogPath)) {
            if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
        }
        $ownAssemblies = @()
        if (-not (Test-RunHasOwnAssemblies $Run)) {   # an explicit list replaces the derivation
            # Only package modules that this job loads (job.modules); game and workshop modules are not own code.
            $loadedPackageModules = @($Modules | Where-Object { @($PackageModuleIds) -contains $_ })
            $ownAssemblies = @(Get-OwnAssemblyNames -ModulesDir (Get-ModulesDir $Config) `
                -ModuleIds $loadedPackageModules -HarnessModuleIds @($script:Harnesses.Values | ForEach-Object { $_.Module }))
        }
        $runCfgTouched = $true   # before the write: a partial file must be deleted too
        Write-Utf8Text $runCfgPath (Get-RunCfgText $Run -OwnAssemblies $ownAssemblies) $false

        # Compile the Win32 helper here, not inside the supervision. Not fatal: the run goes on without dialog handling.
        try { Initialize-GameWindows }
        catch { Write-AgentLog "Game dialog check unavailable: $($_.Exception.Message)" }
        $arguments = Get-GameArguments -Prefix $Config.gameArgumentsPrefix -Modules $Modules
        $gameName = [System.IO.Path]::GetFileNameWithoutExtension($Config.gameExecutable)   # for the stray sweep
        if (-not (Test-Path -LiteralPath $engineLogDir -PathType Container)) {
            Write-AgentLog "engineLogDir $engineLogDir does not exist: crash detection sees no watchdog log in this run unless the game creates the folder."
        }
        # The engine asks for Safe Mode on the start after a run it did not end itself (a run the agent killed).
        Reset-EngineSafelyExited -Path (Join-Path $configsDir 'engine_config.txt')
        $watchdogSnapshot = Get-WatchdogLogSnapshot -LogsDir $engineLogDir   # only what is written after this counts
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
        $nextCrashCheck = $startedAt
        $nextLogCheck = $startedAt
        $logState = @{ Position = [long]0 }   # harness.log was deleted before the launch: every line in it is from this run
        $lastAliveAt = $null   # the silence watchdog is armed by the first Alive line (main thread), not by any line
        $unreadableStatusPasses = 0   # silence passes in a row that found no readable result
        $resultFinal = $false   # the harness wrote its final result: silence is no longer a hang
        $dialogState = @{ Handled = @{}; Seen = @{}; Open = @(); FailureLogged = $false }
        $lastLogReadUtc = $startedAt   # when harness.log was last read (an UnhandledException line in it: Wait-HarnessFinalResult)
        try {
            $null = $process.Handle   # keep the handle so ExitCode stays readable
            $record.pid = $process.Id
            while ($true) {
                $now = [DateTime]::UtcNow
                if ($now -ge $nextAbortCheck) {
                    if (Test-Path -LiteralPath $abortFile) { $aborted = $true; $Context.AbortSeen = $true; break }   # kept apart from exitClass: CleanupFailed overrides it
                    $nextAbortCheck = $now.AddSeconds($script:AbortCheckSeconds)
                }
                if ($now -ge $nextCrashCheck) {
                    # The crash dialog blocks the game until someone answers it: kill now, not at the hard timeout.
                    $crashLog = Find-CrashedWatchdogLog -LogsDir $engineLogDir -ProcessId $process.Id -Snapshot $watchdogSnapshot
                    if ($null -ne $crashLog) { $crashed = $true; break }
                    $nextCrashCheck = $now.AddSeconds($script:CrashCheckSeconds)
                }
                if ($now -ge $nextLogCheck) {
                    # Early signals from harness.log, before the hard timeout: an UnhandledException line, or silence.
                    $nextLogCheck = $now.AddSeconds($script:HarnessLogCheckSeconds)
                    $newLines = @(Read-HarnessLogGrowth -Path $harnessLogPath -State $logState)
                    $lastLogReadUtc = [DateTime]::UtcNow   # a result written after this is newer than any line read here
                    foreach ($line in $newLines) {
                        if (Test-AliveLine $line) { $lastAliveAt = $now; $unreadableStatusPasses = 0 }
                        else { $lastHarnessLine = $line }
                    }
                    $crashLine = Find-UnhandledExceptionLine $newLines
                    if ($null -ne $crashLine) { $crashed = $true; break }
                    # Only Alive lines count: lines of background threads (FirstChance) go on while the main thread hangs.
                    if (-not $resultFinal -and $null -ne $lastAliveAt -and ($now - $lastAliveAt).TotalSeconds -gt $script:SilenceSeconds) {
                        # run-result.json is rewritten after every scenario (status Running); only a final status ends the watch.
                        $resultStatus = Get-ResultStatus $harnessDir
                        if ($null -ne $resultStatus -and $resultStatus -ne 'Running') { $resultFinal = $true }
                        elseif ($null -eq $resultStatus -and $unreadableStatusPasses -lt $script:SilenceStatusRetries) {
                            $unreadableStatusPasses++   # the file may be being replaced: look again on the next pass
                        }
                        else {
                            $silentSeconds = [int][Math]::Floor(($now - $lastAliveAt).TotalSeconds)
                            # A crash also silences the beat: one last look at both crash signals before calling it a hang.
                            $crashLog = Find-CrashedWatchdogLog -LogsDir $engineLogDir -ProcessId $process.Id -Snapshot $watchdogSnapshot
                            if ($null -eq $crashLog) {
                                $lastLines = @(Read-HarnessLogGrowth -Path $harnessLogPath -State $logState)
                                $lastLogReadUtc = [DateTime]::UtcNow
                                foreach ($line in $lastLines) { if (-not (Test-AliveLine $line)) { $lastHarnessLine = $line } }
                                $crashLine = Find-UnhandledExceptionLine $lastLines
                            }
                            $crashed = ($null -ne $crashLog -or $null -ne $crashLine)
                            $hung = -not $crashed
                            break
                        }
                    }
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
            if ($null -ne $crashLine -and -not $aborted) {
                # The harness writes its final result right after the UnhandledException line: give it a moment.
                Wait-HarnessFinalResult -Process $process -HarnessDir $harnessDir -Seconds $script:UnhandledResultGraceSeconds -SinceUtc $lastLogReadUtc
            }
            $stillRunning = $true
            try { $stillRunning = -not $process.HasExited } catch { }
            if ($stillRunning) {
                if ($aborted) { Write-AgentLog "Abort requested - killing the game (process tree)." }
                elseif ($null -ne $crashLine) { Write-AgentLog "Game crashed (UnhandledException in harness.log: $crashLine) - killing the game (process tree)." }
                elseif ($crashed) { Write-AgentLog "Game crashed ($($crashLog.Name): 'Crash occurred') - killing the game (process tree)." }
                elseif ($hung) { Write-AgentLog "Game hung (no Alive line in harness.log for $silentSeconds s, limit $($script:SilenceSeconds) s) - killing the game (process tree)." }
                elseif ($timedOut) { Write-AgentLog "Hard timeout after $($Run.hardTimeoutMinutes) min - killing the game (process tree)." }
                $stopBeat = {
                    Write-JobState -Context $Context -State 'running' -RunId $runId -RunIndex $RunIndex -Message 'stopping game'
                }   # no closure: it runs in the dynamic scope of Invoke-Run and sees these variables and the script functions
                if (-not (Stop-ProcessTree $process -Heartbeat $stopBeat)) { $killFailed = $true }
            }
        }
        if (-not $aborted -and $null -eq $superviseError -and $null -eq $crashLine) {
            # An UnhandledException line written right before the game exited (or was killed) is still unread: the loop
            # stopped on the exit before its next read. After a watchdog crash only the last line is updated (message).
            $finalLines = @(Read-HarnessLogGrowth -Path $harnessLogPath -State $logState)
            foreach ($line in $finalLines) { if (-not (Test-AliveLine $line)) { $lastHarnessLine = $line } }
            if (-not $crashed) {
                $crashLine = Find-UnhandledExceptionLine $finalLines
                if ($null -ne $crashLine) {
                    $crashed = $true
                    Write-AgentLog "Game crashed (UnhandledException in harness.log: $crashLine)."
                }
            }
        }
        if (-not $crashed -and -not $hung -and -not $aborted -and -not $timedOut -and $null -eq $superviseError) {
            # A crash in the last moment before the game exited on its own; the watchdog may write it a moment
            # after the exit, hence a few re-checks.
            $finalUntil = [DateTime]::UtcNow.AddSeconds($script:FinalCrashCheckSeconds)
            while ($true) {
                $crashLog = Find-CrashedWatchdogLog -LogsDir $engineLogDir -ProcessId $process.Id -Snapshot $watchdogSnapshot
                if ($null -ne $crashLog -or [DateTime]::UtcNow -ge $finalUntil) { break }
                Start-Sleep -Milliseconds 250
            }
            if ($null -ne $crashLog) {
                $crashed = $true
                Write-AgentLog "Game crashed ($($crashLog.Name): 'Crash occurred')."
            }
        }
        # After every launched run, whatever its exit class: a relaunched game is outside the tree killed above and must
        # neither run into the next run of the job nor race the restore of the baseline.
        $strayBeat = {
            Write-JobState -Context $Context -State 'running' -RunId $runId -RunIndex $RunIndex -Message 'stopping game'
        }
        if (-not (Stop-StrayGameProcesses -GameName $gameName -Since $startedAt -ExcludeId $process.Id -Heartbeat $strayBeat)) { $killFailed = $true }
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
        $shownLastLine = if ($null -ne $lastHarnessLine) { Format-LogLineForMessage $lastHarnessLine } else { '(none)' }
        if ($killFailed -or -not $runCfgRemoved) {
            $record.exitClass = 'CleanupFailed'
            $record.message = 'The game could not be stopped or run.cfg could not be removed.'
        }
        elseif ($aborted) { $record.exitClass = 'Aborted' }
        elseif ($null -ne $superviseError) { $record.exitClass = 'SetupError'; $record.message = $superviseError }
        elseif ($null -ne $crashLine) { $record.exitClass = 'Crashed'; $record.message = "Harness reported: $crashLine" }
        elseif ($crashed) { $record.exitClass = 'Crashed'; $record.message = "Crash occurred ($($crashLog.Name)); last line: $shownLastLine" }
        elseif ($hung) {
            $record.exitClass = 'Hung'
            $record.message = "No Alive line in harness.log for $silentSeconds s (limit $($script:SilenceSeconds) s); last line: $shownLastLine"
            $openDialogs = @(Get-OpenDialogSummary $dialogState)
            if ($openDialogs.Count -gt 0) { $record.message += '; open dialogs: ' + ($openDialogs -join ', ') }
        }
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
        $copies += @{ Name = 'harness.log'; Source = $harnessLogPath }
    }
    $copies += @{ Name = 'CoherentWarAI.log'; Source = (Join-Path $modLogDir 'CoherentWarAI.log') }
    foreach ($modLog in $script:ModLogFiles) {
        $copies += @{ Name = $modLog.Name; Source = (Join-Path $docs $modLog.RelativePath) }
    }
    if ($null -ne $process) {
        $copies += @{ Name = "rgl_log_$($process.Id).txt"; Source = (Join-Path $engineLogDir "rgl_log_$($process.Id).txt") }
        $copies += @{ Name = "rgl_log_errors_$($process.Id).txt"; Source = (Join-Path $engineLogDir "rgl_log_errors_$($process.Id).txt") }
        $ownWatchdog = "watchdog_log_$($process.Id).txt"
        $copies += @{ Name = $ownWatchdog; Source = (Join-Path $engineLogDir $ownWatchdog) }
        if ($null -ne $crashLog -and $crashLog.Name -ne $ownWatchdog) {   # crash reported under another PID (relaunch)
            $copies += @{ Name = $crashLog.Name; Source = $crashLog.FullName }
        }
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

    $preflight = Get-JobPreflight -Config $Config -Job $job -PackageRoot $package.PackageRoot -PackageModuleIds @($package.ModuleIds)
    if ($preflight.Error) { return New-Outcome 'blocked' $preflight.Error }
    $Context.GameVersion = $preflight.GameVersion
    $Context.ModuleVersions = $preflight.ModuleVersions

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

function Restore-BaselineIfIdle {
    # Restores the baseline unless a Bannerlord process runs (e.g. after CleanupFailed: it could overwrite the files
    # again), and deletes the restore-pending marker after a successful restore. $When completes the log lines.
    # Never throws. Returns @{ Ok; Error }.
    param($Config, [string]$When)
    try {
        $stillRunning = @()
        try { $stillRunning = @(Get-BannerlordProcess | Where-Object { $null -ne $_ }) }
        catch { Write-AgentLog "Bannerlord process check failed: $($_.Exception.Message)" }
        if ($stillRunning.Count -gt 0) {
            Write-AgentLog "Baseline not restored ${When}: Bannerlord still running (PID $(($stillRunning | ForEach-Object { $_.Id }) -join ', '))."
            return @{ Ok = $false; Error = 'Bannerlord still running' }
        }
        $restore = Restore-TestRigBaseline -Config $Config
        if (-not $restore.Ok) {
            Write-AgentLog "Baseline restore $When failed: $($restore.Error)"
            return @{ Ok = $false; Error = $restore.Error }
        }
        Write-AgentLog "Baseline restored $When."
        $marker = Get-RestorePendingPath $Config
        try { if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force } }
        catch { Write-AgentLog "Restore-pending marker $marker could not be deleted (Save-TestRigBaseline.ps1 keeps refusing): $($_.Exception.Message)" }
        return @{ Ok = $true; Error = $null }
    }
    catch {
        Write-AgentLog "Baseline restore $When failed: $($_.Exception.Message)"
        return @{ Ok = $false; Error = $_.Exception.Message }
    }
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
        ConfigTouched  = $false   # set by Invoke-Run before its first change to the documents tree
        GameVersion    = $null
        ModuleVersions = @()
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
    # After the job, also after skipped or aborted runs: back to the baseline (no patch). Best effort, never
    # throws; only when a run got that far or an earlier job left a restore pending, so a rejected or blocked job
    # otherwise leaves the configuration alone.
    $baselineRestored = $null
    $baselineError = $null
    if ($context.ConfigTouched -or (Test-Path -LiteralPath (Get-RestorePendingPath $Config) -PathType Leaf)) {
        $restore = Restore-BaselineIfIdle -Config $Config -When 'after the job'
        $baselineRestored = $restore.Ok
        $baselineError = $restore.Error
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
            baselineRestored = $baselineRestored
            baselineError    = $baselineError
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
            baselineRestored = $null   # same shape as Invoke-Job's done.json; nothing is restored here
            baselineError    = $null
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
    # One poll: claim and process the oldest job, holding the config lock throughout. Returns $true if a job was
    # handled. While Save-TestRigBaseline.ps1 holds the lock no job is claimed (the next poll tries again).
    # Never throws.
    param($Config)
    $lock = $null
    try {
        $lock = Enter-ConfigLock
        if ($null -eq $lock) {
            Write-AgentLog "Save-TestRigBaseline.ps1 holds $($script:ConfigMutexName) - no job claimed in this poll."
            return $false
        }
        $job = Get-NextJob -QueueRoot $Config.queueRoot
        if ($null -eq $job) { return $false }
        Invoke-Job -Config $Config -Job $job
        return $true
    }
    catch {
        Write-AgentLog "Unexpected error in poll cycle: $($_.Exception.Message)"
        return $false
    }
    finally {
        try { Exit-ConfigLock $lock }
        catch { Write-AgentLog "Releasing $($script:ConfigMutexName) failed: $($_.Exception.Message)" }
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
        # A job that died mid-run (or whose after-job restore was skipped or failed) left the run patch in the game
        # configuration. No config lock needed: Save-TestRigBaseline.ps1 refuses while the marker exists.
        if (Test-Path -LiteralPath (Get-RestorePendingPath $config) -PathType Leaf) {
            $null = Restore-BaselineIfIdle -Config $config -When 'at startup (restore pending)'
        }
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
