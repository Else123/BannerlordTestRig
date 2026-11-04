# Build step of the test rig runner: builds the mod projects (six plus the TailModules of the suite, only the
# harness for a suite without mods) into a staging folder, guards the
# tower (the game's own Modules folder) against changes and writes manifest.json.
# Functions only; dot-sourced by Invoke-TestRig.ps1 (and by tests\runner\Build-Package.Tests.ps1).

# Scenario module id -> @(repo, csproj relative to the repo) for the modules a suite lists in its TailModules (the suite
# table $script:RigSuites in Invoke-TestRig.ps1 is the single source of which suite ships which). A new scenario module
# is one entry here plus the TailModules entry of its suite. SmithingSuite.Scenarios is not listed: it is in the base set.
# TestRig.SelfTest holds deliberately crashing code: only the suite that lists it ships it.
$script:RigTailModuleProjects = @{
    'CoherentWarAI.Scenarios'          = @('BannerlordCoherentWarAI', 'tests\InGame\CoherentWarAI.Scenarios\CoherentWarAI.Scenarios.csproj')
    'AutoTraderSpeed.Scenarios'        = @('BannerlordAutoTrader', 'tests\InGame\AutoTraderSpeed.Scenarios\AutoTraderSpeed.Scenarios.csproj')
    'CompanionManagementSuite.Scenarios' = @('CompanionManagementSuite', 'tests\InGame\CompanionManagementSuite.Scenarios\CompanionManagementSuite.Scenarios.csproj')
    'TestRig.SelfTest'                 = @('BannerlordTestRig', 'src\TestRig.SelfTest\TestRig.SelfTest.csproj')
    'CrossMod.Scenarios'               = @('BannerlordTestRig', 'scenarios\CrossMod\CrossMod.Scenarios\CrossMod.Scenarios.csproj')
}

# The six base projects plus one per TailModules entry not already in the base set (a suite's scenario modules), relative
# to the workspace root (the folder that contains the repo folders), in build order: mods, harnesses, then the scenario
# modules in the order of $TailModules (each references its mod and the harness from the stage, so it comes after both).
# -HarnessOnly (a suite that loads no mod and no scenario module) builds only the harness. An unknown tail module throws.
function Get-RigBuildProjects {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [string[]]$TailModules = @(),
        [switch]$HarnessOnly
    )
    $table = @(
        @('BannerlordCoherentWarAI', 'src\CoherentWarAI\CoherentWarAI.csproj', 'CoherentWarAI'),
        @('BannerlordAutoTrader', 'AutoTrader\src\AutoTrader.csproj', 'AutoTraderSpeed'),
        @('BannerlordSmithingSuite', 'src\SmithingSuite.csproj', 'SmithingSuite'),
        @('CompanionManagementSuite', 'src\CompanionSuite.csproj', 'CompanionManagementSuite'),
        @('BannerlordTestRig', 'src\TestRig.Harness\TestRig.Harness.csproj', 'TestRig.Harness'),
        @('BannerlordSmithingSuite', 'tests\InGame\SmithingSuite.Scenarios\SmithingSuite.Scenarios.csproj', 'SmithingSuite.Scenarios')
    )
    foreach ($id in $TailModules) {
        if ($table | Where-Object { $_[2] -ceq $id }) { continue }   # already built (SmithingSuite.Scenarios)
        if (-not $script:RigTailModuleProjects.ContainsKey($id)) {
            throw "Unknown scenario module '$id' in TailModules: add it to `$script:RigTailModuleProjects in Build-Package.ps1."
        }
        $table += , @($script:RigTailModuleProjects[$id][0], $script:RigTailModuleProjects[$id][1], $id)
    }
    # The vanilla baseline loads no mod and no scenario module: only the harness is built (and so only its repo recorded).
    if ($HarnessOnly) { $table = @($table | Where-Object { $_[2] -ceq 'TestRig.Harness' }) }
    foreach ($row in $table) {
        [pscustomobject]@{
            Repo        = $row[0]
            ProjectPath = Join-Path (Join-Path $WorkspaceRoot $row[0]) $row[1]
            ModuleId    = $row[2]
        }
    }
}

