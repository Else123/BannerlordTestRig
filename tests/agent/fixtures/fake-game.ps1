# Fake "Bannerlord" for the agent end-to-end tests. Started by the agent as
#   TestRigFakeGame.exe -NoProfile -File fake-game.ps1 /singleplayer _MODULES_*...*_MODULES_
# (TestRigFakeGame.exe is a renamed copy of powershell.exe, made by the tests.)
# Inputs (environment, inherited from the test):
#   FAKEGAME_DOCS      the documentsRoot the agent uses
#   FAKEGAME_HARNESS   CoherentWarAI (default) | TestRig: Documents subfolder whose harness\ holds run.cfg/harness.log and
#                      the result (CoherentWarAI: result.txt; TestRig: run-result.json, via .tmp + Move)
#   FAKEGAME_NOMODLOG  set (any value): do not create the CoherentWarAI mod log folder or file
#   FAKEGAME_BEHAVIOR  complete (default) | sleep | noresult | child (sleeps, owns a sleeping
#                      child process, PID in child-pid.txt) | slow (completes after 6 s) |
#                      modchange (blocking message box 'Mod change detected' with OK, completes after
#                      it is closed) | modchangeokcancel (same, OK/Cancel) | modchangeyesno (same, Yes/No)
#                      | otherdialog (OK box titled 'Some other dialog')
#                      | txtonly (TestRig only: writes result.txt like the old harness) | badjson (TestRig only: invalid run-result.json)
#                      | crash (watchdog log says 'Crash occurred', then hangs like the real crash dialog)
#                      | crashexit (same log, then exits without a result)
#                      | crashlate (exits without a result; 'Crash occurred' reaches the log about 1 s later)
#                      | relaunch (a process outside the tree crashes, PID in stray-pid.txt; exits without a result)
#                      | relaunchexit (starts a sleeping powershell outside the tree, PID in stray-pid.txt, no crash; completes)
#                      | relaunchsleep (same process outside the tree, then sleeps like 'sleep')
#                      | crashforeign (starts ping.exe outside the tree, PID in foreign-pid.txt, writes 'Crash occurred' into
#                      watchdog_log_<that pid>.txt and exits without a result: a crash log naming a PID of another program)
#                      | crashfirst (first start: like crashexit, marker crashfirst-done.txt in FAKEGAME_DOCS; later starts:
#                      appends a line without a crash to every other watchdog log, like the watchdog of the earlier game
#                      still writing, then completes)
#   FAKEGAME_ENGINELOGS the engineLogDir the agent uses: if set, watchdog_log_<pid>.txt is written there
#                      (needed by crash, crashexit, crashlate, relaunch, crashforeign and crashfirst)
# Snapshots for the tests (in FAKEGAME_DOCS): fake-bannerlordconfig.txt and fake-mcm.json (the configs as the game saw
# them, if present) and fake-mcm-files.txt (every file below Configs\ModSettings\Global, relative, one per line).
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GameArguments)

$ErrorActionPreference = 'Stop'
$docs = Join-Path $env:FAKEGAME_DOCS 'Mount and Blade II Bannerlord'
$modDir = Join-Path $docs 'CoherentWarAI'
$harnessName = if ($env:FAKEGAME_HARNESS) { $env:FAKEGAME_HARNESS } else { 'CoherentWarAI' }   # CoherentWarAI | TestRig
$harnessDir = Join-Path (Join-Path $docs $harnessName) 'harness'
New-Item -ItemType Directory -Path $harnessDir -Force | Out-Null

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'fake-args.txt'), ($GameArguments -join ' '), $utf8)
# Records whether a run.cfg exists in the other harness folder (the agent must write only to the selected one).
$otherName = if ($harnessName -eq 'TestRig') { 'CoherentWarAI' } else { 'TestRig' }
$otherRunCfg = Join-Path (Join-Path (Join-Path $docs $otherName) 'harness') 'run.cfg'
[System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'fake-other-runcfg.txt'), [string](Test-Path -LiteralPath $otherRunCfg), $utf8)
[System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'fake-runcfg.txt'), [System.IO.File]::ReadAllText((Join-Path $harnessDir 'run.cfg')), $utf8)
# The ownAssemblies line of run.cfg ('' if absent), for the tests.
$ownLine = @([System.IO.File]::ReadAllLines((Join-Path $harnessDir 'run.cfg')) | Where-Object { $_ -like 'ownAssemblies=*' }) -join ''
[System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'fake-ownassemblies.txt'), $ownLine, $utf8)
if (-not $env:FAKEGAME_NOMODLOG) {
    New-Item -ItemType Directory -Path $modDir -Force | Out-Null   # the mod log folder exists independently of the harness folder
    [System.IO.File]::WriteAllText((Join-Path $modDir 'CoherentWarAI.log'), "fake mod log`r`n", $utf8)
}
[System.IO.File]::WriteAllText((Join-Path $harnessDir 'harness.log'), "harness started`r`nharness day 1 reached`r`n", $utf8)

