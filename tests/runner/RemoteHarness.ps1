# Test helper (dot-sourced by Transport.Ssh.Tests.ps1): runs the PowerShell scripts that the
# transport sends to the test PC for real, on this machine, against a local folder used as queue root.
#
# Usage in a test (after dot-sourcing Transport.Ssh.ps1 and this file):
#   Mock Invoke-RigSsh { Invoke-RigRemoteLocally -Command $Command }
#   ... then call Get-JobState / Send-JobAbort / Publish-Job with a target whose remoteQueueRoot is a local folder.
#
# The payload goes through "powershell -NoProfile -EncodedCommand <base64>", exactly as on the remote
# side. EncodedCommand is not a script file, so no ExecutionPolicy setting is involved.

# -Command: "powershell -NoProfile -EncodedCommand <base64>" as built by Invoke-RigRemoteScript.
# Returns stdout lines; throws like the real transport on a non-zero exit code (stderr in the message).
function Invoke-RigRemoteLocally {
    param([Parameter(Mandatory)][string]$Command)
    if ($Command -notmatch '^powershell -NoProfile -EncodedCommand ([A-Za-z0-9+/=]+)$') {
        throw "Not an encoded remote command: $Command"
    }
    Invoke-RigNative -Tool 'powershell.exe' -Arguments @('-NoProfile', '-EncodedCommand', $Matches[1])
}

function New-LocalRigTarget {
    param([Parameter(Mandatory)][string]$QueueRoot)
    [pscustomobject]@{ host = 'testpc'; user = 'rig'; keyPath = 'C:\keys\rig_ed25519'; remoteQueueRoot = $QueueRoot }
}

# Creates <QueueRoot>\jobs\<JobId>\<file> (and <QueueRoot>\results\<JobId>\<file>) with placeholder content.
function New-LocalQueueJob {
    param(
        [Parameter(Mandatory)][string]$QueueRoot,
        [Parameter(Mandatory)][string]$JobId,
        [string[]]$JobFile = @(),
        [string[]]$ResultFile = @()
    )
    foreach ($pair in @(@('jobs', $JobFile), @('results', $ResultFile))) {
        foreach ($f in $pair[1]) {
            $p = Join-Path (Join-Path (Join-Path $QueueRoot $pair[0]) $JobId) $f
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force
            [IO.File]::WriteAllText($p, '{}')
        }
    }
    if ($JobFile.Count -eq 0) { $null = New-Item -ItemType Directory -Path (Join-Path (Join-Path $QueueRoot 'jobs') $JobId) -Force }
}
