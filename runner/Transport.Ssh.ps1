# SSH transport for the test rig (PowerShell 5.1). Contract: docs/JOB-PROTOCOL.md.
#
# Public functions (each takes -Target: host, user, keyPath, remoteQueueRoot):
#   Publish-Job, Get-JobState, Receive-JobResult, Send-JobAbort
# Everything else is internal. All ssh/scp calls go through Invoke-RigSsh / Invoke-RigScp
# (which share Invoke-RigNative), so tests can mock them.
#
# The remote shell is cmd.exe. Every remote command is sent as
# "powershell -NoProfile -EncodedCommand <base64 UTF-16LE>" (only [A-Za-z0-9+/=]: no quotes or
# backslashes survive/are needed, PS 5.1 and MSYS ssh both mangle them) and may return JSON on stdout.
# Remote results are data: they are only parsed (ConvertFrom-Json), never executed.

# [0-9], not \d (which matches other Unicode digits); \z, not $ (which also matches before a trailing newline).
$script:JobIdPattern = '^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}\z'

function Assert-RigJobId {
    param([string]$JobId)
    if ($JobId -cnotmatch $script:JobIdPattern) { throw "Invalid jobId '$JobId'." }
}

function ConvertTo-EncodedCommand {
    param([Parameter(Mandatory)][string]$Script)
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
}

function ConvertTo-PsLiteral {
    param([Parameter(Mandatory)][string]$Text)
    # PowerShell treats U+2018, U+2019, U+201A and U+201B like ' as well: a plain Replace("'", "''") is not enough.
    "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Text) + "'"
}

# Drops the harmless OpenSSH post-quantum warning lines ("** ...") and blank lines.
function Select-SshStderrLine {
    param([string[]]$Line)
    foreach ($l in @($Line)) {
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        if ($l.StartsWith('** ')) { continue }
        $l
    }
}

# Runs a native tool, returns stdout lines, throws on a non-zero exit code (transport error).
function Invoke-RigNative {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $prev = $ErrorActionPreference
    # Continue: with "Stop", stderr lines captured via 2>&1 would throw in Windows PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $raw = @(& $Tool @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $stdout = @($raw | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
    $stderr = @(Select-SshStderrLine -Line @($raw | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }))
    if ($null -ne $code -and $code -ne 0) {
        throw "$Tool failed (exit $code): $($stderr -join ' | ')"
    }
    $stdout
}

function Get-RigSshOptions {
    param([Parameter(Mandatory)]$Target)
    # ServerAlive*: a dropped network ends the call after ~45 s instead of hanging for hours.
    # IdentitiesOnly: offer only the configured key, not whatever an ssh-agent holds.
    @(
        '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
        '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3',
        '-o', 'IdentitiesOnly=yes', '-i', $Target.keyPath
    )
}

# Always the Windows OpenSSH client, never whatever "ssh"/"scp" PATH resolves to first: Git's MSYS
# binaries treat backslashes and drive-letter paths differently. Resolved once, then cached.
$script:RigToolPaths = @{}
function Get-RigOpenSshTool {
    param([Parameter(Mandatory)][ValidateSet('ssh', 'scp')][string]$Name)
    if (-not $script:RigToolPaths.ContainsKey($Name)) {
        $path = Join-Path $env:SystemRoot "System32\OpenSSH\$Name.exe"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Windows OpenSSH client not found: $path (install the optional Windows feature 'OpenSSH Client')."
        }
        $script:RigToolPaths[$Name] = $path
    }
    $script:RigToolPaths[$Name]
}

function Invoke-RigSsh {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Command
    )
    # Windows PowerShell 5.1 mangles embedded double quotes (and MSYS ssh eats backslashes) in
    # native arguments: callers must pass a command without " and \ (see Invoke-RigRemoteScript).
    if ($Command.Contains('"') -or $Command.Contains('\')) {
        throw "Remote command must not contain '""' or '\': use Invoke-RigRemoteScript."
    }
    $sshArgs = @(Get-RigSshOptions -Target $Target) + @("$($Target.user)@$($Target.host)", $Command)
    (Invoke-RigNative -Tool (Get-RigOpenSshTool -Name ssh) -Arguments $sshArgs)
}

# -Source / -Destination are passed through unchanged (use Get-ScpRemoteSpec for remote ones).
function Invoke-RigScp {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Recurse
    )
    $scpArgs = @(Get-RigSshOptions -Target $Target)
    if ($Recurse) { $scpArgs += '-r' }
    $scpArgs += @($Source, $Destination)
    $null = Invoke-RigNative -Tool (Get-RigOpenSshTool -Name scp) -Arguments $scpArgs
}

