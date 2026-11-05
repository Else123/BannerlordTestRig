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
    With towerGamePath the whole job (also -PackageFrom) is guarded: no game or launcher process may run
    on the tower and the tower's Modules and Documents folders (towerDocumentsPath, optional) must stay
    unchanged; see "Tower guard" in docs/JOB-PROTOCOL.md (Modules changed: 1; Documents changed or a
    process seen: 3).
    -PackageFrom (diagnosis) skips the build: it is a folder that contains Modules\<ModuleId>\...
    Without -Wait the job is published, the jobId is printed and the script exits 0.
    With -Wait it polls until done.json exists and fetches the result to out\results\<jobId>\.
    Fetched files are data: they are only parsed, never executed.

    Exit codes: 0 all runs Completed with enough days; 1 rig/infrastructure error (blocked, rejected,
    failed, SetupError, LaunchFailed, CleanupFailed, transport error, open job); 2 test failure
    (NotCompleted, Crashed, too few days); 3 time limit or agent not responding (HardTimeout,
    Hung, Aborted, claim timeout, stale heartbeat, overall deadline). Precedence: 1 > 3 > 2 > 0.
    If the job is not completed, the done status and the agent's message are printed.
    -Suite RIG (self-test, one job with five runs) is judged differently: each run must end with its
    expected exitClass (r1, r2: and a run message showing the cause; r4: and its exception counts); exit 0 if all do, 2 if
    one does not, 1 if the job is not completed (except aborted or the runner deadline: 3) or a run is missing.
    -HardTimeoutMinutes conflicts with -Suite RIG.
    -Suite L1-BASE (vanilla baseline: five soak runs with their own seeds, no mod) is judged the same way: each run
    must end Completed with enough days (Hung, HardTimeout, Aborted: 3). -HardTimeoutMinutes and -Seed conflict with it;
    -Days overrides its 30 days (a longer one scales the per-run hard timeout).
    -Suite is checked against the suite table ($script:RigSuites) in the script body: an unknown suite is a usage error
    (exit 1, listing the valid suites) before anything is built; the name is case-insensitive (-Suite l1 = L1).
    -Suite L1 also judges each Completed run's measurements against runner\baselines\L1.json (own/unhandled 0, vanilla
    threshold, tempo ratio, modules; written by Update-L1Baseline.ps1): a violation is exit 2, an unmeasured value exit 1.
    -Suite SM, CS and AT run the scenarios of one mod (SmithingSuite, CompanionManagementSuite, AutoTraderSpeed) with only
    that mod and its scenario module: exit 0 if every scenario Passed, 2 if one Failed, 1 for a rig error.
    -Suite CW1 is the AC25a comparison of CoherentWarAI (only that mod): twelve 30-day runs, seeds 1-3, per seed WarSails,
    FeatureOff, FeatureOff, WarSails, each recording the army digest; judged per run like -Suite RIG (Completed expected).
    Suite checks (after the fetch, on this PC; scripts of the CoherentWarAI repo next to this repo): -Suite L1 and CW1 run
    CW-2 (tools\Check-CommandLog.ps1, row <run> <Suite>-coherentwarai.command-log) on every Completed run with that run's
    mode and -MinDays = the days; CW1 also runs CW-1 (tools\Compare-Ac25a.ps1, rows job CW1-coherentwarai.ac25a-*) over the
    job. A FAIL is exit 2, an Inconclusive verdict exit 3, a missing log, script or result exit 1 (same precedence).
    A run without -Suite (ad hoc; it always loads CoherentWarAI) gets CW-2 the same way (row <run> coherentwarai.command-log),
    so -Days 10 -Wait is the 10-day WarSails check; fewer days than the check needs only warn.
    -Suite X runs the cross-mod scenario crossmod.trade-with-autoequip in two runs (r1 .done, r2 .cancel; 5 minutes each,
    Completed expected) with AutoTraderSpeed, CompanionManagementSuite, the harness and CrossMod.Scenarios.
    runner\Update-JobResult.ps1 -JobId <jobId> re-judges a fetched job offline (rewrites its job-result.json).

