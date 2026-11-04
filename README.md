# BannerlordTestRig

Runs in-game tests for four Mount & Blade II: Bannerlord mods (v1.4.8, War Sails) on a
separate Windows PC, triggered on demand from the dev PC. The dev PC never launches the game.

## Status

Slice S1 (one soak run with the `TestRig.Harness` harness) is implemented:

- `runner/Invoke-TestRig.ps1` with the SSH transport `runner/Transport.Ssh.ps1`
- `agent/TestRigAgent.ps1` with its installer `agent/Install-TestRigAgent.ps1`
- `agent/Save-TestRigBaseline.ps1` records the game configuration baseline the agent restores before each run
  (one-time step, see `docs/SETUP-GAMESERVER.md` section g)

Also implemented: agent preflight (game version, modules, Steam), the baseline restore, the crash watchdog
(`Crashed`), and version reporting with runner warnings (`WARN version differs: ...`); see `docs/JOB-PROTOCOL.md`.

The job protocol between them is `docs/JOB-PROTOCOL.md`. Harness module and scenarios are
not implemented yet; the layout below is the plan.

```powershell
copy runner\runner.config.example.json runner\runner.config.json   # then edit host, user, key, towerGamePath
runner\Invoke-TestRig.ps1 -Days 1 -Wait          # builds the seven projects (eight with -Suite RIG/CS/AT/CW1/X, ten with -Suite L1), packs them, publishes the job
runner\Invoke-TestRig.ps1 -PackageFrom <folder with Modules\CoherentWarAI\...> -Days 1 -Wait   # diagnosis: skip the build
```

`-Harness` accepts only `TestRig` (the default; module `TestRig.Harness` in the load order); any other value is a usage error.
The 10-day soak is `runner\Invoke-TestRig.ps1 -Days 10 -Wait`, the NoDlc variant `-Mode NoDlc -Days 3 -Wait`.

Ad-hoc runs (no `-Suite`) always load CoherentWarAI and get the CW-2 command-log check as post-run check (like the
suites below), with the run's `-Mode` and `-Days` (as `-MinDays`): FAIL gives exit 2, a missing `CoherentWarAI.log`
exit 1, INSUFFICIENT DATA is a WARN. `-SkipChecks` turns it off.

