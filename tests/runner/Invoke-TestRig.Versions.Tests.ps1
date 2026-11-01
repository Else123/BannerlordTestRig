$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\runner\Invoke-TestRig.ps1')

# Version checks: tower game install (Version.xml, SubModule.xml) vs. what the .20 agent reports.

function New-TempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('rigver-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    $d
}

function New-PackageFixture([string]$Root) {
    foreach ($m in 'CoherentWarAI', 'CoherentWarAI.TestHarness', 'TestRig.Harness') {
        $bin = Join-Path $Root "Modules\$m\bin\Win64_Shipping_Client"
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bin "$m.dll") -Value "dll $m"
        Set-Content -LiteralPath (Join-Path $Root "Modules\$m\SubModule.xml") -Value '<Module/>'
    }
}

# Fake Steam library: <Root>\steamapps\common\Game (Version.xml, Modules) and <Root>\steamapps\workshop\content\261550\<n>.
# Returns the game folder (= towerGamePath). An empty $GameVersion writes no Version.xml.
function New-FakeTower([string]$Root, [string]$GameVersion, [hashtable]$Modules = @{}, [hashtable]$Workshop = @{}) {
    $game = Join-Path $Root 'steamapps\common\Game'
    $bin = Join-Path $game 'bin\Win64_Shipping_Client'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    if ($GameVersion) {
        [IO.File]::WriteAllText((Join-Path $bin 'Version.xml'), ('<Version><Singleplayer Value="' + $GameVersion + '"/></Version>'))
    }
    foreach ($id in $Modules.Keys) {
        $d = Join-Path $game "Modules\$id"
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'SubModule.xml'), ('<Module><Name value="x"/><Id value="' + $id + '"/><Version value="' + $Modules[$id] + '"/></Module>'))
    }
    $n = 1000
    foreach ($id in $Workshop.Keys) {
        $n++
        $d = Join-Path $Root "steamapps\workshop\content\261550\$n"
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'SubModule.xml'), ('<Module><Name value="x"/><Id value="' + $id + '"/><Version value="' + $Workshop[$id] + '"/></Module>'))
    }
    $game
}

function New-ModEntry([string]$Id, $Version, [string]$Source) { [pscustomobject]@{ id = $Id; version = $Version; source = $Source } }

Describe 'Get-RigTowerGameVersion' {
    BeforeEach { $script:t = New-TempDir }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reads Singleplayer Value from bin\Win64_Shipping_Client\Version.xml' {
        $g = New-FakeTower $script:t 'v1.4.8'
        Get-RigTowerGameVersion -TowerGamePath $g | Should Be 'v1.4.8'
    }
    It 'throws when Version.xml is missing' {
        $g = New-FakeTower $script:t ''
        { Get-RigTowerGameVersion -TowerGamePath $g } | Should Throw 'Version.xml'
    }
    It 'throws when Version.xml is not valid XML' {
        $g = New-FakeTower $script:t ''
        [IO.File]::WriteAllText((Join-Path $g 'bin\Win64_Shipping_Client\Version.xml'), '<Version><Singleplayer')
        { Get-RigTowerGameVersion -TowerGamePath $g } | Should Throw 'Version.xml'
    }
    It 'throws when there is no Singleplayer Value' {
        $g = New-FakeTower $script:t ''
        [IO.File]::WriteAllText((Join-Path $g 'bin\Win64_Shipping_Client\Version.xml'), '<Version><Multiplayer Value="v1.4.8"/></Version>')
        { Get-RigTowerGameVersion -TowerGamePath $g } | Should Throw 'Singleplayer'
    }
    It 'throws when the Value is blank' {
        $g = New-FakeTower $script:t ''
        [IO.File]::WriteAllText((Join-Path $g 'bin\Win64_Shipping_Client\Version.xml'), '<Version><Singleplayer Value=" "/></Version>')
        { Get-RigTowerGameVersion -TowerGamePath $g } | Should Throw 'Singleplayer'
    }
    It 'rejects a DTD (no entity expansion)' {
        $g = New-FakeTower $script:t ''
        [IO.File]::WriteAllText((Join-Path $g 'bin\Win64_Shipping_Client\Version.xml'), '<!DOCTYPE v [<!ENTITY e "x">]><Version><Singleplayer Value="&e;"/></Version>')
        { Get-RigTowerGameVersion -TowerGamePath $g } | Should Throw 'Version.xml'
    }
}