# Sends a PowerShell script to the remote and returns its stdout lines. Any error in the script
# ends it with a message on stderr and exit code 1 (-> transport error).
function Invoke-RigRemoteScript {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Script
    )
    # ProgressPreference: keeps CLIXML progress records off the stream.
    $full = "`$ErrorActionPreference = 'Stop'; `$ProgressPreference = 'SilentlyContinue'`n" +
    "try {`n$Script`n} catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }"
    $cmd = 'powershell -NoProfile -EncodedCommand ' + (ConvertTo-EncodedCommand -Script $full)
    # The remote cmd.exe truncates command lines at 8191 characters: fail here instead of running a cut-off script.
    if ($cmd.Length -gt 8000) { throw "Encoded remote command is too long ($($cmd.Length) > 8000 characters)." }
    (Invoke-RigSsh -Target $Target -Command $cmd)
}

function ConvertFrom-RigRemoteJson {
    param([string[]]$Lines)
    $text = (@($Lines) -join "`n").Trim()
    try { $text | ConvertFrom-Json } catch { throw "Unparsable remote output: $text" }
}

# Windows path on the test PC: <remoteQueueRoot>\<jobs|results>\<jobId>[\<file>]
function Get-RigRemotePath {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][ValidateSet('jobs', 'results')][string]$Area,
        [Parameter(Mandatory)][string]$JobId,
        [string]$File
    )
    Assert-RigJobId $JobId
    $p = $Target.remoteQueueRoot.TrimEnd('\', '/') + "\$Area\$JobId"
    if ($File) { $p += "\$File" }
    $p
}

# scp remote spec. Isolated here: Windows OpenSSH (9.5) accepts "user@host:C:/path"; the form
# "user@host:/C:/path" was measured to work as well (live test, 2026-10-31), so the simpler one is used.
function Get-ScpRemoteSpec {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$WindowsPath
    )
    "$($Target.user)@$($Target.host):" + ($WindowsPath -replace '\\', '/')
}

function Publish-Job {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$JobDirectory   # local folder with package.zip and job.json
    )
    $zip = Join-Path $JobDirectory 'package.zip'
    $json = Join-Path $JobDirectory 'job.json'
    foreach ($f in $zip, $json) { if (-not (Test-Path -LiteralPath $f)) { throw "Missing local file: $f" } }

    $dir = Get-RigRemotePath -Target $Target -Area jobs -JobId $JobId
    $dirLit = ConvertTo-PsLiteral $dir
    $null = Invoke-RigRemoteScript -Target $Target -Script @"