.PARAMETER Suite
    A fixed test setup from the suite table (case-insensitive; '' or omitted = no suite): L1 (soak, all four mods, health
    bracket, L1 verdict, CW-2), L1-BASE (vanilla baseline for L1), SM (SmithingSuite scenarios), CS (CompanionManagementSuite
    scenarios), AT (AutoTraderSpeed scenarios), CW1 (AC25a comparison of CoherentWarAI, CW-2 and CW-1), RIG (rig self-test), X (cross-mod AutoTraderSpeed + CompanionManagementSuite, two runs).

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
    [ValidateSet('TestRig')][string]$Harness = 'TestRig',
    [string]$Suite,   # validated in the script body against $script:RigSuites (the single suite table)
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
    TestRig = 'TestRig.Harness'
}
# Suite id -> fixed settings. Harness is TestRig (the only harness); Mode, Seed
# and Days are defaults that an explicit parameter overrides. A suite defines its own mod list: base modules,
# CoherentWarAI (only when WithCoherentWarAI), ExtraModules, the harness module, then TailModules (scenario
# modules, which reference the harness and so load after it). Kind is the run kind: 'soak' or 'scenarios'
# (then Scenarios = the scenario ids to run). A suite may instead define Runs: one job with several runs, each with
# RunId, Scenarios, HardTimeoutMinutes and ExpectedExitClass (the verdict then compares every run with it), and
# optionally ExpectedMessagePattern: a case-sensitive regex the run's agent message (agent-run.json) must match,
# Seed: the run's own seed (job.json runs[].seed) instead of the suite's; then an explicit -Seed is a usage error,
# Mode: the run's own mode (job.json runs[].mode) instead of the suite's; then an explicit -Mode is a usage error, and
# every run's mode must load the same module list as the job's (WarSails and FeatureOff do, NoDlc does not: a usage error),
# OwnAssemblies: the DLL names written to job.json runs[].ownAssemblies (the agent passes exactly them to run.cfg),
# ExpectedValues: @{ Path; Value } per value the run's run-result.json must hold when it is Completed (Path = dotted
# property path, Value = a number or a boolean; see Get-RigExpectedValueChecks), and ClassificationTiming = $true: print
# the R2 timing line of exceptions.classification (Format-RigClassificationTiming). The HardTimeoutMinutes of a soak
# suite's run holds for the suite's Days; a longer -Days scales it (Get-RigSuiteRuns).
# Health (soak suites only): the scenario ids of the health bracket (F-S6-1), written to every run as job.json
# runs[].health; the verdict then also needs each <id>@0 and <id>@<days> line (see Get-RigHealthOutcome).
# PostRunChecks / JobChecks (F-S10-1): scripts of a mod repo that the runner calls on this PC after the result is fetched
# (or re-judged offline, Update-JobResult.ps1); Script is relative to the workspace root (the folder of the repos).
# PostRunChecks run once per Completed run: @{ Id; Script; Log } is called as
#   <Script> -LogPath <run folder>\<Log> -Mode <the run's job.json mode> -MinDays <days> -ResultPath <run folder>\<Id>.json
# and must write { "rows": [ { "ac", "verdict", "evidence" } ] } there (see Invoke-RigPostRunCheck for the verdicts).
# JobChecks run once per completed job: @{ Id; Script; ResultFile } is called as
#   <Script> -JobPath <job result folder> -ResultPath <job result folder>\<ResultFile> [-JobManifestPath <out\jobs\<id>\job.json>]
# (the manifest only with UsesJobManifest = $true, when the file exists; the plan is not part of the results folder).
# and must write { "checks": [ { "check", "verdict", "detail" } ] } there (see Invoke-RigJobCheck).
$script:RigCommandLogCheck = @{ Id = 'coherentwarai.command-log'; Script = 'BannerlordCoherentWarAI\tools\Check-CommandLog.ps1'; Log = 'CoherentWarAI.log' }
$script:RigSuites = @{
    L1 = @{
        Harness           = 'TestRig'
        Mode              = 'WarSails'
        Seed              = 1
        Days              = 30
        Kind              = 'soak'
        WithCoherentWarAI = $true
        ExtraModules      = @('AutoTraderSpeed', 'SmithingSuite', 'CompanionManagementSuite')
        # One scenario module per mod, in the order of the mods; each holds that mod's health scenario.
        TailModules       = @('CoherentWarAI.Scenarios', 'AutoTraderSpeed.Scenarios', 'SmithingSuite.Scenarios', 'CompanionManagementSuite.Scenarios')
        Health            = @('coherentwarai.health', 'autotrader.health', 'smithingsuite.health', 'companionsuite.health')
        # CW-2 in every run with CoherentWarAI (F-S10-6).
        PostRunChecks     = @($script:RigCommandLogCheck)
    }
    # Vanilla baseline for L1 (F-S6-3): the L1 module list without the four mods and without scenario modules (the
    # Workshop libraries and NavalDLC stay). Five 30-day soaks; the seed varies across runs, three repeat seed 1.
    'L1-BASE' = @{
        Harness           = 'TestRig'
        Mode              = 'WarSails'
        Seed              = 1
        Days              = 30
        Kind              = 'soak'
        WithCoherentWarAI = $false
        ExtraModules      = @()
        TailModules       = @()
        Runs              = @(
            # 10 min each: a 30-day L1 soak took 3m41s of agent time on the game PC (job 20261102-183606-fd57).
            @{ RunId = 'r1'; Seed = 1; HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r2'; Seed = 1; HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r3'; Seed = 1; HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r4'; Seed = 2; HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r5'; Seed = 3; HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' }
        )
    }
    SM = @{
        Harness           = 'TestRig'
        Mode              = 'WarSails'
        Seed              = 1
        Days              = 1
        Kind              = 'scenarios'
        Scenarios         = @('smithing.smelt-then-refine', 'smithing.nothing-to-do', 'smithing.travel-stamina')
        WithCoherentWarAI = $false
        ExtraModules      = @('SmithingSuite')
        TailModules       = @('SmithingSuite.Scenarios')
    }
    # Companion suite (S7): the three companion scenarios on a fresh WarSails campaign, in this order; only the mod
    # and its scenario module are loaded.
    CS = @{
        Harness           = 'TestRig'
        Mode              = 'WarSails'
        Seed              = 1
        Days              = 1
        Kind              = 'scenarios'
        Scenarios         = @('companion.equip-now', 'companion.roles-apply', 'companion.development-guard')
        WithCoherentWarAI = $false
        ExtraModules      = @('CompanionManagementSuite')
        TailModules       = @('CompanionManagementSuite.Scenarios')
    }
    # AutoTrader suite (S8): the warehouse consignment and the town trade scenario.
    AT = @{
        Harness           = 'TestRig'
        Mode              = 'WarSails'
        Seed              = 1
        Days              = 1
        Kind              = 'scenarios'
        Scenarios         = @('autotrader.warehouse-consign', 'autotrader.town-trade')
        WithCoherentWarAI = $false
        ExtraModules      = @('AutoTraderSpeed')
        TailModules       = @('AutoTraderSpeed.Scenarios')
    }
    # Cross-mod suite (S9, X-1): AutoTraderSpeed with CompanionManagementSuite, one scenario id per run (F-S9-1): the
    # trade with auto-equip confirmed (done) and cancelled (cancel).
    X = @{
        Harness           = 'TestRig'
        Mode              = 'WarSails'
        Seed              = 1
        Days              = 1
        Kind              = 'scenarios'
        WithCoherentWarAI = $false
        ExtraModules      = @('AutoTraderSpeed', 'CompanionManagementSuite')
        TailModules       = @('CrossMod.Scenarios')
        Runs              = @(
            @{ RunId = 'r1'; Seed = 1; Scenarios = @('crossmod.trade-with-autoequip.done'); HardTimeoutMinutes = 5; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r2'; Seed = 1; Scenarios = @('crossmod.trade-with-autoequip.cancel'); HardTimeoutMinutes = 5; ExpectedExitClass = 'Completed' }
        )
    }
    # AC25a comparison (S10, F-S10-4/7): only CoherentWarAI, 30 days. Seeds 1-3, per seed WarSails, FeatureOff, FeatureOff,
    # WarSails (the order evens out drift); every run records the army digest (coherentwarai.ac25a-digest).
    CW1 = @{
        Harness           = 'TestRig'
        Mode              = 'WarSails'
        Seed              = 1
        Days              = 30
        Kind              = 'scenarios'
        WithCoherentWarAI = $true
        ExtraModules      = @()
        TailModules       = @('CoherentWarAI.Scenarios')
        # CW-2 per run (F-S10-6) and CW-1 over the whole job (F-S10-3).
        PostRunChecks     = @($script:RigCommandLogCheck)
        JobChecks         = @(@{ Id = 'coherentwarai.ac25a'; Script = 'BannerlordCoherentWarAI\tools\Compare-Ac25a.ps1'; ResultFile = 'ac25a-compare.json'; UsesJobManifest = $true })
        Runs              = @(
            @{ RunId = 'r1'; Seed = 1; Mode = 'WarSails'; Scenarios = @('coherentwarai.ac25a-digest'); HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r2'; Seed = 1; Mode = 'FeatureOff'; Scenarios = @('coherentwarai.ac25a-digest'); HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r3'; Seed = 1; Mode = 'FeatureOff'; Scenarios = @('coherentwarai.ac25a-digest'); HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r4'; Seed = 1; Mode = 'WarSails'; Scenarios = @('coherentwarai.ac25a-digest'); HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r5'; Seed = 2; Mode = 'WarSails'; Scenarios = @('coherentwarai.ac25a-digest'); HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r6'; Seed = 2; Mode = 'FeatureOff'; Scenarios = @('coherentwarai.ac25a-digest'); HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r7'; Seed = 2; Mode = 'FeatureOff'; Scenarios = @('coherentwarai.ac25a-digest'); HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r8'; Seed = 2; Mode = 'WarSails'; Scenarios = @('coherentwarai.ac25a-digest'); HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r9'; Seed = 3; Mode = 'WarSails'; Scenarios = @('coherentwarai.ac25a-digest'); HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r10'; Seed = 3; Mode = 'FeatureOff'; Scenarios = @('coherentwarai.ac25a-digest'); HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r11'; Seed = 3; Mode = 'FeatureOff'; Scenarios = @('coherentwarai.ac25a-digest'); HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' },
            @{ RunId = 'r12'; Seed = 3; Mode = 'WarSails'; Scenarios = @('coherentwarai.ac25a-digest'); HardTimeoutMinutes = 10; ExpectedExitClass = 'Completed' }
        )
    }
    RIG = @{
        Harness           = 'TestRig'
        Mode              = 'WarSails'
        Seed              = 1
        Days              = 1
        Kind              = 'scenarios'
        WithCoherentWarAI = $false
        ExtraModules      = @()
        TailModules       = @('TestRig.SelfTest')
        Runs              = @(
            # The crash must come from the self-test throw: the harness's UnhandledException line, or (the throw escapes
            # to native, measured 2026-11-02) the watchdog crash with the FirstChance line of the throw as last line. The
            # exception with its full type name, so a harness line that merely names the scenario does not count.
            @{ RunId = 'r1'; Scenarios = @('rig.selftest-throw'); HardTimeoutMinutes = 5; ExpectedExitClass = 'Crashed'
                ExpectedMessagePattern = '^(Harness reported: |Crash occurred \(watchdog_log_\d+\.txt\); last line: ).*System\.InvalidOperationException: rig\.selftest-throw' },
            # Hung by the silence watch, not by another cause.
            @{ RunId = 'r2'; Scenarios = @('rig.selftest-hang'); HardTimeoutMinutes = 5; ExpectedExitClass = 'Hung'
                ExpectedMessagePattern = '^No Alive line in harness\.log for \d+ s' },
            @{ RunId = 'r3'; Scenarios = @('rig.selftest-pass'); HardTimeoutMinutes = 5; ExpectedExitClass = 'Completed' },
            # R2 (#22): 10,000 caught exceptions from the self-test module, which only this run lists as own; the walk
            # budget (1000) is spent, so the rest is answered from the cache and own is no longer exact.
            @{ RunId = 'r4'; Scenarios = @('rig.selftest-exception-storm'); HardTimeoutMinutes = 5; ExpectedExitClass = 'Completed'
                OwnAssemblies = @('TestRig.SelfTest'); ClassificationTiming = $true
                ExpectedValues = @(
                    @{ Path = 'exceptions.own'; Value = 10000 },
                    @{ Path = 'exceptions.classification.walks'; Value = 1000 },
                    @{ Path = 'exceptions.classification.ownExact'; Value = $false })
            },
            # Spike R1 / fixture regression (S8): enter a foreign town, open and close the trade screen, leave; no mod involved.
            @{ RunId = 'r5'; Scenarios = @('rig.town-screen'); HardTimeoutMinutes = 5; ExpectedExitClass = 'Completed' }
        )
    }
}
$script:DefaultMsBuildPath = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\MSBuild\Current\Bin\MSBuild.exe'
# L1 verdict (#21): the vanilla baseline the runner judges -Suite L1 runs against (written by Update-L1Baseline.ps1),
# and the threshold rules (F-S6-7): vanilla exceptions <= 1.5 x max of the base runs + 20, running-phase tempo
# >= 0.7 x median of the base runs.
$script:RigL1BaselinePath = Join-Path $PSScriptRoot 'baselines\L1.json'
$script:RigL1VanillaFactor = 1.5
$script:RigL1VanillaSlack = 20
$script:RigL1TempoFactor = 0.7
# R2 start values [A] (#22, RIG r4): mean handler time of a walked exception and upper bound of a cache hit; above them
# the runner only warns.
$script:RigR2WalkMeanMaxMs = 1
$script:RigR2CacheHitMaxUs = 50

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

function Get-RigModules {
    param(
        [Parameter(Mandatory)][ValidateSet('WarSails', 'NoDlc', 'FeatureOff')][string]$Mode,
        [ValidateSet('TestRig')][string]$Harness = 'TestRig',
        [ValidateScript({ -not $_ -or $script:RigSuites.ContainsKey($_) })][string]$Suite
    )
    $modules = @('Bannerlord.Harmony', 'Bannerlord.ButterLib', 'Bannerlord.UIExtenderEx', 'Bannerlord.MBOptionScreen', 'Native', 'SandBoxCore', 'Sandbox', 'StoryMode')
    if ($Mode -ne 'NoDlc') { $modules += 'NavalDLC' }
    if (-not $Suite) { return ($modules + @('CoherentWarAI') + @($script:RigHarnessModules[$Harness])) }
    $s = $script:RigSuites[$Suite]
    $core = if ($s.WithCoherentWarAI) { @('CoherentWarAI') } else { @() }
    $modules + $core + @($s.ExtraModules) + @($script:RigHarnessModules[$Harness]) + @($s.TailModules)
}

# Run kind of a suite ('soak' without a suite).
function Get-RigSuiteKind {
    param([string]$Suite)
    if ($Suite) { $script:RigSuites[$Suite].Kind } else { 'soak' }
}

# Health scenario ids of a suite (none without a suite or without Health). Callers wrap the result in @().
function Get-RigSuiteHealth {
    param([string]$Suite)
    if ($Suite -and $script:RigSuites[$Suite].ContainsKey('Health')) { $script:RigSuites[$Suite].Health }
}

# The result lines a run with health ids must report, in the harness order (F-S6-1): <id>@0 per id, then <id>@<Days>
# per id (the soak line between them is judged by the soak rules). None without health ids.
function Get-RigHealthLineIds {
    param([string[]]$Health = @(), [Parameter(Mandatory)][int]$Days)
    foreach ($h in $Health) { "$h@0" }
    foreach ($h in $Health) { "$h@$Days" }
}

# Structural verdict of the health lines of a Completed soak run: 'Met' when every expected line (Get-RigHealthLineIds,
# from $Run.requestedHealth and $Days) is reported Passed, or the run has no health ids; 'RigError' when one is missing or
# reported with any status other than Passed or Failed (Skipped, Timeout, Error, unknown: that health check did not
# run to a verdict); else 'Mismatch' (one is Failed). Ids compare case-sensitively, statuses case-insensitively (as in
# Resolve-RigExitCode); a line reported twice counts by its first report. The verdict on the run's measurements is Get-RigL1Verdict, next to this structural one.
function Get-RigHealthOutcome {
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][int]$Days)
    $health = @(if ($null -ne $Run.requestedHealth) { $Run.requestedHealth })
    $ids = @(if ($null -ne $Run.scenarioIds) { $Run.scenarioIds })
    $statuses = @(if ($null -ne $Run.scenarioStatuses) { $Run.scenarioStatuses })
    $failed = $false
    foreach ($wanted in @(Get-RigHealthLineIds -Health $health -Days $Days)) {
        $status = $null
        for ($i = 0; $i -lt $ids.Count; $i++) {
            if ($ids[$i] -ceq $wanted) { $status = $statuses[$i]; break }
        }
        if ($status -is [string] -and $status -eq 'Passed') { continue }
        if ($status -is [string] -and $status -eq 'Failed') { $failed = $true; continue }
        return 'RigError'
    }
    if ($failed) { 'Mismatch' } else { 'Met' }
}

# The runs a suite defines (RunId, Scenarios (empty for a soak run), HardTimeoutMinutes, ExpectedExitClass,
# ExpectedMessagePattern, Seed and Mode = $null when the run has none, OwnAssemblies and ExpectedValues (empty when none),
# ClassificationTiming); none for suites without Runs. $Days = the job's days (0 = the suite's Days): a soak run's
# hard timeout holds for the suite's Days and grows in proportion to a longer -Days, rounded up (L1-BASE: max(10,
# ceil(10 x days / 30)) minutes); a shorter -Days keeps it. Callers wrap the result in @().
function Get-RigSuiteRuns {
    param([string]$Suite, [int]$Days)
    if (-not $Suite -or -not $script:RigSuites[$Suite].ContainsKey('Runs')) { return }
    $s = $script:RigSuites[$Suite]
    foreach ($r in $s.Runs) {
        $hardTimeout = [int]$r.HardTimeoutMinutes
        if ($s.Kind -eq 'soak' -and $Days -gt $s.Days) { $hardTimeout = [int][math]::Ceiling($hardTimeout * $Days / $s.Days) }
        [pscustomobject]@{
            RunId = [string]$r.RunId; Scenarios = @(if ($r.ContainsKey('Scenarios')) { $r.Scenarios })
            HardTimeoutMinutes = $hardTimeout; ExpectedExitClass = [string]$r.ExpectedExitClass
            ExpectedMessagePattern = if ($r.ContainsKey('ExpectedMessagePattern')) { [string]$r.ExpectedMessagePattern } else { $null }
            Seed = if ($r.ContainsKey('Seed')) { [int]$r.Seed } else { $null }
            Mode = if ($r.ContainsKey('Mode')) { [string]$r.Mode } else { $null }
            OwnAssemblies = @(if ($r.ContainsKey('OwnAssemblies')) { $r.OwnAssemblies })
            ExpectedValues = @(if ($r.ContainsKey('ExpectedValues')) { $r.ExpectedValues })
            ClassificationTiming = $r.ContainsKey('ClassificationTiming') -and [bool]$r.ClassificationTiming
        }
    }
}

# Overall runner deadline of a suite with Runs, in minutes; $null without Runs. Formula: per run its hard timeout
# (for $Days, see Get-RigSuiteRuns) + 2 min (baseline restore, kill, stray sweep, artifact copy), plus the claim wait
# (rounded up to whole minutes; install/preflight happen after the claim) plus 5 min slack. Never below the sum of
# hard timeouts + 10 (the default of a single-run job: HardTimeoutMinutes + 10).
function Get-RigSuiteTimeoutMinutes {
    param([string]$Suite, [double]$ClaimTimeoutSeconds = 120, [int]$Days)
    $suiteRuns = @(Get-RigSuiteRuns -Suite $Suite -Days $Days)
    if ($suiteRuns.Count -eq 0) { return $null }
    $hardSum = 0
    foreach ($r in $suiteRuns) { $hardSum += $r.HardTimeoutMinutes }
    $claimMinutes = [int][math]::Ceiling($ClaimTimeoutSeconds / 60)
    $formula = $hardSum + (2 * $suiteRuns.Count) + $claimMinutes + 5
    [math]::Max($formula, $hardSum + 10)
}

# Applies -Suite to the parameter values. $BoundParameters = names of the parameters given explicitly
# (keys of $PSBoundParameters). Harness is the suite's (TestRig, the only one). Mode and
# Seed keep an explicit value; Days defaults to the suite's value only when not given. A suite whose runs fix
# their hard timeout or seed rejects an explicit -HardTimeoutMinutes or -Seed. Without a suite the
# values are returned unchanged.
function Resolve-RigSuiteSettings {
    param(
        [string]$Suite,
        [string[]]$BoundParameters = @(),
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][int]$Seed,
        [Parameter(Mandatory)][int]$Days
    )
    if ($Suite) {
        $s = $script:RigSuites[$Suite]
        if ($BoundParameters -contains 'HardTimeoutMinutes' -and @(Get-RigSuiteRuns -Suite $Suite).Count -gt 0) {
            throw "-Suite $Suite fixes the hard timeout of each run; -HardTimeoutMinutes conflicts with it (omit -HardTimeoutMinutes)."
        }
        if ($BoundParameters -contains 'Seed' -and @(Get-RigSuiteRuns -Suite $Suite | Where-Object { $null -ne $_.Seed }).Count -gt 0) {
            throw "-Suite $Suite fixes the seed of each run; -Seed conflicts with it (omit -Seed)."
        }
        $runModes = @(Get-RigSuiteRuns -Suite $Suite | Where-Object { $null -ne $_.Mode } | ForEach-Object { $_.Mode } | Select-Object -Unique)
        if ($BoundParameters -contains 'Mode' -and $runModes.Count -gt 0) {
            throw "-Suite $Suite fixes the mode of each run; -Mode conflicts with it (omit -Mode)."
        }
        $Harness = $s.Harness
        if ($BoundParameters -notcontains 'Mode') { $Mode = $s.Mode }
        if ($BoundParameters -notcontains 'Seed') { $Seed = $s.Seed }
        if ($BoundParameters -notcontains 'Days') { $Days = $s.Days }
        # One job has one module list: the run modes must load the same modules as the job's mode.
        $jobModules = @(Get-RigModules -Mode $Mode -Harness $Harness -Suite $Suite) -join ','
        foreach ($runMode in $runModes) {
            if ((@(Get-RigModules -Mode $runMode -Harness $Harness -Suite $Suite) -join ',') -ne $jobModules) {
                throw "-Suite $Suite has a run in mode $runMode, which loads other modules than the job's mode $Mode; one job has one module list."
            }
        }
    }
    [pscustomobject]@{ Harness = (Get-RigHarnessName $Harness); Mode = $Mode; Seed = $Seed; Days = $Days }
}

function Get-RigSuiteName {
    # The canonical spelling of a suite id (the key in $script:RigSuites); $null for an unknown suite.
    param([Parameter(Mandatory)][string]$Suite)
    @($script:RigSuites.Keys | Where-Object { $_ -ieq $Suite })[0]
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
        [ValidateSet('TestRig')][string]$Harness = 'TestRig',
        [string]$Suite,
        [AllowNull()][AllowEmptyString()][string]$ExpectedGameVersion   # tower game version; $null/empty = not checked
    )
    $kind = Get-RigSuiteKind -Suite $Suite
    $health = @(Get-RigSuiteHealth -Suite $Suite)
    $newRun = {
        # $RunSeed: $null = the job's -Seed; $RunOwnAssemblies: empty = no ownAssemblies field (the agent derives the list)
        # $RunMode: $null = the job's -Mode
        param([string]$RunId, [int]$RunHardTimeoutMinutes, $RunScenarios, $RunSeed, $RunOwnAssemblies, $RunMode)
        $run = [ordered]@{
            runId              = $RunId
            kind               = $kind
            harness            = $Harness
            seed               = if ($null -ne $RunSeed) { [int]$RunSeed } else { $Seed }
            days               = $Days
            mode               = if ($RunMode) { $RunMode } else { $Mode }
            stallMinutes       = $StallMinutes
            budgetMinutes      = $BudgetMinutes
            hardTimeoutMinutes = $RunHardTimeoutMinutes
        }
        if ($kind -eq 'scenarios') { $run.scenarios = @($RunScenarios) }
        if ($kind -eq 'soak' -and $health.Count -gt 0) { $run.health = $health }   # a JSON array, also with one id
        if ($null -ne $RunOwnAssemblies -and @($RunOwnAssemblies).Count -gt 0) { $run.ownAssemblies = @($RunOwnAssemblies) }   # a JSON array, also with one name
        $run
    }
    $suiteRuns = @(Get-RigSuiteRuns -Suite $Suite -Days $Days)
    # Outer @(): a one-run list must stay a JSON array (an assignment from `if` unrolls a single element).
    $runs = @(if ($suiteRuns.Count -gt 0) {
            $suiteRuns | ForEach-Object { & $newRun $_.RunId $_.HardTimeoutMinutes $_.Scenarios $_.Seed $_.OwnAssemblies $_.Mode }
        } else {
            & $newRun 'r1' $HardTimeoutMinutes $(if ($kind -eq 'scenarios') { $script:RigSuites[$Suite].Scenarios })
        })
    [ordered]@{
        schema              = 1
        jobId               = $JobId
        createdUtc          = $CreatedUtc.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        expectedGameVersion = if ([string]::IsNullOrWhiteSpace($ExpectedGameVersion)) { $null } else { $ExpectedGameVersion }
        package             = [ordered]@{ file = 'package.zip'; sha256 = $PackageSha256 }
        repos               = @($Repos)
        modules             = @(Get-RigModules -Mode $Mode -Harness $Harness -Suite $Suite)
        runs                = $runs
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

# Reads the harness result of one run folder from run-result.json. A missing, invalid or unreadable run-result.json
# = no result (the empty info below).
# Returns Status, DaysReached, Scenarios (@{ Id; Status } per scenario), FailedChecks (@{ Name; Expected;
# Actual; Scenario } per check with passed=false) and Result (for job-result.json).
function Read-RigRunResult {
    param([Parameter(Mandatory)][string]$RunDir)
    $info = [ordered]@{ Status = $null; DaysReached = $null; Scenarios = @(); FailedChecks = @(); Result = [ordered]@{} }
    $jsonFile = Join-Path $RunDir 'run-result.json'
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
        $info.FailedChecks = @($json.checks | Where-Object { $null -ne $_ -and $_.passed -eq $false } | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_.name; Expected = [string]$_.expected; Actual = [string]$_.actual; Scenario = [string]$_.scenario }
            })
        return $info
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

