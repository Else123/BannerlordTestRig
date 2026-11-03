<#
.SYNOPSIS
    Re-judges a fetched test rig job offline and rewrites out\results\<jobId>\job-result.json.

.DESCRIPTION
    Judges out\results\<jobId> again exactly as Invoke-TestRig.ps1 -Wait does after fetching it, without contacting the
    test PC: the per-run rows, the suite verdicts (L1 verdict, expectations) and the suite's PostRunChecks/JobChecks
    (e.g. CW-2 Check-CommandLog.ps1 per run, CW-1 Compare-Ac25a.ps1 per job) with the check scripts as they are now in the
    workspace repos. Days, modules and the mode of every run come from out\jobs\<jobId>\job.json; the suite from the
    job's existing job-result.json unless -Suite is given. Not reconstructed: a runner-side time limit of the original
    wait and the version warnings. Exit codes as Invoke-TestRig.ps1 (docs/JOB-PROTOCOL.md, "Runner exit codes"); 1 also
    when the job folders are unusable.

.EXAMPLE
    .\runner\Update-JobResult.ps1 -JobId 20261103-153840-2fe0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JobId,
    [string]$Suite = '',
    # Default (resolved in the body: $PSScriptRoot is empty inside param() defaults under powershell -File): out of this repo.
    [string]$OutRoot = ''
)

# Dot-sourcing Invoke-TestRig.ps1 binds its own (empty) parameters in this scope, $Suite among them: keep ours first.
$requestedSuite = $Suite
. (Join-Path $PSScriptRoot 'Invoke-TestRig.ps1')

if (-not $OutRoot) { $OutRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'out' }
exit (Update-RigJobResult -JobId $JobId -OutRoot $OutRoot -Suite $requestedSuite)
