# BannerlordTestRig

Runs in-game tests for four Mount & Blade II: Bannerlord mods (v1.4.8, War Sails) on a
separate Windows PC, triggered on demand from the dev PC. The dev PC never launches the game.

## Status

Scaffold only. Nothing is implemented yet; the layout below is the plan.

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