# True when a finished scenario run reported every requested scenario id (case-sensitive) and none is Skipped.
# Run: scenarioIds / scenarioStatuses (parallel, as reported) and requestedScenarios (from the suite).
function Test-RigScenariosChecked {
    param([Parameter(Mandatory)]$Run)
    $ids = @(if ($null -ne $Run.scenarioIds) { $Run.scenarioIds })
    $statuses = @(if ($null -ne $Run.scenarioStatuses) { $Run.scenarioStatuses })
    if ($ids.Count -eq 0) { return $false }
    foreach ($wanted in @(if ($null -ne $Run.requestedScenarios) { $Run.requestedScenarios })) {
        $found = $false
        for ($i = 0; $i -lt $ids.Count; $i++) {
            if ($ids[$i] -ceq $wanted -and $statuses[$i] -ne 'Skipped') { $found = $true; break }
        }
        if (-not $found) { return $false }
    }
    $true
}

# Judges one run of a suite with expectations. Expectation: RunId, Scenarios, ExpectedExitClass, optional
# ExpectedMessagePattern. $Run = the run as collected from done.json and agent-run.json (runId, exitClass, message,
# scenarioIds/scenarioStatuses), $null when done.json has no such run.
# Returns 'Met', 'Mismatch' (a test failure), 'Inconclusive' (a soak run expected Completed ended HardTimeout, Hung or
# Aborted: a time limit or hang, exit 3 as without a suite; an Error or unknown result row there is still RigError), 'RigError' (the run failed in the rig itself: SetupError,
# LaunchFailed, CleanupFailed that was not expected) or 'Missing'. With an ExpectedMessagePattern the run's message must
# match it (case-sensitive; a missing message does not). An expected Completed also needs every scenario of the
# expectation to be reported Passed, every ExpectedValues check Passed (Get-RigExpectedValueChecks: Failed = Mismatch,
# Error = RigError) and, for a run that is not of kind 'scenarios' (a soak), daysReached >= $Days, no soak result row
# Failed (Mismatch) or Error/unknown (RigError) and its health lines judged by Get-RigHealthOutcome. Every rule is
# checked, so a RigError found after a Mismatch still wins. Other expected classes (Crashed, Hung) have no scenario
# results by design.
function Get-RigExpectationOutcome {
    param(
        [Parameter(Mandatory)]$Expectation,
        $Run,
        [Parameter(Mandatory)][int]$Days   # the days the job asked for (judged for soak runs only)
    )
    if ($null -eq $Run) { return 'Missing' }
    $actual = [string]$Run.exitClass
    if ($actual -cne $Expectation.ExpectedExitClass) {
        if ($actual -in 'SetupError', 'LaunchFailed', 'CleanupFailed') { return 'RigError' }
        if ($Run.kind -ne 'scenarios' -and $Expectation.ExpectedExitClass -ceq 'Completed' -and $actual -in 'HardTimeout', 'Hung', 'Aborted') {
            # As without a suite (Resolve-RigExitCode): an Error or unknown result row is a rig error in every exit class.
            foreach ($rowStatus in @(if ($null -ne $Run.scenarioStatuses) { $Run.scenarioStatuses })) {
                if ($rowStatus -isnot [string] -or $rowStatus -notin 'Passed', 'Timeout', 'Skipped', 'Failed') { return 'RigError' }
            }
            return 'Inconclusive'
        }
        return 'Mismatch'
    }
    $mismatch = -not (Test-RigExpectedMessage -Expectation $Expectation -Run $Run)
    if ($actual -ne 'Completed') { return $(if ($mismatch) { 'Mismatch' } else { 'Met' }) }
    if ($Run.kind -ne 'scenarios') {
        if ($null -eq $Run.daysReached -or [int]$Run.daysReached -lt $Days) { $mismatch = $true }
        # The soak's own result row(s): every reported status is judged, like the per-run rules of Resolve-RigExitCode.
        foreach ($soakStatus in @(if ($null -ne $Run.scenarioStatuses) { $Run.scenarioStatuses })) {
            if ($soakStatus -isnot [string] -or $soakStatus -notin 'Passed', 'Timeout', 'Skipped', 'Failed') { return 'RigError' }
            if ($soakStatus -eq 'Failed') { $mismatch = $true }
        }
        switch (Get-RigHealthOutcome -Run $Run -Days $Days) {
            'RigError' { return 'RigError' }
            'Mismatch' { $mismatch = $true }
        }
    }
    $ids = @(if ($null -ne $Run.scenarioIds) { $Run.scenarioIds })
    $statuses = @(if ($null -ne $Run.scenarioStatuses) { $Run.scenarioStatuses })
    foreach ($wanted in @($Expectation.Scenarios)) {
        $passed = $false
        for ($i = 0; $i -lt $ids.Count; $i++) {
            if ($ids[$i] -ceq $wanted -and $statuses[$i] -ceq 'Passed') { $passed = $true; break }
        }
        if (-not $passed) { $mismatch = $true }
    }
    foreach ($check in @(Get-RigExpectedValueChecks -Expectation $Expectation -Result $Run.result)) {
        if ($check.Status -eq 'Error') { return 'RigError' }
        if ($check.Status -eq 'Failed') { $mismatch = $true }
    }
    if ($mismatch) { 'Mismatch' } else { 'Met' }
}

# The value at a dotted property path (e.g. 'exceptions.classification.walks') of a parsed run-result.json; $null when a
# step is missing or not a JSON object (no result has none).
function Get-RigResultValue {
    param($Result, [Parameter(Mandatory)][string]$Path)
    $value = $Result
    foreach ($name in $Path.Split('.')) {
        if ($value -isnot [System.Management.Automation.PSCustomObject] -or $value.PSObject.Properties.Name -cnotcontains $name) { return $null }
        $value = $value.$name
    }
    $value
}

# A value check operand as JSON writes it: true/false, the number (invariant culture), 'null' or 'invalid'.
function Format-RigCheckValue {
    param($Value)
    if ($Value -is [bool]) { if ($Value) { 'true' } else { 'false' } } else { Format-RigMeasuredValue $Value }
}

# The ExpectedValues checks of an expectation against $Result (the parsed run-result.json), in their order:
# Name (the path), Expected and Actual (Format-RigCheckValue) and Status: 'Passed' (equal), 'Failed' (another value of
# the same kind) or 'Error' (missing, or not of the expected kind: a number for a number, a boolean for a boolean: the
# harness did not measure it). None for an expectation without ExpectedValues. Callers wrap the result in @().
function Get-RigExpectedValueChecks {
    param([Parameter(Mandatory)]$Expectation, $Result)
    foreach ($v in @($Expectation.ExpectedValues | Where-Object { $null -ne $_ })) {
        $value = Get-RigResultValue -Result $Result -Path $v.Path
        $status = if ($v.Value -is [bool]) {
            if ($value -isnot [bool]) { 'Error' } elseif ($value -eq $v.Value) { 'Passed' } else { 'Failed' }
        } elseif (-not (Test-RigNumber $value)) { 'Error' } elseif ([double]$value -eq [double]$v.Value) { 'Passed' } else { 'Failed' }
        [pscustomobject]@{ Name = $v.Path; Expected = (Format-RigCheckValue $v.Value); Actual = (Format-RigCheckValue $value); Status = $status }
    }
}

# R2 timing (#22) of a run's exceptions.classification, console lines: the walk mean walkMs / walks (ms) and the
# cache-hit upper bound (handlerMs - walkMs) / (total - walks) (us; the mean of every exception without a walk, see
# docs/JOB-PROTOCOL.md), always printed; a WARN line each when above the R2 start values ($script:RigR2WalkMeanMaxMs,
# $script:RigR2CacheHitMaxUs; never changes the exit code). 'n/a' for a mean without exceptions to divide by;
# 'not measured' when a value is missing.
function Format-RigClassificationTiming {
    param([Parameter(Mandatory)][string]$RunId, $Result)
    $total = Get-RigResultValue -Result $Result -Path 'exceptions.total'
    $walks = Get-RigResultValue -Result $Result -Path 'exceptions.classification.walks'
    $walkMs = Get-RigResultValue -Result $Result -Path 'exceptions.classification.walkMs'
    $handlerMs = Get-RigResultValue -Result $Result -Path 'exceptions.classification.handlerMs'
    if (-not ((Test-RigNumber $total) -and (Test-RigNumber $walks) -and (Test-RigNumber $walkMs) -and (Test-RigNumber $handlerMs))) {
        '    R2 timing: not measured (exceptions.classification incomplete)'
        return
    }
    $others = [double]$total - [double]$walks
    $walkMean = if ([double]$walks -gt 0) { [double]$walkMs / [double]$walks } else { $null }
    # Clamped at 0: handlerMs and walkMs are rounded separately, so their difference can come out slightly negative.
    $hitUs = if ($others -gt 0) { [math]::Max(0.0, [double]$handlerMs - [double]$walkMs) / $others * 1000 } else { $null }
    $walkText = if ($null -ne $walkMean) { '{0} ms' -f (Format-RigNumber $walkMean '0.000') } else { 'n/a' }
    $hitText = if ($null -ne $hitUs) { '{0} us' -f (Format-RigNumber $hitUs '0.0') } else { 'n/a' }
    '    R2 timing: walk mean {0} ({1} walks); cache hit at most {2} (mean of {3} other exceptions)' -f $walkText,
        (Format-RigNumber $walks), $hitText, (Format-RigNumber $others)
    if ($null -ne $walkMean -and $walkMean -gt $script:RigR2WalkMeanMaxMs) {
        'WARN {0} R2 walk mean {1} > {2} ms (start value, warning only)' -f $RunId, $walkText, (Format-RigNumber $script:RigR2WalkMeanMaxMs)
    }
    if ($null -ne $hitUs -and $hitUs -gt $script:RigR2CacheHitMaxUs) {
        'WARN {0} R2 cache hit at most {1} > {2} us (start value, warning only)' -f $RunId, $hitText, (Format-RigNumber $script:RigR2CacheHitMaxUs)
    }
}

# True if the run's message matches the expectation's ExpectedMessagePattern, or the expectation has none.
function Test-RigExpectedMessage {
    param([Parameter(Mandatory)]$Expectation, [Parameter(Mandatory)]$Run)
    $pattern = [string]$Expectation.ExpectedMessagePattern
    if ($pattern -eq '') { return $true }
    $message = $Run.message
    return ($message -is [string] -and $message -cmatch $pattern)
}

# True for a JSON number as ConvertFrom-Json returns it (Int32, Int64, Decimal, Double); $null, strings and booleans are not.
function Test-RigNumber {
    param($Value)
    $Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double]
}

# A number in invariant culture (a German host would print 0,70).
function Format-RigNumber {
    param([Parameter(Mandatory)][double]$Value, [string]$Format = '0.##')
    $Value.ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
}

# A measured value for a verdict row: the number, 'null' for $null (or a missing field), else 'invalid'.
function Format-RigMeasuredValue {
    param($Value, [string]$Format = '0.##')
    if (Test-RigNumber $Value) { Format-RigNumber $Value $Format } elseif ($null -eq $Value) { 'null' } else { 'invalid' }
}

# Thresholds from the base runs (F-S6-7): tempo median (odd count: the middle value, even count: the mean of the two
# middle values), min, max, spread = (max - min) / median, TempoThreshold = 0.7 x median; VanillaMax and
# VanillaThreshold = 1.5 x VanillaMax + 20. Both lists must be non-empty and the tempos positive.
function Get-RigL1Thresholds {
    param([Parameter(Mandatory)][double[]]$Tempos, [Parameter(Mandatory)][double[]]$Vanillas)
    $sorted = @($Tempos | Sort-Object)
    $mid = [int][math]::Floor($sorted.Count / 2)
    $median = if ($sorted.Count % 2 -eq 1) { $sorted[$mid] } else { ($sorted[$mid - 1] + $sorted[$mid]) / 2 }
    $vanillaMax = [double]($Vanillas | Measure-Object -Maximum).Maximum
    [pscustomobject]@{
        TempoMedian      = [double]$median
        TempoMin         = [double]$sorted[0]
        TempoMax         = [double]$sorted[-1]
        TempoSpread      = ($sorted[-1] - $sorted[0]) / $median
        TempoThreshold   = $script:RigL1TempoFactor * $median
        VanillaMax       = $vanillaMax
        VanillaThreshold = $script:RigL1VanillaFactor * $vanillaMax + $script:RigL1VanillaSlack
    }
}

