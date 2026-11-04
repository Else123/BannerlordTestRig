# Job protocol (schema 1, slice S1)

Binding contract between the runner (`runner/`, dev PC) and the agent (`agent/`, test PC).
PowerShell 5.1 on both sides. All JSON is UTF-8 **without BOM**, written with
`ConvertTo-Json -Depth 10`. Every "atomic" write goes to `<name>.tmp` first and is then renamed.
Results are **data**: the runner only parses them (`ConvertFrom-Json`) and never executes
anything from them.

## Folders on the test PC

```
C:\TestRig\
  agent\                 TestRigAgent.ps1, Save-TestRigBaseline.ps1, agent.config.json
  baseline\              Configs\... (recorded game configuration, see "Baseline")
  queue\jobs\<jobId>\    package.zip, job.json | job.claimed.json | job.withdrawn.json, state.json, abort
  queue\results\<jobId>\ <runId>\..., done.json (written last)
  work\<jobId>\          local copy + extracted package (DLLs are never loaded from the queue)
```

`jobId` = `yyyyMMdd-HHmmss-<4 lowercase hex>` (UTC), so sorting by name means sorting by age.

## Lifecycle

1. **Publish (runner):** create `jobs\<jobId>\`, copy `package.zip`, copy `job.json` as
   `job.json.tmp`, then rename it to `job.json`. `job.json` appearing is the only signal.
2. **Claim (agent):** rename `job.json` -> `job.claimed.json`. If the rename fails, someone else
   won: skip the job. The agent handles the oldest claimable job first, one job at a time.
3. **Withdraw (runner):** if `job.json` still exists after the claim timeout (default 120 s), the
   runner renames it to `job.withdrawn.json`. The remote side reports
   `{ withdrawn, jobJsonPresent, claimed }`. `withdrawn` -> runner exit 3 ("agent offline").
   `claimed` (`job.claimed.json` exists) -> keep waiting. `job.json` still present (rename
   blocked, e.g. by a virus scanner holding the file) -> retry on the next polls, at most 5
   attempts; if all fail, exit 3 with a warning that the job may still run.
4. **Heartbeat (agent):** `state.json` in the job folder, rewritten atomically at least every
   15 s while the job is active. `beat` increases by 1 on each write. The runner never compares
   clocks: if `beat` does not change for 120 s, the agent counts as unresponsive (exit 3) and
   the runner sends a best-effort abort.
5. **Abort (runner):** create an empty file `abort` in the job folder. The agent checks for it at
   least every 5 s while a run is active, kills the game (process tree), classifies the run
   `Aborted`, skips the remaining runs and finishes the job.
6. **Finish (agent):** write all run artifacts to `results\<jobId>\<runId>\`, then `done.json`
   atomically and last.
7. **Fetch (runner):** after `done.json` exists, copy `results\<jobId>\` to
   `out\results\<jobId>.partial\` on the dev PC and rename it to `<jobId>` only after the copy
   succeeded. A leftover `.partial` is deleted before a new attempt.

State polls and the fetch are retried up to 3 times with backoff on a transport error; the final
failure is exit 1. Publish, withdraw and abort are not retried.

A job counts as **open** if its folder has `job.json` or `job.claimed.json` and there is no
`results\<jobId>\done.json`. The runner refuses to publish while any job is open (exit 1, the
message names the job). Withdrawn jobs are not open. The agent closes orphaned claimed jobs on
restart (see "Agent restart"); any other stuck open job is cleaned up manually.

## `job.json`

```json
{
  "schema": 1,
  "jobId": "20261031-153000-a1b2",
  "createdUtc": "2026-10-31T15:30:00Z",
  "expectedGameVersion": null,
  "package": { "file": "package.zip", "sha256": "<uppercase hex>" },
  "repos": [ { "name": "BannerlordCoherentWarAI", "sha": "<git sha or null>", "dirty": true } ],
  "modules": [ "Bannerlord.Harmony", "...", "CoherentWarAI", "CoherentWarAI.TestHarness" ],
  "runs": [
    {
      "runId": "r1",
      "kind": "soak",
      "harness": "CoherentWarAI",
      "seed": 1,
      "days": 1,
      "mode": "WarSails",
      "stallMinutes": 5,
      "budgetMinutes": 60,
      "hardTimeoutMinutes": 20
    }
  ]
}
```

- `modules` is the full `_MODULES_` load order; the agent passes it unchanged.
- `expectedGameVersion`: the runner sets it to the `Singleplayer` `Value` of the tower's
  `<towerGamePath>\bin\Win64_Shipping_Client\Version.xml`. A missing or unreadable file -> runner exit 1
  before anything is published. `towerGamePath` not configured -> `null` and one
  `WARN towerGamePath is not configured: game version and module versions not checked.` The agent checks
  it in preflight (see "Preflight"): `null` or `""` = not checked.
- `kind`: `soak` (default shape above) or `scenarios`. A `scenarios` run needs harness `TestRig` and the extra field
  `runs[].scenarios`: a non-empty JSON array of unique (case-insensitive) scenario ids matching `^[A-Za-z0-9._-]+$` (also with one
  element). A `soak` run has no `scenarios` field. Anything else (missing, empty, not an array of strings, an empty,
  invalid or duplicate id) -> job `rejected` (schema check, like an invalid `health`), so the agent never writes an empty
  `scenarios=` line. The agent writes the ids to `run.cfg` (section "`run.cfg`"); the harness runs exactly these scenarios.
- `health` (optional, `soak` runs only): the health bracket (F-S6-1), a non-empty JSON array of unique (case-insensitive)
  scenario ids with the same pattern as `scenarios` (also with one element); only with harness `TestRig`. On a `scenarios` run, with
  another harness, empty, not an array of strings or with an invalid or duplicate id -> job `rejected` (schema check).
  The agent writes the ids to `run.cfg` as `health=` (section "`run.cfg`").
- `ownAssemblies` (optional, any `kind`): a non-empty JSON array of unique (case-insensitive) simple DLL names matching
  `^[A-Za-z0-9._-]+$` (also with one element); only with harness `TestRig`. With another harness, empty, not an array of
  strings or with an invalid or duplicate name -> job `rejected` (schema check). The agent writes exactly this list to
  `run.cfg` as `ownAssemblies=` instead of the derived one (section "`run.cfg`").
- `harness`: selects the in-game harness; `run.cfg`, the result file and `harness.log` live in its folder
  below `<MyDocuments>\Mount and Blade II Bannerlord\`. Anything else -> run classified `SetupError`.

  | `harness` | Folder | Harness module id in `modules` |
  |-----------|--------|--------------------------------|
  | `CoherentWarAI` | `CoherentWarAI\harness` | `CoherentWarAI.TestHarness` |
  | `TestRig` | `TestRig\harness` | `TestRig.Harness` |
- `mode`: `WarSails` | `NoDlc` | `FeatureOff` (as in the CoherentWarAI harness).
- Unknown `schema` or a missing required field -> job finishes with `done.json` status `rejected`.

## `package.zip`

Top level folder `Modules\<ModuleId>\...`. The agent installs a module only if its id is in the
agent's allowlist (`agent.config.json`). Any other module id in the package -> status `rejected`
before anything is installed. Native, NavalDLC and Workshop modules are never touched.

## `state.json` (job folder)

```json
{ "schema": 1, "jobId": "...", "beat": 17, "state": "running", "runId": "r1",
  "runIndex": 1, "runCount": 1, "updatedUtc": "...", "lastHarnessLine": "...", "message": null }
