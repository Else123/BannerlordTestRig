# BannerlordTestRig

Runs in-game tests for four Mount & Blade II: Bannerlord mods (v1.4.8, War Sails) on a
separate Windows PC, triggered on demand from the dev PC. The dev PC never launches the game.

## Status

Slice S1 (one soak run of the existing CoherentWarAI harness) is implemented:

- `runner/Invoke-TestRig.ps1` with the SSH transport `runner/Transport.Ssh.ps1`
- `agent/TestRigAgent.ps1` with its installer `agent/Install-TestRigAgent.ps1`

The job protocol between them is `docs/JOB-PROTOCOL.md`. Harness module and scenarios are
not implemented yet; the layout below is the plan.

```powershell
copy runner\runner.config.example.json runner\runner.config.json   # then edit host, user, key, towerGamePath
runner\Invoke-TestRig.ps1 -Days 1 -Wait          # builds the five mods, packs them, publishes the job
runner\Invoke-TestRig.ps1 -PackageFrom <folder with Modules\CoherentWarAI\...> -Days 1 -Wait   # diagnosis: skip the build
```

The build (default mode) compiles the five projects with MSBuild into `out\stage\<jobId>\Modules`
(not into the game folder), writes `manifest.json` (SHA-256 per file, git SHA and dirty flag per
repo) next to `package.zip` and fails with exit code 1 if the game's `Modules` folder
(`towerGamePath`) changed during the build. `msbuildPath` is optional (default: VS 2026 Build Tools).

Tests (Pester 3.4, Windows PowerShell 5.1): `Invoke-Pester tests\runner` and
`Invoke-Pester tests\agent`.

Live smoke test against an installed agent, without Bannerlord (a fake game stands in):
`powershell -NoProfile -File tests\live\Invoke-FakeGameSmoke.ps1 [-Scenario complete|abort]`.

## Architecture

1. **Runner** (dev PC, PowerShell 5.1): builds the mods, packs them with a manifest (SHA-256 per
   file, git SHA and dirty flag per repo), publishes a job, waits, fetches and prints the results.
2. **SSH transport** (`scp`/`ssh` with key auth to the test PC's existing OpenSSH server): the
   only transport. Jobs go to `C:\TestRig\queue\jobs\<jobId>\` (`package.zip`, then `job.json`
   last), results to `C:\TestRig\queue\results\<jobId>\` (`done.json` last). SSH never starts
   the game; the agent does, in the logged-on session. The rig opens no additional port.
3. **Agent** (`<test-pc>`, PowerShell 5.1): a poller started by a scheduled task in the logged-on
   session. It claims a job, runs preflight checks, installs only allow-listed modules, restores
   a baseline game config, launches Bannerlord, supervises it and publishes the artifacts.
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