# Reads the L1 baseline (runner/baselines/L1.json, format: docs/JOB-PROTOCOL.md "L1 verdict"). Status 'Ok' (GameVersion,
# BaseRunCount, Thresholds from the base runs, JobIds of all runs in the file), 'Missing' (no file, or no base runs: the
# committed placeholder) or 'Invalid' (unreadable, no gameVersion, a base run without a positive tempo or a vanilla
# count >= 0); Reason says why when not 'Ok'. The thresholds are always recomputed from baseRuns: 'derived' in the file
# is for readers only.
function Read-RigL1Baseline {
    param([Parameter(Mandatory)][string]$Path)
    $b = [ordered]@{ Status = 'Missing'; Reason = $null; Path = $Path; GameVersion = $null; BaseRunCount = 0; Thresholds = $null; JobIds = @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $b.Reason = "baseline missing: $Path not found"
        return [pscustomobject]$b
    }
    try {
        $doc = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false, $true))) | ConvertFrom-Json
        if ($doc -isnot [System.Management.Automation.PSCustomObject]) { throw 'not a JSON object' }
        $baseRuns = @($doc.baseRuns | Where-Object { $null -ne $_ })
        if ($baseRuns.Count -eq 0) {
            $b.Reason = "baseline missing: no base runs in $Path"
            return [pscustomobject]$b
        }
        if ($doc.gameVersion -isnot [string] -or $doc.gameVersion -eq '') { throw 'no gameVersion' }
        $tempos = New-Object System.Collections.Generic.List[double]
        $vanillas = New-Object System.Collections.Generic.List[double]
        foreach ($run in $baseRuns) {
            $label = '{0}/{1}' -f $run.jobId, $run.runId
            $tempo = $run.runningDaysPerRealMinute
            $vanilla = if ($null -ne $run.exceptions) { $run.exceptions.vanilla } else { $null }
            if (-not (Test-RigNumber $tempo) -or [double]$tempo -le 0) { throw "base run ${label}: runningDaysPerRealMinute is not a positive number" }
            if (-not (Test-RigNumber $vanilla) -or [double]$vanilla -lt 0) { throw "base run ${label}: exceptions.vanilla is not a number >= 0" }
            $tempos.Add([double]$tempo)
            $vanillas.Add([double]$vanilla)
        }
    } catch {
        $b.Status = 'Invalid'
        $b.Reason = "baseline invalid: ${Path}: $($_.Exception.Message)"
        return [pscustomobject]$b
    }
    $b.Status = 'Ok'
    $b.GameVersion = $doc.gameVersion
    $b.BaseRunCount = $baseRuns.Count
    $b.Thresholds = Get-RigL1Thresholds -Tempos $tempos.ToArray() -Vanillas $vanillas.ToArray()
    $b.JobIds = @(@($baseRuns) + @($doc.l1Runs | Where-Object { $null -ne $_ }) | ForEach-Object { [string]$_.jobId } | Select-Object -Unique)
    [pscustomobject]$b
}

# One row of the L1 verdict. status: Passed | Failed | Warn (never fails) | NotJudged | Error (rig error).
function New-RigL1Check {
    param([string]$Name, [string]$Status, [string]$Expected, [string]$Actual)
    [pscustomobject]@{ name = $Name; status = $Status; expected = $Expected; actual = $Actual }
}

# L1 verdict on the measurements of one Completed L1 run (#21; F-S6-2, F-S6-7). $Result = the parsed run-result.json,
# $ExpectedModules = job.modules ($null = unknown), $GameVersion = the run's game version (agent-run.json), $Baseline =
# Read-RigL1Baseline. Checks, in this order: own = 0, unhandled = 0, vanilla <= baseline threshold, tempo
# (runningDaysPerRealMinute) / baseline median >= 0.7, modules[].id = job.modules (same ids, same order, case-sensitive),
# playerMapEvents > 0 (Warn only), exceptions.classification.ownExact = true (Warn only when false; NotJudged with a
# WARN when missing or not a boolean). A missing own, unhandled or modules value is a rig error (the harness did not
# measure). Vanilla and tempo are NotJudged (with a WARN line) when the baseline is missing or invalid or its game
# version differs from the run's (or the run has none); a null tempo is NotJudged with a WARN line too.
# Returns Outcome ('RigError' if a check is Error, else 'Failed' if one is Failed, else 'Met'), Checks and Warnings.
function Get-RigL1Verdict {
    param(
        [Parameter(Mandatory)][string]$RunId,
        $Result,
        [AllowNull()][string[]]$ExpectedModules,
        $GameVersion,
        [Parameter(Mandatory)]$Baseline
    )
    $checks = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]
    $exceptions = if ($null -ne $Result) { $Result.exceptions } else { $null }
    if ($exceptions -isnot [System.Management.Automation.PSCustomObject]) { $exceptions = $null }
    foreach ($counter in 'own', 'unhandled') {
        $value = if ($null -ne $exceptions) { $exceptions.$counter } else { $null }
        $status = if (-not (Test-RigNumber $value)) { 'Error' } elseif ([double]$value -eq 0) { 'Passed' } else { 'Failed' }
        $checks.Add((New-RigL1Check $counter $status '0' (Format-RigMeasuredValue $value)))
    }

    # Why vanilla and tempo cannot be judged ($null = they can).
    $notJudged = $null
    if ($Baseline.Status -ne 'Ok') { $notJudged = $Baseline.Reason }
    elseif ($GameVersion -isnot [string] -or $GameVersion -eq '') { $notJudged = "the run reported no game version (baseline: $($Baseline.GameVersion))" }
    elseif ($GameVersion -cne $Baseline.GameVersion) { $notJudged = "baseline is for game $($Baseline.GameVersion), the run ran $(Format-RigCheckField $GameVersion 40)" }
    if ($null -ne $notJudged) { $warnings.Add("WARN L1 $RunId vanilla and tempo not judged: $notJudged") }
    $t = $Baseline.Thresholds

    $vanilla = if ($null -ne $exceptions) { $exceptions.vanilla } else { $null }
    if ($null -ne $notJudged) {
        $checks.Add((New-RigL1Check 'vanilla' 'NotJudged' '-' (Format-RigMeasuredValue $vanilla)))
    } else {
        $expected = '<= {0} ({1} x baseline max {2} + {3})' -f (Format-RigNumber $t.VanillaThreshold), (Format-RigNumber $script:RigL1VanillaFactor),
            (Format-RigNumber $t.VanillaMax), (Format-RigNumber $script:RigL1VanillaSlack)
        $status = if (-not (Test-RigNumber $vanilla)) { 'Error' } elseif ([double]$vanilla -le $t.VanillaThreshold) { 'Passed' } else { 'Failed' }
        $checks.Add((New-RigL1Check 'vanilla' $status $expected (Format-RigMeasuredValue $vanilla)))
    }

    $tempo = if ($null -ne $Result) { $Result.runningDaysPerRealMinute } else { $null }
    if ($null -ne $notJudged) {
        $checks.Add((New-RigL1Check 'tempo' 'NotJudged' '-' (Format-RigMeasuredValue $tempo '0.00')))
    } elseif (-not (Test-RigNumber $tempo)) {
        $checks.Add((New-RigL1Check 'tempo' 'NotJudged' '-' (Format-RigMeasuredValue $tempo '0.00')))
        $warnings.Add("WARN L1 $RunId tempo not judged: runningDaysPerRealMinute is $(Format-RigMeasuredValue $tempo)")
    } else {
        # The ratio, not tempo >= 0.7 x median: 0.7 * 10 is 7.000000000000001 in binary floating point, 7 / 10 is 0.7.
        $ratio = [double]$tempo / $t.TempoMedian
        $factor = Format-RigNumber $script:RigL1TempoFactor
        $expected = 'ratio >= {0} ({0} x baseline median {1} = {2} days/min)' -f $factor, (Format-RigNumber $t.TempoMedian '0.00'), (Format-RigNumber $t.TempoThreshold '0.00')
        $actual = '{0} days/min, ratio {1}' -f (Format-RigNumber $tempo '0.00'), (Format-RigNumber $ratio '0.000')
        $status = if ($ratio -ge $script:RigL1TempoFactor) { 'Passed' } else { 'Failed' }
        $checks.Add((New-RigL1Check 'tempo' $status $expected $actual))
    }

    $reported = $null
    if ($null -ne $Result -and $null -ne $Result.modules) {
        $reported = @($Result.modules | ForEach-Object { if ($_ -is [System.Management.Automation.PSCustomObject] -and $_.id -is [string]) { $_.id } else { '' } })
    }
    if ($null -eq $ExpectedModules) {
        $checks.Add((New-RigL1Check 'modules' 'Error' 'job.modules' 'job.modules unknown to the runner'))
    } elseif ($null -eq $reported) {
        $checks.Add((New-RigL1Check 'modules' 'Error' "job.modules ($(@($ExpectedModules).Count))" 'null'))
    } else {
        $expectedIds = @($ExpectedModules)
        $missing = @($expectedIds | Where-Object { $reported -cnotcontains $_ })
        $extra = @($reported | Where-Object { $expectedIds -cnotcontains $_ })
        $firstDiff = -1
        for ($i = 0; $i -lt [math]::Max($expectedIds.Count, $reported.Count); $i++) {
            if ($i -ge $expectedIds.Count -or $i -ge $reported.Count -or $expectedIds[$i] -cne $reported[$i]) { $firstDiff = $i; break }
        }
        if ($firstDiff -lt 0) {
            $checks.Add((New-RigL1Check 'modules' 'Passed' "job.modules ($($expectedIds.Count))" "$($reported.Count) modules, same order"))
        } else {
            $parts = @()
            if ($missing.Count -gt 0) { $parts += 'missing ' + ($missing -join ', ') }
            if ($extra.Count -gt 0) { $parts += 'extra ' + ($extra -join ', ') }
            if ($parts.Count -eq 0) { $parts += 'order differs at position {0}: {1}' -f ($firstDiff + 1), $reported[$firstDiff] }   # 1-based
            $checks.Add((New-RigL1Check 'modules' 'Failed' "job.modules ($($expectedIds.Count))" (Format-RigCheckField ($parts -join '; ') 400)))
        }
    }

    $mapEvents = if ($null -ne $Result) { $Result.playerMapEvents } else { $null }
    if ((Test-RigNumber $mapEvents) -and [double]$mapEvents -gt 0) {
        $checks.Add((New-RigL1Check 'playerMapEvents' 'Passed' '> 0' (Format-RigMeasuredValue $mapEvents)))
    } else {
        $checks.Add((New-RigL1Check 'playerMapEvents' 'Warn' '> 0' (Format-RigMeasuredValue $mapEvents)))
        $warnings.Add("WARN L1 $RunId playerMapEvents is $(Format-RigMeasuredValue $mapEvents): the player party had no map event (warning only)")
    }

    # ownExact (T-0106): false = exceptions.own is only an estimate (walk budget spent or a walk failed). Warn only. A
    # missing or non-boolean value is NotJudged with a WARN (like a null tempo): older harness output must not fail.
    $classification = if ($null -ne $exceptions) { $exceptions.classification } else { $null }
    # Not "$x = if": that unrolls a one-element array, so "ownExact":[true] would pass as a boolean.
    $ownExact = $null
    if ($classification -is [System.Management.Automation.PSCustomObject]) { $ownExact = $classification.ownExact }
    if ($ownExact -isnot [bool]) {
        $checks.Add((New-RigL1Check 'ownExact' 'NotJudged' 'true' (Format-RigMeasuredValue $ownExact)))
        $warnings.Add("WARN L1 $RunId ownExact not judged: exceptions.classification.ownExact is $(Format-RigMeasuredValue $ownExact)")
    } elseif ($ownExact) {
        $checks.Add((New-RigL1Check 'ownExact' 'Passed' 'true' 'true'))
    } else {
        $checks.Add((New-RigL1Check 'ownExact' 'Warn' 'true' 'false'))
        $warnings.Add("WARN L1 $RunId ownExact is false: exceptions.own is an estimate (walk budget spent or a walk failed; warning only)")
    }

    $statuses = @($checks | ForEach-Object { $_.status })
    $outcome = if ($statuses -contains 'Error') { 'RigError' } elseif ($statuses -contains 'Failed') { 'Failed' } else { 'Met' }
    [pscustomobject]@{ Outcome = $outcome; Checks = $checks.ToArray(); Warnings = $warnings.ToArray() }
}

# Console rows of an L1 verdict: one per check (run, L1-<name>, status, expected, actual), then its WARN lines.
function Format-RigL1Lines {
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)]$Verdict)
    foreach ($c in @($Verdict.Checks)) {
        $shown = switch ($c.status) { 'Passed' { 'Passed' } 'Failed' { 'Failed' } 'Warn' { 'WARN' } 'NotJudged' { 'not judged' } default { 'ERROR' } }
        '{0,-6} {1,-18} {2,-10} expected {3}, actual {4}' -f $RunId, "L1-$($c.name)", $shown, $c.expected, $c.actual
    }
    @($Verdict.Warnings)
}

# Reads out\results\<jobId>\job-result.json (written by Publish-RigResult) as data. Throws on an invalid id, a missing
# or unreadable file, or a file of another job.
function Read-RigJobResultFile {
    param([Parameter(Mandatory)][string]$ResultsRoot, [Parameter(Mandatory)][string]$JobId)
    if ($JobId -cnotmatch '^\d{8}-\d{6}-[0-9a-f]{4}\z') { throw "Invalid job id '$JobId' (expected yyyyMMdd-HHmmss-xxxx)." }
    $file = Join-Path (Join-Path $ResultsRoot $JobId) 'job-result.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "No job-result.json for job ${JobId}: $file" }
    $job = [IO.File]::ReadAllText($file, (New-Object Text.UTF8Encoding($false, $true))) | ConvertFrom-Json
    if ($job -isnot [System.Management.Automation.PSCustomObject] -or [string]$job.jobId -cne $JobId) {
        throw "$file does not belong to job $JobId."
    }
    $job
}