Describe 'Get-RigTowerModuleVersion' {
    BeforeEach { $script:t = New-TempDir }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reads the version from <game>\Modules\<id>\SubModule.xml' {
        $g = New-FakeTower $script:t 'v1.4.8' @{ 'Bannerlord.Harmony' = 'v2.4.2.248' }
        Get-RigTowerModuleVersion -TowerGamePath $g -ModuleId 'Bannerlord.Harmony' | Should Be 'v2.4.2.248'
    }
    It 'falls back to the workshop folder matched by Id, not by folder name' {
        $g = New-FakeTower $script:t 'v1.4.8' @{} @{ 'Other.Mod' = 'v9'; 'Bannerlord.ButterLib' = 'v2.10.1' }
        Get-RigTowerModuleVersion -TowerGamePath $g -ModuleId 'Bannerlord.ButterLib' | Should Be 'v2.10.1'
    }
    It 'prefers the game Modules folder over the workshop' {
        $g = New-FakeTower $script:t 'v1.4.8' @{ 'A.B' = 'v1' } @{ 'A.B' = 'v2' }
        Get-RigTowerModuleVersion -TowerGamePath $g -ModuleId 'A.B' | Should Be 'v1'
    }
    It 'returns $null when the module is on the tower nowhere' {
        $g = New-FakeTower $script:t 'v1.4.8'
        ($null -eq (Get-RigTowerModuleVersion -TowerGamePath $g -ModuleId 'Nope')) | Should Be $true
    }
    It 'returns an empty string when the module exists but has no Version' {
        $g = New-FakeTower $script:t 'v1.4.8'
        New-Item -ItemType Directory -Path (Join-Path $g 'Modules\NoVer') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $g 'Modules\NoVer\SubModule.xml'), '<Module><Id value="NoVer"/></Module>')
        $v = Get-RigTowerModuleVersion -TowerGamePath $g -ModuleId 'NoVer'
        ($null -ne $v) | Should Be $true
        $v | Should BeExactly ''
    }
    It 'does not follow an id that could leave the Modules folder' {
        $g = New-FakeTower $script:t 'v1.4.8'
        [IO.File]::WriteAllText((Join-Path $g 'SubModule.xml'), '<Module><Id value=".."/><Version value="v6"/></Module>')
        ($null -eq (Get-RigTowerModuleVersion -TowerGamePath $g -ModuleId '..')) | Should Be $true
        ($null -eq (Get-RigTowerModuleVersion -TowerGamePath $g -ModuleId '..\..\x')) | Should Be $true
    }
}

