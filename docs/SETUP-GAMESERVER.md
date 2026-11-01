# Test PC setup (SSH transport)

Step-by-step setup of the test PC (`<test-pc>`). Transport: SSH to the test PC's existing
OpenSSH server. Nobody should play Bannerlord on this PC: the rig owns the game configuration
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

The Workshop mods live in `<Steam>\steamapps\workshop\content\261550\<item id>\`. Measured ids:
`Bannerlord.Harmony`, `Bannerlord.ButterLib`, `Bannerlord.UIExtenderEx`,
`Bannerlord.MBOptionScreen`.

Pitfalls measured on the test PC (2026-10-31), when the game folder was **copied** from another PC
instead of downloaded by Steam:

- **Visual C++ runtime missing.** The game exits at once; `starter_log.txt` in
  `C:\ProgramData\Mount and Blade II Bannerlord\logs\` shows
  `Unable to load DLL 'TaleWorlds.Native.dll' ... 0x8007007E`. `TaleWorlds.Native.dll` imports
  `vcruntime140.dll` and `msvcp140.dll`. Fix: install the Microsoft Visual C++ v14 Redistributable
  x64 (`https://aka.ms/vc14/vc_redist.x64.exe`, per Microsoft Learn).
- **Steam deletes copied Workshop items it cannot query.** `<Steam>\logs\workshop_log.txt` shows
  `Get details for item <id> failed : Access Denied`, then `removing unknown item <id>`. This hit
  MCM (`2859238197`). Fix: copy the MCM folder to `<game>\Modules\Bannerlord.MBOptionScreen\`,
  which Steam does not clean up. Symptom without it: CoherentWarAI "could not be loaded correctly
  due to a dependency conflict".
- A **"Mod change detected"** dialog appears on the first start after the module list changed.
  It needs one click; it did not reappear on later starts with the same list.

## b. Windows account and session

- One Windows account stays logged on permanently. The agent runs in that interactive session
  and starts the game there; a service or SSH session cannot show the game window.
- Autologon is optional. Without it the owner logs on again after every reboot; until then a job
  ends with runner exit 3 ("agent offline"). The owner of the test PC chose no autologon, so no
  password is stored on the PC (spec R4 does not apply).
- Measured in slice S1 (2026-10-31/11-01): a **locked** session keeps computing, and the game
  runs **without a monitor** attached. Both runs completed one game day.

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
- The agent sets this itself before every run: `StopGameOnFocusLost=False`,
  `AutoSaveInterval=-1` and `EnableTutorialHints=False` in
  `Documents\Mount and Blade II Bannerlord\Configs\BannerlordConfig.txt` (the same keys the
  CoherentWarAI `Run-SoakTest.ps1` patches).

## e. SSH access from the dev PC

The test PC runs the Windows OpenSSH server. The rig uses it only to copy jobs and results
(`scp`) and to read state; it never starts the game over SSH.

1. Key login for the session user must work from the dev PC without a password prompt:

```powershell
ssh -i <dev-pc-key> <user>@<test-pc> whoami
```

2. For an administrator account the server reads keys from
   `C:\ProgramData\ssh\administrators_authorized_keys` (the `Match Group administrators` block in
   `C:\ProgramData\ssh\sshd_config`), otherwise from `%USERPROFILE%\.ssh\authorized_keys`.
3. The remote shell is `cmd.exe`. Send PowerShell as
   `powershell -NoProfile -EncodedCommand <base64 UTF-16LE>`.
4. Anyone who can write a job can run code on the test PC (DLLs are loaded), so only the dev-PC
   key gets access.
5. Optional hardening (**pending**, owner's decision): `PasswordAuthentication no` in
   `sshd_config` and restricting the `OpenSSH Server (sshd)` firewall rule to the LAN subnet.

## f. Install the agent

1. Check the execution policy for the session user:

```powershell
Get-ExecutionPolicy -List
```

   If every scope is `Undefined`, the effective policy is `Restricted` (measured on the test PC,
   Windows 11 Pro, PowerShell 5.1: `Get-ExecutionPolicy` returned `Restricted`) and
   `powershell -File` refuses the agent. The owner decides; the rig never bypasses it. A common choice for unsigned local
   scripts is:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

2. Run the installer from a copy of the `agent\` folder on the test PC. Over SSH from the dev PC
   (no repo checkout needed on the test PC):

```powershell
ssh -i <key> <user>@<test-pc> "mkdir C:\TestRig\src"
scp -i <key> -r agent <user>@<test-pc>:C:/TestRig/src/
ssh -i <key> <user>@<test-pc> "powershell -NoProfile -File C:\TestRig\src\agent\Install-TestRigAgent.ps1"
```

   Use the Windows OpenSSH client (`%SystemRoot%\System32\OpenSSH\`). Locally on the test PC the
   same installer runs as `powershell -NoProfile -File agent\Install-TestRigAgent.ps1`.

What the installer does:

- Copies the agent to `C:\TestRig\agent\` and creates `agent.config.json` from the example if
  none exists. Set `gamePath` in it to the Bannerlord install folder.
- Registers a scheduled task that starts the agent **at logon of the current user**, with
  logon type **Interactive** and run level **Limited** (no elevation), for the current user.
- The agent polls `C:\TestRig\queue\jobs` every 10 s and holds the named mutex
  `Global\BannerlordTestRigAgent` to prevent double starts.

## g. Capture the baseline config

Planned for a later wave (TODO #7): the rig will restore this configuration before every run.
Until then the agent only patches the keys listed in section d and keeps no backup
(`baselineRestored` in `agent-run.json` is `null`). Capture the baseline once anyway, after
steps a to d, so it exists when restore arrives:

```powershell
New-Item -ItemType Directory -Force C:\TestRig\baseline | Out-Null
$cfg = Join-Path $env:USERPROFILE 'Documents\Mount and Blade II Bannerlord\Configs'
Copy-Item (Join-Path $cfg 'BannerlordConfig.txt') C:\TestRig\baseline\
```

The `Configs` location is unverified: confirm it on the test PC. The MCM JSON files of the four
mods are added to `C:\TestRig\baseline\` as well once they exist (their location is determined
in slice S3).

## h. Verify: no new inbound port

From the dev PC, port 22 (SSH) must report `True` and every other port `False`:

```powershell
22,135,139,445,3389,5900,80,443 | % { Test-NetConnection <test-pc-ip> -Port $_ -WarningAction SilentlyContinue | select RemotePort,TcpTestSucceeded }
```

Ports that are open for reasons outside this rig (existing services on that PC) must be
documented, not silently accepted.