# The build projects of a suite: its TailModules, and only the harness when the suite loads no mod and no scenario module
# (L1-BASE). Without a suite: the base set. The suite comes from -SuiteDefinition (its entry of the suite table) or else by
# name from the suite table $script:RigSuites, which only Invoke-TestRig.ps1 defines (this file alone has none: a clear
# error). Throws on an unknown suite.
function Get-RigSuiteBuildProjects {
    param([Parameter(Mandatory)][string]$WorkspaceRoot, [string]$Suite, [hashtable]$SuiteDefinition)
    if (-not $Suite -and $null -eq $SuiteDefinition) { return Get-RigBuildProjects -WorkspaceRoot $WorkspaceRoot }
    $s = $SuiteDefinition
    if ($null -eq $s) {
        if ($null -eq $script:RigSuites) {
            throw "Suite '$Suite': no suite table. Pass -SuiteDefinition, or dot-source Invoke-TestRig.ps1 (it defines `$script:RigSuites)."
        }
        if (-not $script:RigSuites.ContainsKey($Suite)) { throw "Unknown suite '$Suite'." }
        $s = $script:RigSuites[$Suite]
    }
    $tail = @($s.TailModules)
    $harnessOnly = -not $s.WithCoherentWarAI -and @($s.ExtraModules).Count -eq 0 -and $tail.Count -eq 0
    Get-RigBuildProjects -WorkspaceRoot $WorkspaceRoot -TailModules $tail -HarnessOnly:$harnessOnly
}

# MSBuild decodes %XX and splits property values on ';' and ',' - escape them (the '%' first).
function ConvertTo-RigMsBuildValue {
    param([Parameter(Mandatory)][string]$Value)
    $Value.Replace('%', '%25').Replace(';', '%3B').Replace(',', '%2C')
}

# Builds one project with the build landing in $ModulesPath (BannerlordModulesPath overrides the
# game-folder default of the projects' Directory.Build.props; BannerlordPath pins the game install the
# projects resolve their references against). None of the projects uses PackageReference or
# packages.config, so no /restore is needed. The output is appended to $LogPath when given and is
# otherwise not printed; on failure the exception message carries the output tail.
function Invoke-RigMsBuild {
    param(
        [Parameter(Mandatory)][string]$MsBuildPath,
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$ModulesPath,
        [string]$BannerlordPath,
        [string]$Configuration = 'Debug',
        [string]$LogPath
    )
    # Separate array elements: Windows PowerShell 5.1 would drop embedded quotes of a hand-built string.
    $msbuildArgs = @(
        '/nologo', '/v:minimal',
        "/p:Configuration=$Configuration", '/p:Platform=x64',
        ('/p:BannerlordModulesPath=' + (ConvertTo-RigMsBuildValue $ModulesPath))
    )
    if ($BannerlordPath) { $msbuildArgs += '/p:BannerlordPath=' + (ConvertTo-RigMsBuildValue $BannerlordPath) }
    $msbuildArgs += $ProjectPath
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # native stderr must not turn into a terminating error
    try {
        $output = @(& $MsBuildPath @msbuildArgs 2>&1 | ForEach-Object { "$_" })
        $exit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    if ($LogPath) {
        $header = "=== $(Split-Path -Leaf $ProjectPath) (exit $exit) ==="
        Add-Content -LiteralPath $LogPath -Value (@($header) + $output) -Encoding UTF8 -ErrorAction Stop
    }
    if ($exit -ne 0) {
        $tail = ($output | Select-Object -Last 30) -join "`n"
        throw "MSBuild failed for $(Split-Path -Leaf $ProjectPath) (exit $exit):`n$tail"
    }
}

# Runs git and returns its stdout lines; stderr (traces, warnings) is kept apart and only used in the error.
function Invoke-RigGit {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$GitArgs
    )
    $errFile = [IO.Path]::GetTempFileName()
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $stdout = @(& git -C $RepoPath @GitArgs 2>$errFile)
        $exit = $LASTEXITCODE
        $stderr = [IO.File]::ReadAllText($errFile)
    } finally {
        $ErrorActionPreference = $old
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
    if ($exit -ne 0) { throw "git $($GitArgs -join ' ') failed in ${RepoPath} (exit $exit): $($stderr.Trim())" }
    $stdout
}

