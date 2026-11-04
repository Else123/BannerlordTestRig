# Fake "Bannerlord" for the agent end-to-end tests. Started by the agent as
#   TestRigFakeGame.exe -NoProfile -File fake-game.ps1 /singleplayer _MODULES_*...*_MODULES_
# (TestRigFakeGame.exe is a renamed copy of powershell.exe, made by the tests.)
# Inputs (environment, inherited from the test):
#   FAKEGAME_DOCS      the documentsRoot the agent uses
#   FAKEGAME_NOMODLOG  set (any value): do not create the CoherentWarAI mod log folder or file
#   FAKEGAME_MODLOGS   set (any value): also write the logs of the other mods (Configs\AutoTrader.log,
#                      SmithingSuite\smithingsuite.log, CompanionManagementSuite\companion-suite.log)
#   FAKEGAME_BEHAVIOR  complete (default) | sleep | noresult | child (sleeps, owns a sleeping
#                      child process, PID in child-pid.txt) | slow (completes after 6 s) |
#                      modchange (blocking message box 'Mod change detected' with OK, completes after
#                      it is closed) | modchangeokcancel (same, OK/Cancel) | modchangeyesno (same, Yes/No)
#                      | otherdialog (OK box titled 'Some other dialog')
#                      (complete: with health=<ids> in run.cfg the result lists the health bracket lines
#                      <id>@0 ..., soak, <id>@<days> ..., all Passed)
#                      | badjson (invalid run-result.json)
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
#                      | unhandled (appends a harness.log line '<s> UnhandledException (terminating=True): ...', then hangs)
#                      | unhandledexit (appends the same line, then exits at once without a result)
#                      | unhandledthenresult (appends the same line, 2 s later the final run-result.json
#                      (status Aborted, reason unhandled:Campaign), then hangs)
#                      | completedthenunhandled (final run-result.json (status Completed, unhandled 0), then
#                      the same line, 3.5 s later the result rewritten with unhandled 1 (like the harness after a crash
#                      during shutdown), then hangs)
#                      | unhandledlate (appends the same line after 3 s, then hangs)
#                      | nolog (writes no harness.log at all, then hangs)
#                      | alivesleep (appends one '<s> Alive: phase=...' line, then hangs)
#                      | firstchancehang (appends one Alive line, then a FirstChance line every second, like a background
#                      thread while the main thread is blocked)
#                      | crashafter (no Alive line; 'Crash occurred' reaches the watchdog log after 6 s, then hangs)
#                      | alivecrash (appends one Alive line, 'Crash occurred' in the watchdog log at once, then hangs)
#                      | safemode (blocking Yes/No message box titled 'Safe Mode'; writes the answer (Yes|No) to
#                      fake-safemode-answer.txt in FAKEGAME_DOCS, then completes)
#                      | safemodeok (blocking message box titled 'Safe Mode' with only OK, completes after it is closed)
#                      | firstchance (appends a FirstChance line that merely contains the word UnhandledException, then
#                      completes after 3 s)
#                      | partial (appends the UnhandledException line in two pieces 3 s apart, the first without a line
#                      break, then hangs)
#                      | runningsleep (one Alive line, run-result.json with status Running, then hangs)
#                      | resultthenslow (one Alive line, writes the final result, then needs 6 s to exit)
#   FAKEGAME_ENGINELOGS the engineLogDir the agent uses: if set, watchdog_log_<pid>.txt is written there
#                      (needed by crash, crashexit, crashlate, relaunch, crashforeign, crashfirst, crashafter and alivecrash)
# Snapshots for the tests (in FAKEGAME_DOCS): fake-bannerlordconfig.txt and fake-mcm.json (the configs as the game saw
# them, if present) and fake-mcm-files.txt (every file below Configs\ModSettings\Global, relative, one per line).
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GameArguments)

