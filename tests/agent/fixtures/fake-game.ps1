# Fake "Bannerlord" for the agent end-to-end tests. Started by the agent as
#   powershell.exe -NoProfile -File fake-game.ps1 /singleplayer _MODULES_*...*_MODULES_
# Inputs (environment, inherited from the test):
#   FAKEGAME_DOCS      the documentsRoot the agent uses
#   FAKEGAME_HARNESS   CoherentWarAI (default) | TestRig: Documents subfolder whose harness\ holds run.cfg/result.txt/harness.log
#   FAKEGAME_NOMODLOG  set (any value): do not create the CoherentWarAI mod log folder or file
#   FAKEGAME_BEHAVIOR  complete (default) | sleep | noresult | child (sleeps, owns a sleeping
#                      child process, PID in child-pid.txt) | slow (completes after 6 s) |
#                      modchange (blocking message box 'Mod change detected' with OK, completes after
#                      it is closed) | modchangeokcancel (same, OK/Cancel) | modchangeyesno (same, Yes/No)
#                      | otherdialog (OK box titled 'Some other dialog')
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
if (-not $env:FAKEGAME_NOMODLOG) {
    New-Item -ItemType Directory -Path $modDir -Force | Out-Null   # the mod log folder exists independently of the harness folder
    [System.IO.File]::WriteAllText((Join-Path $modDir 'CoherentWarAI.log'), "fake mod log`r`n", $utf8)
}
[System.IO.File]::WriteAllText((Join-Path $harnessDir 'harness.log'), "harness started`r`nharness day 1 reached`r`n", $utf8)

$behavior = $env:FAKEGAME_BEHAVIOR
if ($behavior -eq 'sleep') {
    Start-Sleep -Seconds 120
    exit 0
}
if ($behavior -eq 'child') {
    # Parent that owns a child process; the child PID goes to child-pid.txt.
    $child = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
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
if ($behavior -ne 'noresult') {
    [System.IO.File]::WriteAllText((Join-Path $harnessDir 'result.txt'), "status=Completed`r`ndaysReached=1`r`n", $utf8)
}
exit 0