$configsDir = Join-Path $docs 'Configs'
$bannerlordConfig = Join-Path $configsDir 'BannerlordConfig.txt'
if (Test-Path -LiteralPath $bannerlordConfig) { Copy-Item -LiteralPath $bannerlordConfig -Destination (Join-Path $env:FAKEGAME_DOCS 'fake-bannerlordconfig.txt') }
$mcmJson = Join-Path $configsDir 'ModSettings\Global\CoherentWarAI\CoherentWarAI_v1.json'
if (Test-Path -LiteralPath $mcmJson) { Copy-Item -LiteralPath $mcmJson -Destination (Join-Path $env:FAKEGAME_DOCS 'fake-mcm.json') }
$globalDir = Join-Path $configsDir 'ModSettings\Global'
$mcmFiles = @()
if (Test-Path -LiteralPath $globalDir) {
    $mcmFiles = @(Get-ChildItem -LiteralPath $globalDir -Recurse -File | ForEach-Object { $_.FullName.Substring($globalDir.Length + 1) })
}
[System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'fake-mcm-files.txt'), ($mcmFiles -join "`n"), $utf8)

function New-ProcessOutsideTree {
    # Starts $CommandLine via WMI, so the new process has no parent here (like a game that relaunched itself). Returns its PID.
    param([string]$CommandLine)
    $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $CommandLine }
    return [int]$created.ProcessId
}
# Strays and children run under this process's own executable (the tests' renamed powershell.exe), so they carry the
# fake game's process name, like a real relaunched game.
$selfExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$sleeperCommand = '"' + $selfExe + '" -NoProfile -Command Start-Sleep 120'