$ErrorActionPreference = 'Stop'
$docs = Join-Path $env:FAKEGAME_DOCS 'Mount and Blade II Bannerlord'
$modDir = Join-Path $docs 'CoherentWarAI'
$harnessDir = Join-Path (Join-Path $docs 'TestRig') 'harness'   # run.cfg, harness.log and run-result.json (via .tmp + Move)
New-Item -ItemType Directory -Path $harnessDir -Force | Out-Null

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'fake-args.txt'), ($GameArguments -join ' '), $utf8)
[System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'fake-runcfg.txt'), [System.IO.File]::ReadAllText((Join-Path $harnessDir 'run.cfg')), $utf8)
# The ownAssemblies line of run.cfg ('' if absent), for the tests.
$ownLine = @([System.IO.File]::ReadAllLines((Join-Path $harnessDir 'run.cfg')) | Where-Object { $_ -like 'ownAssemblies=*' }) -join ''
[System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'fake-ownassemblies.txt'), $ownLine, $utf8)
if (-not $env:FAKEGAME_NOMODLOG) {
    New-Item -ItemType Directory -Path $modDir -Force | Out-Null   # the mod log folder exists independently of the harness folder
    [System.IO.File]::WriteAllText((Join-Path $modDir 'CoherentWarAI.log'), "fake mod log`r`n", $utf8)
}
if ($env:FAKEGAME_MODLOGS) {
    foreach ($relative in @('Configs\AutoTrader.log', 'SmithingSuite\smithingsuite.log', 'CompanionManagementSuite\companion-suite.log')) {
        $logPath = Join-Path $docs $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $logPath) -Force | Out-Null
        [System.IO.File]::WriteAllText($logPath, "fake $relative`r`n", $utf8)
    }
}
if ($env:FAKEGAME_BEHAVIOR -ne 'nolog') {
    [System.IO.File]::WriteAllText((Join-Path $harnessDir 'harness.log'), "harness started`r`nharness day 1 reached`r`n", $utf8)
}

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
function Add-HarnessLog {
    param([string]$Text)
    [System.IO.File]::AppendAllText((Join-Path $harnessDir 'harness.log'), $Text, $utf8)
}
function Add-WatchdogCrash {
    [System.IO.File]::AppendAllText((Join-Path $env:FAKEGAME_ENGINELOGS "watchdog_log_$PID.txt"), "Crash occurred`r`n", $utf8)
}
$aliveLine = "10.0 Alive: phase=Campaign`n"
if ($behavior -eq 'unhandled') {
    Add-HarnessLog "5.0 UnhandledException (terminating=True): System.InvalidOperationException: boom`n"
    Start-Sleep -Seconds 120
    exit 0
}
if ($behavior -eq 'unhandledthenresult') {
    Add-HarnessLog "5.0 UnhandledException (terminating=True): System.InvalidOperationException: then-result`n"
    Start-Sleep -Seconds 2
    $tmp = Join-Path $harnessDir 'run-result.json.tmp'
    [System.IO.File]::WriteAllText($tmp, '{"schema":1,"status":"Aborted","reason":"unhandled:Campaign","exceptions":{"total":1,"own":0,"unhandled":1,"top":[]},"scenarios":[]}', $utf8)
    Move-Item -LiteralPath $tmp -Destination (Join-Path $harnessDir 'run-result.json') -Force
    Start-Sleep -Seconds 120
    exit 0
}
if ($behavior -eq 'completedthenunhandled') {
    $tmp = Join-Path $harnessDir 'run-result.json.tmp'
    $resultPath = Join-Path $harnessDir 'run-result.json'
    [System.IO.File]::WriteAllText($tmp, '{"schema":1,"status":"Completed","exceptions":{"total":0,"own":0,"unhandled":0,"top":[]},"scenarios":[]}', $utf8)
    Move-Item -LiteralPath $tmp -Destination $resultPath -Force
    Add-HarnessLog "5.0 UnhandledException (terminating=True): System.InvalidOperationException: during-shutdown`n"
    Start-Sleep -Milliseconds 3500
    [System.IO.File]::WriteAllText($tmp, '{"schema":1,"status":"Completed","exceptions":{"total":1,"own":0,"unhandled":1,"top":[]},"scenarios":[]}', $utf8)
    Move-Item -LiteralPath $tmp -Destination $resultPath -Force
    Start-Sleep -Seconds 120
    exit 0
}
if ($behavior -eq 'unhandledlate') {
    Start-Sleep -Seconds 3
    Add-HarnessLog "5.0 UnhandledException (terminating=True): System.InvalidOperationException: late`n"
    Start-Sleep -Seconds 120
    exit 0
}
if ($behavior -eq 'unhandledexit') {
    Add-HarnessLog "5.0 UnhandledException (terminating=True): System.InvalidOperationException: last-words`n"
    exit 0
}
if ($behavior -eq 'nolog' -or $behavior -eq 'alivesleep') {
    if ($behavior -eq 'alivesleep') { Add-HarnessLog $aliveLine }
    Start-Sleep -Seconds 120
    exit 0
}
if ($behavior -eq 'firstchancehang') {
    Add-HarnessLog $aliveLine
    for ($i = 1; $i -le 120; $i++) {
        Start-Sleep -Seconds 1
        Add-HarnessLog "$(10 + $i).0 FirstChance #$i [Worker]: System.IO.IOException: background noise`n"
    }
    exit 0
}
if ($behavior -eq 'crashafter') {
    Start-Sleep -Seconds 6
    Add-WatchdogCrash
    Start-Sleep -Seconds 120
    exit 0
}
if ($behavior -eq 'alivecrash') {
    Add-HarnessLog $aliveLine
    Add-WatchdogCrash
    Start-Sleep -Seconds 120
    exit 0
}
if ($behavior -eq 'partial') {
    Add-HarnessLog '5.0 UnhandledException (terminating=Tr'
    Start-Sleep -Seconds 3
    Add-HarnessLog "ue): System.InvalidOperationException: partial-boom`n"
    Start-Sleep -Seconds 120
    exit 0
}
if ($behavior -eq 'resultthenslow') { Add-HarnessLog $aliveLine }   # arms the silence watch before the result
if ($behavior -eq 'firstchance') {
    Add-HarnessLog "5.0 FirstChance #1 [Main]: System.Exception: a handler named UnhandledException saw it`n"
    Start-Sleep -Seconds 3   # then completes normally
}
if ($behavior -eq 'runningsleep') {
    Add-HarnessLog $aliveLine
    $tmp = Join-Path $harnessDir 'run-result.json.tmp'
    [System.IO.File]::WriteAllText($tmp, '{"schema":1,"status":"Running","scenarios":[]}', $utf8)
    Move-Item -LiteralPath $tmp -Destination (Join-Path $harnessDir 'run-result.json') -Force
    Start-Sleep -Seconds 120
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
    safemode          = @{ Title = 'Safe Mode'; Buttons = 'YesNo' }
    safemodeok        = @{ Title = 'Safe Mode'; Buttons = 'OK' }
}
if ($behavior -and $dialogs.ContainsKey($behavior)) {
    # A real #32770 dialog owned by this process, like the engine's; returns only once it is closed.
    # Engine dialog, measured 2026-11-01 on v1.4.8: #32770, one push button, confirmed via the single-button rule.
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = $dialogs[$behavior]
    $answer = [System.Windows.Forms.MessageBox]::Show('A change in your active mods was detected.', $dialog.Title,
        [System.Windows.Forms.MessageBoxButtons]$dialog.Buttons)
    if ($behavior -eq 'safemode') {
        [System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'fake-safemode-answer.txt'), [string]$answer, $utf8)
    }
}
if ($behavior -eq 'slow') {
    Start-Sleep -Seconds 6   # then completes normally
}
if ($behavior -eq 'badjson') {
    [System.IO.File]::WriteAllText((Join-Path $harnessDir 'run-result.json'), '{ "schema": 1, "status": ', $utf8)
}
elseif ($behavior -ne 'noresult') {
    # With health=<ids> in run.cfg the lines of the health bracket, in the harness order: <id>@0 per id, soak,
    # <id>@<days> per id (days from run.cfg), all Passed.
    $cfgLines = @([System.IO.File]::ReadAllLines((Join-Path $harnessDir 'run.cfg')))
    $healthIds = @($cfgLines | Where-Object { $_ -like 'health=*' } | ForEach-Object { $_.Substring(7).Split(',') })
    $cfgDays = @($cfgLines | Where-Object { $_ -like 'days=*' } | ForEach-Object { $_.Substring(5) }) -join ''
    $lineIds = @($healthIds | ForEach-Object { "$_@0" }) + @('soak') + @($healthIds | ForEach-Object { "$_@$cfgDays" })
    $scenarioLines = @($lineIds | ForEach-Object {
            $seconds = if ($_ -ceq 'soak') { 25 } else { 1 }
            '{"id":"' + $_ + '","status":"Passed","seconds":' + $seconds + '}'
        }) -join ','
    $json = '{"schema":1,"status":"Completed","reason":"","seed":7,"mode":"WarSails","daysRequested":1,"daysReached":1,"realSeconds":25,"gameDaysPerRealMinute":2.41,"playerMapEvents":0,' +
        '"modules":[{"id":"Native","version":"v1.4.8"}],"exceptions":{"total":0,"own":0,"unhandled":0,"top":[]},' +
        '"scenarios":[' + $scenarioLines + '],"checks":[{"name":"daysReached","expected":">= 1","actual":"1","passed":true}]}'
    $tmp = Join-Path $harnessDir 'run-result.json.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, $utf8)
    Move-Item -LiteralPath $tmp -Destination (Join-Path $harnessDir 'run-result.json') -Force
}
if ($behavior -eq 'resultthenslow') { Start-Sleep -Seconds 6 }
exit 0