Describe 'Get-RigVersionWarnings' {
    BeforeEach {
        $script:t = New-TempDir
        $script:g = New-FakeTower $script:t 'v1.4.8' @{ 'Bannerlord.Harmony' = 'v2.4.2.248'; 'Native' = 'v1.4.8' } @{ 'Bannerlord.ButterLib' = 'v2.10.1' }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    function Run($game, $mods) { [pscustomobject]@{ gameVersion = $game; moduleVersions = @($mods) } }

    It 'no warnings when everything matches (game, module in Modules, workshop module)' {
        $r = Run 'v1.4.8' @((New-ModEntry 'Bannerlord.Harmony' 'v2.4.2.248' 'workshop'), (New-ModEntry 'Native' 'v1.4.8' 'game'), (New-ModEntry 'Bannerlord.ButterLib' 'v2.10.1' 'workshop'))
        @(Get-RigVersionWarnings -TowerGamePath $script:g -Runs @($r)).Count | Should Be 0
    }
    It 'warns for a differing module version in the exact format' {
        $r = Run 'v1.4.8' @(New-ModEntry 'Bannerlord.Harmony' 'v2.4.2.249' 'workshop')
        $w = @(Get-RigVersionWarnings -TowerGamePath $script:g -Runs @($r))
        $w.Count | Should Be 1
        $w[0] | Should BeExactly 'WARN version differs: Bannerlord.Harmony tower v2.4.2.248, .20 v2.4.2.249'
    }
    It 'warns for a module that is missing on the tower' {
        $r = Run 'v1.4.8' @(New-ModEntry 'Bannerlord.Gone' 'v1.0.0' 'workshop')
        $w = @(Get-RigVersionWarnings -TowerGamePath $script:g -Runs @($r))
        $w.Count | Should Be 1
        $w[0] | Should BeExactly 'WARN version differs: Bannerlord.Gone tower missing, .20 v1.0.0'
    }
    It 'warns when the tower module has no version' {
        New-Item -ItemType Directory -Path (Join-Path $script:g 'Modules\NoVer') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:g 'Modules\NoVer\SubModule.xml'), '<Module><Id value="NoVer"/></Module>')
        $w = @(Get-RigVersionWarnings -TowerGamePath $script:g -Runs @((Run 'v1.4.8' @(New-ModEntry 'NoVer' 'v3' 'game'))))
        $w[0] | Should BeExactly 'WARN version differs: NoVer tower unknown, .20 v3'
    }
    It 'warns for a differing game version' {
        $w = @(Get-RigVersionWarnings -TowerGamePath $script:g -Runs @((Run 'v1.4.9' @())))
        $w.Count | Should Be 1
        $w[0] | Should BeExactly 'WARN version differs: game tower v1.4.8, .20 v1.4.9'
    }
    It 'ignores package modules and entries without a version' {
        $r = Run 'v1.4.8' @((New-ModEntry 'CoherentWarAI' 'v0.1' 'package'), (New-ModEntry 'Bannerlord.Harmony' $null 'workshop'))
        @(Get-RigVersionWarnings -TowerGamePath $script:g -Runs @($r)).Count | Should Be 0
    }
    It 'compares each distinct (id, version) once over all runs' {
        $a = Run 'v1.4.9' @(New-ModEntry 'Bannerlord.Harmony' 'v2.4.2.249' 'workshop')
        $b = Run 'v1.4.9' @(New-ModEntry 'Bannerlord.Harmony' 'v2.4.2.249' 'workshop')
        $c = Run 'v1.4.9' @(New-ModEntry 'Bannerlord.Harmony' 'v2.4.2.250' 'workshop')
        $w = @(Get-RigVersionWarnings -TowerGamePath $script:g -Runs @($a, $b, $c))
        $w.Count | Should Be 3   # game once, Harmony .249 once, Harmony .250 once
    }
    It 'old agent without the fields: no warning, no error' {
        $old = [pscustomobject]@{ runId = 'r1' }
        @(Get-RigVersionWarnings -TowerGamePath $script:g -Runs @($old)).Count | Should Be 0
        $nulls = [pscustomobject]@{ gameVersion = $null; moduleVersions = $null }
        @(Get-RigVersionWarnings -TowerGamePath $script:g -Runs @($nulls)).Count | Should Be 0
    }
    It 'skips malformed module entries and ids with path characters' {
        $r = Run 'v1.4.8' @('junk', (New-ModEntry '..\..\x' 'v1' 'game'), (New-ModEntry $null 'v1' 'game'))
        @(Get-RigVersionWarnings -TowerGamePath $script:g -Runs @($r)).Count | Should Be 0
    }
}

