# Run:  powershell -NoProfile -Command "Invoke-Pester <repo>\tests\runner\Build-Package.Tests.ps1"
# Pester 3.4 / Windows PowerShell 5.1. A fake MSBuild (cmd -> fake-msbuild.ps1) stands in for the real one;
# behaviour is steered through environment variables (inherited by the child process).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:buildScript = Join-Path $here '..\..\runner\Build-Package.ps1'
# Guarded so a missing file shows up as one red test per It (not as a crashed test file).
if (Test-Path -LiteralPath $script:buildScript) { . $script:buildScript }

function New-TempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('rigbuild-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    $d
}

# Deletes a fixture folder, also when it holds paths longer than MAX_PATH or junctions.
function Remove-TestDir([string]$Path) {
    try { [IO.Directory]::Delete('\\?\' + $Path, $true) } catch { }
}

# Creates <Root>\...\deep.dll below a path of 330+ chars (only reachable through the \\?\ prefix).
function New-LongPathFile([string]$Root) {
    $dir = $Root
    while ($dir.Length -lt 330) { $dir = Join-Path $dir ('d' * 40) }
    $null = [IO.Directory]::CreateDirectory('\\?\' + $dir)
    [IO.File]::WriteAllText('\\?\' + (Join-Path $dir 'deep.dll'), 'x')
}

function Invoke-Git([string]$Repo, [string[]]$GitArgs) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git -C $Repo -c user.name=tester -c user.email=tester@example.invalid @GitArgs 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
}

function New-GitRepo([string]$Path, [string[]]$Files) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Invoke-Git $Path @('init', '-q')
    foreach ($f in $Files) {
        $full = Join-Path $Path $f
        New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
        New-Item -ItemType File -Path $full -Force | Out-Null
    }
    Invoke-Git $Path @('add', '--all')
    Invoke-Git $Path @('commit', '-q', '-m', 'init')
}

# Seven project paths relative to the workspace root, in the order of the contract table.
$script:projects = @(
    @{ Repo = 'BannerlordCoherentWarAI'; Rel = 'src\CoherentWarAI\CoherentWarAI.csproj'; Id = 'CoherentWarAI' },
    @{ Repo = 'BannerlordCoherentWarAI'; Rel = 'tools\TestHarness\CoherentWarAI.TestHarness.csproj'; Id = 'CoherentWarAI.TestHarness' },
    @{ Repo = 'BannerlordAutoTrader'; Rel = 'AutoTrader\src\AutoTrader.csproj'; Id = 'AutoTraderSpeed' },
    @{ Repo = 'BannerlordSmithingSuite'; Rel = 'src\SmithingSuite.csproj'; Id = 'SmithingSuite' },
    @{ Repo = 'CompanionManagementSuite'; Rel = 'src\CompanionSuite.csproj'; Id = 'CompanionManagementSuite' },
    @{ Repo = 'BannerlordTestRig'; Rel = 'src\TestRig.Harness\TestRig.Harness.csproj'; Id = 'TestRig.Harness' },
    @{ Repo = 'BannerlordSmithingSuite'; Rel = 'tests\InGame\SmithingSuite.Scenarios\SmithingSuite.Scenarios.csproj'; Id = 'SmithingSuite.Scenarios' }
)

function New-FakeWorkspace([string]$Root) {
    foreach ($repo in ($script:projects | ForEach-Object { $_.Repo } | Select-Object -Unique)) {
        $files = @($script:projects | Where-Object { $_.Repo -eq $repo } | ForEach-Object { $_.Rel })
        New-GitRepo (Join-Path $Root $repo) $files
    }
}

# Fake MSBuild. Env vars: RIG_FAKE_LOG (append the argument line), RIG_FAKE_FAIL (csproj file name that exits 1),
# RIG_FAKE_SKIP (csproj file name for which nothing is written, exit 0), RIG_FAKE_NODLL (csproj file name that gets
# SubModule.xml but no dll),
# RIG_FAKE_TOWER (folder that additionally receives a stray module folder, simulating a build that touches the game).
function New-FakeMsBuild([string]$Dir) {
    $ps1 = @'
$argLine = $args -join ' '
if ($env:RIG_FAKE_LOG) { Add-Content -LiteralPath $env:RIG_FAKE_LOG -Value $argLine }
$proj = @($args | Where-Object { $_ -like '*.csproj' })[0]
$modules = $null
foreach ($a in $args) { if ($a -like '/p:BannerlordModulesPath=*') { $modules = $a.Substring('/p:BannerlordModulesPath='.Length).Trim('"') } }
$name = [IO.Path]::GetFileName($proj)
if ($env:RIG_FAKE_FAIL -and $name -eq $env:RIG_FAKE_FAIL) { Write-Output "error MSB9999: fake failure in $name"; exit 1 }
$ids = @{
    'CoherentWarAI.csproj' = 'CoherentWarAI'; 'CoherentWarAI.TestHarness.csproj' = 'CoherentWarAI.TestHarness'; 'TestRig.Harness.csproj' = 'TestRig.Harness'
    'AutoTrader.csproj' = 'AutoTraderSpeed'; 'SmithingSuite.csproj' = 'SmithingSuite'; 'CompanionSuite.csproj' = 'CompanionManagementSuite'
    'SmithingSuite.Scenarios.csproj' = 'SmithingSuite.Scenarios'; 'TestRig.SelfTest.csproj' = 'TestRig.SelfTest'
}
$id = $ids[$name]
if (-not $id -or -not $modules) { Write-Output "fake msbuild: bad arguments: $argLine"; exit 2 }
if ($env:RIG_FAKE_SKIP -and $name -eq $env:RIG_FAKE_SKIP) { Write-Output "fake msbuild: wrote nothing for $name"; exit 0 }
foreach ($root in @($modules, $env:RIG_FAKE_TOWER)) {
    if (-not $root) { continue }
    $bin = Join-Path $root "$id\bin\Win64_Shipping_Client"
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    if (-not ($env:RIG_FAKE_NODLL -and $name -eq $env:RIG_FAKE_NODLL)) { Set-Content -LiteralPath (Join-Path $bin "$id.dll") -Value "dll $id" }
    Set-Content -LiteralPath (Join-Path $root "$id\SubModule.xml") -Value "<Module><Name value=`"$id`"/><Version value=`"v1.2.3`"/></Module>"
}
Write-Output "fake msbuild ok: $name"
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $Dir 'fake-msbuild.ps1'), $ps1, (New-Object Text.UTF8Encoding($false)))
    $cmd = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-msbuild.ps1`" %*`r`nexit /b %errorlevel%`r`n"
    $p = Join-Path $Dir 'fake-msbuild.cmd'
    [IO.File]::WriteAllText($p, $cmd, [Text.Encoding]::ASCII)
    $p
}

# Relative paths compare independent of the separator the implementation chooses.
function ConvertTo-Slash($Paths) { @($Paths | ForEach-Object { ([string]$_) -replace '\\', '/' }) }

Describe 'Get-RigBuildProjects' {
    It 'returns the seven projects with repo, absolute path and module id' {
        $r = Get-RigBuildProjects -WorkspaceRoot 'C:\ws'
        @($r).Count | Should Be 7
        foreach ($p in $script:projects) {
            $hit = @($r | Where-Object { $_.ModuleId -eq $p.Id })
            $hit.Count | Should Be 1
            $hit[0].Repo | Should Be $p.Repo
            $hit[0].ProjectPath | Should Be (Join-Path (Join-Path 'C:\ws' $p.Repo) $p.Rel)
            [IO.Path]::IsPathRooted($hit[0].ProjectPath) | Should Be $true
        }
    }
    It 'orders the scenario project after the harness and the mod (build order mod -> harness -> scenarios)' {
        $ids = @(Get-RigBuildProjects -WorkspaceRoot 'C:\ws' | ForEach-Object { $_.ModuleId })
        $iScen = [array]::IndexOf($ids, 'SmithingSuite.Scenarios')
        $iScen | Should BeGreaterThan -1
        $iScen | Should BeGreaterThan ([array]::IndexOf($ids, 'TestRig.Harness'))
        $iScen | Should BeGreaterThan ([array]::IndexOf($ids, 'SmithingSuite'))
    }
    It 'adds TestRig.SelfTest (repo BannerlordTestRig) after the harness only for -Suite RIG' {
        foreach ($s in @($null, '', 'L1', 'SM')) {
            @(Get-RigBuildProjects -WorkspaceRoot 'C:\ws' -Suite $s).Count | Should Be 7
            @(Get-RigBuildProjects -WorkspaceRoot 'C:\ws' -Suite $s | Where-Object { $_.ModuleId -eq 'TestRig.SelfTest' }).Count | Should Be 0
        }
        $r = @(Get-RigBuildProjects -WorkspaceRoot 'C:\ws' -Suite RIG)
        $r.Count | Should Be 8
        $hit = @($r | Where-Object { $_.ModuleId -eq 'TestRig.SelfTest' })
        $hit.Count | Should Be 1
        $hit[0].Repo | Should Be 'BannerlordTestRig'
        $hit[0].ProjectPath | Should Be (Join-Path 'C:\ws\BannerlordTestRig' 'src\TestRig.SelfTest\TestRig.SelfTest.csproj')
        $ids = @($r | ForEach-Object { $_.ModuleId })
        [array]::IndexOf($ids, 'TestRig.SelfTest') | Should BeGreaterThan ([array]::IndexOf($ids, 'TestRig.Harness'))
    }
}

Describe 'Invoke-RigMsBuild' {
    BeforeAll {
        $script:t = New-TempDir
        $script:fake = New-FakeMsBuild $script:t
        $script:proj = Join-Path $script:t 'SmithingSuite.csproj'
        New-Item -ItemType File -Path $script:proj | Out-Null
    }
    AfterAll { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:log = Join-Path $script:t ('log-' + [guid]::NewGuid().ToString('N') + '.txt')
        $env:RIG_FAKE_LOG = $script:log
        $env:RIG_FAKE_FAIL = ''
        $env:RIG_FAKE_TOWER = ''
        $script:mods = Join-Path $script:t ('Modules-' + [guid]::NewGuid().ToString('N'))
    }
    AfterEach { $env:RIG_FAKE_LOG = ''; $env:RIG_FAKE_FAIL = '' }

    It 'passes BannerlordPath when given' {
        Invoke-RigMsBuild -MsBuildPath $script:fake -ProjectPath $script:proj -ModulesPath $script:mods -BannerlordPath 'C:\Games\Bannerlord' | Out-Null
        (Get-Content -LiteralPath $script:log) -join "`n" | Should Match '/p:BannerlordPath=C:\\Games\\Bannerlord'
    }

    It 'escapes % ; and , in the property values (MSBuild decodes %XX and splits on ; and ,)' {
        $mods = Join-Path $script:t 'a%41;b,c'
        $game = Join-Path $script:t 'g%41;h,i'
        Invoke-RigMsBuild -MsBuildPath $script:fake -ProjectPath $script:proj -ModulesPath $mods -BannerlordPath $game | Out-Null
        $line = (Get-Content -LiteralPath $script:log) -join "`n"
        $line.Contains('/p:BannerlordModulesPath=' + $script:t + '\a%2541%3Bb%2Cc') | Should Be $true
        $line.Contains('/p:BannerlordPath=' + $script:t + '\g%2541%3Bh%2Ci') | Should Be $true
    }

    It 'appends the output to -LogPath and prints nothing on success' {
        $logPath = Join-Path $script:t ('build-' + [guid]::NewGuid().ToString('N') + '.log')
        $r = @(Invoke-RigMsBuild -MsBuildPath $script:fake -ProjectPath $script:proj -ModulesPath $script:mods -LogPath $logPath)
        $r.Count | Should Be 0
        Invoke-RigMsBuild -MsBuildPath $script:fake -ProjectPath $script:proj -ModulesPath $script:mods -LogPath $logPath | Out-Null
        $text = [IO.File]::ReadAllText($logPath)
        ([regex]::Matches($text, 'fake msbuild ok: SmithingSuite\.csproj')).Count | Should Be 2
    }

    It 'passes Configuration (default Debug), Platform x64 and BannerlordModulesPath, and the build lands in ModulesPath' {
        Invoke-RigMsBuild -MsBuildPath $script:fake -ProjectPath $script:proj -ModulesPath $script:mods | Out-Null
        $line = (Get-Content -LiteralPath $script:log) -join "`n"
        $line | Should Match '/p:Configuration=Debug'
        $line | Should Match '/p:Platform=x64'
        $line.Contains('/p:BannerlordModulesPath=' + $script:mods) | Should Be $true
        $line.Contains('SmithingSuite.csproj') | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:mods 'SmithingSuite\SubModule.xml') | Should Be $true
    }

    It 'honours -Configuration' {
        Invoke-RigMsBuild -MsBuildPath $script:fake -ProjectPath $script:proj -ModulesPath $script:mods -Configuration Release | Out-Null
        (Get-Content -LiteralPath $script:log) -join "`n" | Should Match '/p:Configuration=Release'
    }

    It 'throws naming the project when the exit code is not 0' {
        $env:RIG_FAKE_FAIL = 'SmithingSuite.csproj'
        { Invoke-RigMsBuild -MsBuildPath $script:fake -ProjectPath $script:proj -ModulesPath $script:mods } | Should Throw 'SmithingSuite.csproj'
    }
}