$behavior = $env:FAKEGAME_BEHAVIOR
$crashfirstDone = Join-Path $env:FAKEGAME_DOCS 'crashfirst-done.txt'
$crashNow = ($behavior -eq 'crash' -or $behavior -eq 'crashexit' -or ($behavior -eq 'crashfirst' -and -not (Test-Path -LiteralPath $crashfirstDone)))
if ($env:FAKEGAME_ENGINELOGS) {
    # The TaleWorlds watchdog log of this process; after a crash it says 'Crash occurred' (the real game then
    # shows a blocking dialog).
    New-Item -ItemType Directory -Path $env:FAKEGAME_ENGINELOGS -Force | Out-Null
    $watchdogText = "watchdog started`r`n"
    if ($crashNow) { $watchdogText += "Crash occurred`r`n" }
    [System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_ENGINELOGS "watchdog_log_$PID.txt"), $watchdogText, $utf8)
}
if ($behavior -eq 'crashfirst') {
    if ($crashNow) {
        [System.IO.File]::WriteAllText($crashfirstDone, 'done', $utf8)
        exit 0
    }
    foreach ($old in @(Get-ChildItem -LiteralPath $env:FAKEGAME_ENGINELOGS -Filter 'watchdog_log_*.txt' | Where-Object { $_.Name -ne "watchdog_log_$PID.txt" })) {
        [System.IO.File]::AppendAllText($old.FullName, "watchdog still running`r`n", $utf8)
    }
}
if ($behavior -eq 'crashforeign') {
    $foreignPid = New-ProcessOutsideTree ('"' + (Join-Path $env:SystemRoot 'System32\PING.EXE') + '" -n 60 127.0.0.1')
    [System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'foreign-pid.txt'), [string]$foreignPid, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_ENGINELOGS "watchdog_log_$foreignPid.txt"), "watchdog started`r`nCrash occurred`r`n", $utf8)
    exit 0
}
if ($behavior -eq 'relaunchexit' -or $behavior -eq 'relaunchsleep') {
    $strayPid = New-ProcessOutsideTree $sleeperCommand
    [System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'stray-pid.txt'), [string]$strayPid, $utf8)
    if ($behavior -eq 'relaunchsleep') {
        Start-Sleep -Seconds 120
        exit 0
    }
}
if ($behavior -eq 'crash') {
    Start-Sleep -Seconds 120
    exit 0
}
if ($behavior -eq 'crashexit') { exit 0 }
if ($behavior -eq 'crashlate') {
    # Exits at once; about 1 s later a helper appends 'Crash occurred' to this process's watchdog log.
    $ownLog = Join-Path $env:FAKEGAME_ENGINELOGS "watchdog_log_$PID.txt"
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -WindowStyle Hidden `
        -ArgumentList ('/c ping -n 2 127.0.0.1 >nul & echo Crash occurred>>"' + $ownLog + '"')
    exit 0
}
if ($behavior -eq 'relaunch') {
    # Like a game that relaunched itself: a sleeping process outside this process tree (created via WMI, so it
    # has no parent here) crashes - its watchdog log says 'Crash occurred' - and this process exits without a result.
    $strayPid = New-ProcessOutsideTree $sleeperCommand
    [System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'stray-pid.txt'), [string]$strayPid, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_ENGINELOGS "watchdog_log_$strayPid.txt"), "watchdog started`r`nCrash occurred`r`n", $utf8)
    exit 0
}
if ($behavior -eq 'sleep') {
    Start-Sleep -Seconds 120
    exit 0
}
if ($behavior -eq 'child') {
    # Parent that owns a child process; the child PID goes to child-pid.txt.
    $child = Start-Process -FilePath $selfExe `
        -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru -NoNewWindow
    [System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'child-pid.txt'), [string]$child.Id, $utf8)
    Start-Sleep -Seconds 120
    exit 0
}
$dialogs = @{
    modchange         = @{ Title = 'Mod change detected'; Buttons = 'OK' }
    modchangeokcancel = @{ Title = 'Mod change detected'; Buttons = 'OKCancel' }
    modchangeyesno    = @{ Title = 'Mod change detected'; Buttons = 'YesNo' }
    otherdialog       = @{ Title = 'Some other dialog'; Buttons = 'OK' }
}
if ($behavior -and $dialogs.ContainsKey($behavior)) {
    # A real #32770 dialog owned by this process, like the engine's; returns only once it is closed.
    # Engine dialog, measured 2026-11-01 on v1.4.8: #32770, one push button, confirmed via the single-button rule.
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = $dialogs[$behavior]
    $null = [System.Windows.Forms.MessageBox]::Show('A change in your active mods was detected.', $dialog.Title,
        [System.Windows.Forms.MessageBoxButtons]$dialog.Buttons)
}
if ($behavior -eq 'slow') {
    Start-Sleep -Seconds 6   # then completes normally
}
if ($behavior -eq 'badjson' -and $harnessName -eq 'TestRig') {
    [System.IO.File]::WriteAllText((Join-Path $harnessDir 'run-result.json'), '{ "schema": 1, "status": ', $utf8)
}
elseif ($behavior -ne 'noresult') {
    if ($harnessName -eq 'TestRig' -and $behavior -ne 'txtonly') {
        $json = '{"schema":1,"status":"Completed","reason":"","seed":7,"mode":"WarSails","daysRequested":1,"daysReached":1,"realSeconds":25,"gameDaysPerRealMinute":2.41,"playerMapEvents":0,' +
            '"modules":[{"id":"Native","version":"v1.4.8"}],"exceptions":{"total":0,"own":0,"unhandled":0,"top":[]},' +
            '"scenarios":[{"id":"soak","status":"Passed","seconds":25}],"checks":[{"name":"daysReached","expected":">= 1","actual":"1","passed":true}]}'
        $tmp = Join-Path $harnessDir 'run-result.json.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        Move-Item -LiteralPath $tmp -Destination (Join-Path $harnessDir 'run-result.json') -Force
    }
    else {
        [System.IO.File]::WriteAllText((Join-Path $harnessDir 'result.txt'), "status=Completed`r`ndaysReached=1`r`n", $utf8)
    }
}
exit 0