`-Suite L1` runs the L1 soak: harness `TestRig`, mode `WarSails`, seed 1, and the module load order Bannerlord.Harmony,
ButterLib, UIExtenderEx, MBOptionScreen, Native, SandBoxCore, Sandbox, StoryMode, NavalDLC, CoherentWarAI, AutoTraderSpeed,
SmithingSuite, CompanionManagementSuite, TestRig.Harness, CoherentWarAI.Scenarios, AutoTraderSpeed.Scenarios,
SmithingSuite.Scenarios, CompanionManagementSuite.Scenarios. Without an explicit `-Days` it uses 30 days. Combination rules:
`-Days`, `-Seed` and `-Mode` keep an explicit value; the suite fixes the harness, so an explicit `-Harness` other than
`TestRig` is a usage error (exit 1 before anything is built or published). With `-PackageFrom` the package must contain
all suite modules. The result rows show `<Suite>-<scenario id>` (e.g. `L1-soak Passed 3/3`). Without `-Suite` nothing changes.
Suite names are case-insensitive (`-Suite l1` is `L1`).
The L1 run also asks for the four mod health scenarios (`coherentwarai.health`, `autotrader.health`, `smithingsuite.health`,
`companionsuite.health`), each checked before the soak (`<id>@0`) and after it (`<id>@<days>`); the rows show them as e.g.
`L1-autotrader.health@0`. Every health line must be Passed: a Failed line gives exit 2, a missing, Skipped or Timeout line
of a completed run gives exit 1 (details: "Health lines" in `docs/JOB-PROTOCOL.md`).
A completed L1 run is also judged on its measurements, one row each: own and unhandled exceptions 0, vanilla exceptions
at most 1.5 x the baseline maximum + 20, running-phase tempo at least 0.7 x the baseline median, the reported modules
equal to the job's module list, and a player map event (`playerMapEvents` 0 is a WARN only). A violation gives exit 2.
`ownExact` false (`own` is only an estimate) is a WARN only; the exit code is unchanged.
The baseline is `runner/baselines/L1.json`; until it holds base runs (or when its game version differs from the run's),
vanilla and tempo are not judged and a WARN line says so. Fill or refresh it from finished jobs, never by hand:
`runner\Update-L1Baseline.ps1 -BaseJobIds <L1-BASE jobId> -L1JobIds <L1 jobId>, <L1 jobId>, <L1 jobId>` (details:
"L1 verdict" in `docs/JOB-PROTOCOL.md`).

`-Suite SM` runs the SmithingSuite scenario `smithing.smelt-then-refine` (`kind` `scenarios`): harness `TestRig`,
mode `WarSails`, seed 1, 1 day, and only the base modules, SmithingSuite, TestRig.Harness and SmithingSuite.Scenarios
(no CoherentWarAI). With `-PackageFrom` the package must contain those three modules. Failed checks are printed below
the scenario row; the exit code is 0 (the scenario Passed), 2 (Failed) or 1 (rig error: the scenario is missing from the
result or Skipped) regardless of days reached.

`-Suite CS` runs the CompanionManagementSuite scenarios `companion.equip-now`, `companion.roles-apply` and
`companion.development-guard` (in this order; `kind` `scenarios`): harness `TestRig`, mode `WarSails`, seed 1, 1 day, and
only the base modules, CompanionManagementSuite, TestRig.Harness and CompanionManagementSuite.Scenarios (no CoherentWarAI).
`-Suite AT` is the same for AutoTraderSpeed: scenarios `autotrader.warehouse-consign` and `autotrader.town-trade`, modules
AutoTraderSpeed, TestRig.Harness and AutoTraderSpeed.Scenarios. With `-PackageFrom` the package must contain those three
modules. Exit code of both (as for `-Suite SM`): 0 if every scenario Passed, 2 if one Failed, 1 for a rig error (a
scenario missing from the result, Skipped or in error, or the job not completed), 3 if the agent aborted the job or the
runner deadline hit; a failed check is printed below its scenario row.

`-Suite X` is the cross-mod scenario X-1 (AutoTraderSpeed with CompanionManagementSuite): harness `TestRig`, seed 1, one job
with two runs (`r1` scenario `crossmod.trade-with-autoequip.done`, `r2` `crossmod.trade-with-autoequip.cancel`; hard timeout
5 minutes each, `Completed` expected; each run is a fresh campaign with its own seed 1). Modules: the base modules,
AutoTraderSpeed, CompanionManagementSuite, TestRig.Harness and CrossMod.Scenarios (no CoherentWarAI). The seed and hard
timeout are fixed per run, so an explicit `-Seed` or `-HardTimeoutMinutes` is a usage error (exit 1). Every run must end
`Completed` with its scenario Passed. Exit code (as for `-Suite RIG`): 0 if every run meets its expectation, 2 if one does
not (a Failed scenario, or a scenario missing from a completed run), 1 if the job is not completed or a run is missing, 3 if
the agent aborted the job or the runner deadline hit.

`-Suite CW1` is the AC25a comparison of CoherentWarAI: harness `TestRig`, only the base modules, CoherentWarAI,
TestRig.Harness and CoherentWarAI.Scenarios (no other mod), 30 days. One job with twelve runs r1-r12 (`kind` `scenarios`,
scenario `coherentwarai.ac25a-digest`, hard timeout 10 minutes each): seeds 1, 2, 3, and per seed the modes `WarSails`,
`FeatureOff`, `FeatureOff`, `WarSails` (this order evens out drift). The mode is fixed per run, so an explicit `-Mode`,
`-Seed` or `-HardTimeoutMinutes` is a usage error (exit 1); `-Days` is allowed (e.g. `-Days 3` as a smoke test). Every
run must end `Completed` with its scenario Passed. Exit code (as for `-Suite RIG`): 0 if every run meets its expectation,
2 if one does not, 1 if the job is not completed or a run is missing, 3 if the agent aborted the job or the runner deadline
hit. The overall deadline is 151 minutes with the defaults. The 300 s limit per scenario holds for 30 days with a factor
of about 3; far longer `-Days` (about 80 and more) can exceed it. With `-PackageFrom` the package must contain those
modules (CoherentWarAI included).

Suite checks: after the result is fetched, `-Suite L1` and `-Suite CW1` run CW-2 (`tools\Check-CommandLog.ps1` of the
CoherentWarAI repo next to this one) on every `Completed` run, with that run's mode and `-MinDays` = the days; CW1 also runs
CW-1 (`tools\Compare-Ac25a.ps1`) over the whole job. One row per check, e.g.
`r1     L1-coherentwarai.command-log Passed       expected no FAIL, actual 6 PASS, 1 N/A for mode, 1 MANUAL  <json>` and
`job    CW1-coherentwarai.ac25a-armydays Passed ...`; FAIL and warning rows (INSUFFICIENT DATA, WARN) are listed below it.
A FAIL is exit 2, an Inconclusive CW-1 verdict exit 3, a missing log, script or result exit 1 (precedence 1 > 3 > 2 > 0).
CW-1 gets the job plan via `-JobManifestPath out\jobs\<jobId>\job.json`. CW-1 always runs. If a run did not meet its
expectation (it did not end `Completed`, or ended `Completed` but a scenario check failed), a `Failed` verdict stays
Failed (a found violation is evidence; exit 2) and every other outcome becomes `Skipped`, e.g.
`job    CW1-coherentwarai.ac25a-invariant Skipped  not judged: run(s) rN did not meet its expectation (check said Inconclusive)`, without effect on the exit code.
An ad-hoc job is re-judged with CW-2 as well.
Re-judge a fetched job offline (no test PC needed; rewrites `out\results\<jobId>\job-result.json`):
`runner\Update-JobResult.ps1 -JobId <jobId>`. Jobs of the retired CoherentWarAI harness (`result.txt`) are refused with exit 1.
Details: "Suite checks" in `docs/JOB-PROTOCOL.md`.

`-Suite RIG` is the rig self-test: one job with five runs, each judged against an expected outcome. r1
`rig.selftest-throw` must end `Crashed`, r2 `rig.selftest-hang` must end `Hung`, r3 `rig.selftest-pass` must end
`Completed` with its scenario Passed (hard timeout 5 minutes each); for r1 and r2 the agent's run message must also
show the cause (r1: the exception `System.InvalidOperationException: rig.selftest-throw` itself, not just a harness line
naming the scenario, r2: the missing `Alive:` line; see `docs/JOB-PROTOCOL.md`). r4 `rig.selftest-exception-storm` (R2)
lists `TestRig.SelfTest` as its own assembly (`runs[].ownAssemblies`) and must end `Completed` with its scenario Passed
and `exceptions.own` 10000, `exceptions.classification.walks` 1000 and `ownExact` false (another value: exit 2, a missing
one: exit 1). Below its row the runner prints each value check and the R2 timing line (walk mean in ms, cache hit upper
bound in us); above 1 ms / 50 us it adds a WARN line only. r5 `rig.town-screen` (the town and trade screen fixtures:
enter a foreign town, open and close the trade screen, leave) must end `Completed` with its scenario Passed. Modules: base modules, TestRig.Harness and
TestRig.SelfTest (built and packaged only for this suite; it contains deliberately crashing code). Exit code: 0 if every
run meets its expectation, 2 if one does not, 1 if the job is not completed or a run is missing, except 3 if the agent
aborted the job or the runner deadline hit. If the job is not completed, the runner prints `job status: <status> -
<message>` (e.g. the agent's rejection reason). The result table shows expected and actual per run. The hard timeout is
fixed per run, so `-HardTimeoutMinutes` is a usage error with this suite. The overall deadline is, per run, its hard
timeout plus 2 minutes (baseline restore, cleanup, artifact copy), plus the claim wait (`-ClaimTimeoutSeconds`, rounded
up to minutes) plus 5 minutes (42 minutes with the defaults), unless `-TimeoutMinutes` is given. With `-PackageFrom` the package must contain TestRig.Harness and TestRig.SelfTest.

`-Suite L1-BASE` is the vanilla baseline for L1: the L1 module list without the four mods and without scenario
modules (base modules incl. the Workshop libraries and NavalDLC, plus TestRig.Harness). One job with five soak runs
r1-r5 with seeds 1, 1, 1, 2, 3, 30 days each (an explicit `-Days` changes all of them), hard timeout 10 minutes each
(a longer `-Days` scales it: `max(10, ceil(10 x days / 30))`, e.g. 20 minutes for 60 days);
every run must end `Completed` with all days reached (exit codes as for `-Suite RIG`, except that a run ending `Hung`,
`HardTimeout` or `Aborted` is inconclusive: exit 3). The seeds and hard timeouts are
fixed per run, so `-Seed` and `-HardTimeoutMinutes` are usage errors. Overall deadline (same formula as RIG): 67 minutes
with the defaults. The build compiles only TestRig.Harness; with `-PackageFrom` the package must contain it.

The build (default mode) compiles the seven projects (eight with `-Suite RIG`, `CS`, `AT`, `CW1` or `X`, ten with `-Suite L1`, only the harness with `-Suite L1-BASE`) with MSBuild into `out\stage\<jobId>\Modules`
(not into the game folder), writes `manifest.json` (SHA-256 per file, git SHA and dirty flag per
repo) next to `package.zip` and fails with exit code 1 if the game's `Modules` folder
(`towerGamePath`) changed during the build. `msbuildPath` is optional (default: VS 2026 Build Tools).

Tests (Pester 3.4, Windows PowerShell 5.1): `Invoke-Pester tests\runner` and
`Invoke-Pester tests\agent`.

Live smoke test against an installed agent, without Bannerlord (a fake game stands in):
`powershell -NoProfile -File tests\live\Invoke-FakeGameSmoke.ps1 [-Scenario complete|abort]`.

## Harness module (`src/TestRig.Harness`)

The in-game driver, shipped as Bannerlord module `TestRig.Harness` (old-style net48 csproj, game DLLs
referenced from the install, no mod references). It is inert unless the agent has written a `run.cfg` in
`Documents\Mount and Blade II Bannerlord\TestRig\harness`; it then drives a seeded campaign, logs to
`harness.log` and writes `run-result.json` (the only result file agent and runner read). The engine-free state machine lives in `src/TestRig.Harness/Logic`.

History: the older harness module inside CoherentWarAI (with a `result.txt` handshake and its own soak script) was
retired on 2026-11-04 (last state: commit `8f1bd1f` in BannerlordCoherentWarAI).

Build: the game install is auto-detected by `src/Directory.Build.props`, or set `BannerlordPath` in a
git-ignored `src/paths.props.user` (copy `src/paths.props.user.template`). A plain build deploys into the
game's `Modules` folder; to build elsewhere, override `/p:BannerlordModulesPath=<folder>`:

```powershell
& "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\MSBuild\Current\Bin\MSBuild.exe" src\TestRig.Harness\TestRig.Harness.csproj /p:Configuration=Debug /p:Platform=x64 /p:BannerlordModulesPath=<folder>\Modules
```

The harness writes `Alive: phase=<phase>` to `harness.log` every 10 s of real time from the main thread
(the first one comes about 10 s after the first harness line, from the game tick). The agent measures silence on
`Alive:` lines only, armed by the first one, so a silent log means a blocked or dead game.

Self-test module (`src/TestRig.SelfTest`, build it after the harness with the same `BannerlordModulesPath`):
scenarios `rig.selftest-throw` (module tick throws, the game must crash), `rig.selftest-hang` (main thread
blocks forever) and `rig.selftest-pass` (control). It crashes on purpose, so it is only for the rig's own tests.

Unit tests (xUnit on the host .NET SDK, no game needed):
`dotnet test tests\TestRig.Harness.Tests\TestRig.Harness.Tests.csproj`

## Architecture

1. **Runner** (dev PC, PowerShell 5.1): builds the mods, packs them with a manifest (SHA-256 per
   file, git SHA and dirty flag per repo), publishes a job, waits, fetches and prints the results.
2. **SSH transport** (`scp`/`ssh` with key auth to the test PC's existing OpenSSH server): the
   only transport. Jobs go to `C:\TestRig\queue\jobs\<jobId>\` (`package.zip`, then `job.json`
   last), results to `C:\TestRig\queue\results\<jobId>\` (`done.json` last). SSH never starts
   the game; the agent does, in the logged-on session. The rig opens no additional port.
3. **Agent** (`<test-pc>`, PowerShell 5.1): a poller started by a scheduled task in the logged-on
   session. It claims a job, runs preflight checks, installs only allow-listed modules, restores
   a baseline game config, launches Bannerlord, supervises it (sending OK to the engine's
   "Mod change detected" dialog) and publishes the artifacts.
4. **Harness module** (`TestRig.Harness`): the in-game driver that runs scenarios tick by tick
   and writes `run-result.json`. Inert without a `run.cfg`.
5. **Scenario modules** (one per mod, living in each mod repo, plus `scenarios/CrossMod` here):
   scenarios are iterator-based steps driven by the harness.

## Planned layout

```
src/TestRig.Harness   harness module (engine-free Logic/ plus engine part)
scenarios/CrossMod    scenarios spanning several mods
runner/               dev-PC scripts (Invoke-TestRig.ps1, transport adapter)
agent/                test-PC agent and its installer
tests/                xUnit tests for the engine-free logic
docs/                 setup guides (see docs/SETUP-GAMESERVER.md)
```

## Planned invocation

```powershell
runner\Invoke-TestRig.ps1 -Suite L1 -Days 3 -Wait
```

Planned runner exit codes: `0` all passed, `1` rig or infrastructure error, `2` test failure,
`3` timeout or agent unresponsive.
