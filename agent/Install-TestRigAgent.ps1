<#
.SYNOPSIS
    Installs the Bannerlord test rig agent on the test PC.

.DESCRIPTION
    - Copies TestRigAgent.ps1 to -InstallRoot (default C:\TestRig\agent).
    - Creates agent.config.json from agent.config.example.json only if none exists.
    - Registers the scheduled task "BannerlordTestRigAgent": at logon of the current user,
      principal = current user, logon type Interactive, run level Limited (no elevation).
      Running the script again replaces the task.

    The execution policy is never bypassed or changed by this script. If the effective
    policy would block "powershell -File", a message says so; the owner decides.

    A running agent keeps executing the old script until the task is restarted (next logon,
    or -Restart, which stops and starts the task; a job in progress is then cut off).

    Usage:  powershell -File agent\Install-TestRigAgent.ps1 [-InstallRoot C:\TestRig\agent] [-Restart] [-WhatIf]
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallRoot = 'C:\TestRig\agent',
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'
$taskName = 'BannerlordTestRigAgent'
$sourceDir = $PSScriptRoot

$agentSource = Join-Path $sourceDir 'TestRigAgent.ps1'
$exampleSource = Join-Path $sourceDir 'agent.config.example.json'
foreach ($required in @($agentSource, $exampleSource)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing file next to the installer: $required" }
}

$agentTarget = Join-Path $InstallRoot 'TestRigAgent.ps1'
$configTarget = Join-Path $InstallRoot 'agent.config.json'

if ($PSCmdlet.ShouldProcess($InstallRoot, 'Copy TestRigAgent.ps1')) {
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    Copy-Item -LiteralPath $agentSource -Destination $agentTarget -Force
    Write-Host "Installed $agentTarget"
}

if (Test-Path -LiteralPath $configTarget) {
    Write-Host "Kept existing $configTarget"
}
elseif ($PSCmdlet.ShouldProcess($configTarget, 'Create agent.config.json from the example')) {
    Copy-Item -LiteralPath $exampleSource -Destination $configTarget
    Write-Host "Created $configTarget - edit gamePath (and other paths) before the first job."
}

$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($PSCmdlet.ShouldProcess("$taskName ($user)", 'Register scheduled task (at logon, Interactive, Limited)')) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -WindowStyle Hidden -File "{0}"' -f $agentTarget)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    # The default execution time limit (72 h) would kill the long-running agent. The default
    # priority 7 (below normal) would be inherited by the game: use 4 (normal).
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Priority 4 `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force
    Write-Host "Registered scheduled task $taskName for $user."
}

# Effective policy as the scheduled task sees it: the Process scope (e.g. this session's
# Bypass) does not apply to the task's own powershell.exe.
$policy = 'Restricted'
$policyList = @(Get-ExecutionPolicy -List)
foreach ($scope in @('MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine')) {
    $entry = $policyList | Where-Object { [string]$_.Scope -eq $scope } | Select-Object -First 1
    if ($entry -and [string]$entry.ExecutionPolicy -ne 'Undefined') { $policy = [string]$entry.ExecutionPolicy; break }
}
if ($policy -in @('Restricted', 'AllSigned')) {
    Write-Warning ("The effective execution policy is '$policy': 'powershell -File TestRigAgent.ps1' will be blocked " +
        "(unsigned script). This installer does not change it. Owner decision: either sign the script, or run " +
        "'Set-ExecutionPolicy -Scope CurrentUser RemoteSigned' yourself.")
}
if ($Restart) {
    if ($PSCmdlet.ShouldProcess($taskName, 'Stop and start the scheduled task')) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $taskName
        Write-Host "Restarted $taskName - the new script is running."
    }
}
else {
    Write-Host 'A running agent keeps the old script until the next logon; use -Restart to stop and start the task now.'
}
Write-Host 'Done. The agent starts at the next logon of this user; to start it now: Start-ScheduledTask -TaskName BannerlordTestRigAgent'
