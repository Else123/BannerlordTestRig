<#
.SYNOPSIS
    Records the rig's baseline game configuration from the current state of the test PC.

.DESCRIPTION
    Copies <documentsRoot>\Mount and Blade II Bannerlord\Configs\BannerlordConfig.txt (required) and the
    managed MCM folders (Configs\ModSettings\Global\<folder>\, the list in TestRigAgent.ps1) into
    <baselineRoot> with the same layout, and prints every file with its SHA-256. The agent restores this
    baseline before each run and after each job.

    Paths come from agent.config.json, read exactly as the agent reads it (this script dot-sources
    TestRigAgent.ps1 next to it). An existing baseline is never overwritten without -Force; with -Force
    the old <baselineRoot>\Configs is replaced completely. The new baseline is first staged in
    <baselineRoot>\Configs.new and checked (SHA-256 against the source), then swapped in; the old one is
    deleted only after the swap. Every recorded baseline carries the marker file Configs\.testrig-baseline;
    an existing Configs or Configs.old without it is never replaced or deleted, -Force included.
    Refuses while Bannerlord is running, while the agent runs a job (mutex Global\BannerlordTestRigConfig),
    while <workRoot>\restore-pending exists (a run patch may still be in the game configuration), and on
    any junction or symbolic link in the managed folders or in the baseline folders it would replace.

    Usage:  powershell -File agent\Save-TestRigBaseline.ps1 [-ConfigPath <agent.config.json>] [-Force]
    Exit code 0 = saved, 1 = refused or failed.
#>
[CmdletBinding()]
param(
    # Default (agent.config.json next to this script) is resolved below: $PSScriptRoot is empty in param
    # defaults under powershell -File (PS 5.1).
    [string]$ConfigPath = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
# Dot-sourcing the agent runs its param block in this scope and would reset $ConfigPath: keep the values.
$baselineConfigPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $PSScriptRoot 'agent.config.json' }
$baselineForce = [bool]$Force
. (Join-Path $PSScriptRoot 'TestRigAgent.ps1')

function Move-BaselineFolder {
    # Separate function so tests can simulate a failing rename.
    param([string]$From, [string]$To)
    [System.IO.Directory]::Move($From, $To)
}

function Assert-BaselineFolderReplaceable {
    # Throws unless the existing folder $Path may be renamed or deleted by this script: no junction or symbolic link
    # in it or below it (PS 5.1 Remove-Item -Recurse follows one) and, with -RequireMarker, it carries the marker
    # file, i.e. it is a baseline this script recorded and not some other folder named Configs.
    param([string]$Path, [switch]$RequireMarker)
    Assert-NoReparsePoint (Get-Item -LiteralPath $Path -Force)
    Add-ManagedFolderFiles -Dir $Path -RelDir (Split-Path -Leaf $Path) -Files (New-Object System.Collections.Generic.List[string])
    if ($RequireMarker -and -not (Test-Path -LiteralPath (Join-Path $Path $script:BaselineMarkerFile) -PathType Leaf)) {
        throw ("$Path has no $($script:BaselineMarkerFile) file, so it was not recorded by this script (or by a version " +
            "before the marker). Nothing was changed. Check that baselineRoot is right, then delete or move $Path by hand and save again.")
    }
}