```

`state`: `claimed` | `preflight` | `installing` | `running` | `collecting` | `finished`.

`lastHarnessLine`: the last non-empty line of `harness.log` (from its last 8 KB), skipping the harness's `Alive:` beat
lines so the last progress line stays visible; the last `Alive:` line only if the tail holds nothing else.

## Preflight (job level)

Before anything is installed the agent checks, in this order; the first failure ends the job with
`done.json` status `blocked` and the reason in `message`:

1. Bannerlord is not already running.
2. The game executable exists.
3. A `steam` process is running.
4. Game version: `Singleplayer` `Value` of `<gamePath>\bin\Win64_Shipping_Client\Version.xml` must equal
   `job.expectedGameVersion` (exact, case-sensitive) when that is a non-empty string. `null` or `""` = not
   checked. A non-string value -> `blocked`. A `Version.xml` that cannot be read while a version is expected
   -> `blocked`.
5. Every id in `job.modules` is present: in the package, else as `<gamePath>\Modules\<id>\SubModule.xml`,
   else in the workshop folder (`workshopRoot`; matched by the `<Id value>` of each item's `SubModule.xml`).
   All missing ids are listed in the message.

The versions found here go into every `agent-run.json` (`gameVersion`, `moduleVersions`).

## `results\<jobId>\<runId>\agent-run.json`

```json
{ "schema": 1, "runId": "r1", "exitClass": "Completed", "pid": 1234,
  "startedUtc": "...", "endedUtc": "...", "artifacts": [ "run-result.json", "harness.log" ],
  "baselineRestored": true,
  "baselineSha256": { "Configs/BannerlordConfig.txt": "<uppercase hex>" },
  "gameVersion": "v1.4.8",
  "moduleVersions": [ { "id": "Bannerlord.Harmony", "version": "v2.3.6", "source": "workshop" } ],
  "message": null, "dismissedDialogs": [ "Mod change detected" ] }