Describe 'Tower lookup by source (game Modules vs. workshop)' {
    BeforeEach {
        $script:t = New-TempDir
        # A.B is in both places with different versions; OnlyWs only in the workshop, OnlyGame only in Modules.
        $script:g = New-FakeTower $script:t 'v1.4.8' @{ 'A.B' = 'v1'; 'OnlyGame' = 'v5' } @{ 'A.B' = 'v2'; 'OnlyWs' = 'v7' }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    function Warn($id, $ver, $src) {
        @(Get-RigVersionWarnings -TowerGamePath $script:g -Runs @([pscustomobject]@{ gameVersion = $null; moduleVersions = @(New-ModEntry $id $ver $src) }))
    }

    It 'source=workshop compares against the workshop copy first' {
        (Warn 'A.B' 'v2' 'workshop').Count | Should Be 0
        @(Warn 'A.B' 'v1' 'workshop')[0] | Should BeExactly 'WARN version differs: A.B tower v2, .20 v1'
    }
    It 'source=game compares against Modules first' {
        (Warn 'A.B' 'v1' 'game').Count | Should Be 0
        @(Warn 'A.B' 'v2' 'game')[0] | Should BeExactly 'WARN version differs: A.B tower v1, .20 v2'
    }
    It 'falls back to the other location when the preferred one lacks the module' {
        (Warn 'OnlyWs' 'v7' 'game').Count | Should Be 0
        (Warn 'OnlyGame' 'v5' 'workshop').Count | Should Be 0
    }
    It 'Get-RigTowerModuleVersion honours -Source' {
        Get-RigTowerModuleVersion -TowerGamePath $script:g -ModuleId 'A.B' -Source 'workshop' | Should Be 'v2'
        Get-RigTowerModuleVersion -TowerGamePath $script:g -ModuleId 'A.B' -Source 'game' | Should Be 'v1'
    }
}

Describe 'Tower workshop scan happens once per job' {
    BeforeEach {
        $script:t = New-TempDir
        $script:g = New-FakeTower $script:t 'v1.4.8' @{} @{ 'W.One' = 'v1'; 'W.Two' = 'v2'; 'W.Three' = 'v3' }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    It 'builds the workshop index a single time for many module ids and runs' {
        $script:scans = 0
        Mock Get-RigTowerWorkshopIndex {
            $script:scans++
            [pscustomobject]@{ Versions = @{ 'W.One' = 'v1'; 'W.Two' = 'v2'; 'W.Three' = 'v3' }; Duplicates = @() }
        }
        $mods = @((New-ModEntry 'W.One' 'v1' 'workshop'), (New-ModEntry 'W.Two' 'v9' 'workshop'), (New-ModEntry 'W.Three' 'v3' 'workshop'))
        $runs = @([pscustomobject]@{ gameVersion = $null; moduleVersions = $mods }, [pscustomobject]@{ gameVersion = $null; moduleVersions = $mods })
        $w = @(Get-RigVersionWarnings -TowerGamePath $script:g -Runs $runs)
        $w.Count | Should Be 1
        $script:scans | Should Be 1
    }
    It 'does not scan the workshop when every module is found in Modules' {
        $script:scans = 0
        Mock Get-RigTowerWorkshopIndex { $script:scans++; [pscustomobject]@{ Versions = @{}; Duplicates = @() } }
        $g2 = New-FakeTower (Join-Path $script:t 'lib2') 'v1.4.8' @{ 'M.One' = 'v1' }
        $w = @(Get-RigVersionWarnings -TowerGamePath $g2 -Runs @([pscustomobject]@{ gameVersion = $null; moduleVersions = @(New-ModEntry 'M.One' 'v1' 'game') }))
        $w.Count | Should Be 0
        $script:scans | Should Be 0
    }
}

Describe 'Duplicate workshop ids on the tower' {
    BeforeEach {
        $script:t = New-TempDir
        $script:g = New-FakeTower $script:t 'v1.4.8'
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    function Add-WorkshopCopy([string]$Folder, [string]$Id, [string]$Version, [datetime]$Written) {
        $d = Join-Path $script:t "steamapps\workshop\content\261550\$Folder"
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $f = Join-Path $d 'SubModule.xml'
        [IO.File]::WriteAllText($f, ('<Module><Id value="' + $Id + '"/><Version value="' + $Version + '"/></Module>'))
        (Get-Item -LiteralPath $f).LastWriteTimeUtc = $Written
    }
    function Run1($id, $ver) { [pscustomobject]@{ gameVersion = $null; moduleVersions = @(New-ModEntry $id $ver 'workshop') } }

    It 'picks the copy with the newest LastWriteTime and warns once about the duplicate' {
        Add-WorkshopCopy '111' 'D.Up' 'v1' ([datetime]'2026-01-01')
        Add-WorkshopCopy '222' 'D.Up' 'v2' ([datetime]'2026-06-01')
        $w = @(Get-RigVersionWarnings -TowerGamePath $script:g -Runs @((Run1 'D.Up' 'v2'), (Run1 'D.Up' 'v3')))
        @($w | Where-Object { $_ -eq 'WARN duplicate workshop id D.Up on tower' }).Count | Should Be 1
        @($w | Where-Object { $_ -eq 'WARN version differs: D.Up tower v2, .20 v3' }).Count | Should Be 1
        $w.Count | Should Be 2
    }
    It 'breaks a LastWriteTime tie by folder name (ascending)' {
        $same = [datetime]'2026-03-03'
        Add-WorkshopCopy '900' 'D.Tie' 'v9' $same
        Add-WorkshopCopy '100' 'D.Tie' 'v1' $same
        (Get-RigTowerModuleVersion -TowerGamePath $script:g -ModuleId 'D.Tie' -Source 'workshop') | Should Be 'v1'
    }
    It 'no duplicate warning when the copies carry the same version' {
        Add-WorkshopCopy '111' 'D.Same' 'v4' ([datetime]'2026-01-01')
        Add-WorkshopCopy '222' 'D.Same' 'v4' ([datetime]'2026-06-01')
        @(Get-RigVersionWarnings -TowerGamePath $script:g -Runs @((Run1 'D.Same' 'v4'))).Count | Should Be 0
    }
}

Describe 'Publish-RigResult version warnings and Crashed' {
    BeforeEach {
        $script:t = New-TempDir
        $script:id = '20261031-153000-a1b2'
        $script:rd = Join-Path $script:t $script:id
        New-Item -ItemType Directory -Path (Join-Path $script:rd 'r1') | Out-Null
        $script:lines = @()
        Mock Write-Host { $script:lines += "$Object" }
        $script:g = New-FakeTower $script:t 'v1.4.8' @{ 'Native' = 'v1.4.8' } @{ 'Bannerlord.Harmony' = 'v2.4.2.248' }
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    function Write-Done([string]$ExitClass) {
        [IO.File]::WriteAllText((Join-Path $script:rd 'done.json'), ('{"schema":1,"jobId":"20261031-153000-a1b2","status":"completed","runs":[{"runId":"r1","exitClass":"' + $ExitClass + '"}]}'))
    }
    function Write-AgentRun([string]$Json) { [IO.File]::WriteAllText((Join-Path $script:rd 'r1\agent-run.json'), $Json) }
    function Get-JobResult { Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw | ConvertFrom-Json }
    $agentJson = '{"schema":1,"runId":"r1","startedUtc":"2026-10-31T15:00:00Z","endedUtc":"2026-10-31T15:12:30Z","gameVersion":"v1.4.9","moduleVersions":[{"id":"Bannerlord.Harmony","version":"v2.4.2.249","source":"workshop"},{"id":"CoherentWarAI","version":"v0.1","source":"package"}]}'

    It 'prints WARN lines and adds additive version fields to job-result.json' {
        Write-Done 'Completed'
        Write-AgentRun $agentJson
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -TowerGamePath $script:g) | Should Be 2   # no result.txt: 0/1 days
        ($script:lines -contains 'WARN version differs: game tower v1.4.8, .20 v1.4.9') | Should Be $true
        ($script:lines -contains 'WARN version differs: Bannerlord.Harmony tower v2.4.2.248, .20 v2.4.2.249') | Should Be $true
        $jr = Get-JobResult
        $jr.runs[0].gameVersion | Should Be 'v1.4.9'
        @($jr.runs[0].moduleVersions).Count | Should Be 2
        $jr.runs[0].moduleVersions[0].id | Should Be 'Bannerlord.Harmony'
        $jr.runs[0].moduleVersions[0].source | Should Be 'workshop'
        @($jr.versionWarnings).Count | Should Be 2
        $jr.versionWarnings[0] | Should Match '^WARN version differs: game '
        $jr.exitCode | Should Be 2
    }
    It 'does not change the exit code: a fully completed run stays 0 with warnings' {
        Write-Done 'Completed'
        Write-AgentRun $agentJson
        [IO.File]::WriteAllText((Join-Path $script:rd 'r1\result.txt'), "status=Completed`ndaysReached=1")
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -TowerGamePath $script:g) | Should Be 0
        @((Get-JobResult).versionWarnings).Count | Should Be 2
    }
    It 'old agent-run.json: no warnings, versionWarnings is an empty array, version fields null' {
        Write-Done 'Completed'
        Write-AgentRun '{"schema":1,"runId":"r1","startedUtc":"2026-10-31T15:00:00Z","endedUtc":"2026-10-31T15:12:30Z"}'
        Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -TowerGamePath $script:g | Out-Null
        @($script:lines | Where-Object { $_ -match '^WARN' }).Count | Should Be 0
        $jr = Get-JobResult
        $jr.runs[0].gameVersion | Should BeNullOrEmpty
        $jr.runs[0].moduleVersions | Should BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $script:rd 'job-result.json') -Raw) | Should Match '"versionWarnings":\s*\[\s*\]'
    }
    It 'without TowerGamePath: versions are copied but nothing is compared' {
        Write-Done 'Completed'
        Write-AgentRun $agentJson
        Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 | Out-Null
        @($script:lines | Where-Object { $_ -match '^WARN' }).Count | Should Be 0
        (Get-JobResult).runs[0].gameVersion | Should Be 'v1.4.9'
    }
    It 'an unreadable tower Version.xml only skips the comparison with a message' {
        Write-Done 'Completed'
        Write-AgentRun $agentJson
        Remove-Item -LiteralPath (Join-Path $script:g 'bin\Win64_Shipping_Client\Version.xml')
        { Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 -TowerGamePath $script:g } | Should Not Throw
        (Test-Path -LiteralPath (Join-Path $script:rd 'job-result.json')) | Should Be $true
        @($script:lines | Where-Object { $_ -match 'version check skipped' }).Count | Should Be 1
    }
    It 'moduleVersions stays a JSON array for 0 and 1 entries; null stays null for an old agent' {
        Write-Done 'Completed'
        $head = '{"schema":1,"runId":"r1","startedUtc":"2026-10-31T15:00:00Z","endedUtc":"2026-10-31T15:12:30Z"'
        $raw = Join-Path $script:rd 'job-result.json'
        Write-AgentRun ($head + ',"gameVersion":"v1.4.8","moduleVersions":[]}')
        Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 | Out-Null
        (Get-Content -LiteralPath $raw -Raw) | Should Match '"moduleVersions":\s*\[\s*\]'
        Write-AgentRun ($head + ',"gameVersion":"v1.4.8","moduleVersions":[{"id":"Native","version":"v1.4.8","source":"game"}]}')
        Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 | Out-Null
        (Get-Content -LiteralPath $raw -Raw) | Should Match '"moduleVersions":\s*\[\s*\{'
        Write-AgentRun ($head + '}')
        Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1 | Out-Null
        (Get-Content -LiteralPath $raw -Raw) | Should Match '"moduleVersions":\s*null'
    }
    It 'Crashed shows in the table and maps to exit 2' {
        Write-Done 'Crashed'
        Write-AgentRun $agentJson
        (Publish-RigResult -ResultDir $script:rd -JobId $script:id -Days 1) | Should Be 2
        @($script:lines | Where-Object { $_ -match '^r1 .*Crashed' }).Count | Should Be 1
        (Get-JobResult).runs[0].exitClass | Should Be 'Crashed'
    }
}