Describe 'Get-RigRepoState' {
    BeforeEach { $script:t = New-TempDir; $script:repo = Join-Path $script:t 'my-repo'; New-GitRepo $script:repo @('a.txt') }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reports folder name, full HEAD sha and dirty=false for a clean tree' {
        $s = Get-RigRepoState -RepoPath $script:repo
        $s.name | Should Be 'my-repo'
        $s.sha | Should Match '^[0-9a-f]{40}$'
        $s.sha | Should Be ((& git -C $script:repo rev-parse HEAD) | Select-Object -First 1).Trim()
        $s.dirty | Should Be $false
        ($s.dirty -is [bool]) | Should Be $true
    }
    It 'ignores git stderr noise (GIT_TRACE) when reading sha and dirty' {
        $env:GIT_TRACE = '1'
        try { $s = Get-RigRepoState -RepoPath $script:repo } finally { Remove-Item Env:\GIT_TRACE -ErrorAction SilentlyContinue }
        $s.sha | Should Match '^[0-9a-f]{40}$'
        $s.dirty | Should Be $false
    }
    It 'dirty=true with an untracked file' {
        Set-Content -LiteralPath (Join-Path $script:repo 'new.txt') -Value 'x'
        (Get-RigRepoState -RepoPath $script:repo).dirty | Should Be $true
    }
    It 'dirty=true with a modified tracked file' {
        Set-Content -LiteralPath (Join-Path $script:repo 'a.txt') -Value 'changed'
        (Get-RigRepoState -RepoPath $script:repo).dirty | Should Be $true
    }
}

