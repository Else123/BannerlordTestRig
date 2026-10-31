# Fake "Bannerlord" for the agent end-to-end tests. Started by the agent as
#   powershell.exe -NoProfile -File fake-game.ps1 /singleplayer _MODULES_*...*_MODULES_
# Inputs (environment, inherited from the test):
#   FAKEGAME_DOCS      the documentsRoot the agent uses
#   FAKEGAME_BEHAVIOR  complete (default) | sleep | noresult | child (sleeps, owns a sleeping
#                      child process, PID in child-pid.txt) | slow (completes after 6 s)
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GameArguments)

$ErrorActionPreference = 'Stop'
$docs = Join-Path $env:FAKEGAME_DOCS 'Mount and Blade II Bannerlord'
$modDir = Join-Path $docs 'CoherentWarAI'
$harnessDir = Join-Path $modDir 'harness'
New-Item -ItemType Directory -Path $harnessDir -Force | Out-Null

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'fake-args.txt'), ($GameArguments -join ' '), $utf8)
[System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'fake-runcfg.txt'), [System.IO.File]::ReadAllText((Join-Path $harnessDir 'run.cfg')), $utf8)
[System.IO.File]::WriteAllText((Join-Path $modDir 'CoherentWarAI.log'), "fake mod log`r`n", $utf8)
[System.IO.File]::WriteAllText((Join-Path $harnessDir 'harness.log'), "harness started`r`nharness day 1 reached`r`n", $utf8)

$behavior = $env:FAKEGAME_BEHAVIOR
if ($behavior -eq 'sleep') {
    Start-Sleep -Seconds 120
    exit 0
}
if ($behavior -eq 'child') {
    # Parent that owns a child process; the child PID goes to child-pid.txt.
    $child = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru
    [System.IO.File]::WriteAllText((Join-Path $env:FAKEGAME_DOCS 'child-pid.txt'), [string]$child.Id, $utf8)
    Start-Sleep -Seconds 120
    exit 0
}
if ($behavior -eq 'slow') {
    Start-Sleep -Seconds 6   # then completes normally
}
if ($behavior -ne 'noresult') {
    [System.IO.File]::WriteAllText((Join-Path $harnessDir 'result.txt'), "status=Completed`r`ndaysReached=1`r`n", $utf8)
}
exit 0