# Folder name, full HEAD sha and dirty flag (any uncommitted or untracked change) of a git repo.
function Get-RigRepoState {
    param([Parameter(Mandatory)][string]$RepoPath)
    $sha = ([string](Invoke-RigGit -RepoPath $RepoPath -GitArgs @('rev-parse', 'HEAD') | Select-Object -First 1)).Trim()
    if ($sha -cnotmatch '^[0-9a-f]{40}$') { throw "git rev-parse HEAD in $RepoPath did not return a sha: '$sha'" }
    $status = @(Invoke-RigGit -RepoPath $RepoPath -GitArgs @('status', '--porcelain') | Where-Object { "$_".Trim() })
    [pscustomobject]@{
        name  = Split-Path -Leaf $RepoPath.TrimEnd('\', '/')
        sha   = $sha
        dirty = [bool]($status.Count -gt 0)
    }
}

# Relative path ('/' separated) -> "d" for folders or "f|<length>|<LastWriteTimeUtc ticks>" for files.
# Fails closed: an unreadable subtree or a reparse point (junction/symlink, whose target would go
# unwatched) throws instead of being skipped.
function Get-RigModulesSnapshot {
    param([Parameter(Mandatory)][string]$Path)
    $root = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
    $snapshot = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($item in (Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point (junction or symlink) in snapshot tree: $($item.FullName)" }
        $rel = $item.FullName.Substring($root.Length + 1) -replace '\\', '/'
        $snapshot[$rel] = if ($item.PSIsContainer) { 'd' } else { 'f|{0}|{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks }
    }
    $snapshot
}

# Paths that were added, removed or changed between two snapshots (ordinal sorted; empty if equal).
function Compare-RigModulesSnapshot {
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After
    )
    $changed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in $Before.Keys) {
        if (-not $After.ContainsKey($key) -or $After[$key] -cne $Before[$key]) { $changed.Add($key) }
    }
    foreach ($key in $After.Keys) {
        if (-not $Before.ContainsKey($key)) { $changed.Add($key) }
    }
    $changed.Sort([StringComparer]::Ordinal)
    $changed.ToArray()
}

# Tower guard (AC2 of TESTRIG-SPEC): over a whole job no game or launcher process runs on the tower and neither
# <game>\Modules nor the Documents folder of the game changes. Outcome: RigError (1) = Modules changed; Inconclusive (3) =
# Documents changed, or a game or launcher process was seen (at the job start or later): the launcher and Steam cloud write
# to Documents too (measured: Configs\LauncherData.xml, Configs\NewsFeedConfig.xml, Game Saves\steam_autocloud.vdf), so such
# a change cannot be attributed to the rig and AC2 is neither met nor refuted; Passed (0) otherwise.

# Ids of the processes on this machine (the tower) whose executable lies below $GameBinPath (<game>\bin: Bannerlord.exe,
# Bannerlord.Native.exe, the launcher, wrappers such as BLSE). A process whose path cannot be read (protected or gone) is
# skipped. A function of its own so tests can stand in for it.
function Get-RigTowerGameProcessId {
    param([Parameter(Mandatory)][string]$GameBinPath)
    $prefix = $GameBinPath.TrimEnd('\', '/') + '\'
    [int[]]@(Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            $path = $null
            try { $path = $_.Path } catch { }
            if ($path -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $_.Id }
        })
}

# The tower's Documents folder of the game: the configured path, else <user's Documents>\Mount and Blade II Bannerlord.
function Get-RigTowerDocumentsPath {
    param([string]$ConfiguredPath)
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) { return $ConfiguredPath }
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Mount and Blade II Bannerlord'
}