Describe 'Get-RigModulesSnapshot / Compare-RigModulesSnapshot' {
    BeforeEach {
        $script:t = New-TempDir
        New-Item -ItemType Directory -Path (Join-Path $script:t 'Native\bin') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:t 'Native\bin\a.dll') -Value 'a'
        Set-Content -LiteralPath (Join-Path $script:t 'Native\SubModule.xml') -Value 'x'
    }
    AfterEach { Remove-TestDir $script:t }

    It 'throws instead of silently skipping a subtree below a path longer than MAX_PATH' {
        New-LongPathFile (Join-Path $script:t 'Native\deepdir')
        { Get-RigModulesSnapshot -Path $script:t } | Should Throw
    }
    It 'throws naming a junction (reparse points are not followed, so changes behind them would go unseen)' {
        $target = Join-Path $script:t 'elsewhere'
        New-Item -ItemType Directory -Path $target | Out-Null
        $link = Join-Path $script:t 'Native\link'
        cmd /c mklink /J "$link" "$target" | Out-Null
        $msg = $null
        try { Get-RigModulesSnapshot -Path $script:t | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should Not BeNullOrEmpty
        $msg.Contains($link) | Should Be $true
    }
    It 'an unchanged tree compares equal (empty result)' {
        $a = Get-RigModulesSnapshot -Path $script:t
        $b = Get-RigModulesSnapshot -Path $script:t
        @(Compare-RigModulesSnapshot -Before $a -After $b).Count | Should Be 0
    }
    It 'detects an added file' {
        $a = Get-RigModulesSnapshot -Path $script:t
        Set-Content -LiteralPath (Join-Path $script:t 'Native\bin\new.dll') -Value 'n'
        $d = ConvertTo-Slash (Compare-RigModulesSnapshot -Before $a -After (Get-RigModulesSnapshot -Path $script:t))
        ($d -contains 'Native/bin/new.dll') | Should Be $true
    }
    It 'detects a removed file' {
        $a = Get-RigModulesSnapshot -Path $script:t
        Remove-Item -LiteralPath (Join-Path $script:t 'Native\bin\a.dll')
        $d = ConvertTo-Slash (Compare-RigModulesSnapshot -Before $a -After (Get-RigModulesSnapshot -Path $script:t))
        ($d -contains 'Native/bin/a.dll') | Should Be $true
    }
    It 'detects a changed LastWriteTime' {
        $f = Join-Path $script:t 'Native\SubModule.xml'
        (Get-Item -LiteralPath $f).LastWriteTimeUtc = [datetime]'2026-01-01T00:00:00Z'
        $a = Get-RigModulesSnapshot -Path $script:t
        (Get-Item -LiteralPath $f).LastWriteTimeUtc = [datetime]'2026-01-02T00:00:00Z'
        $d = ConvertTo-Slash (Compare-RigModulesSnapshot -Before $a -After (Get-RigModulesSnapshot -Path $script:t))
        ($d -contains 'Native/SubModule.xml') | Should Be $true
    }
    It 'also snapshots directories (an added empty folder is a change)' {
        $a = Get-RigModulesSnapshot -Path $script:t
        New-Item -ItemType Directory -Path (Join-Path $script:t 'StrayModule') | Out-Null
        $d = ConvertTo-Slash (Compare-RigModulesSnapshot -Before $a -After (Get-RigModulesSnapshot -Path $script:t))
        ($d -contains 'StrayModule') | Should Be $true
    }
}

