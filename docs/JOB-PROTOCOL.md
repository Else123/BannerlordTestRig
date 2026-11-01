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
`run-result.json`, `result.txt`, `harness.log`, `CoherentWarAI.log` (mod log, if present) and the
engine logs `rgl_log_<pid>.txt` / `rgl_log_errors_<pid>.txt` / `watchdog_log_<pid>.txt`.

`baselineRestored`: `true` if the baseline was restored before this run, `false` if the restore failed or was not
reached. `baselineSha256`: relative path (with `/`) -> uppercase hex SHA-256 of every restored file, `null` if not
restored. `gameVersion`: installed game version, `string|null`. `moduleVersions`: one entry per id of
`job.modules`, in that order: `version` is `string|null` (module without `Version`), `source` is `package` |
`game` | `workshop` (where the agent found the module, checked in this order).

`dismissedDialogs`: titles of game dialogs the agent sent OK to during the run, empty if none.
While the game runs, the agent checks its visible standard dialogs (`#32770`) every second. Only the
exact title `Mod change detected` (shown by the engine on the first start after the module list
changed) gets OK; any other dialog title is logged once per run and left alone.

`exitClass` (names for the exit codes of `Run-SoakTest.ps1` in BannerlordCoherentWarAI):

| exitClass | Meaning |
|---|---|
| `Completed` | game ended, the harness result has status `Completed` (`run-result.json`, else `result.txt`) |
| `SetupError` | precondition or setup failed before or at launch |
| `LaunchFailed` | process exited within 30 s and the harness log never appeared |
| `HardTimeout` | `hardTimeoutMinutes` expired, game killed |
| `NotCompleted` | game ended, but no usable result (missing, or `run-result.json` invalid JSON) or status not `Completed` |
| `CleanupFailed` | the game could not be stopped or `run.cfg` could not be removed |
| `Crashed` | the watchdog log reported `Crash occurred`, game killed (see "Crash watchdog") |
| `Aborted` | `abort` file seen, game killed |

If several apply, the first in this order wins: `CleanupFailed` > `Aborted` > `SetupError` > `Crashed` >
`HardTimeout` > `Completed` > `LaunchFailed` > `NotCompleted`.

### Crash watchdog

