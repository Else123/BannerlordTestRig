<#
.SYNOPSIS
    Live smoke test of the whole rig without Bannerlord: runner (dev PC) -> SSH -> real agent
    (test PC) -> fake game -> results back on the dev PC.

.DESCRIPTION
    Needs an installed agent on the test PC (agent\Install-TestRigAgent.ps1) and a working
    runner\runner.config.json. The test PC needs no game: the agent runs with its own config
    <RemoteRigRoot>\fake\agent.config.fake.json, which points gamePath/gameExecutable at
    tests\agent\fixtures\fake-game.ps1. The real agent.config.json is not touched.

    The agent is started once with -Once over SSH, i.e. outside the logged-on session. That is
    fine for the fake game; the real game must be started by the scheduled task instead.

    Scenarios:
      complete  the fake game completes after 6 s           -> runner exit 0
      abort     the fake game hangs with a child process,   -> runner exit 3, game and child
                the runner deadline (30 s) sends an abort      killed, run.cfg removed

    Cleans up the job, its results and work folder on the test PC and locally afterwards.

    Usage:  powershell -NoProfile -File tests\live\Invoke-FakeGameSmoke.ps1 [-Scenario complete|abort]
    Exit:   0 = PASS, 1 = FAIL
#>
param(
    [ValidateSet('complete', 'abort')][string]$Scenario = 'complete',
    [string]$ConfigPath = '',
    [string]$RemoteRigRoot = 'C:\TestRig'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repo 'runner\Transport.Ssh.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $repo 'runner\runner.config.json' }
$target = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$fakeRoot = $RemoteRigRoot.TrimEnd('\') + '\fake'
$lit = @{
    Fake   = ConvertTo-PsLiteral $fakeRoot
    Rig    = ConvertTo-PsLiteral $RemoteRigRoot.TrimEnd('\')
    Queue  = ConvertTo-PsLiteral $target.remoteQueueRoot.TrimEnd('\', '/')
    Behave = ConvertTo-PsLiteral $(if ($Scenario -eq 'abort') { 'child' } else { 'slow' })
}

function Write-Step([string]$Text) { Write-Host "== $Text" }

# 1. Fake game setup on the test PC.
Write-Step 'Preparing the fake game on the test PC'
$null = Invoke-RigRemoteScript -Target $target -Script @"
`$fake = $($lit.Fake)
New-Item -ItemType Directory -Force -Path (Join-Path `$fake 'game\Modules'), (Join-Path `$fake 'docs') | Out-Null
`$base = Get-Content -LiteralPath (Join-Path $($lit.Rig) 'agent\agent.config.json') -Raw | ConvertFrom-Json
`$cfg = [ordered]@{
    queueRoot = $($lit.Queue); workRoot = (Join-Path $($lit.Rig) 'work'); gamePath = (Join-Path `$fake 'game')
    gameExecutable = (Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    gameArgumentsPrefix = ('-NoProfile -File "' + (Join-Path `$fake 'fake-game.ps1') + '" /singleplayer')
    documentsRoot = (Join-Path `$fake 'docs'); pollSeconds = 10; heartbeatSeconds = 10
    moduleAllowlist = `$base.moduleAllowlist
}
[IO.File]::WriteAllText((Join-Path `$fake 'agent.config.fake.json'), (`$cfg | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding(`$false)))
"@
Invoke-RigScp -Target $target -Source (Join-Path $repo 'tests\agent\fixtures\fake-game.ps1') `
    -Destination (Get-ScpRemoteSpec -Target $target -WindowsPath "$fakeRoot\fake-game.ps1")

# 2. Minimal package.
$pkg = Join-Path ([IO.Path]::GetTempPath()) ('rig-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'Modules\CoherentWarAI') | Out-Null
Set-Content -LiteralPath (Join-Path $pkg 'Modules\CoherentWarAI\SubModule.xml') -Value '<Module><Id value="CoherentWarAI"/></Module>' -Encoding ASCII

# 3. Runner in the background, waiting for the result.
Write-Step "Starting the runner (scenario $Scenario)"
$log = Join-Path $pkg 'runner.log'
$runnerArgs = @('-NoProfile', '-File', (Join-Path $repo 'runner\Invoke-TestRig.ps1'), '-ConfigPath', $ConfigPath,
    '-PackageFrom', $pkg, '-Days', '1', '-HardTimeoutMinutes', '2', '-Wait')
if ($Scenario -eq 'abort') { $runnerArgs += @('-TimeoutMinutes', '0.5') }
$runner = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
    -ArgumentList $runnerArgs -RedirectStandardOutput $log -NoNewWindow -PassThru
$null = $runner.Handle   # PS 5.1: without touching Handle before exit, ExitCode stays $null
Start-Sleep -Seconds 5   # publish takes a few seconds; the agent runs -Once and needs the job to exist

# 4. Real agent, once, with the fake config.
Write-Step 'Running the agent once on the test PC'
$agentOut = Invoke-RigRemoteScript -Target $target -Script @"
`$fake = $($lit.Fake)
`$env:FAKEGAME_DOCS = Join-Path `$fake 'docs'; `$env:FAKEGAME_BEHAVIOR = $($lit.Behave)
& (Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -File (Join-Path $($lit.Rig) 'agent\TestRigAgent.ps1') -Once -ConfigPath (Join-Path `$fake 'agent.config.fake.json')
"agentExit=`$LASTEXITCODE"
`$cp = Get-Content -LiteralPath (Join-Path `$fake 'docs\child-pid.txt') -ErrorAction SilentlyContinue
"childAlive=" + [bool](`$cp -and (Get-Process -Id `$cp -ErrorAction SilentlyContinue))
"runCfgLeft=" + (Test-Path -LiteralPath (Join-Path `$fake 'docs\Mount and Blade II Bannerlord\CoherentWarAI\harness\run.cfg'))
"@
$runner.WaitForExit()
$runnerExit = $runner.ExitCode
$runnerOut = @(Get-Content -LiteralPath $log)
$runnerOut | ForEach-Object { Write-Host "   runner: $_" }
$agentOut | Where-Object { $_ -match '^(agentExit|childAlive|runCfgLeft)=' } | ForEach-Object { Write-Host "   agent:  $_" }

# 5. Verdict.
$expected = if ($Scenario -eq 'abort') { 3 } else { 0 }
$checks = [ordered]@{
    "runner exit $expected" = ($runnerExit -eq $expected)
    'agent exit 0'          = [bool]($agentOut -contains 'agentExit=0')
    'game child gone'       = [bool]($agentOut -contains 'childAlive=False')
    'run.cfg removed'       = [bool]($agentOut -contains 'runCfgLeft=False')
}

# 6. Cleanup (test PC and local), also after a failure.
$jobLine = $runnerOut | Where-Object { $_ -match '^jobId: ' } | Select-Object -First 1
if ($jobLine) {
    $jobId = ($jobLine -replace '^jobId: ', '').Trim()
    Assert-RigJobId $jobId
    $j = ConvertTo-PsLiteral $jobId
    Write-Step "Cleaning up job $jobId"
    $null = Invoke-RigRemoteScript -Target $target -Script @"
foreach (`$p in (Join-Path $($lit.Queue) ('jobs\' + $j)), (Join-Path $($lit.Queue) ('results\' + $j)), (Join-Path $($lit.Rig) ('work\' + $j)), (Join-Path $($lit.Fake) 'game'), (Join-Path $($lit.Fake) 'docs')) {
    if (Test-Path -LiteralPath `$p) { Remove-Item -LiteralPath `$p -Recurse -Force }
}
"@
    foreach ($p in (Join-Path $repo "out\jobs\$jobId"), (Join-Path $repo "out\results\$jobId")) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
    }
}
Remove-Item -LiteralPath $pkg -Recurse -Force

$failed = @($checks.Keys | Where-Object { -not $checks[$_] })
$checks.Keys | ForEach-Object { Write-Host ('   {0} {1}' -f $(if ($checks[$_]) { 'ok  ' } else { 'FAIL' }), $_) }
if ($failed.Count -gt 0) { Write-Host "FAIL ($Scenario)"; exit 1 }
Write-Host "PASS ($Scenario)"
exit 0