```

`artifacts` lists what was copied to the run folder (only files that exist, written during the run):
`run-result.json`, `result.txt`, `harness.log`, the mod logs (each only if present; a missing one is no error) and the
engine logs `rgl_log_<pid>.txt` / `rgl_log_errors_<pid>.txt` / `watchdog_log_<pid>.txt`. The mod logs are copied
under their file name, without a size cap, from below `<MyDocuments>\Mount and Blade II Bannerlord\`:

| Artifact | Source (below the game's documents folder) | Mod |
|----------|--------------------------------------------|-----|
| `CoherentWarAI.log` | `CoherentWarAI\CoherentWarAI.log` | CoherentWarAI |
| `AutoTrader.log` | `Configs\AutoTrader.log` (`EngineFilePaths.ConfigsPath`) | AutoTraderSpeed |
| `smithingsuite.log` | `SmithingSuite\smithingsuite.log` | SmithingSuite |
| `companion-suite.log` | `CompanionManagementSuite\companion-suite.log` | CompanionManagementSuite |

A mod log is only copied if its last write time is not older than the run start (a stale log from an earlier session
is skipped). That check only proves the file was touched during the run, not that it holds only this run:
`smithingsuite.log` is appended across sessions (the mod rotates it to `smithingsuite.log.old` once it passes
about 5 MB), so the copy can contain earlier sessions. `AutoTrader.log` and `companion-suite.log` are rewritten at every
game start (the previous session moves to `AutoTrader.previous.log` / `companion-suite.prev.log`), so they hold
the current session only.

`baselineRestored`: `true` if the baseline was restored before this run, `false` if the restore failed or was not
reached. `baselineSha256`: relative path (with `/`) -> uppercase hex SHA-256 of every restored file, `null` if not
restored. `gameVersion`: installed game version, `string|null`. `moduleVersions`: one entry per id of
`job.modules`, in that order: `version` is `string|null` (module without `Version`), `source` is `package` |
`game` | `workshop` (where the agent found the module, checked in this order).

`dismissedDialogs`: titles of game dialogs the agent answered during the run, empty if none.
While the game runs, the agent checks its visible standard dialogs (`#32770`) every second. Only two exact titles
are answered: `Mod change detected` (shown by the engine on the first start after the module list changed) gets OK;
`Safe Mode` (the engine's Yes/No question "Game shut down unexpectedly on previous session. Would you like to enable
safe mode?") gets No, via the box's `IDNO` button, whatever the language of its captions. Any other dialog title is
logged once per run and left alone.

Safe Mode prevention: the engine writes `safely_exited = 0` into
`<documentsRoot>\Mount and Blade II Bannerlord\Configs\engine_config.txt` when it starts and `1` only on a clean exit,
so after every run the agent had to kill the next start would block on the `Safe Mode` question (measured 2026-11-02).
Right before every launch the agent therefore sets a line `safely_exited = 0` to `1`: exactly that one byte is
rewritten in place, everything else in the file (encoding, BOM, line endings, other values) stays as it is, and
`agent.log` gets one line ("previous run did not exit cleanly"). Reading and writing go through one exclusive handle
(no other handle may have the file open in between). A missing file or no such line: nothing happens. While a
`Bannerlord` process runs the file belongs to that game: the reset is skipped and logged. If the file cannot be opened
or written, the agent logs it and launches anyway (the dialog answer above is the fallback).

`exitClass` (names for the exit codes of `Run-SoakTest.ps1` in BannerlordCoherentWarAI):

| exitClass | Meaning |
|---|---|
| `Completed` | game ended, the harness result has status `Completed` (`run-result.json`, else `result.txt`) |
| `SetupError` | precondition or setup failed before or at launch |
| `LaunchFailed` | process exited within 30 s and the harness log never appeared |
| `HardTimeout` | `hardTimeoutMinutes` expired, game killed |
| `NotCompleted` | game ended, but no usable result (missing, or `run-result.json` invalid JSON) or status not `Completed` |
| `CleanupFailed` | the game could not be stopped or `run.cfg` could not be removed |
| `Crashed` | the watchdog log reported `Crash occurred`, or `harness.log` gained an `UnhandledException` line; game killed (see "Crash watchdog" and "Early signals from harness.log") |
| `Hung` | harness `TestRig` only: no new `Alive:` line in `harness.log` for more than 60 s, game killed (see "Early signals from harness.log") |
| `Aborted` | `abort` file seen, game killed |

If several apply, the first in this order wins: `CleanupFailed` > `Aborted` > `SetupError` > `Crashed` >
`Hung` > `HardTimeout` > `Completed` > `LaunchFailed` > `NotCompleted`.

### Early signals from harness.log

About once per second the agent reads only what `harness.log` gained since the last read (it remembers the
byte position; a missing, locked or half-written file is tolerated, and a partial last line waits for its
line break). `harness.log` is deleted before the launch, so only lines of this run count. Two signals end the
run before `hardTimeoutMinutes`; the agent then kills the process tree (after a silence at once, after an
`UnhandledException` line after a short grace, see below). After the game has ended (on its own or killed) the agent
reads the growth once more, so an `UnhandledException` line written right before the exit still counts (`Crashed`,
which wins over `Hung` and `HardTimeout`).

- **`UnhandledException` line** (all harnesses): a complete line whose text after the leading `<seconds> `
  timestamp starts with `UnhandledException` gives `exitClass` `Crashed`; `message` is `Harness reported: <that line>`
  (single line, printable ASCII, cut to 200 characters). A `FirstChance` line that merely contains the
  word does not count. The line ends the run whatever its `terminating=` value: under the .NET Framework 4.8 default
  policy an unhandled exception terminates the process (the game ships no `Bannerlord.exe.config` that changes it).
  Right after the line the harness writes its final `run-result.json` (status `Aborted`, reason `unhandled:<phase>`,
  updated exception counts; a result that was final already is rewritten with the updated counts), so the agent waits
  up to 5 s (`UnhandledResultGraceSeconds`) until the game has exited or the harness result was written after the
  agent read the line and has a status other than `Running`, then kills; the result is collected as an artifact.
- **Silence** (harness `TestRig` only; the CoherentWarAI harness writes no beat): measured on the harness's beat
  only, the lines whose text after the `<seconds> ` timestamp starts with `Alive:`. The harness writes one every
  10 s from the main thread (`OnApplicationTick`; the largest gap measured in a real run was 14.5 s). The watch is
  armed by the first `Alive:` line of the run, so the long gap between module load and the first tick is never a
  hang, and a game that never writes an `Alive:` line ends by `hardTimeoutMinutes` instead. Other lines (e.g.
  `FirstChance` lines of background threads) neither arm the watch nor keep the run alive. More than 60 s without a
  new `Alive:` line gives `exitClass` `Hung`; `message` states the seconds of silence and the last harness line that
  is not an `Alive:` line (`(none)` if there is none), followed by `; open dialogs: '<title>' (<state>), ...` when the
  agent's last dialog check (once a second) found game dialogs open: `(not answered)` for other titles,
  `(answer failed)` for a known title whose answer could not be sent (e.g. a `Safe Mode` box without a No button),
  `(still open after answer)` for a known title still open 5 s after its answer was sent; so a blocking native dialog
  is visible in the message. Before deciding `Hung`
  the agent looks once more at the watchdog log and at the growth of
  `harness.log`; a crash found there gives `Crashed` instead. The watch ends once the harness has written its final
  result: `run-result.json` (or `result.txt`) with a status other than `Running`. `run-result.json` is rewritten
  after every scenario with status `Running`, so its mere existence does not end the watch. A result that cannot be
  read at that moment (e.g. while it is being replaced) is looked at again on the next two passes (about one second
  apart) before the run counts as `Hung`.

### Crash watchdog

About once per second while the game runs, the agent looks for `Crash occurred` in
`<engineLogDir>\watchdog_log_<pid>.txt` (fallback, e.g. after a relaunch under another PID: another
`watchdog_log_*.txt`, most recently written first). At the launch the agent records the name and length of every
`watchdog_log_*.txt`; only a new file, or the bytes appended to a recorded file after the launch, count (a file that got
shorter counts as replaced and is read in full). An old crash log, or a log from an earlier run under a reused PID,
therefore never counts, and neither does a mere write to an old log. If `engineLogDir` does not exist at the launch the
agent logs that once per run (no watchdog log is seen unless the game creates the folder).
On a hit it kills the process tree at once (the crash dialog would otherwise block the game until the hard timeout) and
classifies the run `Crashed`; `message` is `Crash occurred (<watchdog log name>); last line: <last harness.log line that
is not an Alive: line, or (none)>` (the line, read once more after the kill, shows what the game did when it crashed). After the game exited on its own the check repeats for up to 2 s (not after an abort, a
hard timeout, a hang or a supervision error); a crash found only then still counts as `Crashed`. After every launched run
(whatever its outcome) the agent stops every process with the name of `gameExecutable` (without `.exe`) that started at
or after the launch, except the launched process; processes with other names are never touched. A process whose start
time cannot be read (e.g. an elevated game) is not stopped but makes the run `CleanupFailed`, as does a process (or the
launched process tree) that cannot be stopped, or a `run.cfg` that cannot be removed: the job is then `failed` and no
further run starts. `watchdog_log_<pid>.txt` is copied to the run folder when it exists.

## Baseline

The agent keeps the game configuration of the test PC at a recorded baseline (`baselineRoot`, recorded once with
`agent\Save-TestRigBaseline.ps1`, see `docs/SETUP-GAMESERVER.md`). The folder mirrors
`<MyDocuments>\Mount and Blade II Bannerlord\`:

- `Configs\BannerlordConfig.txt` (required)
- `Configs\ModSettings\Global\<folder>\*` for the managed MCM folders `CoherentWarAI`, `AutoTraderSpeed`,
  `SmithingSuite`, `CompanionManagementSuite` (`$script:BaselineMcmFolders` in `TestRigAgent.ps1`).

Restore: delete the files in the managed folders that the baseline does not have (and empty folders the baseline lacks;
empty folders the baseline has are kept), copy the baseline files, verify the SHA-256 of each copied file, verify that
no extra file is left. The restore touches nothing else (`engine_config.txt`, `LauncherData.xml`, `ModLogs`, other
folders). The one write of the agent outside the managed files is not part of the restore: the `safely_exited` reset in
`engine_config.txt` before each launch (see "Safe Mode prevention").
Restore fails, before anything is deleted ("Nothing was changed"), when the game documents folder does not exist (it is
never created) or when a reparse point (junction or symlink) is in the managed tree of the documents folder or of the
baseline: `Configs`, `Configs\ModSettings`, `Configs\ModSettings\Global`, `BannerlordConfig.txt`, the managed MCM
folders and their contents. A restore that fails after it started changing the documents tree says "The managed
configuration may be partly restored" instead. The marker file `Configs\.testrig-baseline` that
`Save-TestRigBaseline.ps1` writes into the baseline is not a managed file: the restore neither needs nor copies it.

Agent config: `workRoot`, `documentsRoot` (also its MyDocuments default) and `baselineRoot` (also its default) must be
absolute (`X:\...` or `\\server\share\...`; relative, drive-relative `C:x`, rooted `\x` and the `\\?\` and `\\.\`
device forms are rejected) and are normalized (no trailing backslash except at a drive root; 8.3 short names are
expanded only when the whole path exists). `baselineRoot` must not be, contain or lie inside
`<documentsRoot>\Mount and Blade II Bannerlord` (case-insensitive, whole path segments), and neither `baselineRoot` nor
any existing folder above it may be a junction or symbolic link (through one it could be the documents folder under
another name). A violation makes the agent exit with 1 and `Save-TestRigBaseline.ps1` refuse.

- Before each run: restore, then the per-run patch (section "`run.cfg`" and `docs/SETUP-GAMESERVER.md` section d). A
  failed restore -> the run is `SetupError` with message `Baseline restore failed: ...`; the game is not started.
- Before the first patch of a job the agent writes `<workRoot>\restore-pending`. After the job (also after skipped,
  aborted or rejected jobs): restore again, best effort, if a run reached the restore or the marker exists, and not
  while any Bannerlord process runs (`baselineRestored: false`, `baselineError: "Bannerlord still running"`). The
  outcome goes into `done.json` (`baselineRestored`, `baselineError`). The marker is deleted only after a successful
  restore; if it is still there at agent start (agent died mid-job, or the restore was skipped or failed), the agent
  restores at startup when no Bannerlord runs.
- The agent holds the mutex `Global\BannerlordTestRigConfig` from claiming a job until the job is done.
  `Save-TestRigBaseline.ps1` refuses while it is held, and the agent claims no job while the save holds it.

## Harness result: `run-result.json` / `result.txt`

The harness writes its result into its harness folder. The `TestRig` harness writes `run-result.json`
(schema 1, UTF-8 without BOM, written via `run-result.json.tmp` + rename); the old `CoherentWarAI` harness
writes `result.txt` (`key=value` lines, e.g. `status=Completed`, `daysReached=3`).

```json
{
  "schema": 1, "status": "Completed", "reason": "", "seed": 1, "mode": "WarSails",
  "daysRequested": 1, "daysReached": 1, "realSeconds": 25, "gameDaysPerRealMinute": 2.41,
  "runningDaysPerRealMinute": 3.60, "playerMapEvents": 0,
  "modules": [ { "id": "Native", "version": "v1.4.8" } ],
  "exceptions": { "total": 3, "own": 1, "harness": 0, "vanilla": 2, "unhandled": 0,
    "classification": { "walks": 3, "walkMs": 0.42, "handlerMs": 0.42, "maxHandlerMs": 0.21, "ownExact": true },
    "top": [ { "key": "KeyA", "count": 2 }, { "key": "KeyB", "count": 1 } ] },
  "scenarios": [ { "id": "soak", "status": "Passed", "seconds": 25 } ],
  "checks": [ { "name": "daysReached", "expected": ">= 1", "actual": "1", "passed": true } ]
}
```

`checks[].scenario` (optional string, scenario runs): the id of the scenario the check belongs to; checks without it
belong to the run.

Unknown values are `null`. Scenario `status`: `Passed` | `Failed` | `Error` | `Timeout` | `Skipped` (`Skipped` is produced for
the scenarios that follow a tainted scenario; the runner treats a Skipped requested scenario as a rig error, see below). `exceptions.total` counts first-chance exceptions in the game process, including
the harness's own (e.g. a retried file write); `top` lists the most frequent keys (`<type>: <message> @ <site>`, at most
10000 distinct keys are tracked, later new keys never enter `top`), so its counts add up to at most `total`.
Exception counting starts when the harness module loads (`OnSubModuleLoad`, once `run.cfg` was read and accepted), by
installing the first-chance and unhandled hooks; a later map window only restarts the log budget, not the counters.
`gameDaysPerRealMinute` is `daysReached` per real minute since the harness armed (includes loading and character
creation, so it depends on the load time and on `days`). `runningDaysPerRealMinute` (two decimals) counts only the
Running phase: the days gained from entering it (the tick after the map was reached) until it ends (completion, abort
or taint; while it lasts, until the record is written), per real minute of that span; `null` when the run never
reached Running or the span has no duration. In scenario runs the Running phase includes the time stopped between
`Days` steps.
`exceptions.own` is only counted when `run.cfg` has `ownAssemblies`. An exception is own when any frame of the
throwing thread's live stack (harness frames skipped) comes from an `ownAssemblies` DLL. Every exception gets its own
stack walk until 1000 walks are spent; within that budget `own` is exact. After it, exceptions are answered per group
(exception type and throw site, `<type> @ <declaring type>.<method>`, no message) with the result of the first walked
exception of that group, so `own` becomes an **estimate**: too high (a vanilla throw site whose first walk ran through
an own mod), too low (the first walk of the group did not run through an own mod, but this exception did - a false
negative of the cache), and groups never walked count as not own. A failed classification (logged once) also counts
as not own and makes `own` an estimate (`ownExact` `false`). `exceptions.harness`: not own, and the throwing method (`TargetSite`) is declared in an assembly whose
simple name starts with `TestRig.` (case-insensitive; `TestRig.Harness`, `TestRig.SelfTest`); own wins, so an exception
of `TestRig.SelfTest` in a run that lists it in `ownAssemblies` is own. `exceptions.vanilla` = `total - own - harness`
(everything else, including other Workshop mods). `exceptions.classification`: `walks` = stack walks used (at most
1000), `ownExact` = `false` once an exception was answered without its own walk (budget spent) or a walk failed
(`true` without `ownAssemblies`), `handlerMs` / `maxHandlerMs` = summed / longest time (milliseconds, two decimals,
`Stopwatch`) the first-chance handler spent per exception on key building, the own/harness classification incl. stack
capture and walk, and counting (the `harness.log` write is not included). `walkMs` = the part of `handlerMs` spent in
the handler calls that were granted a walk (counted in `walks`, whether the walk succeeded or failed; stack capture
included). So `walkMs / walks` is the mean handler time of a walked exception and `(handlerMs - walkMs) / (total -
walks)` the mean of all other exceptions (cache hits, groups never walked, and every exception of a run without
`ownAssemblies`; a stack capture for a full `harness.log` line of a new key is included there too). Each handler time is
wall-clock time, so it also contains the wait for the harness lock (other threads' exceptions) and any preemption of
the thread: the values are upper bounds of the pure classification cost. They cover the whole run from the hook
installation on, including module loading and character creation, so `handlerMs` related to the Running phase alone
overstates the share. The log budget is unchanged: it only limits `harness.log` lines, never the counting.
`exceptions.unhandled`: on a terminating unhandled .NET exception the harness counts it and writes `run-result.json`
at once (best effort, values read without a lock, so they can be one tick old). A run still in progress then ends as
`status` `Aborted`, `reason` `unhandled:<phase>`, scenario `Failed` (runner exit `2`, a failure of the mods under test);
the times are those of the crash. A run that had already finished keeps its status, reason, `daysReached` and checks,
and its times frozen at the moment it finished; only `exceptions` is updated. Before the run is armed (module loading,
before the initial state) nothing is written. A native engine crash never reaches this handler: then there is no new
record and `unhandled` stays `0` in any file written earlier. The harness writes the file with up to 4 attempts 75 ms
apart on `IOException` or `UnauthorizedAccessException` (e.g. a virus scanner holding the old file). A config error
has `status` `Aborted`, `reason` `config:...`, run values `null` and `scenarios` `[ { "id": "soak", "status": "Error", "seconds": null } ]`.

Fallback rule (agent and runner): read `run-result.json` if it exists, else `result.txt`. If `run-result.json`
exists but is unreadable, not valid JSON, not a JSON object at top level (array, number, string, `null`), or has no `status`, the run has **no result**: there is no fallback to
`result.txt`; the agent logs it once and classifies `NotCompleted`, the runner warns. Before each launch the agent
deletes `run-result.json`, `run-result.json.tmp`, `result.txt` and `harness.log`, so a result of an earlier run is never read.

Runner output: with `run-result.json` one console line per scenario (scenario `id` in the kind column, scenario
`status` in the status column; a result without scenarios prints one line with `soak` and the run status). With
`result.txt` one line per run (`soak`, status from the file), unchanged. With `-Suite <name>` the kind column shows
`<name>-<id>` (e.g. `L1-soak`), also for the fallback lines; the ids in the files stay raw. Below the row of a scenario
the runner prints one indented line per failed check (`passed: false`) whose `checks[].scenario` is that scenario, e.g.
`    smelted > 0: expected >0, actual 0`; passed checks are not printed. A failed `daysReached` check of a soak run is
printed the same way (below the `soak` row). Control characters (incl. CR/LF) in `name`/`expected`/`actual` are replaced by a space
and each field is cut at 200 characters. The kind of the run (`soak` / `scenarios`) comes
from the suite (`-Suite SM` = `scenarios`); for a `scenarios` run the days column shows `-`. For a `scenarios` run the exit
code ignores `daysReached`; instead a run with exit class `Completed` must report every scenario id of the run's
`scenarios` (case-sensitive) and none of them may be `Skipped`, otherwise the exit code is `1` (rig error: nothing, or not
everything, was checked; this includes a missing, empty or invalid `scenarios` list). A `Failed` scenario is `2`.

### Runner `-Suite`

A suite defines its own mod list. `-Suite L1` sets harness `TestRig`, mode `WarSails`, seed 1, `days` 30 and the `modules` load
order `Bannerlord.Harmony, Bannerlord.ButterLib, Bannerlord.UIExtenderEx, Bannerlord.MBOptionScreen, Native, SandBoxCore,
Sandbox, StoryMode, NavalDLC, CoherentWarAI, AutoTraderSpeed, SmithingSuite, CompanionManagementSuite, TestRig.Harness,
CoherentWarAI.Scenarios, AutoTraderSpeed.Scenarios, SmithingSuite.Scenarios, CompanionManagementSuite.Scenarios`
(`NavalDLC` is dropped with `-Mode NoDlc`; `Bannerlord.MBOptionScreen` is MCM v5, which CoherentWarAI needs). The four
scenario modules hold one health scenario per mod and load after the harness they reference; `runs[0].health` is
`["coherentwarai.health", "autotrader.health", "smithingsuite.health", "companionsuite.health"]` (the health bracket,
see "`run.cfg`"). Explicit `-Days`, `-Seed`, `-Mode` win over the suite defaults; an explicit
`-Harness` other than `TestRig` is a usage error (runner exit 1, nothing built or published). `job.json` keeps its
schema: the suite only shapes `modules` and `runs[]` (several runs for RIG, L1-BASE and CW1), there is no suite key (the agent never sees it). The suite name
appears in `job-result.json` as job-level `suite` (`"L1"`, `null` without `-Suite`); `scenarios[].id` stays raw (`soak`,
`autotrader.health@0`). With `-PackageFrom` the package must contain the four mods, `TestRig.Harness` and the four
scenario modules. The build mode builds ten projects for L1: the seven of every job (see `-Suite SM`), then
`BannerlordCoherentWarAI\tests\InGame\CoherentWarAI.Scenarios`, `BannerlordAutoTrader\tests\InGame\AutoTraderSpeed.Scenarios`
and `CompanionManagementSuite\tests\InGame\CompanionManagementSuite.Scenarios` (each references its mod and the harness
from the stage, so they build last); `repos` records the state of the five repos as built (`dirty` is `true` while a
scenario project is uncommitted).

Health lines (runner, any soak suite with health ids, today L1): the expected lines are `<id>@0` per id, then
`<id>@<days>` per id, with `days` the job's days (30, or an explicit `-Days`). Each reported line gets its own console row
(`L1-autotrader.health@0`, status, days, exit class) with its failed checks below it; an expected line the run did not
report gets a row with status `missing` (when the run reported any line, and always for a `Completed` run, e.g. one with
`scenarios: []`; a run that ended otherwise without any line keeps its single `soak` row). `job-result.json` holds per run `health`: one `{ "id", "expected": "Passed", "actual" }` per expected line
(`actual` = the reported status, `null` when not reported); the field is absent for jobs without health ids. Exit code:
the status rules of "Runner exit codes" stay (`Failed` = `2`, `Error`/unknown = `1`); in addition a run with exit class
`Completed` must report every expected health line `Passed`, so a missing line or one with `Skipped` or `Timeout` is `1`
(rig error: that health check did not run to a verdict, like a missing requested scenario). A run that is not
`Completed` (e.g. a taint in health@0 ends `NotCompleted` with the rest `Skipped`) is judged by its exit class and
statuses only. A suite with per-run expectations applies the same health rule to an expected `Completed` soak run
(`Mismatch` for a `Failed` line, `RigError` for a missing or unchecked one). The verdict on the measurements
(exceptions, tempo, modules) is separate from this structural check: see "L1 verdict".

L1 verdict (runner, `-Suite L1` only, every run with exit class `Completed`; the harness only measures, the runner
judges). Seven checks on the run's `run-result.json`, each printed as a row after the run's result rows
(`r1     L1-vanilla         Passed     expected <= 29 (1.5 x baseline max 6 + 20), actual 0`):

| Check | Rule | Status when violated |
|---|---|---|
| `own` | `exceptions.own` = 0 | `Failed` (exit `2`); not a number = `ERROR` (exit `1`) |
| `unhandled` | `exceptions.unhandled` = 0 | `Failed` (`2`); not a number = `ERROR` (`1`) |
| `vanilla` | `exceptions.vanilla` <= 1.5 x max(base runs' `vanilla`) + 20 | `Failed` (`2`); not a number = `ERROR` (`1`) |
| `tempo` | `runningDaysPerRealMinute` / median(base runs' `runningDaysPerRealMinute`) >= 0.7 | `Failed` (`2`) |
| `modules` | `modules[].id` = `job.modules` (same ids, same order, case-sensitive) | `Failed` (`2`), naming missing/extra ids or the first position (1-based) that differs; not reported = `ERROR` (`1`) |
| `playerMapEvents` | > 0 | `WARN` only, never changes the exit code |
| `ownExact` | `exceptions.classification.ownExact` = `true` | `false`: `WARN` only (`exceptions.own` is an estimate), never changes the exit code; missing or not a boolean: `not judged` with `WARN L1 <run> ownExact not judged: ...` |

`vanilla` and `tempo` are `not judged` (row status `not judged`, `expected -`, plus a line
`WARN L1 <run> vanilla and tempo not judged: <reason>`) when the baseline is missing (no file, or no base runs: the
committed placeholder), invalid, or for another game version than the run's `agent-run.json` `gameVersion` (or the run
reported none). A `null` (or missing) `runningDaysPerRealMinute` makes `tempo` `not judged` with
`WARN L1 <run> tempo not judged: runningDaysPerRealMinute is null`. `own`, `unhandled` and `modules` are always judged.
The tempo rule compares the ratio (7.00 / 10.00 = 0.7 passes). A violation adds `2`, an `ERROR` row `1` to the exit code
(precedence as in "Runner exit codes"); a run that is not `Completed` gets no verdict (its exit class decides).
`job-result.json` holds per run `l1` (absent for other suites, `null` for a run that is not `Completed`):
`{ "outcome": "Met" | "Failed" | "RigError", "baseline": { "path", "status": "Ok" | "Missing" | "Invalid", "reason",
"gameVersion", "jobIds": [...] }, "checks": [ { "name", "status": "Passed" | "Failed" | "Warn" | "NotJudged" | "Error",
"expected", "actual" } ], "warnings": [ "WARN L1 ..." ] }` (`expected`/`actual` are the strings of the console row).

The baseline is `runner/baselines/L1.json` (committed; UTF-8, LF), written only by `runner/Update-L1Baseline.ps1`:

```json
{
  "schema": 1, "suite": "L1", "note": "...", "gameVersion": "v1.4.8", "updatedUtc": "2026-11-04T09:30:00Z",
  "jobs": [ { "jobId": "20261103-063455-cd32", "suite": "L1-BASE", "exitCode": 0,
              "modules": [ { "id": "Native", "version": "v1.4.8" } ] } ],
  "baseRuns": [ { "jobId": "20261103-063455-cd32", "runId": "r1", "seed": 1, "daysReached": 30,
                  "runningDaysPerRealMinute": 22.26, "playerMapEvents": 0,
                  "exceptions": { "total": 0, "own": 0, "harness": 0, "vanilla": 0, "unhandled": 0 } } ],
  "l1Runs": [ "same shape as baseRuns, from the L1 calibration jobs" ],
  "derived": { "baseRunCount": 5, "tempoMedian": 22.26, "tempoMin": 22.23, "tempoMax": 22.27, "tempoSpread": 0.0018,
               "tempoThreshold": 15.582, "vanillaMax": 6, "vanillaThreshold": 29, "l1TempoRatioMin": 0.8163 }
}
```

`jobs[].modules` = the module versions the first run of that job reported. The runner recomputes the thresholds from
`baseRuns` on every verdict (`derived` is for readers and is not read back); a file with base runs needs a non-empty
`gameVersion`, and every base run a positive `runningDaysPerRealMinute` and `exceptions.vanilla` >= 0, else the baseline
is invalid. The `l1Runs` do not enter the thresholds; they record the calibration (`l1TempoRatioMin` = slowest L1 run /
base median). `runner/Update-L1Baseline.ps1 -BaseJobIds <id>[,<id>...] [-L1JobIds <id>,<id>,<id>]` reads
`out\results\<jobId>\job-result.json` of each job and rewrites the whole file: base jobs must be `-Suite L1-BASE` with
exit code `0`, L1 jobs `-Suite L1` (any exit code); every run must be `Completed` with a positive tempo and numeric
exception counters, all runs must report the same game version, and no job may be listed twice; otherwise nothing is
written (exit `1`). Several base jobs are pooled. It prints the derived values and warns (without failing) when the
base-run tempo spread (max - min) / median exceeds 10 % or the slowest L1 run is below 0.8 x the base median.

`-Suite SM` (SmithingSuite scenarios) sets harness `TestRig`, mode `WarSails`, seed 1, `days` 1, `kind` `scenarios`,
`scenarios` `["smithing.smelt-then-refine"]` and the `modules` load order `Bannerlord.Harmony, Bannerlord.ButterLib,
Bannerlord.UIExtenderEx, Bannerlord.MBOptionScreen, Native, SandBoxCore, Sandbox, StoryMode, NavalDLC, SmithingSuite,
TestRig.Harness, SmithingSuite.Scenarios` (no CoherentWarAI; the scenario module loads after the harness it references).
With `-PackageFrom` the package must contain `SmithingSuite`, `TestRig.Harness` and `SmithingSuite.Scenarios`. The
default build mode builds seven projects for every job (eight with `-Suite RIG`, `CS`, `AT`, `CW1` or `X`, ten with
`-Suite L1`, one with `-Suite L1-BASE`), including `BannerlordSmithingSuite\tests\InGame\SmithingSuite.Scenarios`.

`-Suite CS` (CompanionManagementSuite) and `-Suite AT` (AutoTraderSpeed) are scenario suites like SM: harness `TestRig`,
mode `WarSails`, seed 1, `days` 1, `kind` `scenarios`, one run `r1`. CS: `scenarios` `["companion.equip-now",
"companion.roles-apply", "companion.development-guard"]`, `modules` = base modules, `CompanionManagementSuite`,
`TestRig.Harness`, `CompanionManagementSuite.Scenarios`. AT: `["autotrader.warehouse-consign", "autotrader.town-trade"]`,
`modules` = base modules, `AutoTraderSpeed`, `TestRig.Harness`, `AutoTraderSpeed.Scenarios`. No CoherentWarAI. Exit codes
as for SM (no per-run expectations): 0 all scenarios Passed, 2 one Failed, 1 rig error (missing, Skipped, Error), 3
abort or runner deadline. The scenario row prefix is the suite (`CS-companion.equip-now`).

`-Suite X` (cross-mod scenario X-1) has per-run expectations: harness `TestRig`, mode `WarSails`, seed 1, `days` 1, `kind`
`scenarios`, two runs `r1` (`["crossmod.trade-with-autoequip.done"]`) and `r2` (`["crossmod.trade-with-autoequip.cancel"]`),
hard timeout 5 minutes, expected exit class `Completed`; each run carries its own `seed` 1, so an explicit `-Seed` or
`-HardTimeoutMinutes` is a usage error. `modules` = base modules, `AutoTraderSpeed`, `CompanionManagementSuite`,
`TestRig.Harness`, `CrossMod.Scenarios`. No CoherentWarAI. Exit codes as for RIG and CW1: 0 every run meets its expectation,
2 one does not (a Failed scenario or a scenario missing from a completed run), 1 job not completed or run missing, 3 abort
or runner deadline.

`-Suite CW1` (AC25a comparison) has per-run expectations and per-run modes. `modules` = base modules, `CoherentWarAI`,
`TestRig.Harness`, `CoherentWarAI.Scenarios` (no other mod); `days` 30 (an explicit `-Days` applies to all runs). Twelve
runs `r1`-`r12`, `kind` `scenarios`, `scenarios` `["coherentwarai.ac25a-digest"]`, `hardTimeoutMinutes` 10, each expected
`Completed` with its scenario Passed, with `runs[].seed` 1, 2, 3 (four runs each) and `runs[].mode` per seed `WarSails`,
`FeatureOff`, `FeatureOff`, `WarSails`. `mode` is already a per-run field of `job.json`; a suite run definition may set
`Mode`, which the runner writes to that run's `runs[].mode` instead of the `-Mode` value. Rules: an explicit `-Mode` is a
usage error when the runs fix their modes (as `-Seed`); every run mode must load the same module list as the job's mode
(`WarSails` and `FeatureOff` do, `NoDlc` drops NavalDLC), else usage error (runner exit 1 before anything is built).
`FeatureOff` itself is applied by the agent (it writes the MCM settings of the run after the baseline restore). Exit codes
as for `-Suite RIG`. Overall deadline: 12 x (10 + 2) + claim wait + 5 = 151 minutes with the defaults. The harness limit
of 300 s per scenario holds for 30 days with a factor of about 3; with far more days (about 80 and up) the digest
scenario can run into it. CW1 also runs CW-2 per run and CW-1 per job (see "Suite checks").

### Suite checks (runner, after the fetch)

A suite may name check scripts of a mod repo that the runner calls on the tower after the result is fetched (the agent
and `job.json` are not involved, so an old job can be judged again offline). `Script` is relative to the workspace root
(the folder that holds the repos, the parent of this repo). Each script runs in its own `powershell -NoProfile -File`
process; the runner reads only the JSON it writes (a stale file is deleted first) and does not show its console output.

- `PostRunChecks` (per run, every run with `exitClass` `Completed`): `@{ Id; Script; Log }`, called as
  `<Script> -LogPath <run>\<Log> -Mode <runs[].mode of job.json> -MinDays <days> -ResultPath <run>\<Id>.json`; the result
  is `{ "rows": [ { "ac", "verdict", "evidence" } ] }`. Verdicts: `FAIL` = `Failed`; `PASS`, `N/A for mode`, `MANUAL` are
  met; `INSUFFICIENT DATA` and `WARN ...` are warnings (shown, exit code unchanged); any other verdict, no row, no result,
  a missing log, script or run mode = `RigError`.
- `JobChecks` (per job, only when done status is `completed`): `@{ Id; Script; ResultFile; UsesJobManifest? }`, called as
  `<Script> -JobPath <job result folder> -ResultPath <job result folder>\<ResultFile>`, plus
  `-JobManifestPath <OutRoot>\jobs\<jobId>\job.json` for a check with `UsesJobManifest` (CW-1) when that file exists: the
  job plan is not part of the results folder (also passed by the offline re-judgement). The result is
  `{ "checks": [ { "check", "verdict", "detail", "violations"? } ] }`. Verdicts `Passed`, `Failed`, `Inconclusive`; any
  other (including `RigError`, which the script reports for missing or broken artifacts), no check or no result (e.g. the
  script exits 1: job folder unusable) = `RigError` under the JobCheck's `Id`; an entry without a `check` name takes the
  JobCheck's `Id`. A script that runs longer than 10 minutes is killed and counts as no result (`RigError`). If any run
  of the job did not meet its expectation (a suite with per-run expectations: verdict not `Met`, e.g. `Crashed`, or
  `Completed` with a failed scenario check; otherwise: the run did not end `Completed`), the JobChecks still run (a
  violation they find is evidence even when another run is unusable): a `Failed` outcome stays `Failed` (shown and
  counted); every other outcome (`Passed`, `Inconclusive`, `RigError`) becomes `Skipped` with the detail
  `not judged: run(s) rN did not meet its expectation (check said <verdict>)` (`not Completed` for a suite without
  expectations), exit code unchanged (otherwise an `Inconclusive` would outrank the run's own verdict). A stale result
  file of an earlier judgement is deleted before each script call on every path (also when the script or the log is
  missing), so a Skipped or Error row never leaves an old result looking current.

Suites: `L1` and `CW1` run CW-2 (`coherentwarai.command-log`: `BannerlordCoherentWarAI\tools\Check-CommandLog.ps1` on
`CoherentWarAI.log`, F-S10-6); `CW1` also runs CW-1 (`coherentwarai.ac25a`: `BannerlordCoherentWarAI\tools\Compare-Ac25a.ps1`,
result `ac25a-compare.json`, checks `coherentwarai.ac25a-invariant` and `coherentwarai.ac25a-armydays`). Console rows, after
the rows of the run (`job` instead of the run id for a JobCheck), then one indented row per FAIL / warning row or violation:

```
r1     L1-coherentwarai.command-log Passed       expected no FAIL, actual 6 PASS, 1 N/A for mode, 1 MANUAL  <run>\coherentwarai.command-log.json
    AC13: expected PASS, actual INSUFFICIENT DATA (WARN) - <evidence>
job    CW1-coherentwarai.ac25a-invariant Failed       <detail>  <job>\ac25a-compare.json
    FAIL  <violation>
```

(`Error` is shown for `RigError`.) Exit code: `Failed` = `2`, `Inconclusive` = `3`, `RigError` = `1`, on top of the
other rules, with the precedence 1 > 3 > 2 > 0. `job-result.json`: each run of such a suite holds `checks` (one
`{ "id", "outcome", "detail", "resultPath", "rows": [ { "ac", "expected": "PASS", "actual", "evidence" } ] }` per
PostRunCheck; an empty array for a run that is not `Completed`); on job level `jobChecks` holds one
`{ "id", "outcome", "detail", "resultPath", "violations": [...] }` per check (an empty array for a job that is not
completed, `null` for a suite without JobChecks).

Offline re-judgement: `runner\Update-JobResult.ps1 -JobId <jobId> [-Suite <suite>]` judges `out\results\<jobId>` again as
after the fetch (all rows, the suite verdicts and the suite checks with the scripts as they are now) and rewrites its
`job-result.json`. Days, modules and the run modes come from `out\jobs\<jobId>\job.json`, the suite from the existing
`job-result.json` (or `-Suite`). The expectations come from today's suite definition, so re-judging an old job after
the suite changed can report missing runs. The earlier `job-result.json` is kept as `job-result.previous.json` in the
same folder (the first judgement is never overwritten, so the original exit code and any time-limit evidence stay
available), its `versionWarnings` are carried over, and the new file gets the additive field
`rejudgedFrom: { "exitCode": <exit code of the first judgement>, "at": "<UTC time of the latest re-judgement>" }`
(absent when there was no earlier file). Not reconstructed: a runner-side time limit of the original wait (see the kept
file). Exit codes as above; `1` when the job folders are unusable.

`-Suite L1-BASE` (vanilla baseline for L1) sets harness `TestRig`, mode `WarSails`, `days` 30, `kind` `soak` and the
`modules` load order `Bannerlord.Harmony, Bannerlord.ButterLib, Bannerlord.UIExtenderEx, Bannerlord.MBOptionScreen, Native,
SandBoxCore, Sandbox, StoryMode, NavalDLC, TestRig.Harness` (the L1 list without the four mods and without scenario
modules). It has per-run expectations (see "Runner exit codes"): five runs `r1`-`r5`, each expected `Completed`, with
`hardTimeoutMinutes` 10 and their own `runs[].seed` 1, 1, 1, 2, 3; every run gets the job's `days` (30, or an explicit
`-Days`). The 10 minutes hold for 30 days; a longer `-Days` scales them, `max(10, ceil(10 x days / 30))` (60 days: 20,
90 days: 30), a shorter one keeps 10 (a 30-day soak took 2m20s-3m41s of agent time on the game PC). Because the runs fix
seed and hard timeout, an explicit `-Seed` or `-HardTimeoutMinutes` is a usage error (runner exit 1). The build mode builds
only `TestRig.Harness` (manifest and `repos` list only `BannerlordTestRig`); with `-PackageFrom` the package must contain
`TestRig.Harness`. Overall deadline: per run its (scaled) hard timeout + 2 minutes, plus the claim wait rounded up to
minutes, plus 5 minutes: 67 minutes with the defaults (167 with `-Days 90`), unless `-TimeoutMinutes` is given.

Per-run seed: `job.json` carries `seed` (and `days`) per run, and the agent writes each run's own values to that run's
`run.cfg`; nothing in the job schema or the agent is suite-specific. A suite run definition may set `Seed`; the runner
then writes it to that run's `runs[].seed` instead of the `-Seed` value.

`-Suite RIG` (rig self-test) sets harness `TestRig`, mode `WarSails`, seed 1, `days` 1, `kind` `scenarios` and the `modules`
load order of the base modules, `TestRig.Harness`, `TestRig.SelfTest`. One job with five runs, each with
`hardTimeoutMinutes` 5 and one scenario: `r1` `rig.selftest-throw` (expected `Crashed`), `r2` `rig.selftest-hang` (`Hung`),
`r3` `rig.selftest-pass` (`Completed`), `r4` `rig.selftest-exception-storm` (`Completed`; R2), `r5` `rig.town-screen`
(`Completed`; town and trade screen fixtures, no mod). Only `r4` carries
`runs[].ownAssemblies` `["TestRig.SelfTest"]` (a JSON array, also with this one name), so its 10,000 caught self-test
exceptions count as own; its expectation also checks three values of its `run-result.json`: `exceptions.own` = 10000,
`exceptions.classification.walks` = 1000 and `exceptions.classification.ownExact` = `false` (verdict: "Runner exit codes").
Below the expectation row the runner prints one line per value check (`    exceptions.own: expected 10000, actual 10000
met`, `MISMATCH` or `ERROR`; only when `r4` ended `Completed`) and always the R2 timing line of
`exceptions.classification`: `    R2 timing: walk mean <walkMs / walks> ms (<walks> walks); cache hit at most <(handlerMs -
walkMs) / (total - walks)> us (mean of <total - walks> other exceptions)` (`n/a` for a mean without exceptions, `not
measured` when a value is missing). Above the R2 start values [A] (walk mean > 1 ms, cache hit > 50 us) it adds
`WARN r4 R2 walk mean ...` / `WARN r4 R2 cache hit at most ...`; warnings never change the exit code. With `-PackageFrom`
the package must contain `TestRig.Harness` and `TestRig.SelfTest`. Overall deadline (formula as for `-Suite L1-BASE`):
42 minutes with the defaults.

### Version warnings (runner)

After fetching, the runner compares the game version and the versions of modules with source `game` or `workshop`
(from `agent-run.json`) with the tower: game version from `<towerGamePath>\bin\Win64_Shipping_Client\Version.xml`,
module version from the place matching the source `.20` reported: for `workshop` the tower workshop folder (matched by
`<Id value>`) first, else `Modules\<id>\SubModule.xml`; for `game` the tower `Modules\<id>\SubModule.xml` first, else
the workshop folder. The tower workshop folder is indexed once per job; for a workshop id found in several folders the
newest copy wins (`SubModule.xml` `LastWriteTime`, then folder name), and if the copies carry different versions the
runner prints `WARN duplicate workshop id <id> on tower`. Each distinct value (game) or (id, version) is compared once per job. A difference prints, after the table:
`WARN version differs: <id> tower <v|missing|unknown>, .20 <v>` (`game` instead of `<id>` for the game version). The
exit code does not change. Old agents without the fields produce no warning. If the tower `Version.xml` cannot be read
at that time: `WARN version check skipped: <reason>`. Without `towerGamePath` no comparison runs.

`job-result.json` (written by the runner) holds one `result` per run, in one of two shapes: from `run-result.json`, the
parsed object as written by the harness (nested, typed values as above); from legacy `result.txt`, a flat map of the
`key=value` lines (all values strings, e.g. `{ "status": "Completed", "daysReached": "3" }`); `{}` when there is no result
(missing file, or invalid `run-result.json`). Per run it also holds `gameVersion` and `moduleVersions`, copied from
`agent-run.json` (`moduleVersions` is always a JSON array when present, also with 0 or 1 entry; `null` only for an old
agent); on job level `versionWarnings` is an array of the warning lines above and `suite` is the runner's `-Suite`
value or `null`. Only for a suite with per-run expectations (`-Suite RIG`, `-Suite L1-BASE`, `-Suite CW1`) every run also holds `expected`
(`{ "exitClass": "...", "messagePattern": "<regex>" | null, "values": [ { "name": "<path>", "expected": <number|boolean> } ] }`,
`values` = the value checks of the run, an empty array for runs without, e.g. `RIG` `r4`: `exceptions.own` 10000; `null`
for a run the suite does not define) and `verdict` (`Met`, `Mismatch`, `Inconclusive` or `RigError`, see the exit codes;
`null` when `expected` is `null`; the actual values are in `result`). For `-Suite L1` every
run also holds `l1` (see "L1 verdict"). Every run holds `mode`: its `runs[].mode` from `job.json` (`null` when unknown).
Suites with checks add `checks` per run and `jobChecks` on job level (see "Suite checks").

### `run.cfg`

`seed`, `days`, `mode`, `stallMinutes`, `budgetMinutes`, plus, for harness `TestRig` only:
`ownAssemblies=<comma-separated simple DLL names without .dll>` - for every module of the package that is not a
harness module (`CoherentWarAI.TestHarness`, `TestRig.Harness`), the `SubModules/SubModule/DLLName/@value` entries of its
installed `SubModule.xml`, in order, de-duplicated case-insensitively. A module with a missing or unparseable
`SubModule.xml` is skipped (logged); a name that does not match `[A-Za-z0-9_.-]+` (after stripping `.dll`) is skipped
(logged); no names = no line. A run with `runs[].ownAssemblies` skips this derivation: exactly that list is written
(needed e.g. for `TestRig.SelfTest`, which depends on a harness module and so never appears in the derived list). The
`CoherentWarAI` harness never gets this key (its parser rejects unknown keys).

`scenarios=<comma-separated scenario ids>` - only for harness `TestRig` with run `kind` `scenarios`, taken from
`runs[].scenarios` (ids contain no `,` or line breaks, see the schema check); soak runs and the `CoherentWarAI`
harness never get this key. Written after the numeric keys and before `ownAssemblies`.

`health=<comma-separated scenario ids>` (harness `TestRig`, soak runs only; health bracket, F-S6-1) - the agent writes it
from `runs[].health` (only for harness `TestRig` with run `kind` `soak`; never together with `scenarios`, which the schema
check already rules out), after the numeric keys and before `ownAssemblies`; without `runs[].health` no line. The harness parses
it like `scenarios` (trimmed, at least one id, an id twice or the key twice = config error) and rejects it together with
`scenarios` (config error). The ids are resolved against the discovered scenarios like `scenarios`; an unknown or
ambiguous id is a config error (`reason` `config:health: unknown scenario id '<id>'`, every expected line below
`Error`). Flow of the Running phase: health@0 (all health scenarios in order, game time stopped) -> soak (time runs until
`days`, watchdog and `daysReached` check as in a plain soak) -> health@N (the same scenario instances again, time
stopped) -> end game. Result lines, in this order: `<id>@0` per id, `soak`, `<id>@<days>` per id (e.g.
`autotrader.health@0`, `soak`, `autotrader.health@30`); checks carry the same ids in `checks[].scenario`, the
`daysReached` check belongs to `soak`. A health scenario that yields `Days(n)` ends as `Error` (does not taint). A taint
in health@0 (throw, timeout) ends the run as `Aborted`, `reason` `tainted:<id>@0`: the rest of health@0, `soak` and all
of health@N are `Skipped` (no `daysReached` check), no game time runs. A taint in health@N keeps the passed `soak`. A
stall or budget abort during the soak makes `soak` `Timeout` and health@N `Skipped`; a crash during the soak makes it
`Failed`. A budget abort during health@N (a running health scenario counts as progress for the stall watchdog) keeps
the passed `soak`: the current `<id>@<days>` is `Timeout`, the rest of health@N `Skipped`. An abort before the Running phase (e.g. `stall:CharacterCreation`) lists every line
`Skipped`, `soak` with `seconds` `null`, and no checks (no `daysReached` check). An end-stall after a completed run
(`status` `Aborted`, `reason` `end-stall`) keeps every line as it was, so `soak` stays `Passed`; this differs from a
plain soak, whose single `soak` line then reports `Timeout`. `soak.seconds` is the soak segment only; `runningDaysPerRealMinute` covers only the soak segment (health
time excluded, comparable with a soak without health). An interim `run-result.json` (status `Running`) lists only the
lines that already have a result. Scenarios read `ctx.Day`: the harness day counter of the current tick (daily ticks
since the campaign session launched, the counter behind `daysReached`), normally `0` in health@0 and `>= days` in
health@N; a health scenario can keep state on its instance from the @0 call to the @N call (e.g. a mod-log length,
F-S6-6). Without `health=` the run is a plain soak, unchanged by this key.

## `results\<jobId>\done.json`

```json
{ "schema": 1, "jobId": "...", "status": "completed", "finishedUtc": "...",
  "runs": [ { "runId": "r1", "exitClass": "Completed" } ], "message": null,
  "baselineRestored": true, "baselineError": null }
```

`baselineRestored` (bool|null) and `baselineError` (string|null): result of the restore after the job; both `null` when
no run reached the restore (e.g. `rejected`, `blocked`, or an orphaned `done.json` written for a job without run after
an agent restart).

`status`: `completed` (all runs executed, whatever their result) | `aborted` (an `abort` was
seen; `runs` lists only the executed runs) | `blocked` (preflight failed, e.g. Bannerlord.exe
already running) | `rejected` (invalid job or package, out-of-range numbers, protected or
non-allowlisted module) | `failed` (agent error, or a run ended `CleanupFailed`: the remaining
runs are skipped because the game could not be stopped).

## Runner exit codes

`0` every run `Completed` and `daysReached >= days` (kind `scenarios`: every requested scenario reported and none
`Skipped`) - `1` rig or infrastructure error
(`blocked`, `rejected`, `failed`, `SetupError`, `LaunchFailed`, `CleanupFailed`, transport error,
open job, a scenario with status `Error`, a `Completed` scenarios run with a missing or `Skipped` requested scenario, a
`Completed` soak run with a missing, `Skipped` or `Timeout` health line, see "Health lines"; an `ERROR` row of the L1
verdict) - `2` test failure (`NotCompleted`, `Crashed`, `Completed` with too few days,
a scenario with status `Failed`, a `Failed` row of the L1 verdict, see "L1 verdict") -
`3` time limit, hang or agent not responding (`HardTimeout`, `Hung`, `Aborted`, done status `aborted`, claim
timeout, stale heartbeat, overall deadline; the runner aborts at its deadline and, best effort,
on a stale heartbeat). The suite checks add their own codes (`Failed` 2, `Inconclusive` 3, `RigError` 1, see "Suite
checks"). Precedence:
1 > 3 > 2 > 0. An unknown `exitClass` or `status` maps to `1`. Scenario statuses (case-insensitive): `Passed`,
`Timeout` and `Skipped` do not change the code by themselves (except the requested-scenario rule above), `Failed` gives `2`, `Error` and any other value (unknown
string, empty, `null`, non-string) give `1`.

Suites with per-run expectations (`Runs` in the suite definition, e.g. `-Suite RIG`: r1 must end `Crashed`, r2 `Hung`,
r3 and r4 `Completed` with their scenario `Passed`) replace the per-run rules above with a verdict per run: `0` if every run
meets its expectation (exact `exitClass`; an expected `Completed` also needs every scenario of the run reported
`Passed` and every value check of the expectation met: the value at that path of `run-result.json` equal to the expected
number or boolean, e.g. r4 `exceptions.own` 10000, `exceptions.classification.walks` 1000,
`exceptions.classification.ownExact` `false`; another value is a mismatch, `2`; a missing value or one of another JSON
type is `RigError`, `1`, the harness did not measure it; an expectation with a message pattern also needs the run's
`agent-run.json` `message` to match it,
case-sensitive: r1
`^(Harness reported: |Crash occurred \(watchdog_log_\d+\.txt\); last line: ).*System\.InvalidOperationException: rig\.selftest-throw`,
so the crash is the self-test throw (the exception itself under its full type name, as the harness's `FirstChance` and
`UnhandledException` lines write it, not a harness line that merely names the scenario),
whether the harness reported it or the throw escaped to native and the watchdog did; r2 `^No Alive line in harness\.log for \d+ s`, so the silence watch ended it) - `2` a run that does not
(mismatch; a pattern mismatch prints an indented `message does not match <pattern>: <message>` line below the row) -
`1` a run missing from a `completed` job, or an unexpected
`SetupError`, `LaunchFailed` or `CleanupFailed` - `3` job status `aborted` or the runner's deadline. The job-status
rules (`blocked`, `rejected`, `failed` = `1`) and the precedence 1 > 3 > 2 > 0 stay. An expected `Crashed` or `Hung`
is therefore a pass (`0`), not a test failure. Every rule of an expected `Completed` is checked, so a `RigError` found
after a mismatch (e.g. an `Error` row after a `Failed` one, or a missing health line next to a `Failed` one) still
gives `1`.

For a `soak` run (e.g. `-Suite L1-BASE`) an expected `Completed` also needs `daysReached >= days` (else mismatch, `2`)
and no `soak` result row `Failed` (mismatch, `2`) or `Error`/unknown (`RigError`, `1`). If it ends `HardTimeout`, `Hung`
or `Aborted` instead, the verdict is `Inconclusive` (row `INCONCLUSIVE`, exit `3`: a time limit or hang, as without a
suite), unless a `soak` result row is `Error`/unknown (`RigError`, `1`, as without a suite); a `scenarios` run that ends so instead of its expected class stays a mismatch (`2`; e.g. RIG r2 `HardTimeout`
instead of `Hung` means the hang detection failed). Such a soak run keeps its `soak` row (`<Suite>-soak`, status and
days reached, failed checks below it) next to its expectation row; a run without a result shows `?` there.

## Agent restart

On startup the agent finishes every orphaned job (a `job.claimed.json` without
`results\<jobId>\done.json`) with `done.json` status `failed`, message
`agent restarted during job`, and removes a leftover harness `run.cfg`. This keeps one agent
crash from blocking the queue forever.

## Transport (SSH)

`runner/Transport.Ssh.ps1` has exactly four functions, each taking a `-Target` object
(`host`, `user`, `keyPath`, `remoteQueueRoot`): `Publish-Job`, `Get-JobState`,
`Receive-JobResult`, `Send-JobAbort`. The runner uses the Windows OpenSSH client
(`%SystemRoot%\System32\OpenSSH\ssh.exe`/`scp.exe`), never one found on `PATH`, with
`-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3
-o IdentitiesOnly=yes -i <key>`. The remote shell is `cmd.exe`. Windows PowerShell 5.1 drops
embedded double quotes from native arguments, so **every** remote command is sent as
`powershell -NoProfile -EncodedCommand <base64 UTF-16LE>` (no quotes or backslashes on the
command line); values inside the script are single-quoted PowerShell literals.