About once per second while the game runs, the agent looks for `Crash occurred` in
`<engineLogDir>\watchdog_log_<pid>.txt` (fallback, e.g. after a relaunch under another PID: another
`watchdog_log_*.txt`, most recently written first). At the launch the agent records the name and length of every
`watchdog_log_*.txt`; only a new file, or the bytes appended to a recorded file after the launch, count (a file that got
shorter counts as replaced and is read in full). An old crash log, or a log from an earlier run under a reused PID,
therefore never counts, and neither does a mere write to an old log. If `engineLogDir` does not exist at the launch the
agent logs that once per run (no watchdog log is seen unless the game creates the folder).
On a hit it kills the process tree at once (the crash dialog would otherwise block the game until the hard timeout) and
classifies the run `Crashed`. After the game exited on its own the check repeats for up to 2 s (not after an abort, a
hard timeout or a supervision error); a crash found only then still counts as `Crashed`. After every launched run
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
no extra file is left. Nothing else is touched (`engine_config.txt`, `LauncherData.xml`, `ModLogs`, other folders).
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
  "daysRequested": 1, "daysReached": 1, "realSeconds": 25, "gameDaysPerRealMinute": 2.41, "playerMapEvents": 0,
  "modules": [ { "id": "Native", "version": "v1.4.8" } ],
  "exceptions": { "total": 3, "own": 1, "unhandled": 0, "top": [ { "key": "KeyA", "count": 2 }, { "key": "KeyB", "count": 1 } ] },
  "scenarios": [ { "id": "soak", "status": "Passed", "seconds": 25 } ],
  "checks": [ { "name": "daysReached", "expected": ">= 1", "actual": "1", "passed": true } ]
}
```

Unknown values are `null`. Scenario `status`: `Passed` | `Failed` | `Error` | `Timeout` | `Skipped` (`Skipped` is reserved:
the harness does not produce it yet). `exceptions.total` counts first-chance exceptions in the game process, including
the harness's own (e.g. a retried file write); `top` lists the most frequent keys (`<type>: <message> @ <site>`, at most
10000 distinct keys are tracked, later new keys never enter `top`), so its counts add up to at most `total`.
Exception counting starts when the harness module loads (`OnSubModuleLoad`, once `run.cfg` was read and accepted), by
installing the first-chance and unhandled hooks; a later map window only restarts the log budget, not the counters.
`exceptions.own` is an **estimate** and is only counted when `run.cfg` has `ownAssemblies`: exceptions are grouped by
exception type and throw site (`<type> @ <declaring type>.<method>`, no message); each group is classified once, by one
stack walk at its first occurrence, and every repeat gets the same answer, so `own` can be too high (a vanilla throw
site first reached through an own mod) or too low (at most 1000 walks per run; groups first seen after that, and a
failed classification, count as not own).
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
`<name>-<id>` (e.g. `L1-soak`), also for the fallback lines; the ids in the files stay raw.

### Runner `-Suite`

`-Suite L1` (the only suite so far) sets harness `TestRig`, mode `WarSails`, seed 1, `days` 30 and the `modules` load
order `Bannerlord.Harmony, Bannerlord.ButterLib, Bannerlord.UIExtenderEx, Bannerlord.MBOptionScreen, Native, SandBoxCore,
Sandbox, StoryMode, NavalDLC, CoherentWarAI, AutoTraderSpeed, SmithingSuite, CompanionManagementSuite, TestRig.Harness`
(`NavalDLC` is dropped with `-Mode NoDlc`). Explicit `-Days`, `-Seed`, `-Mode` win over the suite defaults; an explicit
`-Harness` other than `TestRig` is a usage error (runner exit 1, nothing built or published). `job.json` keeps its
schema: the suite only shapes `modules` and `runs[0]`, there is no suite key (the agent never sees it). The suite name
appears in `job-result.json` as job-level `suite` (`"L1"`, `null` without `-Suite`); `scenarios[].id` stays `soak`.

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
value or `null`.

### `run.cfg`

`seed`, `days`, `mode`, `stallMinutes`, `budgetMinutes`, plus, for harness `TestRig` only:
`ownAssemblies=<comma-separated simple DLL names without .dll>` - for every module of the package that is not a
harness module (`CoherentWarAI.TestHarness`, `TestRig.Harness`), the `SubModules/SubModule/DLLName/@value` entries of its
installed `SubModule.xml`, in order, de-duplicated case-insensitively. A module with a missing or unparseable
`SubModule.xml` is skipped (logged); a name that does not match `[A-Za-z0-9_.-]+` (after stripping `.dll`) is skipped
(logged); no names = no line. The `CoherentWarAI` harness never gets this key (its parser rejects unknown keys).

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

`0` every run `Completed` and `daysReached >= days` - `1` rig or infrastructure error
(`blocked`, `rejected`, `failed`, `SetupError`, `LaunchFailed`, `CleanupFailed`, transport error,
open job, a scenario with status `Error`) - `2` test failure (`NotCompleted`, `Crashed`, `Completed` with too few days,
a scenario with status `Failed`) -
`3` time limit or agent not responding (`HardTimeout`, `Aborted`, done status `aborted`, claim
timeout, stale heartbeat, overall deadline; the runner aborts at its deadline and, best effort,
on a stale heartbeat). Precedence:
1 > 3 > 2 > 0. An unknown `exitClass` or `status` maps to `1`. Scenario statuses (case-insensitive): `Passed`,
`Timeout` and `Skipped` do not change the code by themselves, `Failed` gives `2`, `Error` and any other value (unknown
string, empty, `null`, non-string) give `1`.

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
