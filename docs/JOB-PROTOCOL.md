# Job protocol (schema 1, slice S1)

Binding contract between the runner (`runner/`, dev PC) and the agent (`agent/`, test PC).
PowerShell 5.1 on both sides. All JSON is UTF-8 **without BOM**, written with
`ConvertTo-Json -Depth 10`. Every "atomic" write goes to `<name>.tmp` first and is then renamed.
Results are **data**: the runner only parses them (`ConvertFrom-Json`) and never executes
anything from them.

## Folders on the test PC

```
C:\TestRig\
  agent\                 TestRigAgent.ps1, agent.config.json
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
   runner renames it to `job.withdrawn.json`. Success = the agent never claimed it -> runner
   exit 3 ("agent offline"). Failure = the agent claimed it just now -> keep waiting.
4. **Heartbeat (agent):** `state.json` in the job folder, rewritten atomically at least every
   15 s while the job is active. `beat` increases by 1 on each write. The runner never compares
   clocks: if `beat` does not change for 120 s, the agent counts as unresponsive (exit 3).
5. **Abort (runner):** create an empty file `abort` in the job folder. The agent checks for it at
   least every 5 s while a run is active, kills the game (process tree), classifies the run
   `Aborted`, skips the remaining runs and finishes the job.
6. **Finish (agent):** write all run artifacts to `results\<jobId>\<runId>\`, then `done.json`
   atomically and last.
7. **Fetch (runner):** after `done.json` exists, copy `results\<jobId>\` to
   `out\results\<jobId>\` on the dev PC.

A job counts as **open** if its folder has `job.json` or `job.claimed.json` and there is no
`results\<jobId>\done.json`. The runner refuses to publish while any job is open (exit 1, the
message names the job). Withdrawn jobs are not open. Cleaning up a stuck open job is manual.

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
- `expectedGameVersion`: `null` in S1 = not checked.
- `harness`: S1 knows only `CoherentWarAI` (the existing harness, run.cfg in
  `<MyDocuments>\Mount and Blade II Bannerlord\CoherentWarAI\harness\run.cfg`). Anything else ->
  run classified `SetupError`.
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

## `results\<jobId>\<runId>\agent-run.json`

```json
{ "schema": 1, "runId": "r1", "exitClass": "Completed", "pid": 1234,
  "startedUtc": "...", "endedUtc": "...", "artifacts": [ "result.txt", "harness.log" ],
  "baselineRestored": null, "message": null }
```

`exitClass` (names for the exit codes of `Run-SoakTest.ps1` in BannerlordCoherentWarAI):

| exitClass | Meaning |
|---|---|
| `Completed` | game ended, `result.txt` has `status=Completed` |
| `SetupError` | precondition or setup failed before or at launch |
| `LaunchFailed` | process exited within 30 s and the harness log never appeared |
| `HardTimeout` | `hardTimeoutMinutes` expired, game killed |
| `NotCompleted` | game ended, but no `result.txt` or status not `Completed` |
| `CleanupFailed` | the game could not be stopped or `run.cfg` could not be removed |
| `Crashed` | crash detected (not in S1: arrives with slice S5/#7) |
| `Aborted` | `abort` file seen, game killed |

## `results\<jobId>\done.json`

```json
{ "schema": 1, "jobId": "...", "status": "completed", "finishedUtc": "...",
  "runs": [ { "runId": "r1", "exitClass": "Completed" } ], "message": null }
```

`status`: `completed` (all runs executed, whatever their result) | `aborted` | `blocked`
(preflight failed, e.g. Bannerlord.exe already running) | `rejected` (invalid job or package) |
`failed` (agent error).

## Runner exit codes

`0` every run `Completed` and `daysReached >= days` - `1` rig or infrastructure error
(`blocked`, `rejected`, `failed`, `SetupError`, `LaunchFailed`, `CleanupFailed`, transport error,
open job) - `2` test failure (`NotCompleted`, `Crashed`, or `Completed` with too few days) -
`3` time limit or agent not responding (`HardTimeout`, claim timeout, stale heartbeat, overall
deadline). Precedence: 1 > 3 > 2 > 0.

## Transport (SSH)

`runner/Transport.Ssh.ps1` has exactly four functions, each taking a `-Target` object
(`host`, `user`, `keyPath`, `remoteQueueRoot`): `Publish-Job`, `Get-JobState`,
`Receive-JobResult`, `Send-JobAbort`. `ssh`/`scp` always run with `-o BatchMode=yes` and the key.
The remote shell is `cmd.exe`; anything beyond a single command is sent as
`powershell -NoProfile -EncodedCommand <base64 UTF-16LE>`.
