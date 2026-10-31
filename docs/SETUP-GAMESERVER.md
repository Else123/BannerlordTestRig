# Test PC setup (transport B: NAS job folder)

Step-by-step setup of the test PC (`<test-pc>`). Only transport B (NAS job folder) is covered;
SSH is dropped. Nobody should play Bannerlord on this PC: the rig owns the game configuration
there (open question F3, recommended answer "no").

Legend: **[OPEN]** = open in the spec, **unverified** = not confirmed against a source, check the
vendor docs, **pending** = decision not yet made.

## a. Install the game and the Workshop mods

1. Install Steam on the test PC.
2. Install Mount & Blade II: Bannerlord **v1.4.8** and the **War Sails** DLC.
3. Subscribe to these Workshop mods: Harmony, ButterLib, UIExtenderEx, MCM v5 (Mod Configuration Menu).
4. Start the game once and go to the main menu. Note the game version shown there (expected v1.4.8).
5. Read the module ids of the Workshop mods from their `SubModule.xml` (`<Id value="..."/>`):

```powershell
Get-ChildItem "<game>\Modules" -Directory | ForEach-Object {
    $xml = Join-Path $_.FullName 'SubModule.xml'
    if (Test-Path $xml) { '{0} -> {1}' -f $_.Name, ([xml](Get-Content $xml)).Module.Id.value }
}
```

The Workshop content folder location is unverified; see the Steam documentation. Expected ids
(to be confirmed by this step): `Bannerlord.Harmony`, `Bannerlord.ButterLib`,
`Bannerlord.UIExtenderEx`, `Bannerlord.MBOptionScreen`.

## b. Windows account and autologon

- One Windows account stays logged on permanently. The agent runs in that interactive session
  and starts the game there; a service or SSH session cannot show the game window.
- Configure autologon for that account so the session returns after a reboot. The tool and the
  steps are unverified: see the Microsoft documentation for the autologon mechanism you choose.
- Risk (spec R4): autologon stores the password as an LSA secret that an administrator can read.
  Accepted because it is the account that is logged on anyway.
- Open point (slice S1): whether a locked PC keeps computing normally is measured, not assumed.
  If not, leave the session unlocked with the monitor off; the risk is physical access.

## c. Steam mode (decision pending, open question F4)

Both options avoid a conflict with the dev PC's Steam session. **Decision: pending.**

1. **Offline mode (recommended).** No session conflict, no automatic updates, so the game version
   stays stable. Risks, unverified: how long offline mode lasts and its prerequisites (spec R6).
   Workshop updates arrive only when the test PC is deliberately put online.
2. **Second Steam account in the same Steam family.** No second license is needed (spec R5b).
   Blocks only while the same library is played elsewhere. Joining and switching rules of Steam
   Family are unverified: see the Steam documentation.

How to switch Steam into offline mode (menu path) is unverified: see the Steam documentation.

## d. Bannerlord options

- Run in **windowed mode**.
- Turn **"Stop Game on Focus Lost" off**, otherwise the game pauses while unattended.
- **[OPEN]** The exact key name in `BannerlordConfig.txt` is not yet determined. Find it by
  toggling the option in the game and diffing the config file before and after.

## e. NAS share and credentials

1. On the NAS create a share `testrig` and a NAS user `testrig-agent` with read/write access to
   that share only. The menu path depends on the NAS software: see the vendor docs.
2. Write access to this share lets the writer run code on the test PC (DLLs are loaded). Grant it
   only to the dev-PC user and the agent user.
3. Store the credentials for the session user on the test PC (run in that user's session):

```powershell
cmdkey /add:<nas-server> /user:testrig-agent /pass
```

`/pass` without a value prompts for the password, so it does not land in the shell history.
Check the exact `cmdkey` syntax with `cmdkey /?`. Then verify access:

```powershell
Test-Path \\<nas-server>\testrig
```

## f. Install the agent

`agent\Install-TestRigAgent.ps1` **does not exist yet** (planned for wave 2). Intended behavior:

- Copies the agent to `C:\TestRig\agent\`.
- Registers a scheduled task that starts the agent **at logon of the current user**, with
  logon type **Interactive** and run level **Limited** (no elevation), for the current user.
- The agent polls the job folder every 10 s and holds the named mutex
  `Global\BannerlordTestRigAgent` to prevent double starts.

Run it as `powershell -File agent\Install-TestRigAgent.ps1` with the machine's execution policy
left as configured (do not bypass it; sign the script or set an appropriate policy per the
Microsoft documentation).

## g. Capture the baseline config

The rig restores this configuration before every run. Capture it once, after steps a to d:

```powershell
New-Item -ItemType Directory -Force C:\TestRig\baseline | Out-Null
$cfg = Join-Path $env:USERPROFILE 'Documents\Mount and Blade II Bannerlord\Configs'
Copy-Item (Join-Path $cfg 'BannerlordConfig.txt') C:\TestRig\baseline\
```

The `Configs` location is unverified: confirm it on the test PC. The MCM JSON files of the four
mods are added to `C:\TestRig\baseline\` as well once they exist (their location is determined
in slice S3).

## h. Verify: no new inbound port

From the dev PC, every port must report `False`:

```powershell
22,135,139,445,3389,5900,80,443 | % { Test-NetConnection <test-pc-ip> -Port $_ -WarningAction SilentlyContinue | select RemotePort,TcpTestSucceeded }
```

Ports that are open for reasons outside this rig (existing services on that PC) must be
documented, not silently accepted.