Describe 'expectedGameVersion in job.json' {
    BeforeEach {
        $script:t = New-TempDir
        $script:out = Join-Path $script:t 'out'
        $script:cfg = Join-Path $script:t 'v.config.json'
        $script:published = $null
        $script:calls = @{ Publish = 0 }
        $script:lines = @()
        Mock Get-JobState { @() } -ParameterFilter { $OpenJobs }
        Mock Publish-Job {
            $script:calls.Publish++
            $script:published = @{ JobId = $JobId; Dir = $JobDirectory; Job = (Get-Content -LiteralPath (Join-Path $JobDirectory 'job.json') -Raw | ConvertFrom-Json) }
        }
        Mock Write-Host { $script:lines += "$Object" }
        Mock Invoke-RigBuildPackage {
            $m = Join-Path $StageDir 'Modules\CoherentWarAI\bin\Win64_Shipping_Client'
            New-Item -ItemType Directory -Path $m -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $m 'CoherentWarAI.dll') -Value 'dll'
            Set-Content -LiteralPath (Join-Path $StageDir 'manifest.json') -Value '{"schema":1}'
            [pscustomobject]@{ StageDir = $StageDir; ManifestPath = (Join-Path $StageDir 'manifest.json'); Repos = @() }
        }
        $script:pkg = Join-Path $script:t 'pkg'; New-PackageFixture $script:pkg
    }
    AfterEach { Remove-Item -LiteralPath $script:t -Recurse -Force -ErrorAction SilentlyContinue }

    function Write-VConfig([hashtable]$Extra) {
        $c = @{ host = 'testpc'; user = 'rig'; keyPath = 'C:\keys\k'; remoteQueueRoot = 'C:\TestRig\queue' }
        foreach ($k in $Extra.Keys) { $c[$k] = $Extra[$k] }
        [IO.File]::WriteAllText($script:cfg, ($c | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    }
    function Start-VRig([hashtable]$o) {
        $p = @{
            PackageFrom = $script:pkg; Seed = 1; Days = 1; Mode = 'WarSails'
            StallMinutes = 5; BudgetMinutes = 60; HardTimeoutMinutes = 20
            ClaimTimeoutSeconds = 0.3; TimeoutMinutes = 0.5
            ConfigPath = $script:cfg; OutRoot = $script:out
            PollSeconds = 0.02; StaleSeconds = 0.3; AbortWaitSeconds = 0.3; RetryDelaySeconds = 0
        }
        foreach ($k in $o.Keys) { $p[$k] = $o[$k] }
        Start-TestRigJob @p
    }

    It '-PackageFrom: reads the tower version from Version.xml' {
        $g = New-FakeTower $script:t 'v1.4.8'
        Write-VConfig @{ towerGamePath = $g }
        (Start-VRig @{}) | Should Be 0
        $script:published.Job.expectedGameVersion | Should Be 'v1.4.8'
    }
    It 'build mode: reads the tower version from Version.xml' {
        $g = New-FakeTower $script:t 'v1.4.8'
        Write-VConfig @{ towerGamePath = $g }
        (Start-VRig @{ PackageFrom = '' }) | Should Be 0
        $script:published.Job.expectedGameVersion | Should Be 'v1.4.8'
    }
    It 'configured but Version.xml missing: exit 1 before publishing, clear message' {
        $g = New-FakeTower $script:t ''
        Write-VConfig @{ towerGamePath = $g }
        (Start-VRig @{}) | Should Be 1
        $script:calls.Publish | Should Be 0
        ($script:lines -join "`n") | Should Match 'Version\.xml'
    }
    It 'configured but no Singleplayer Value: exit 1 before publishing (build mode: no build)' {
        $g = New-FakeTower $script:t ''
        [IO.File]::WriteAllText((Join-Path $g 'bin\Win64_Shipping_Client\Version.xml'), '<Version/>')
        Write-VConfig @{ towerGamePath = $g }
        (Start-VRig @{ PackageFrom = '' }) | Should Be 1
        $script:calls.Publish | Should Be 0
        Assert-MockCalled Invoke-RigBuildPackage -Exactly 0 -Scope It
        ($script:lines -join "`n") | Should Match 'Singleplayer'
    }
    It 'towerGamePath not configured (-PackageFrom): expectedGameVersion null, exactly one warning, exit 0' {
        Write-VConfig @{}
        (Start-VRig @{}) | Should Be 0
        $script:published.Job.expectedGameVersion | Should BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $script:published.Dir 'job.json') -Raw) | Should Match '"expectedGameVersion":\s*null'
        @($script:lines | Where-Object { $_ -match 'WARN.*towerGamePath.*not checked' }).Count | Should Be 1
    }
}
