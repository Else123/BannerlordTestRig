<#
.SYNOPSIS
    Writes the L1 baseline runner\baselines\L1.json from finished L1-BASE and L1 jobs (no hand-edited numbers).

.DESCRIPTION
    Reads out\results\<jobId>\job-result.json of each job (fetched by Invoke-TestRig.ps1 -Wait) and writes the whole
    baseline file anew: game version, the jobs with their module versions, every base run and every L1 run with its
    tempo (runningDaysPerRealMinute) and exception counts, and the derived values (tempo median, vanilla threshold).
    Base jobs must be -Suite L1-BASE with exit code 0; L1 jobs must be -Suite L1. Every run must be Completed with a
    tempo, and all runs must report the same game version; otherwise nothing is written (exit 1).
    Prints the derived values and warns when the base-run tempo spread exceeds 10 % or the slowest L1 run is below
    0.8 x the base median. Format and verdict rules: docs/JOB-PROTOCOL.md, "L1 verdict".
    Job ids may be given as a list or comma-separated (powershell -File passes a list as one string).

.EXAMPLE
    .\runner\Update-L1Baseline.ps1 -BaseJobIds 20261104-090000-0b0b -L1JobIds 20261104-093000-1111, 20261104-094000-2222, 20261104-095000-3333
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$BaseJobIds,
    [string[]]$L1JobIds = @(),
    # Defaults (resolved in the body: $PSScriptRoot is empty inside param() defaults under powershell -File):
    # out\results of this repo and runner\baselines\L1.json.
    [string]$ResultsRoot = '',
    [string]$Path = ''
)

. (Join-Path $PSScriptRoot 'Invoke-TestRig.ps1')

if (-not $ResultsRoot) { $ResultsRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'out\results' }
if (-not $Path) { $Path = $script:RigL1BaselinePath }
$splitIds = { param([string[]]$Ids) @($Ids | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) }
exit (Update-RigL1Baseline -BaseJobIds (& $splitIds $BaseJobIds) -L1JobIds (& $splitIds $L1JobIds) -ResultsRoot $ResultsRoot -Path $Path)