# Like Get-RigModulesSnapshot, but a folder that does not exist is an empty tree (the game never wrote its Documents
# folder yet; its later creation is then a change).
function Get-RigGuardSnapshot {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return (New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal))
    }
    Get-RigModulesSnapshot -Path $Path
}

# Takes the "before" state: both snapshots and the running game processes. Throws (fail closed) when a tree cannot be
# snapshotted or a configured $DocumentsPath does not exist (only the default Documents folder may be absent: the game
# never ran for this user yet; it is then an empty tree).
function Start-RigTowerGuard {
    param(
        [Parameter(Mandatory)][string]$TowerGamePath,
        [string]$DocumentsPath
    )
    $towerGame = $TowerGamePath.TrimEnd('\', '/')
    $modulesPath = Join-Path $towerGame 'Modules'
    $watchedDocuments = Get-RigTowerDocumentsPath -ConfiguredPath $DocumentsPath
    $documentsExist = Test-Path -LiteralPath $watchedDocuments -PathType Container
    if (-not $documentsExist -and -not [string]::IsNullOrWhiteSpace($DocumentsPath)) {
        throw "tower guard: towerDocumentsPath not found: $watchedDocuments"
    }
    $snapshot = {
        param([string]$Path)
        try { Get-RigGuardSnapshot -Path $Path } catch { throw "tower guard: cannot watch ${Path}: $($_.Exception.Message)" }
    }
    $binPath = Join-Path $towerGame 'bin'
    [pscustomobject]@{
        ModulesPath           = $modulesPath
        DocumentsPath         = $watchedDocuments
        GameBinPath           = $binPath
        DocumentsAbsentAtStart = (-not $documentsExist)
        ModulesBefore         = & $snapshot $modulesPath
        DocumentsBefore       = & $snapshot $watchedDocuments
        StartProcessIds       = [int[]]@(Get-RigTowerGameProcessId -GameBinPath $binPath)
        StartedDuringJob      = $false
    }
}

# Samples the game and launcher processes (cheap; called while the job is waited for): one that was not there at the start sets StartedDuringJob.
function Update-RigTowerGuard {
    param([Parameter(Mandatory)]$Guard)
    foreach ($id in @(Get-RigTowerGameProcessId -GameBinPath $Guard.GameBinPath)) {
        if ($Guard.StartProcessIds -notcontains $id) { $Guard.StartedDuringJob = $true }
    }
}

# Joins a list of changed paths for a message: the first 20, then "(and N more)".
function Format-RigGuardPaths {
    param([string[]]$Paths)
    $shown = (@($Paths) | Select-Object -First 20) -join ', '
    $more = if (@($Paths).Count -gt 20) { " (and $(@($Paths).Count - 20) more)" } else { '' }
    "$shown$more"
}

# Takes the "after" state and judges. Returns the record written to job-result.json as 'towerGuard':
# outcome, detail (the console text), window (what the guard covered when that is less than the whole job, else $null),
# gameRunningAtStart, gameStartedDuringJob, modulesChanged[], documentsChanged[].
# $Window names that shorter window (e.g. "until publish only, job not waited for"). A snapshot that cannot be taken
# gives a RigError record instead of throwing, so the job result is still written.
function Complete-RigTowerGuard {
    param([Parameter(Mandatory)]$Guard, [string]$Window)
    $atStart = ($Guard.StartProcessIds.Count -gt 0)
    $windowValue = if ([string]::IsNullOrWhiteSpace($Window)) { $null } else { $Window }
    $path = $Guard.ModulesPath
    try {
        Update-RigTowerGuard -Guard $Guard
        $modulesChanged = [string[]]@(Compare-RigModulesSnapshot -Before $Guard.ModulesBefore -After (Get-RigGuardSnapshot -Path $path))
        $path = $Guard.DocumentsPath
        $documentsChanged = [string[]]@(Compare-RigModulesSnapshot -Before $Guard.DocumentsBefore -After (Get-RigGuardSnapshot -Path $path))
    } catch {
        return [ordered]@{
            outcome              = 'RigError'
            detail               = "tower guard could not snapshot ${path}: $($_.Exception.Message)"
            window               = $windowValue
            gameRunningAtStart   = $atStart
            gameStartedDuringJob = [bool]$Guard.StartedDuringJob
            modulesChanged       = [string[]]@()
            documentsChanged     = [string[]]@()
        }
    }
    $during = [bool]$Guard.StartedDuringJob
    $gameSeen = $atStart -or $during

    $outcome = if ($modulesChanged.Count -gt 0) { 'RigError' }
    elseif ($documentsChanged.Count -gt 0 -or $gameSeen) { 'Inconclusive' }
    else { 'Passed' }

    $parts = @()
    if ($modulesChanged.Count -gt 0) { $parts += "tower Modules changed: $(Format-RigGuardPaths $modulesChanged)" }
    if ($documentsChanged.Count -gt 0) {
        $parts += $(if ($gameSeen) { "tower Documents changed: $(Format-RigGuardPaths $documentsChanged)" } else { "unattributed Documents change: $(Format-RigGuardPaths $documentsChanged)" })
    }
    if ($atStart) { $parts += 'a game or launcher process was running at job start' }
    if ($during) { $parts += 'a game or launcher process started on the tower during the job' }
    if ($outcome -ceq 'Passed') {
        $parts = @('no game or launcher process seen on the tower; tower Modules and Documents unchanged')
    } elseif ($outcome -ceq 'Inconclusive') {
        if ($documentsChanged.Count -gt 0) {
            $parts += $(if ($gameSeen) { 'Documents changes cannot be attributed to the rig' } else { 'no process seen, so the launcher or Steam cloud may have written there (not attributable to the rig)' })
        } else {
            $parts += 'tower Modules and Documents unchanged'
        }
        $parts += 'AC2 not demonstrable; repeat the job with the game and launcher closed on the tower'
    }
    if ($Guard.DocumentsAbsentAtStart) { $parts += '(Documents folder absent at start)' }
    [ordered]@{
        outcome              = $outcome
        detail               = $parts -join '; '
        window               = $windowValue
        gameRunningAtStart   = $atStart
        gameStartedDuringJob = $during
        modulesChanged       = $modulesChanged
        documentsChanged     = $documentsChanged
    }
}

# Writes <StageDir>\manifest.json (UTF-8 without BOM): repo states plus, per Modules\<id> folder,
# the SubModule.xml version and every file with its SHA-256. Returns the manifest path.
function New-RigBuildManifest {
    param(
        [Parameter(Mandatory)][string]$StageDir,
        [Parameter(Mandatory)][object[]]$Repos
    )
    $root = (Resolve-Path -LiteralPath $StageDir).ProviderPath.TrimEnd('\')
    $modulesDir = Join-Path $root 'Modules'

    $modules = New-Object 'System.Collections.Generic.List[object]'
    $moduleDirs = New-Object 'System.Collections.Generic.List[IO.DirectoryInfo]'
    $moduleDirs.AddRange([IO.DirectoryInfo[]]@(Get-ChildItem -LiteralPath $modulesDir -Directory -Force -ErrorAction Stop))
    $moduleDirs.Sort([Comparison[IO.DirectoryInfo]] { param($a, $b) [string]::CompareOrdinal($a.Name, $b.Name) })
    foreach ($dir in $moduleDirs) {
        $version = $null
        $subModule = Join-Path $dir.FullName 'SubModule.xml'
        if (Test-Path -LiteralPath $subModule -PathType Leaf) {
            $xml = New-Object Xml.XmlDocument
            $xml.Load($subModule)
            $node = $xml.SelectSingleNode('/Module/Version')
            if ($node -and $node.HasAttribute('value')) { $version = $node.GetAttribute('value') }
        }
        $files = New-Object 'System.Collections.Generic.List[object]'
        foreach ($f in (Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Force -ErrorAction Stop)) {
            $files.Add([ordered]@{
                    path   = ($f.FullName.Substring($root.Length + 1) -replace '\\', '/')
                    sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                })
        }
        $files.Sort([Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a['path'], $b['path']) })
        $modules.Add([ordered]@{ id = $dir.Name; version = $version; files = $files.ToArray() })
    }

    $manifest = [ordered]@{
        schema  = 1
        repos   = @($Repos | ForEach-Object { [ordered]@{ name = $_.name; sha = $_.sha; dirty = $_.dirty } })
        modules = $modules.ToArray()
    }
    $path = Join-Path $StageDir 'manifest.json'
    $json = ConvertTo-Json -InputObject $manifest -Depth 10
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
    $path
}

# Builds the projects of Get-RigBuildProjects into <StageDir>\Modules against the game install at $TowerGamePath, verifies
# that <TowerGamePath>\Modules is untouched and that every module landed in the stage, then writes the
# manifest. Throws on a missing prerequisite, a failed build, an incomplete stage or a tower change (no
# manifest is written then). The MSBuild output goes to <StageDir>\build.log.
# Returns StageDir, ManifestPath and the per-repo states.
function Invoke-RigBuildPackage {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$StageDir,
        [Parameter(Mandatory)][string]$TowerGamePath,
        [Parameter(Mandatory)][string]$MsBuildPath,
        [string]$Configuration = 'Debug',
        [string]$Suite,
        [hashtable]$SuiteDefinition   # the suite's entry of the suite table (see Get-RigSuiteBuildProjects)
    )
    $towerGame = $TowerGamePath.TrimEnd('\', '/')   # a trailing '\' would escape the closing quote in the MSBuild argument
    $towerModules = Join-Path $towerGame 'Modules'
    if (-not (Test-Path -LiteralPath $towerModules -PathType Container)) {
        throw "Tower Modules folder not found: $towerModules"
    }
    if (-not (Test-Path -LiteralPath $MsBuildPath -PathType Leaf)) {
        throw "MSBuild not found: $MsBuildPath"
    }

    $projects = @(Get-RigSuiteBuildProjects -WorkspaceRoot $WorkspaceRoot -Suite $Suite -SuiteDefinition $SuiteDefinition)
    # State of the sources as built (taken before the build, so build output cannot show up as dirty).
    $repos = @($projects | ForEach-Object { $_.Repo } | Select-Object -Unique | ForEach-Object {
            Get-RigRepoState -RepoPath (Join-Path $WorkspaceRoot $_)
        })

    $towerBefore = Get-RigModulesSnapshot -Path $towerModules
    $modulesDir = Join-Path $StageDir 'Modules'
    $null = New-Item -ItemType Directory -Path $modulesDir -Force -ErrorAction Stop
    $logPath = Join-Path $StageDir 'build.log'
    foreach ($p in $projects) {
        Invoke-RigMsBuild -MsBuildPath $MsBuildPath -ProjectPath $p.ProjectPath -ModulesPath $modulesDir `
            -BannerlordPath $towerGame -Configuration $Configuration -LogPath $logPath
    }

    $changes = @(Compare-RigModulesSnapshot -Before $towerBefore -After (Get-RigModulesSnapshot -Path $towerModules))
    if ($changes.Count -gt 0) {
        throw "tower Modules changed during the build: $(Format-RigGuardPaths $changes)"
    }

    # An MSBuild exit code of 0 does not prove the module was staged (e.g. a project that ignores the output path).
    foreach ($p in $projects) {
        $moduleDir = Join-Path $modulesDir $p.ModuleId
        $dlls = @(Get-ChildItem -LiteralPath (Join-Path $moduleDir 'bin\Win64_Shipping_Client') -Filter '*.dll' -File -ErrorAction SilentlyContinue)
        if (-not (Test-Path -LiteralPath (Join-Path $moduleDir 'SubModule.xml') -PathType Leaf) -or $dlls.Count -eq 0) {
            throw "Module '$($p.ModuleId)' is incomplete in the stage (needs SubModule.xml and a dll in bin\Win64_Shipping_Client): $moduleDir"
        }
    }

    $manifestPath = New-RigBuildManifest -StageDir $StageDir -Repos $repos
    [pscustomobject]@{ StageDir = $StageDir; ManifestPath = $manifestPath; Repos = $repos }
}