Describe 'New-RigBuildManifest' {
    BeforeEach {
        $script:t = New-TempDir
        $m = Join-Path $script:t 'Modules'
        New-Item -ItemType Directory -Path (Join-Path $m 'ModA') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $m 'ModB') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $m 'ModA\SubModule.xml') -Value '<Module><Name value="A"/><Version value="v1.2.3"/></Module>'
        Set-Content -LiteralPath (Join-Path $m 'ModA\Zeta.dll') -Value 'zeta'
        Set-Content -LiteralPath (Join-Path $m 'ModA\Beta.dll') -Value 'beta'
        Set-Content -LiteralPath (Join-Path $m 'ModB\SubModule.xml') -Value '<Module><Name value="B"/></Module>'
        $script:repos = @([pscustomobject]@{ name = 'RepoOne'; sha = ('a' * 40); dirty = $false })
        $script:path = New-RigBuildManifest -StageDir $script:t -Repos $script:repos
        $script:text = [IO.File]::ReadAllText($script:path, [Text.Encoding]::UTF8)
        $script:o = $script:text | ConvertFrom-Json
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes <StageDir>\manifest.json and returns its path' {
        $script:path | Should Be (Join-Path $script:t 'manifest.json')
        Test-Path -LiteralPath $script:path | Should Be $true
    }
    It 'has schema 1 and the repo states, serialized as an array even for one repo' {
        $script:o.schema | Should Be 1
        $script:o.repos[0].name | Should Be 'RepoOne'
        $script:o.repos[0].sha | Should Be ('a' * 40)
        $script:o.repos[0].dirty | Should Be $false
        $script:text | Should Match '"repos":\s*\[\s*\{'
    }
    It 'lists one entry per Modules\<id> folder with the SubModule.xml version (null if absent)' {
        @($script:o.modules).Count | Should Be 2
        $a = @($script:o.modules | Where-Object { $_.id -eq 'ModA' })[0]
        $b = @($script:o.modules | Where-Object { $_.id -eq 'ModB' })[0]
        $a.version | Should Be 'v1.2.3'
        ($b.PSObject.Properties.Name -contains 'version') | Should Be $true
        $b.version | Should BeNullOrEmpty
    }
    It 'lists every file as Modules/<id>/... with uppercase SHA-256, sorted by path, files always an array' {
        $a = @($script:o.modules | Where-Object { $_.id -eq 'ModA' })[0]
        # Beta < SubModule < Zeta under both ordinal and culture ordering, so the expectation is unambiguous
        (@($a.files | ForEach-Object { $_.path }) -join ',') | Should Be 'Modules/ModA/Beta.dll,Modules/ModA/SubModule.xml,Modules/ModA/Zeta.dll'
        foreach ($f in $a.files) {
            $f.sha256 | Should Match '^[0-9A-F]{64}$'
            $f.sha256 | Should Be (Get-FileHash -LiteralPath (Join-Path $script:t ($f.path -replace '/', '\')) -Algorithm SHA256).Hash
        }
        $script:text | Should Match '"files":\s*\[\s*\{'
        # ModB has exactly one file: a one-element list must still be a JSON array
        $b = @($script:o.modules | Where-Object { $_.id -eq 'ModB' })[0]
        @($b.files).Count | Should Be 1
        $script:text | Should Match '"path":\s*"Modules/ModB/SubModule\.xml"'
        $script:text | Should Match '"id":\s*"ModB"[\s\S]*?"files":\s*\[\s*\{'
    }
}

Describe 'New-RigBuildManifest ordering and fail-closed' {
    BeforeEach { $script:t = New-TempDir }
    AfterEach { Remove-TestDir $script:t }

    It 'sorts modules and files ordinally (uppercase before lowercase)' {
        foreach ($m in 'moda', 'ModB') { New-Item -ItemType Directory -Path (Join-Path $script:t "Modules\$m") -Force | Out-Null }
        foreach ($f in 'a.dll', 'B.dll') { Set-Content -LiteralPath (Join-Path $script:t "Modules\ModB\$f") -Value $f }
        $path = New-RigBuildManifest -StageDir $script:t -Repos @([pscustomobject]@{ name = 'R'; sha = ('a' * 40); dirty = $false })
        $o = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        (@($o.modules | ForEach-Object { $_.id }) -join ',') | Should Be 'ModB,moda'
        (@($o.modules[0].files | ForEach-Object { $_.path }) -join ',') | Should Be 'Modules/ModB/B.dll,Modules/ModB/a.dll'
    }
    It 'throws instead of silently leaving out files below a path longer than MAX_PATH' {
        New-LongPathFile (Join-Path $script:t 'Modules\ModX')
        { New-RigBuildManifest -StageDir $script:t -Repos @([pscustomobject]@{ name = 'R'; sha = ('a' * 40); dirty = $false }) } | Should Throw
    }
}

Describe 'Invoke-RigBuildPackage' {
    BeforeAll {
        $script:t = New-TempDir
        $script:fake = New-FakeMsBuild $script:t
        $script:ws = Join-Path $script:t 'ws'
        New-FakeWorkspace $script:ws
    }
    AfterAll { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:run = Join-Path $script:t ('run-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:run | Out-Null
        $script:game = Join-Path $script:run 'tower'
        $script:tower = Join-Path $script:game 'Modules'
        New-Item -ItemType Directory -Path (Join-Path $script:tower 'Native\bin') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:tower 'Native\bin\Native.dll') -Value 'native'
        $script:stage = Join-Path $script:run 'stage\job1'
        $script:log = Join-Path $script:run 'msbuild.log'
        $env:RIG_FAKE_LOG = $script:log
        $env:RIG_FAKE_FAIL = ''
        $env:RIG_FAKE_TOWER = ''
        $env:RIG_FAKE_SKIP = ''
        $env:RIG_FAKE_NODLL = ''
    }
    AfterEach { $env:RIG_FAKE_LOG = ''; $env:RIG_FAKE_FAIL = ''; $env:RIG_FAKE_TOWER = ''; $env:RIG_FAKE_SKIP = ''; $env:RIG_FAKE_NODLL = '' }

    function Build([hashtable]$o) {
        $p = @{ WorkspaceRoot = $script:ws; StageDir = $script:stage; TowerGamePath = $script:game; MsBuildPath = $script:fake }
        foreach ($k in $o.Keys) { $p[$k] = $o[$k] }
        Invoke-RigBuildPackage @p
    }

    It 'builds all seven projects into <StageDir>\Modules, writes the manifest and returns StageDir, ManifestPath, 5 repos' {
        $r = Build @{}
        $r.StageDir | Should Be $script:stage
        $r.ManifestPath | Should Be (Join-Path $script:stage 'manifest.json')
        Test-Path -LiteralPath $r.ManifestPath | Should Be $true
        @($r.Repos).Count | Should Be 5
        @($r.Repos | ForEach-Object { $_.name } | Select-Object -Unique).Count | Should Be 5
        ((@($r.Repos | ForEach-Object { $_.name }) | Sort-Object) -join ',') | Should Be 'BannerlordAutoTrader,BannerlordCoherentWarAI,BannerlordSmithingSuite,BannerlordTestRig,CompanionManagementSuite'
        foreach ($s in $r.Repos) { $s.dirty | Should Be $false; $s.sha | Should Match '^[0-9a-f]{40}$' }
        foreach ($p in $script:projects) {
            Test-Path -LiteralPath (Join-Path $script:stage "Modules\$($p.Id)\SubModule.xml") | Should Be $true
        }
        $lines = @(Get-Content -LiteralPath $script:log)
        $lines.Count | Should Be 7
        foreach ($l in $lines) {
            $l.Contains('/p:BannerlordModulesPath=' + (Join-Path $script:stage 'Modules')) | Should Be $true
            $l.Contains('/p:BannerlordPath=' + $script:game) | Should Be $true
        }
        $m = [IO.File]::ReadAllText($r.ManifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        ((@($m.modules | ForEach-Object { $_.id }) | Sort-Object) -join ',') | Should Be ((@($script:projects | ForEach-Object { $_.Id }) | Sort-Object) -join ',')
        @($m.repos).Count | Should Be 5
    }

    It 'builds the scenario project after the harness project' {
        Build @{} | Out-Null
        $lines = @(Get-Content -LiteralPath $script:log)
        $iH = [array]::IndexOf(@($lines | ForEach-Object { [bool]($_ -match 'TestRig\.Harness\.csproj') }), $true)
        $iS = [array]::IndexOf(@($lines | ForEach-Object { [bool]($_ -match 'SmithingSuite\.Scenarios\.csproj') }), $true)
        $iH | Should BeGreaterThan -1
        $iS | Should BeGreaterThan $iH
    }

    It 'builds TestRig.SelfTest after the harness and stages it only for -Suite RIG' {
        $r = Build @{ Suite = 'RIG' }
        $lines = @(Get-Content -LiteralPath $script:log)
        $lines.Count | Should Be 8
        $iH = [array]::IndexOf(@($lines | ForEach-Object { [bool]($_ -match 'TestRig\.Harness\.csproj') }), $true)
        $iT = [array]::IndexOf(@($lines | ForEach-Object { [bool]($_ -match 'TestRig\.SelfTest\.csproj') }), $true)
        $iH | Should BeGreaterThan -1
        $iT | Should BeGreaterThan $iH
        Test-Path -LiteralPath (Join-Path $script:stage 'Modules\TestRig.SelfTest\SubModule.xml') | Should Be $true
        @($r.Repos).Count | Should Be 5
    }

    It 'does not build or stage TestRig.SelfTest for other suites or without a suite' {
        foreach ($s in @(@{}, @{ Suite = 'SM' }, @{ Suite = 'L1' })) {
            if (Test-Path -LiteralPath $script:stage) { Remove-Item -LiteralPath $script:stage -Recurse -Force }
            Set-Content -LiteralPath $script:log -Value ''
            Build $s | Out-Null
            ((Get-Content -LiteralPath $script:log) -join "`n").Contains('TestRig.SelfTest') | Should Be $false
            Test-Path -LiteralPath (Join-Path $script:stage 'Modules\TestRig.SelfTest') | Should Be $false
        }
    }

    It 'throws naming TestRig.SelfTest when its build exits 0 but wrote nothing (-Suite RIG)' {
        $env:RIG_FAKE_SKIP = 'TestRig.SelfTest.csproj'
        $msg = $null
        try { Build @{ Suite = 'RIG' } | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'TestRig\.SelfTest'
    }

    It 'keeps the MSBuild output of every project in <StageDir>\build.log' {
        Build @{} | Out-Null
        $text = [IO.File]::ReadAllText((Join-Path $script:stage 'build.log'))
        foreach ($n in 'CoherentWarAI.csproj', 'CoherentWarAI.TestHarness.csproj', 'AutoTrader.csproj', 'SmithingSuite.csproj', 'CompanionSuite.csproj', 'TestRig.Harness.csproj', 'SmithingSuite.Scenarios.csproj') {
            $text.Contains("fake msbuild ok: $n") | Should Be $true
        }
    }

    It 'throws naming the module when a build exits 0 but wrote nothing for it, and writes no manifest' {
        $env:RIG_FAKE_SKIP = 'CompanionSuite.csproj'
        $msg = $null
        try { Build @{} | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'CompanionManagementSuite'
        Test-Path -LiteralPath (Join-Path $script:stage 'manifest.json') | Should Be $false
    }

    It 'throws naming the module when a module has no dll in bin\Win64_Shipping_Client' {
        $env:RIG_FAKE_NODLL = 'SmithingSuite.csproj'
        $msg = $null
        try { Build @{} | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'SmithingSuite'
        Test-Path -LiteralPath (Join-Path $script:stage 'manifest.json') | Should Be $false
    }

    It 'passes -Configuration through' {
        Build @{ Configuration = 'Release' } | Out-Null
        foreach ($l in @(Get-Content -LiteralPath $script:log)) { $l | Should Match '/p:Configuration=Release' }
    }

    It 'reports a dirty repo in the returned state' {
        $f = Join-Path $script:ws 'BannerlordSmithingSuite\untracked.txt'
        Set-Content -LiteralPath $f -Value 'x'
        try {
            $r = Build @{}
            (@($r.Repos | Where-Object { $_.name -eq 'BannerlordSmithingSuite' })[0]).dirty | Should Be $true
            (@($r.Repos | Where-Object { $_.name -eq 'BannerlordAutoTrader' })[0]).dirty | Should Be $false
        } finally { Remove-Item -LiteralPath $f -Force }
    }

    It 'throws when a build fails, naming the project, and writes no manifest' {
        $env:RIG_FAKE_FAIL = 'SmithingSuite.csproj'
        { Build @{} } | Should Throw 'SmithingSuite.csproj'
        Test-Path -LiteralPath (Join-Path $script:stage 'manifest.json') | Should Be $false
    }

    It 'throws "tower Modules changed" with the changed paths when a build writes into the tower, and writes no manifest' {
        $env:RIG_FAKE_TOWER = $script:tower
        $msg = $null
        try { Build @{} | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'tower Modules changed'
        $msg | Should Match 'CoherentWarAI'
        Test-Path -LiteralPath (Join-Path $script:stage 'manifest.json') | Should Be $false
    }

    It 'throws (naming the Modules path) when TowerGamePath has no Modules folder, before building anything' {
        $missing = Join-Path $script:run 'nope'
        $msg = $null
        try { Build @{ TowerGamePath = $missing } | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should Not BeNullOrEmpty
        $msg.Contains((Join-Path $missing 'Modules')) | Should Be $true
        Test-Path -LiteralPath $script:log | Should Be $false
    }

    It 'throws (naming the path) when MsBuildPath does not exist' {
        $missing = Join-Path $script:run 'nope\MSBuild.exe'
        $msg = $null
        try { Build @{ MsBuildPath = $missing } | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should Not BeNullOrEmpty
        $msg.Contains($missing) | Should Be $true
    }
}