function Save-TestRigBaseline {
    # Returns the process exit code: 0 only if the new baseline, BannerlordConfig.txt included, is in place.
    param([string]$Path, [bool]$Overwrite)
    $staging = $null
    $lock = $null
    try {
        # Get-AgentConfig also refuses a baselineRoot that is, contains or lies inside the game's documents folder,
        # or that is or lies below a junction or symbolic link.
        $config = Get-AgentConfig -Path $Path
        $running = @(Get-BannerlordProcess | Where-Object { $null -ne $_ })
        if ($running.Count -gt 0) {
            Write-Host "Not saved: Bannerlord is running (PID $(($running | ForEach-Object { $_.Id }) -join ', ')). Close the game first: it rewrites its configuration."
            return 1
        }
        # Held until the end, so the agent claims no job while the baseline is recorded.
        $lock = Enter-ConfigLock
        if ($null -eq $lock) {
            Write-Host "Not saved: the agent is running a job (it holds $($script:ConfigMutexName)). Try again when the job is done."
            return 1
        }
        $pending = Get-RestorePendingPath $config
        if (Test-Path -LiteralPath $pending) {
            Write-Host ("Not saved: $pending exists - a job's run patch may still be in the game configuration, and saving now " +
                "would record it as the baseline. Restart the agent or let it finish a job (it restores the baseline and " +
                "deletes the marker), or, after checking the game configuration by hand, delete $pending.")
            return 1
        }
        $docs = Join-Path $config.documentsRoot 'Mount and Blade II Bannerlord'
        $baselineRoot = $config.baselineRoot
        $source = Join-Path $docs $script:BaselineConfigFile
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            Write-Host "Not saved: $source does not exist (start the game once, or check documentsRoot)."
            return 1
        }
        $configs = Join-Path $baselineRoot 'Configs'
        $previous = Join-Path $baselineRoot 'Configs.old'
        $stagingPath = Join-Path $baselineRoot 'Configs.new'
        # Configs.old and Configs.new are only ever left by an interrupted save; Configs is replaced only if it is ours.
        if (Test-Path -LiteralPath $previous) { Assert-BaselineFolderReplaceable $previous -RequireMarker }
        if (Test-Path -LiteralPath $stagingPath) { Assert-BaselineFolderReplaceable $stagingPath }
        # A swap interrupted between its two renames left the previous baseline in Configs.old: put it back first.
        if ((Test-Path -LiteralPath $previous) -and -not (Test-Path -LiteralPath $configs)) { Move-BaselineFolder -From $previous -To $configs }
        if ((Test-Path -LiteralPath $configs) -and -not $Overwrite) {
            Write-Host "Not saved: a baseline already exists in $baselineRoot. Use -Force to replace it."
            return 1
        }
        if (Test-Path -LiteralPath $configs) { Assert-BaselineFolderReplaceable $configs -RequireMarker }

        # Stage the new baseline in Configs.new and check it; the old one stays untouched until then.
        $files = @(Get-ManagedConfigFiles $docs)   # throws on a junction or symbolic link
        $staging = $stagingPath
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        Write-Host "Saving the baseline from $docs to $baselineRoot"
        $lines = @()
        foreach ($rel in $files) {
            $sourceFile = Join-Path $docs $rel
            $target = Join-Path $staging $rel.Substring('Configs\'.Length)   # every managed path starts with Configs\
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $sourceFile -Destination $target -Force
            $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            if ($hash -ne (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash) {
                throw "The copy of $sourceFile differs from the file (changed while copying?)."
            }
            $lines += ('{0}  {1}' -f $rel.Replace('\', '/'), $hash)
        }
        $stagedConfig = Join-Path $staging 'BannerlordConfig.txt'
        if (-not (Test-Path -LiteralPath $stagedConfig -PathType Leaf)) { throw "$source was not copied." }
        $configHash = (Get-FileHash -LiteralPath $stagedConfig -Algorithm SHA256).Hash
        [System.IO.File]::WriteAllText((Join-Path $staging $script:BaselineMarkerFile), "Baseline recorded by Save-TestRigBaseline.ps1 at $(Get-UtcStamp)`n")

        # Swap: Configs -> Configs.old, Configs.new -> Configs; the old baseline is deleted only after that.
        if (Test-Path -LiteralPath $configs) {
            if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Recurse -Force }   # left by an earlier save
            Move-BaselineFolder -From $configs -To $previous
        }
        try { Move-BaselineFolder -From $staging -To $configs }
        catch {
            if (Test-Path -LiteralPath $previous) { Move-BaselineFolder -From $previous -To $configs }
            throw
        }
        $staging = $null
        if (Test-Path -LiteralPath $previous) {
            try { Remove-Item -LiteralPath $previous -Recurse -Force }
            catch { Write-Host "Warning: the previous baseline $previous could not be deleted: $($_.Exception.Message)" }
        }

        $savedConfig = Join-Path $configs 'BannerlordConfig.txt'
        if (-not (Test-Path -LiteralPath $savedConfig -PathType Leaf) -or (Get-FileHash -LiteralPath $savedConfig -Algorithm SHA256).Hash -ne $configHash) {
            throw "$savedConfig is missing or differs after the swap."
        }
        foreach ($line in $lines) { Write-Host $line }
        Write-Host "Managed MCM folders: $($script:BaselineMcmFolders -join ', ')"
        return 0
    }
    catch {
        Write-Host "Not saved: $($_.Exception.Message)"
        if ($null -ne $staging -and (Test-Path -LiteralPath $staging)) {
            try { Remove-Item -LiteralPath $staging -Recurse -Force } catch { }
        }
        return 1
    }
    finally {
        try { Exit-ConfigLock $lock } catch { }
    }
}

if ($MyInvocation.InvocationName -ne '.') {   # dot-sourced by the tests: functions only
    exit (Save-TestRigBaseline -Path $baselineConfigPath -Overwrite $baselineForce)
}