if (Test-Path -LiteralPath $dirLit) { throw 'Remote job folder already exists.' }
`$null = [IO.Directory]::CreateDirectory($dirLit)
"@
    Invoke-RigScp -Target $Target -Source $zip -Destination (Get-ScpRemoteSpec -Target $Target -WindowsPath "$dir\package.zip")
    Invoke-RigScp -Target $Target -Source $json -Destination (Get-ScpRemoteSpec -Target $Target -WindowsPath "$dir\job.json.tmp")
    # job.json appearing is the only signal for the agent: rename last.
    # Rename-Item never overwrites an existing job.json (it errors instead).
    $tmpLit = ConvertTo-PsLiteral "$dir\job.json.tmp"
    $null = Invoke-RigRemoteScript -Target $Target -Script "Rename-Item -LiteralPath $tmpLit -NewName 'job.json'"
}

# -OpenJobs: returns the ids of open jobs (job.json or job.claimed.json, no done.json).
# -JobId:    returns { jobJson, claimed, withdrawn, state (parsed state.json or $null), done }.
function Get-JobState {
    [CmdletBinding(DefaultParameterSetName = 'Job')]
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory, ParameterSetName = 'Job')][string]$JobId,
        [Parameter(Mandatory, ParameterSetName = 'Open')][switch]$OpenJobs
    )
    if ($PSCmdlet.ParameterSetName -eq 'Open') {
        $jobs = ConvertTo-PsLiteral ($Target.remoteQueueRoot.TrimEnd('\', '/') + '\jobs')
        $results = ConvertTo-PsLiteral ($Target.remoteQueueRoot.TrimEnd('\', '/') + '\results')
        $script = @"
`$open = @()
if (Test-Path -LiteralPath $jobs) {
    foreach (`$d in Get-ChildItem -LiteralPath $jobs -Directory | Sort-Object Name) {
        `$hasJob = (Test-Path -LiteralPath (Join-Path `$d.FullName 'job.json')) -or (Test-Path -LiteralPath (Join-Path `$d.FullName 'job.claimed.json'))
        `$done = Test-Path -LiteralPath (Join-Path (Join-Path $results `$d.Name) 'done.json')
        if (`$hasJob -and -not `$done) { `$open += `$d.Name }
    }
}
[pscustomobject]@{ open = @(`$open) } | ConvertTo-Json -Depth 5 -Compress
"@
        $o = ConvertFrom-RigRemoteJson (Invoke-RigRemoteScript -Target $Target -Script $script)
        return @($o.open)   # callers wrap the result in @() (the pipeline unrolls it)
    }

    $jobDir = ConvertTo-PsLiteral (Get-RigRemotePath -Target $Target -Area jobs -JobId $JobId)
    $resDir = ConvertTo-PsLiteral (Get-RigRemotePath -Target $Target -Area results -JobId $JobId)
    $script = @"
`$j = $jobDir
`$r = $resDir
`$state = `$null
`$sp = Join-Path `$j 'state.json'
if (Test-Path -LiteralPath `$sp) { try { `$state = Get-Content -LiteralPath `$sp -Raw | ConvertFrom-Json } catch { `$state = `$null } }
[pscustomobject]@{
    jobJson   = [bool](Test-Path -LiteralPath (Join-Path `$j 'job.json'))
    claimed   = [bool](Test-Path -LiteralPath (Join-Path `$j 'job.claimed.json'))
    withdrawn = [bool](Test-Path -LiteralPath (Join-Path `$j 'job.withdrawn.json'))
    state     = `$state
    done      = [bool](Test-Path -LiteralPath (Join-Path `$r 'done.json'))
} | ConvertTo-Json -Depth 10 -Compress
"@
    ConvertFrom-RigRemoteJson (Invoke-RigRemoteScript -Target $Target -Script $script)
}

# Copies results\<jobId> into <DestinationRoot>\<jobId> and returns that path. The copy lands in
# <DestinationRoot>\<jobId>.partial first and is renamed only after scp succeeded, so a failed or
# interrupted fetch never leaves something that looks like a complete result. A leftover .partial
# from an earlier attempt is deleted first.
function Receive-JobResult {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$DestinationRoot
    )
    $local = Join-Path $DestinationRoot $JobId
    if (Test-Path -LiteralPath $local) { throw "Local result folder already exists: $local" }
    $partial = "$local.partial"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $partial -Force   # also creates DestinationRoot
    $remote = Get-ScpRemoteSpec -Target $Target -WindowsPath (Get-RigRemotePath -Target $Target -Area results -JobId $JobId)
    # scp -r into an existing folder creates <partial>\<jobId>.
    Invoke-RigScp -Target $Target -Source $remote -Destination $partial -Recurse
    $fetched = Join-Path $partial $JobId
    if (-not (Test-Path -LiteralPath $fetched -PathType Container)) { throw "scp succeeded but the result folder is missing: $fetched" }
    Move-Item -LiteralPath $fetched -Destination $local
    Remove-Item -LiteralPath $partial -Recurse -Force
    $local
}

# Default: creates the empty "abort" file in the job folder.
# -Withdraw: tries to rename job.json -> job.withdrawn.json and returns
#            { withdrawn, jobJsonPresent, claimed } (all booleans, read after the attempt):
#            withdrawn      the rename worked: the agent never claimed the job
#            claimed        job.claimed.json exists: the agent claimed it
#            jobJsonPresent job.json is still there: the rename failed for another reason (e.g. the file is
#                           open in an antivirus scanner/indexer), so the agent may still pick the job up.
function Send-JobAbort {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$JobId,
        [switch]$Withdraw
    )
    $dir = Get-RigRemotePath -Target $Target -Area jobs -JobId $JobId
    if ($Withdraw) {
        $dirLit = ConvertTo-PsLiteral $dir
        $script = @"
`$j = $dirLit
`$jp = Join-Path `$j 'job.json'
`$ok = `$false
try { Rename-Item -LiteralPath `$jp -NewName 'job.withdrawn.json' -ErrorAction Stop; `$ok = `$true } catch { `$ok = `$false }
[pscustomobject]@{
    withdrawn      = `$ok
    jobJsonPresent = [bool](Test-Path -LiteralPath `$jp)
    claimed        = [bool](Test-Path -LiteralPath (Join-Path `$j 'job.claimed.json'))
} | ConvertTo-Json -Compress
"@
        $o = ConvertFrom-RigRemoteJson (Invoke-RigRemoteScript -Target $Target -Script $script)
        return [pscustomobject]@{ withdrawn = [bool]$o.withdrawn; jobJsonPresent = [bool]$o.jobJsonPresent; claimed = [bool]$o.claimed }
    }
    $ap = ConvertTo-PsLiteral "$dir\abort"
    $script = "New-Item -ItemType File -Path $ap -Force | Out-Null"
    $null = Invoke-RigRemoteScript -Target $Target -Script $script
}