# The runner/baselines/L1.json document from finished jobs (parsed job-result.json): $BaseJobs = one or more L1-BASE
# jobs (exit code 0), $L1Jobs = the L1 calibration jobs (any exit code). Every run must be Completed with a positive
# runningDaysPerRealMinute, numeric exceptions counters and a game version, all runs the same one; a job may appear
# only once. Throws naming the first violation.
function New-RigL1BaselineDocument {
    param([Parameter(Mandatory)][object[]]$BaseJobs, [object[]]$L1Jobs = @(), [datetime]$UtcNow = [datetime]::UtcNow)
    $jobs = New-Object System.Collections.Generic.List[object]
    $baseRuns = New-Object System.Collections.Generic.List[object]
    $l1Runs = New-Object System.Collections.Generic.List[object]
    $versions = New-Object System.Collections.Generic.List[string]
    $seenJobs = New-Object System.Collections.Generic.HashSet[string]
    foreach ($group in @(@{ Suite = 'L1-BASE'; Jobs = @($BaseJobs); Runs = $baseRuns }, @{ Suite = 'L1'; Jobs = @($L1Jobs); Runs = $l1Runs })) {
        foreach ($job in @($group.Jobs | Where-Object { $null -ne $_ })) {
            $jobId = [string]$job.jobId
            if (-not $seenJobs.Add($jobId)) { throw "job ${jobId} is listed twice." }
            if ([string]$job.suite -cne $group.Suite) { throw "job ${jobId}: suite '$($job.suite)', expected $($group.Suite)." }
            if ($group.Suite -eq 'L1-BASE' -and $job.exitCode -ne 0) { throw "job ${jobId}: exit code $($job.exitCode); a base job must have exit code 0." }
            $runs = @($job.runs | Where-Object { $null -ne $_ })
            if ($runs.Count -eq 0) { throw "job ${jobId}: no runs." }
            foreach ($run in $runs) {
                $label = "$jobId/$($run.runId)"
                if ([string]$run.exitClass -cne 'Completed') { throw "run ${label}: exitClass '$($run.exitClass)', expected Completed." }
                $r = $run.result
                $tempo = $r.runningDaysPerRealMinute
                if (-not (Test-RigNumber $tempo) -or [double]$tempo -le 0) { throw "run ${label}: runningDaysPerRealMinute is not a positive number." }
                $counts = [ordered]@{}
                foreach ($k in 'total', 'own', 'harness', 'vanilla', 'unhandled') {
                    $v = if ($null -ne $r.exceptions) { $r.exceptions.$k } else { $null }
                    if (-not (Test-RigNumber $v)) { throw "run ${label}: exceptions.$k is not a number." }
                    $counts[$k] = [long]$v
                }
                if ($run.gameVersion -isnot [string] -or $run.gameVersion -eq '') { throw "run ${label}: no gameVersion." }
                if ($versions -cnotcontains $run.gameVersion) { $versions.Add($run.gameVersion) }
                $group.Runs.Add([ordered]@{
                        jobId = $jobId; runId = [string]$run.runId; seed = $r.seed; daysReached = $r.daysReached
                        runningDaysPerRealMinute = [double]$tempo; playerMapEvents = $r.playerMapEvents; exceptions = $counts
                    })
            }
            $jobs.Add([ordered]@{
                    jobId = $jobId; suite = $group.Suite; exitCode = $job.exitCode
                    modules = @(@($runs[0].result.modules | Where-Object { $null -ne $_ }) | ForEach-Object { [ordered]@{ id = [string]$_.id; version = [string]$_.version } })
                })
        }
    }
    if ($baseRuns.Count -eq 0) { throw 'no base runs.' }
    if ($versions.Count -gt 1) { throw "the runs report different game versions: $($versions -join ', ')." }
    $t = Get-RigL1Thresholds -Tempos @($baseRuns | ForEach-Object { $_.runningDaysPerRealMinute }) -Vanillas @($baseRuns | ForEach-Object { [double]$_.exceptions.vanilla })
    $l1RatioMin = $null
    if ($l1Runs.Count -gt 0) {
        $slowest = ($l1Runs | ForEach-Object { $_.runningDaysPerRealMinute } | Measure-Object -Minimum).Minimum
        $l1RatioMin = [math]::Round($slowest / $t.TempoMedian, 4)
    }
    [ordered]@{
        schema      = 1
        suite       = 'L1'
        note        = 'Written by runner/Update-L1Baseline.ps1, do not edit by hand. The runner recomputes the thresholds from baseRuns; derived is for reading.'
        gameVersion = $versions[0]
        updatedUtc  = $UtcNow.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        jobs        = $jobs.ToArray()
        baseRuns    = $baseRuns.ToArray()
        l1Runs      = $l1Runs.ToArray()
        derived     = [ordered]@{
            baseRunCount     = $baseRuns.Count
            tempoMedian      = [math]::Round($t.TempoMedian, 4)
            tempoMin         = $t.TempoMin
            tempoMax         = $t.TempoMax
            tempoSpread      = [math]::Round($t.TempoSpread, 4)
            tempoThreshold   = [math]::Round($t.TempoThreshold, 4)
            vanillaMax       = $t.VanillaMax
            vanillaThreshold = $t.VanillaThreshold
            l1TempoRatioMin  = $l1RatioMin
        }
    }
}

# Writes the L1 baseline from finished jobs (out\results\<jobId>\job-result.json) to $Path (UTF-8 without BOM, LF) and
# prints the derived values with the calibration checks: tempo spread of the base runs (max - min) / median <= 10 %
# (else run more base runs) and slowest L1 run / base median >= 0.8 (else decide the threshold before trusting the
# tempo verdict); both only warn. Returns 0, or 1 (nothing written) when a job is unusable.
function Update-RigL1Baseline {
    param(
        [Parameter(Mandatory)][string[]]$BaseJobIds,
        [string[]]$L1JobIds = @(),
        [Parameter(Mandatory)][string]$ResultsRoot,
        [Parameter(Mandatory)][string]$Path
    )
    try {
        # Where-Object: a $null list (no ids) must not become one $null id.
        $baseJobs = @($BaseJobIds | Where-Object { $null -ne $_ } | ForEach-Object { Read-RigJobResultFile -ResultsRoot $ResultsRoot -JobId $_ })
        $l1Jobs = @($L1JobIds | Where-Object { $null -ne $_ } | ForEach-Object { Read-RigJobResultFile -ResultsRoot $ResultsRoot -JobId $_ })
        $doc = New-RigL1BaselineDocument -BaseJobs $baseJobs -L1Jobs $l1Jobs
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $json = (ConvertTo-RigJson $doc) -replace "`r`n", "`n"
        [IO.File]::WriteAllText($Path, $json + "`n", (New-Object Text.UTF8Encoding($false)))
    } catch {
        Write-RigMessage "ERROR: baseline not written: $($_.Exception.Message)"
        return 1
    }
    $d = $doc.derived
    Write-RigMessage ("baseline written: {0} (game {1}, {2} base runs, {3} L1 runs)" -f $Path, $doc.gameVersion, $d.baseRunCount, @($doc.l1Runs).Count)
    Write-RigMessage ('tempo (days/min): median {0}, min {1}, max {2}, spread {3} %; L1 needs ratio >= {4} (>= {5})' -f (Format-RigNumber $d.tempoMedian '0.00'),
        (Format-RigNumber $d.tempoMin '0.00'), (Format-RigNumber $d.tempoMax '0.00'), (Format-RigNumber ($d.tempoSpread * 100) '0.0'),
        (Format-RigNumber $script:RigL1TempoFactor), (Format-RigNumber $d.tempoThreshold '0.00'))
    Write-RigMessage ('vanilla exceptions: base max {0}; L1 threshold {1} x max + {2} = {3}' -f (Format-RigNumber $d.vanillaMax),
        (Format-RigNumber $script:RigL1VanillaFactor), (Format-RigNumber $script:RigL1VanillaSlack), (Format-RigNumber $d.vanillaThreshold))
    if ($d.tempoSpread -gt 0.10) {
        Write-RigMessage ('WARN tempo spread {0} % > 10 % across the base runs: run more base runs (calibration rule)' -f (Format-RigNumber ($d.tempoSpread * 100) '0.0'))
    }
    if ($null -ne $d.l1TempoRatioMin) {
        if ($d.l1TempoRatioMin -lt 0.8) {
            Write-RigMessage ('WARN slowest L1 run / base median = {0} < 0.8: decide the tempo threshold (or record that the mods slow the game) before relying on the tempo verdict' -f (Format-RigNumber $d.l1TempoRatioMin '0.000'))
        } else {
            Write-RigMessage ('slowest L1 run / base median = {0}' -f (Format-RigNumber $d.l1TempoRatioMin '0.000'))
        }
    }
    0
}

# Exit code of one finished job. A run with kind 'scenarios' skips the daysReached rule below; instead a Completed
# one must report every requested scenario without Skipped (Test-RigScenariosChecked), else 1. A Completed soak run with
# health ids (requestedHealth) must also report every health line Passed (Get-RigHealthOutcome): missing or unchecked
# = 1, Failed = 2 by the status rule below; a Completed soak run with an L1 verdict (property l1Verdict, see
# Get-RigL1Verdict) adds 2 for outcome Failed and 1 for RigError. Per run: the exitClass maps to 0/1/2/3 (see below); additionally a scenario
# (run-result.json) with status Failed counts as 2; Passed/Timeout/Skipped add nothing here; Error and any
# unknown or non-string status count as 1.
# Across everything: 1 > 3 > 2 > 0, so an Error scenario wins over any other code, and Failed (2) is the weakest.
# With -Expectations (a suite with Runs) the per-run rules above do not apply; instead every expectation is judged by
# Get-RigExpectationOutcome: Met = 0, Mismatch = 2, Inconclusive = 3, RigError or a run missing from a completed job = 1. The job status
# and -ForceTimeout rules stay.
# -CheckOutcomes (the suite's PostRunChecks and JobChecks, in addition to either rule set): Passed = 0, Failed = 2,
# Inconclusive = 3, RigError and anything else = 1.
function Resolve-RigExitCode {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$DoneStatus,
        [object[]]$Runs,
        [Parameter(Mandatory)][int]$Days,
        [object[]]$Expectations,
        [string[]]$CheckOutcomes = @(),
        [switch]$ForceTimeout   # the runner itself hit a time limit (e.g. overall deadline)
    )
    $runList = @($Runs)
    $expectationList = @($Expectations | Where-Object { $null -ne $_ })
    $codes = New-Object System.Collections.Generic.List[int]
    switch ($DoneStatus) {
        'completed' { if ($runList.Count -eq 0) { $codes.Add(1) } }
        'aborted' { $codes.Add(3) }
        default { $codes.Add(1) }   # blocked, rejected, failed and anything unknown
    }
    foreach ($e in $expectationList) {
        $run = $runList | Where-Object { $_.runId -ceq $e.RunId } | Select-Object -First 1
        if ($null -eq $run -and $DoneStatus -ne 'completed') { continue }   # the job status already decided
        switch (Get-RigExpectationOutcome -Expectation $e -Run $run -Days $Days) {
            'Met' { }
            'Mismatch' { $codes.Add(2) }
            'Inconclusive' { $codes.Add(3) }
            default { $codes.Add(1) }   # RigError, Missing
        }
    }
    if ($expectationList.Count -gt 0) { $runList = @() }   # judged above, not by the per-run rules
    foreach ($r in $runList) {
        switch ($r.exitClass) {
            'Completed' {
                # A scenario run ends by its scenarios, not by a day count (its scenarios decide below).
                if ($r.kind -ne 'scenarios') {
                    if ($null -eq $r.daysReached -or [int]$r.daysReached -lt $Days) { $codes.Add(2) }
                    # Health bracket: a Failed line already gives 2 below; a missing or unchecked one is a rig error.
                    if ((Get-RigHealthOutcome -Run $r -Days $Days) -eq 'RigError') { $codes.Add(1) }
                    # L1 verdict on the measurements (Get-RigL1Verdict), when the run has one.
                    if ($null -ne $r.l1Verdict) {
                        switch ($r.l1Verdict.Outcome) { 'Failed' { $codes.Add(2) } 'RigError' { $codes.Add(1) } }
                    }
                }
                elseif (-not (Test-RigScenariosChecked -Run $r)) { $codes.Add(1) }   # nothing (or not everything) was checked
            }
            { $_ -in 'NotCompleted', 'Crashed' } { $codes.Add(2) }
            { $_ -in 'HardTimeout', 'Hung', 'Aborted' } { $codes.Add(3) }
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
    foreach ($o in $CheckOutcomes) {
        switch -CaseSensitive ($o) {
            { $_ -cin 'Passed', 'Skipped' } { }   # Skipped: the check was not run because a run did not complete (that run decides)
            'Failed' { $codes.Add(2) }
            'Inconclusive' { $codes.Add(3) }
            default { $codes.Add(1) }   # RigError and anything unknown
        }
    }
    if ($ForceTimeout) { $codes.Add(3) }
    foreach ($c in 1, 3, 2) { if ($codes.Contains($c)) { return $c } }
    0
}

# Control characters (incl. CR/LF) become a space, the text is capped: run-result.json comes from the tower's game process.
function Format-RigCheckField {
    param([string]$Text, [int]$MaxLength = 200)
    $clean = [regex]::Replace($Text, '\p{Cc}', ' ')
    if ($clean.Length -gt $MaxLength) { $clean = $clean.Substring(0, $MaxLength) }
    $clean
}

function Format-RigRunLine {
    param(
        [string]$RunId, [string]$Kind, [string]$Status,
        $DaysReached, [int]$Days, [string]$ExitClass,
        $Duration, [string]$Path,
        [string]$RunKind   # 'scenarios': days are not part of the verdict, the column shows -
    )
    $st = if ($Status) { $Status } else { '?' }
    $reached = if ($null -ne $DaysReached) { [string]$DaysReached } else { '?' }
    $daysCell = if ($RunKind -eq 'scenarios') { '-' } else { "$reached/$Days" }
    $dur = if ($null -ne $Duration) { '{0}m{1:00}s' -f [int][math]::Floor($Duration.TotalMinutes), $Duration.Seconds } else { '?' }
    '{0,-6} {1,-6} {2,-12} {3,-7} {4,-13} {5,-8} {6}' -f $RunId, $Kind, $st, $daysCell, $ExitClass, $dur, $Path
}

# Console row of a suite run with an expectation: the expected and the actual exitClass and whether they agree
# (met / MISMATCH / INCONCLUSIVE / ERROR for a rig error / missing). The actual class comes from the tower: sanitized like
# the check fields.
function Format-RigExpectationLine {
    param(
        [Parameter(Mandatory)]$Expectation,
        $Run,   # $null = the run is missing from done.json
        [Parameter(Mandatory)][string]$Suite,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Days   # passed on to Get-RigExpectationOutcome
    )
    $verdict = switch (Get-RigExpectationOutcome -Expectation $Expectation -Run $Run -Days $Days) {
        'Met' { 'met' }
        'Mismatch' { 'MISMATCH' }
        'Inconclusive' { 'INCONCLUSIVE' }
        'RigError' { 'ERROR' }
        default { 'missing' }
    }
    $actual = if ($null -eq $Run) { '-' } else { Format-RigCheckField ([string]$Run.exitClass) 40 }
    $what = if (@($Expectation.Scenarios).Count -gt 0) { @($Expectation.Scenarios) -join '+' } else { 'soak' }
    '{0,-6} {1,-6} expected {2,-10} actual {3,-12} {4,-8} {5}' -f $Expectation.RunId, "$Suite-$what", `
        $Expectation.ExpectedExitClass, $actual, $verdict, $Path
}

# Longest a check script may run before it is killed (a hung script must not hang the whole judgement).
$script:RigCheckScriptTimeoutSeconds = 600

# Runs a check script of a suite (PostRunChecks / JobChecks) in its own Windows PowerShell process and reads the JSON it
# writes to $ResultPath (a stale file from an earlier judgement is deleted first, on every path, so only this call's
# result counts). Returns Document (the parsed JSON object) and Problem: $null on success, else why there is no result
# (script missing, timed out and killed, no or invalid JSON; with the script's exit code and last output line). The
# script's console output is not shown.
function Invoke-RigCheckScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$ResultPath
    )
    if (Test-Path -LiteralPath $ResultPath) { Remove-Item -LiteralPath $ResultPath -Force -ErrorAction Stop }
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        return [pscustomobject]@{ Document = $null; Problem = "check script not found: $ScriptPath" }
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $quoted = foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $ScriptPath) + @($Arguments)) {
        '"' + ($argument -replace '(\\*)"', '$1$1\"' -replace '(\\+)\z', '$1$1') + '"'
    }
    $startInfo.Arguments = $quoted -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        # Both streams are drained asynchronously, else a chatty script could block on a full pipe.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit([int]($script:RigCheckScriptTimeoutSeconds * 1000))) {
            try { $process.Kill() } catch { }   # it may have ended just now
            $process.WaitForExit()
            return [pscustomobject]@{ Document = $null; Problem = "$(Split-Path -Leaf $ScriptPath) timed out after $($script:RigCheckScriptTimeoutSeconds) seconds and was killed" }
        }
        $process.WaitForExit()   # flushes the redirected streams
        $exit = $process.ExitCode
        $output = @(($stdout.Result + "`n" + $stderr.Result) -split "`r?`n")
    } finally { $process.Dispose() }
    $lastLine = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    $shownLine = if ($lastLine.Count -gt 0) { Format-RigCheckField $lastLine[0] 200 } else { '(no output)' }
    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        return [pscustomobject]@{ Document = $null; Problem = "$(Split-Path -Leaf $ScriptPath) wrote no result (exit $exit): $shownLine" }
    }
    try {
        $doc = [IO.File]::ReadAllText($ResultPath, (New-Object Text.UTF8Encoding($false, $true))) | ConvertFrom-Json
        if ($doc -isnot [System.Management.Automation.PSCustomObject]) { throw 'not a JSON object' }
    } catch {
        return [pscustomobject]@{ Document = $null; Problem = "$(Split-Path -Leaf $ScriptPath) wrote an invalid result ${ResultPath}: $($_.Exception.Message)" }
    }
    [pscustomobject]@{ Document = $doc; Problem = $null }
}

# One PostRunCheck (CW-2, F-S10-6) on one Completed run. The rows of the result JSON decide: any FAIL = 'Failed'; PASS,
# 'N/A for mode' and MANUAL count as met; 'INSUFFICIENT DATA' and 'WARN ...' are warnings (shown, no exit code);
# 'RigError' when the log or the script is missing, the run mode is unknown, the script wrote no result, there is no row,
# or a row has an unknown verdict. Returns Id, Outcome, Detail (expected/actual summary), Rows (the FAIL and warning rows:
# Ac, Verdict, Evidence, Shown = 'FAIL' / 'WARN' / 'UNKNOWN') and ResultPath.
function Invoke-RigPostRunCheck {
    param(
        [Parameter(Mandatory)][hashtable]$Check,
        [Parameter(Mandatory)][string]$RunDir,
        [AllowNull()][AllowEmptyString()][string]$Mode,   # the run's job.json mode
        [Parameter(Mandatory)][int]$Days,
        [Parameter(Mandatory)][string]$WorkspaceRoot
    )
    $resultPath = Join-Path $RunDir "$($Check.Id).json"
    $outcome = { param($Outcome, $Detail, $Rows = @()) [pscustomobject]@{ Id = $Check.Id; Outcome = $Outcome; Detail = $Detail; Rows = @($Rows); ResultPath = $resultPath } }
    $logPath = Join-Path $RunDir $Check.Log
    # A stale result of an earlier judgement must not survive an early return (Invoke-RigCheckScript deletes it as well).
    if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath -Force -ErrorAction Stop }
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { return (& $outcome 'RigError' "log missing: $logPath") }
    if ([string]::IsNullOrWhiteSpace($Mode)) { return (& $outcome 'RigError' 'run mode unknown (no mode for this run in job.json)') }
    $script = Join-Path $WorkspaceRoot $Check.Script
    $r = Invoke-RigCheckScript -ScriptPath $script -ResultPath $resultPath `
        -Arguments @('-LogPath', $logPath, '-Mode', $Mode, '-MinDays', [string]$Days, '-ResultPath', $resultPath)
    if ($null -ne $r.Problem) { return (& $outcome 'RigError' $r.Problem) }
    $rows = @($r.Document.rows | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) { return (& $outcome 'RigError' "no verdict rows in $resultPath") }
    $counts = [ordered]@{}
    $notable = @()
    $failed = $false
    $unknown = $false
    foreach ($row in $rows) {
        $verdict = [string]$row.verdict
        $counts[$verdict] = 1 + $(if ($counts.Contains($verdict)) { $counts[$verdict] } else { 0 })
        $shown = if ($verdict -ceq 'FAIL') { 'FAIL' }
        elseif ($verdict -ceq 'INSUFFICIENT DATA' -or $verdict -clike 'WARN*') { 'WARN' }
        elseif ($verdict -cin 'PASS', 'N/A for mode', 'MANUAL') { $null }
        else { 'UNKNOWN' }
        if ($shown -ceq 'FAIL') { $failed = $true }
        if ($shown -ceq 'UNKNOWN') { $unknown = $true }
        if ($shown) { $notable += [pscustomobject]@{ Ac = [string]$row.ac; Verdict = $verdict; Evidence = [string]$row.evidence; Shown = $shown } }
    }
    $actual = @($counts.Keys | ForEach-Object { '{0} {1}' -f $counts[$_], (Format-RigCheckField $_ 40) }) -join ', '
    $result = if ($unknown) { 'RigError' } elseif ($failed) { 'Failed' } else { 'Passed' }
    & $outcome $result "expected no FAIL, actual $actual" $notable
}

# One JobCheck (CW-1) on a completed job: one entry per check of the result JSON (Id = its 'check', Outcome = its verdict
# when Passed, Failed or Inconclusive, else 'RigError'; Detail; Violations), or one 'RigError' entry under the JobCheck's
# Id when the script is missing, wrote no result or the result holds no check.
function Invoke-RigJobCheck {
    param(
        [Parameter(Mandatory)][hashtable]$Check,
        [Parameter(Mandatory)][string]$ResultDir,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [string]$JobManifestPath   # job.json of the job (the plan); passed as -JobManifestPath to a check with UsesJobManifest, when the file exists
    )
    $resultPath = Join-Path $ResultDir $Check.ResultFile
    $arguments = @('-JobPath', $ResultDir, '-ResultPath', $resultPath)
    if ($Check.UsesJobManifest -and $JobManifestPath -and (Test-Path -LiteralPath $JobManifestPath -PathType Leaf)) {
        $arguments += @('-JobManifestPath', $JobManifestPath)
    }
    $r = Invoke-RigCheckScript -ScriptPath (Join-Path $WorkspaceRoot $Check.Script) -ResultPath $resultPath -Arguments $arguments
    $entries = @(if ($null -eq $r.Problem) { $r.Document.checks | Where-Object { $null -ne $_ } })
    if ($null -ne $r.Problem -or $entries.Count -eq 0) {
        $problem = if ($null -ne $r.Problem) { $r.Problem } else { "no checks in $resultPath" }
        return [pscustomobject]@{ Id = $Check.Id; Outcome = 'RigError'; Detail = $problem; Violations = @(); Warnings = @(); ResultPath = $resultPath }
    }
    # The result document may carry a top-level 'warnings' list (Compare-Ac25a.ps1). It belongs to the document, not to one
    # check, so it is reported once, with the first entry.
    $docWarnings = @(if ($r.Document.PSObject.Properties.Name -contains 'warnings') { @($r.Document.warnings | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ }) })
    $first = $true
    foreach ($e in $entries) {
        $verdict = [string]$e.verdict
        $entryWarnings = @(if ($first) { $docWarnings })
        $first = $false
        [pscustomobject]@{
            Warnings = $entryWarnings
            Id = Format-RigCheckField $(if ([string]::IsNullOrWhiteSpace([string]$e.check)) { $Check.Id } else { [string]$e.check }) 80
            Outcome = if ($verdict -cin 'Passed', 'Failed', 'Inconclusive') { $verdict } else { 'RigError' }
            Detail = Format-RigCheckField ([string]$e.detail) 400
            Violations = @(if ($e.PSObject.Properties.Name -contains 'violations') { @($e.violations | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) })
            ResultPath = $resultPath
        }
    }
}

# Console rows of the suite checks, in the style of the run rows: '<runId> <Suite>-<check id> <outcome> <detail> <file>'
# ('job' instead of a run id for a JobCheck), then one indented row per FAIL / warning row or violation. 'Error' is shown
# for 'RigError'.
function Format-RigCheckLines {
    param([Parameter(Mandatory)][string]$Where, [AllowNull()][AllowEmptyString()][string]$Suite, [Parameter(Mandatory)]$Result)
    $shown = if ($Result.Outcome -ceq 'RigError') { 'Error' } else { $Result.Outcome }
    $name = if ($Suite) { "$Suite-$($Result.Id)" } else { $Result.Id }   # an ad-hoc run has no suite prefix
    '{0,-6} {1,-6} {2,-12} {3}  {4}' -f $Where, $name, $shown, $Result.Detail, $Result.ResultPath
    if ($Result.PSObject.Properties.Name -contains 'Rows') {
        foreach ($row in @($Result.Rows)) {
            '    {0}: expected PASS, actual {1} ({2}) - {3}' -f (Format-RigCheckField $row.Ac 20), (Format-RigCheckField $row.Verdict 40), $row.Shown, (Format-RigCheckField $row.Evidence 300)
        }
    }
    if ($Result.PSObject.Properties.Name -contains 'Violations') {
        foreach ($v in @($Result.Violations)) { '    FAIL  {0}' -f (Format-RigCheckField $v 300) }
    }
    if ($Result.PSObject.Properties.Name -contains 'Warnings') {
        foreach ($w in @($Result.Warnings)) { '    WARN  {0}' -f (Format-RigCheckField $w 300) }
    }
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
        [int]$MaxWithdrawAttempts = 5,
        [AllowNull()]$TowerGuard   # sampled for game and launcher processes on every poll (also while the abort is awaited)
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $claimSeen = $false
    $lastBeat = $null
    $beatSince = $null
    $withdrawAttempts = 0
    $pollMs = [int][math]::Max(1, $PollSeconds * 1000)
    while ($true) {
        $st = Invoke-RigWithRetry -DelaySeconds $RetryDelaySeconds -Action { Get-JobState -Target $Target -JobId $JobId }
        if ($null -ne $TowerGuard) { Update-RigTowerGuard -Guard $TowerGuard }
        if ($st.done) { return 'Done' }

        if ($sw.Elapsed.TotalSeconds -ge $OverallSeconds) {
            Send-JobAbort -Target $Target -JobId $JobId
            $abortSw = [Diagnostics.Stopwatch]::StartNew()
            while ($abortSw.Elapsed.TotalSeconds -lt $AbortWaitSeconds) {
                Start-Sleep -Milliseconds $pollMs
                if ($null -ne $TowerGuard) { Update-RigTowerGuard -Guard $TowerGuard }
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

# The console line of a tower guard record (Complete-RigTowerGuard; also one read back from job-result.json).
function Format-RigTowerGuardLine {
    param([Parameter(Mandatory)]$Guard)
    $prefix = switch -CaseSensitive ([string]$Guard.outcome) { 'Passed' { '' } 'Inconclusive' { 'WARN ' } default { 'ERROR ' } }
    $window = if ($Guard.window -is [string] -and $Guard.window) { " ($($Guard.window))" } else { '' }
    "${prefix}tower guard${window}: $($Guard.detail)"
}

# Exit code share of a tower guard record: Passed 0, Inconclusive 3, RigError and anything else 1; no guard 0.
function Get-RigTowerGuardExitCode {
    param([AllowNull()]$Guard)
    if ($null -eq $Guard) { return 0 }
    switch -CaseSensitive ([string]$Guard.outcome) { 'Passed' { 0 } 'Inconclusive' { 3 } default { 1 } }
}

# The worse of two runner exit codes by the precedence 1 > 3 > 2 > 0.
function Join-RigExitCode {
    param([int]$First, [int]$Second)
    foreach ($code in 1, 3, 2) {
        if ($First -eq $code -or $Second -eq $code) { return $code }
    }
    [math]::Max($First, $Second)
}

# Ends the tower guard at an exit that does not reach Publish-RigResult (job not waited for, claim timeout, stale heartbeat,
# deadline): prints its line (naming the shorter $Window it covered) and joins its code with $Code. Without a guard it returns $Code.
function Close-RigTowerGuard {
    param([AllowNull()]$Guard, [Parameter(Mandatory)][int]$Code, [Parameter(Mandatory)][string]$Window)
    if ($null -eq $Guard) { return $Code }
    $record = Complete-RigTowerGuard -Guard $Guard -Window $Window
    Write-RigMessage (Format-RigTowerGuardLine -Guard $record)
    Join-RigExitCode $Code (Get-RigTowerGuardExitCode -Guard $record)
}

# Reads the fetched result folder (data only), prints one line per run, writes job-result.json.
# Returns the exit code.
function Publish-RigResult {
    param(
        [Parameter(Mandatory)][string]$ResultDir,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][int]$Days,
        [string]$Suite,           # when set, scenario ids are shown as <Suite>-<id> and job-result.json gets 'suite'
        [string]$TowerGamePath,   # when set, versions reported by the agent are compared with the tower (warnings only)
        [AllowNull()][string[]]$ExpectedModules,   # job.modules; the L1 verdict compares the reported modules with it
        [string]$BaselinePath = $script:RigL1BaselinePath,   # the L1 baseline (-Suite L1 only)
        [object[]]$JobRuns = @(),   # job.json runs[]: the mode of each run (job-result.json runs[].mode, the PostRunChecks' -Mode)
        [string]$WorkspaceRoot,     # resolves the Script of the suite's PostRunChecks/JobChecks; default: parent folder of this repo
        [string]$JobManifestPath,   # <OutRoot>\jobs\<id>\job.json: the job plan, passed to the JobChecks that use it (-JobManifestPath)
        [AllowNull()][string[]]$CarriedVersionWarnings,   # offline re-judgement: the version warnings of the earlier job-result.json (no tower to compare with)
        [AllowNull()]$RejudgedFrom,   # offline re-judgement: { exitCode; at } written as 'rejudgedFrom' to job-result.json
        [AllowNull()]$TowerGuard,     # the tower guard record of the job (Complete-RigTowerGuard; offline: the earlier job-result.json's); $null = none
        [switch]$SkipChecks,       # do not run the suite's PostRunChecks/JobChecks (tests of the other verdict parts)
        [switch]$ForceTimeout
    )
    if (-not $WorkspaceRoot) { $WorkspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $suiteDef = if ($Suite) { $script:RigSuites[$Suite] } else { $null }
    # An ad-hoc run (no suite) always loads CoherentWarAI (Get-RigModules): CW-2 as in the suites that load it (S12 #70).
    $postRunChecks = @(if ($SkipChecks) { }
        elseif ($null -eq $suiteDef) { $script:RigCommandLogCheck }
        elseif ($suiteDef.ContainsKey('PostRunChecks')) { $suiteDef.PostRunChecks })
    $jobChecks = @(if (-not $SkipChecks -and $null -ne $suiteDef -and $suiteDef.ContainsKey('JobChecks')) { $suiteDef.JobChecks })
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
    $runKind = Get-RigSuiteKind -Suite $Suite   # the job's run kind follows from its suite (jobs carry one suite)
    $expectations = @(Get-RigSuiteRuns -Suite $Suite -Days $Days)   # suites with Runs: one expectation per run
    $requestedScenarios = @(if ($runKind -eq 'scenarios' -and $expectations.Count -eq 0) { $script:RigSuites[$Suite].Scenarios })
    $requestedHealth = @(if ($runKind -eq 'soak') { Get-RigSuiteHealth -Suite $Suite })   # as written to job.json runs[].health
    $healthLineIds = @(Get-RigHealthLineIds -Health $requestedHealth -Days $Days)
    $l1Baseline = if ($Suite -ceq 'L1') { Read-RigL1Baseline -Path $BaselinePath } else { $null }
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
        $runMessage = if ($arProps -contains 'message') { $ar.message } else { $null }   # judged by ExpectedMessagePattern
        # Explicit assignment: `$x = if (...) { @(...) }` would unroll 0 elements to $null and 1 to a scalar (not a JSON array).
        $moduleVersions = $null
        if ($arProps -contains 'moduleVersions' -and $null -ne $ar.moduleVersions) { $moduleVersions = @($ar.moduleVersions) }

        # L1 verdict on the measurements: only a Completed run (any other exit class already fails by itself).
        $l1Verdict = $null
        if ($null -ne $l1Baseline -and [string]$dr.exitClass -ceq 'Completed') {
            $l1Verdict = Get-RigL1Verdict -RunId $runId -Result $rr.Result -ExpectedModules $ExpectedModules -GameVersion $gameVersion -Baseline $l1Baseline
        }
        $jobRun = @($JobRuns | Where-Object { $null -ne $_ -and [string]$_.runId -ceq $runId }) | Select-Object -First 1
        $runMode = if ($null -ne $jobRun -and $jobRun.mode -is [string] -and $jobRun.mode -ne '') { $jobRun.mode } else { $null }
        # Suite checks on the fetched artifacts: only a Completed run (any other exit class already fails by itself).
        $checkResults = @(if ([string]$dr.exitClass -ceq 'Completed') {
                foreach ($check in $postRunChecks) {
                    Invoke-RigPostRunCheck -Check $check -RunDir $runDir -Mode $runMode -Days $Days -WorkspaceRoot $WorkspaceRoot
                }
            })

        $runs += [pscustomobject]@{
            runId = $runId; kind = $runKind; exitClass = [string]$dr.exitClass; daysReached = $daysReached; result = $rr.Result
            scenarioStatuses = @($rr.Scenarios | ForEach-Object { $_.Status })
            scenarioIds = @($rr.Scenarios | ForEach-Object { $_.Id })
            requestedScenarios = $requestedScenarios; requestedHealth = $requestedHealth
            gameVersion = $gameVersion; moduleVersions = $moduleVersions; message = $runMessage; l1Verdict = $l1Verdict
            mode = $runMode; checks = $checkResults
        }
        # One line per scenario, each followed by one indented line per failed check of that scenario
        # (with expectations, a scenario run without scenario results, e.g. a crashed one, gets only its expectation row;
        # a soak run keeps its line: its days reached are part of the verdict)
        $lineSources = if ($rr.Scenarios.Count -gt 0) { $rr.Scenarios } elseif ($expectations.Count -eq 0 -or $runKind -ne 'scenarios') { @([pscustomobject]@{ Id = 'soak'; Status = $rr.Status }) } else { @() }
        foreach ($sc in $lineSources) {
            $kind = if ($Suite) { "$Suite-$($sc.Id)" } else { $sc.Id }
            $lines += Format-RigRunLine -RunId $runId -Kind $kind -Status $sc.Status -DaysReached $daysReached -Days $Days `
                -ExitClass ([string]$dr.exitClass) -Duration $duration -Path $runDir -RunKind $runKind
            foreach ($check in @($rr.FailedChecks | Where-Object { $_.Scenario -ceq $sc.Id })) {
                $lines += '    {0}: expected {1}, actual {2}' -f (Format-RigCheckField $check.Name), (Format-RigCheckField $check.Expected), (Format-RigCheckField $check.Actual)
            }
        }
        # An expected health line the run did not report gets its own row (status 'missing') once the run reported any
        # line, and always for a Completed run (it must report them all); a run that ended otherwise without a line keeps
        # its single soak row.
        if ($rr.Scenarios.Count -gt 0 -or [string]$dr.exitClass -ceq 'Completed') {
            $reportedIds = @($rr.Scenarios | ForEach-Object { $_.Id })
            foreach ($missingId in @($healthLineIds | Where-Object { $reportedIds -cnotcontains $_ })) {
                $kind = if ($Suite) { "$Suite-$missingId" } else { $missingId }
                $lines += Format-RigRunLine -RunId $runId -Kind $kind -Status 'missing' -DaysReached $daysReached -Days $Days `
                    -ExitClass ([string]$dr.exitClass) -Duration $duration -Path $runDir -RunKind $runKind
            }
        }
        if ($null -ne $l1Verdict) { $lines += @(Format-RigL1Lines -RunId $runId -Verdict $l1Verdict) }
        foreach ($c in $checkResults) { $lines += @(Format-RigCheckLines -Where $runId -Suite $Suite -Result $c) }
    }
    # Job checks (CW-1) over the whole fetched job: only a completed job (otherwise the job status already decides).
    # The check always runs: a violation it finds is evidence even when another run is unusable. With a run that did not
    # end as its expectation says (a suite with Runs; else: did not end Completed) a Failed outcome stays Failed (shown and
    # counted); every other outcome (Passed, Inconclusive, RigError) becomes Skipped, since it could only outrank the run's
    # own verdict (a Crashed run or a Completed one with a failed scenario is a Mismatch, 2).
    $unusableRunIds = @(if ($expectations.Count -gt 0) {
            foreach ($e in $expectations) {
                $judged = $runs | Where-Object { $_.runId -ceq $e.RunId } | Select-Object -First 1
                if ((Get-RigExpectationOutcome -Expectation $e -Run $judged -Days $Days) -cne 'Met') { $e.RunId }
            }
        } else {
            $runs | Where-Object { $_.exitClass -cne 'Completed' } | ForEach-Object { $_.runId }
        })
    $unusableWording = if ($expectations.Count -gt 0) { 'did not meet its expectation' } else { 'not Completed' }
    $jobCheckResults = @(if ($doneStatus -ceq 'completed') {
            foreach ($check in $jobChecks) {
                foreach ($result in @(Invoke-RigJobCheck -Check $check -ResultDir $ResultDir -WorkspaceRoot $WorkspaceRoot -JobManifestPath $JobManifestPath)) {
                    if ($unusableRunIds.Count -gt 0 -and $result.Outcome -cne 'Failed') {
                        $result.Detail = "not judged: run(s) $($unusableRunIds -join ', ') $unusableWording (check said $($result.Outcome))"
                        $result.Outcome = 'Skipped'
                    }
                    $result
                }
            }
        })
    foreach ($c in $jobCheckResults) { $lines += @(Format-RigCheckLines -Where 'job' -Suite $Suite -Result $c) }
    if ($expectations.Count -gt 0) {
        $expectationLines = foreach ($e in $expectations) {
            $run = $runs | Where-Object { $_.runId -ceq $e.RunId } | Select-Object -First 1
            $dir = Join-Path $ResultDir $e.RunId
            Format-RigExpectationLine -Expectation $e -Run $run -Suite $Suite -Path $dir -Days $Days
            if ($null -ne $run -and [string]$run.exitClass -ceq $e.ExpectedExitClass -and -not (Test-RigExpectedMessage -Expectation $e -Run $run)) {
                $shownMessage = if ($run.message -is [string]) { Format-RigCheckField $run.message 400 } else { '(none)' }
                '    message does not match {0}: {1}' -f $e.ExpectedMessagePattern, $shownMessage
            }
            # Value checks: judged (and shown) only for a run that ended Completed as expected.
            if ($null -ne $run -and [string]$run.exitClass -ceq 'Completed' -and $e.ExpectedExitClass -ceq 'Completed') {
                foreach ($check in @(Get-RigExpectedValueChecks -Expectation $e -Result $run.result)) {
                    $shown = switch ($check.Status) { 'Passed' { 'met' } 'Failed' { 'MISMATCH' } default { 'ERROR' } }
                    '    {0}: expected {1}, actual {2} {3}' -f $check.Name, $check.Expected, $check.Actual, $shown
                }
            }
            if ($null -ne $run -and $e.ClassificationTiming) { Format-RigClassificationTiming -RunId $e.RunId -Result $run.result }
        }
        $lines = @($expectationLines) + @($lines)
    }
    $lines | ForEach-Object { Write-RigMessage $_ }

    # The reason the agent gave when it did not complete the job (rejected, blocked, failed, aborted ...).
    if ($doneStatus -cne 'completed') {
        $shownStatus = if ($doneStatus) { Format-RigCheckField $doneStatus 40 } else { '?' }
        $doneMessage = if ($done.PSObject.Properties.Name -contains 'message') { Format-RigCheckField ([string]$done.message) 400 } else { '' }
        Write-RigMessage $(if ([string]::IsNullOrWhiteSpace($doneMessage)) { "job status: $shownStatus" } else { "job status: $shownStatus - $doneMessage" })
    }

    $versionWarnings = @($CarriedVersionWarnings | Where-Object { $null -ne $_ })
    if (-not [string]::IsNullOrWhiteSpace($TowerGamePath)) {
        try { $versionWarnings = @(Get-RigVersionWarnings -TowerGamePath $TowerGamePath -Runs $runs) } catch {
            Write-RigMessage "WARN version check skipped: $($_.Exception.Message)"
        }
    }
    $versionWarnings | ForEach-Object { Write-RigMessage $_ }
    if ($null -ne $TowerGuard) { Write-RigMessage (Format-RigTowerGuardLine -Guard $TowerGuard) }

    $checkOutcomes = @(@($runs | ForEach-Object { $_.checks }) + $jobCheckResults | Where-Object { $null -ne $_ } | ForEach-Object { $_.Outcome })
    $code = Resolve-RigExitCode -DoneStatus $doneStatus -Runs $runs -Days $Days -Expectations $expectations -CheckOutcomes $checkOutcomes -ForceTimeout:$ForceTimeout
    $code = Join-RigExitCode $code (Get-RigTowerGuardExitCode -Guard $TowerGuard)   # the tower guard: Passed 0, Inconclusive 3, anything else 1
    $checkJson = {
        param($Result)
        $o = [ordered]@{ id = $Result.Id; outcome = $Result.Outcome; detail = $Result.Detail; resultPath = $Result.ResultPath }
        if ($Result.PSObject.Properties.Name -contains 'Rows') {
            $o.rows = @($Result.Rows | ForEach-Object { [ordered]@{ ac = $_.Ac; expected = 'PASS'; actual = $_.Verdict; evidence = $_.Evidence } })
        }
        if ($Result.PSObject.Properties.Name -contains 'Violations') { $o.violations = @($Result.Violations) }
        if ($Result.PSObject.Properties.Name -contains 'Warnings') { $o.warnings = @($Result.Warnings) }
        $o
    }
    $jobResult = [ordered]@{
            jobId    = $JobId
            suite    = if ($Suite) { $Suite } else { $null }
            status   = if ($doneStatus) { $doneStatus } else { $null }
            exitCode = $code
            runs     = @($runs | ForEach-Object {
                    $entry = [ordered]@{
                        runId = $_.runId; mode = $_.mode; exitClass = $_.exitClass; result = $_.result
                        gameVersion = $_.gameVersion; moduleVersions = $_.moduleVersions
                    }
                    if ($postRunChecks.Count -gt 0) {   # suites with PostRunChecks: empty for a run that is not Completed
                        $entry.checks = @($_.checks | ForEach-Object { & $checkJson $_ })
                    }
                    if ($healthLineIds.Count -gt 0) {   # health suites: every expected health line with what the run reported
                        $reportedIds = [object[]]@($_.scenarioIds)
                        $reportedStatuses = @($_.scenarioStatuses)
                        $entry.health = @($healthLineIds | ForEach-Object {
                                $index = [array]::IndexOf($reportedIds, $_)   # ordinal: the first report of that id
                                [ordered]@{ id = $_; expected = 'Passed'; actual = $(if ($index -ge 0) { $reportedStatuses[$index] } else { $null }) }
                            })
                    }
                    if ($null -ne $l1Baseline) {   # -Suite L1: the verdict on the measurements, null for a run that is not Completed
                        $entry.l1 = $null
                        if ($null -ne $_.l1Verdict) {
                            $entry.l1 = [ordered]@{
                                outcome  = $_.l1Verdict.Outcome
                                baseline = [ordered]@{
                                    path = $l1Baseline.Path; status = $l1Baseline.Status; reason = $l1Baseline.Reason
                                    gameVersion = $l1Baseline.GameVersion; jobIds = @($l1Baseline.JobIds)
                                }
                                checks   = @($_.l1Verdict.Checks)
                                warnings = @($_.l1Verdict.Warnings)
                            }
                        }
                    }
                    if ($expectations.Count -gt 0) {   # suites with Runs: what the run was judged against, and the verdict
                        $judgedRunId = $_.runId
                        $judgedBy = $expectations | Where-Object { $_.RunId -ceq $judgedRunId } | Select-Object -First 1
                        $entry.expected = $null   # a run the suite does not define is not judged
                        $entry.verdict = $null
                        if ($null -ne $judgedBy) {
                            $entry.expected = [ordered]@{
                                exitClass = $judgedBy.ExpectedExitClass; messagePattern = $judgedBy.ExpectedMessagePattern
                                values = @($judgedBy.ExpectedValues | ForEach-Object { [ordered]@{ name = $_.Path; expected = $_.Value } })
                            }
                            $entry.verdict = Get-RigExpectationOutcome -Expectation $judgedBy -Run $_ -Days $Days
                        }
                    }
                    $entry
                })
            # suites with JobChecks: one entry per check (empty for a job that is not completed); else null
            jobChecks = if ($jobChecks.Count -gt 0) { , @($jobCheckResults | ForEach-Object { & $checkJson $_ }) } else { $null }
            versionWarnings = $versionWarnings
            towerGuard = $TowerGuard   # null without towerGamePath (and for a job judged before the guard existed)
        }
    if ($null -ne $RejudgedFrom) { $jobResult.rejudgedFrom = $RejudgedFrom }
    Write-RigJsonFile -Path (Join-Path $ResultDir 'job-result.json') -InputObject $jobResult
    $code
}

# Re-judges a fetched job offline (F-S10-1, entry point runner\Update-JobResult.ps1): reads <OutRoot>\jobs\<jobId>\job.json
# (days, modules, the runs with their modes) and the suite from the job's existing job-result.json (-Suite overrides it),
# then judges <OutRoot>\results\<jobId> again exactly as after the fetch (Publish-RigResult, including the suite's
# PostRunChecks/JobChecks with the scripts as they are now) and rewrites its job-result.json. The earlier file is kept as
# job-result.previous.json (the first judgement is never overwritten), its versionWarnings are carried over and its exit
# code is recorded as rejudgedFrom. Not reconstructed: a runner-side time limit of the original wait (-ForceTimeout)
# (visible in the kept file). Returns the exit code (1 when the job folders are unusable).
function Update-RigJobResult {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$OutRoot,
        [string]$Suite,
        [string]$WorkspaceRoot,   # default: parent folder of this repo (see Publish-RigResult)
        [string]$BaselinePath = $script:RigL1BaselinePath
    )
    try {
        if ($JobId -cnotmatch '^[A-Za-z0-9_-]+\z') { throw "Invalid jobId '$JobId'." }
        $resultDir = Join-Path (Join-Path $OutRoot 'results') $JobId
        $jobFile = Join-Path (Join-Path (Join-Path $OutRoot 'jobs') $JobId) 'job.json'
        if (-not (Test-Path -LiteralPath $resultDir -PathType Container)) { throw "Result folder not found: $resultDir" }
        if (-not (Test-Path -LiteralPath $jobFile -PathType Leaf)) { throw "job.json not found: $jobFile" }
        $job = Get-Content -LiteralPath $jobFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $jobRuns = @($job.runs | Where-Object { $null -ne $_ })
        # Jobs of the retired CoherentWarAI harness (result.txt, no run-result.json) cannot be judged any more; a run without
        # a 'harness' field predates the field, when CoherentWarAI was the only harness.
        foreach ($jobRun in $jobRuns) {
            $runHarness = if ($jobRun.PSObject.Properties.Name -contains 'harness') { [string]$jobRun.harness } else { 'CoherentWarAI' }
            if ($runHarness -cne 'TestRig') {
                throw "job $JobId ran with the retired harness '$runHarness' (result.txt); it cannot be re-judged."
            }
        }
        $days = 0
        if ($jobRuns.Count -eq 0 -or -not [int]::TryParse([string]$jobRuns[0].days, [ref]$days) -or $days -lt 1) {
            throw "$jobFile has no run with a valid 'days'."
        }
        $previousFile = Join-Path $resultDir 'job-result.json'
        $previous = $null   # the earlier job-result.json, $null when there is none or it is unreadable
        $previousError = $null
        if (Test-Path -LiteralPath $previousFile -PathType Leaf) {
            try { $previous = Get-Content -LiteralPath $previousFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $previousError = $_ }
        }
        if (-not $Suite) {
            if ($null -ne $previousError) { throw $previousError }   # the suite cannot be taken from an unreadable file
            if ($null -ne $previous) { $Suite = [string]$previous.suite }
        }
        if ($Suite) {
            $canonical = Get-RigSuiteName $Suite
            if (-not $canonical) { throw "unknown suite '$Suite'. Valid suites: $((@($script:RigSuites.Keys) | Sort-Object) -join ', ')." }
            $Suite = $canonical
        }
        Write-RigMessage "re-judging job $JobId offline (suite: $(if ($Suite) { $Suite } else { 'none' }), $days days)"
        # Keep the evidence of the earlier judgement (original exit code, timeout, version warnings) before it is overwritten.
        $carriedWarnings = @()
        $carriedTowerGuard = $null   # the guard watched the live job: re-judging runs no job, so the earlier record stays as it was
        $rejudgedFrom = $null
        if ($null -ne $previous) {
            if ($previous.PSObject.Properties.Name -contains 'towerGuard') { $carriedTowerGuard = $previous.towerGuard }
            $copy = Join-Path $resultDir 'job-result.previous.json'
            if (-not (Test-Path -LiteralPath $copy)) { Copy-Item -LiteralPath $previousFile -Destination $copy }   # the first judgement stays
            if ($previous.PSObject.Properties.Name -contains 'versionWarnings') { $carriedWarnings = @($previous.versionWarnings | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) }
            $originalExitCode = if ($previous.PSObject.Properties.Name -contains 'rejudgedFrom' -and $null -ne $previous.rejudgedFrom) { $previous.rejudgedFrom.exitCode }
            elseif ($previous.PSObject.Properties.Name -contains 'exitCode') { $previous.exitCode }
            else { $null }
            $rejudgedFrom = [ordered]@{ exitCode = $originalExitCode; at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
        }
        Publish-RigResult -ResultDir $resultDir -JobId $JobId -Days $days -Suite $Suite -ExpectedModules @($job.modules | Where-Object { $null -ne $_ }) `
            -JobRuns $jobRuns -WorkspaceRoot $WorkspaceRoot -BaselinePath $BaselinePath -JobManifestPath $jobFile `
            -CarriedVersionWarnings $carriedWarnings -RejudgedFrom $rejudgedFrom -TowerGuard $carriedTowerGuard
    } catch {
        Write-RigMessage "ERROR: $($_.Exception.Message)"
        1
    }
}

function Start-TestRigJob {
    param(
        [string]$PackageFrom,
        [int]$Seed, [int]$Days, [string]$Mode,
        [int]$StallMinutes, [int]$BudgetMinutes, [int]$HardTimeoutMinutes,
        [ValidateSet('TestRig')][string]$Harness = 'TestRig',
        [string]$Suite,
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
            if ($Suite) {
                $s = $script:RigSuites[$Suite]
                foreach ($suiteModule in @(if ($s.WithCoherentWarAI) { 'CoherentWarAI' }) + @($s.ExtraModules) + @($s.TailModules)) {
                    if (-not (Test-Path -LiteralPath (Join-Path $PackageFrom "Modules\$suiteModule") -PathType Container)) {
                        throw "Package source '$PackageFrom' has no Modules\$suiteModule (needed by -Suite $Suite)."
                    }
                }
            }
        }
        if ($buildMode) {
            if ([string]::IsNullOrWhiteSpace([string]$target.towerGamePath)) {
                throw "Config '$ConfigPath' is missing 'towerGamePath' (needed to build; that game folder is only read, never written)."
            }
            $msbuildPath = if ([string]::IsNullOrWhiteSpace([string]$target.msbuildPath)) { $script:DefaultMsBuildPath } else { [string]$target.msbuildPath }
        }
        # Also with -PackageFrom: the suite's PostRunChecks/JobChecks are scripts in the workspace repos.
        if (-not $WorkspaceRoot) { $WorkspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

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
        # Tower guard (AC2): from here (before the build) to the result fetch the tower must stay untouched and free of game
        # and launcher processes. Needs towerGamePath.
        $guard = $null
        if (-not [string]::IsNullOrWhiteSpace($towerGamePath)) {
            $guard = Start-RigTowerGuard -TowerGamePath $towerGamePath -DocumentsPath ([string]$target.towerDocumentsPath)
        }

        $jobId = New-RigJobId
        $jobDir = Join-Path (Join-Path $OutRoot 'jobs') $jobId
        $null = New-Item -ItemType Directory -Path $jobDir -Force
        $repos = @()
        if ($buildMode) {
            $stageDir = Join-Path (Join-Path $OutRoot 'stage') $jobId
            $build = Invoke-RigBuildPackage -WorkspaceRoot $WorkspaceRoot -StageDir $stageDir `
                -TowerGamePath ([string]$target.towerGamePath) -MsBuildPath $msbuildPath -Suite $Suite `
                -SuiteDefinition $(if ($Suite) { $script:RigSuites[$Suite] } else { $null })
            Write-RigMessage "build: staged in $stageDir; tower Modules unchanged"
            if ($null -ne $guard) { Update-RigTowerGuard -Guard $guard }
            Copy-Item -LiteralPath $build.ManifestPath -Destination (Join-Path $jobDir 'manifest.json') -ErrorAction Stop
            $repos = @($build.Repos)
            $PackageFrom = $stageDir
        }
        $pkg = New-RigPackage -PackageFrom $PackageFrom -ZipPath (Join-Path $jobDir 'package.zip')
        $manifest = New-RigJobManifest -JobId $jobId -CreatedUtc ([datetime]::UtcNow) -PackageSha256 $pkg.Sha256 `
            -Seed $Seed -Days $Days -Mode $Mode -StallMinutes $StallMinutes -BudgetMinutes $BudgetMinutes -HardTimeoutMinutes $HardTimeoutMinutes `
            -Repos $repos -Harness $Harness -Suite $Suite -ExpectedGameVersion $expectedGameVersion
        Write-RigJsonFile -Path (Join-Path $jobDir 'job.json') -InputObject $manifest

        Publish-Job -Target $target -JobId $jobId -JobDirectory $jobDir
        Write-RigMessage "jobId: $jobId"
        if (-not $Wait) { return (Close-RigTowerGuard -Guard $guard -Code 0 -Window 'until publish only, job not waited for') }

        $outcome = Wait-RigJob -Target $target -JobId $jobId -ClaimTimeoutSeconds $ClaimTimeoutSeconds -StaleSeconds $StaleSeconds `
            -OverallSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds -AbortWaitSeconds $AbortWaitSeconds `
            -RetryDelaySeconds $RetryDelaySeconds -MaxWithdrawAttempts $MaxWithdrawAttempts -TowerGuard $guard
        switch ($outcome) {
            'ClaimTimeout' { Write-RigMessage "ERROR: agent offline - job $jobId was not claimed within $ClaimTimeoutSeconds s and has been withdrawn."; return (Close-RigTowerGuard -Guard $guard -Code 3 -Window 'until the runner stopped waiting, no result fetched') }
            'WithdrawPending' {
                Write-RigMessage "ERROR: job $jobId was not claimed within $ClaimTimeoutSeconds s, but job.json could not be withdrawn after $MaxWithdrawAttempts attempts: job.json may still be pending on the test PC and the agent could still run it. Check $($target.remoteQueueRoot)\jobs\$jobId."
                return (Close-RigTowerGuard -Guard $guard -Code 3 -Window 'until the runner stopped waiting, no result fetched')
            }
            'StaleHeartbeat' {
                try { Send-JobAbort -Target $target -JobId $jobId } catch { Write-RigMessage "WARNING: could not send abort for job ${jobId}: $($_.Exception.Message)" }
                Write-RigMessage "ERROR: agent not responding - heartbeat of job $jobId did not change for $StaleSeconds s."
                return (Close-RigTowerGuard -Guard $guard -Code 3 -Window 'until the runner stopped waiting, no result fetched')
            }
            'Deadline' { Write-RigMessage "ERROR: overall timeout; abort sent for job $jobId but no done.json appeared within $AbortWaitSeconds s."; return (Close-RigTowerGuard -Guard $guard -Code 3 -Window 'until the runner stopped waiting, no result fetched') }
        }
        $forceTimeout = ($outcome -eq 'DeadlineDone')
        if ($forceTimeout) { Write-RigMessage "WARNING: overall timeout; job $jobId was aborted." }

        $localDir = Invoke-RigWithRetry -DelaySeconds $RetryDelaySeconds -Action {
            Receive-JobResult -Target $target -JobId $jobId -DestinationRoot (Join-Path $OutRoot 'results')
        }
        $towerGuard = if ($null -ne $guard) { Complete-RigTowerGuard -Guard $guard }   # after the fetch: the whole job is covered
        return (Publish-RigResult -ResultDir $localDir -JobId $jobId -Days $Days -Suite $Suite -TowerGamePath $towerGamePath `
                -ExpectedModules @($manifest.modules) -JobRuns @($manifest.runs) -WorkspaceRoot $WorkspaceRoot `
                -JobManifestPath (Join-Path $jobDir 'job.json') -TowerGuard $towerGuard -ForceTimeout:$forceTimeout)
    } catch {
        Write-RigMessage "ERROR: $($_.Exception.Message)"
        return 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'runner.config.json' }
    if ($Suite -and -not $script:RigSuites.ContainsKey($Suite)) {
        Write-RigMessage "ERROR: unknown -Suite '$Suite'. Valid suites: $((@($script:RigSuites.Keys) | Sort-Object) -join ', ')."
        exit 1
    }
    # The canonical spelling of the suite (the table key): the verdict compares suite names case-sensitively (-Suite l1 = L1).
    if ($Suite) { $Suite = Get-RigSuiteName $Suite }
    try {
        $settings = Resolve-RigSuiteSettings -Suite $Suite -BoundParameters @($PSBoundParameters.Keys) `
            -Harness $Harness -Mode $Mode -Seed $Seed -Days $Days
    } catch {
        Write-RigMessage "ERROR: $($_.Exception.Message)"
        exit 1
    }
    # A suite with Runs sets its own overall deadline (see Get-RigSuiteTimeoutMinutes) unless -TimeoutMinutes is given.
    if (@($PSBoundParameters.Keys) -notcontains 'TimeoutMinutes') {
        $suiteTimeout = Get-RigSuiteTimeoutMinutes -Suite $Suite -ClaimTimeoutSeconds $ClaimTimeoutSeconds -Days $settings.Days
        if ($null -ne $suiteTimeout) { $TimeoutMinutes = $suiteTimeout }
    }
    $code = Start-TestRigJob -PackageFrom $PackageFrom -Seed $settings.Seed -Days $settings.Days -Mode $settings.Mode `
        -StallMinutes $StallMinutes -BudgetMinutes $BudgetMinutes -HardTimeoutMinutes $HardTimeoutMinutes -Harness $settings.Harness -Suite $Suite `
        -ClaimTimeoutSeconds $ClaimTimeoutSeconds -TimeoutMinutes $TimeoutMinutes `
        -ConfigPath $ConfigPath -OutRoot (Join-Path (Split-Path -Parent $PSScriptRoot) 'out') `
        -WorkspaceRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -Wait:$Wait
    exit $code
}
