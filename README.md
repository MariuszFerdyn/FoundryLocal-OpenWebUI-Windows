# FoundryLocal-OpenWebUI-Windows

Single-script setup for [Open WebUI](https://github.com/open-webui/open-webui)
on **Windows Server 2019 / 2022 / 2025** (or Windows 10 / 11), backed by
**Microsoft Foundry Local** serving the
`qwen2.5-coder-1.5b-instruct-generic-gpu:4` model by default.

Open WebUI is exposed directly on **TCP port 80** (no IIS reverse proxy — Open
WebUI uses WebSockets that don't play well with IIS, and a direct bind keeps
the stack simple). The script automatically stops IIS (`W3SVC`) if it's
holding port 80.

The headline feature is that **the stack survives unattended cold reboots**:
after install, the server reboots, no one logs in, and Open WebUI comes up on
`:80` within ~70 seconds of power-on.

---

## Quick start (minimal)

From an **elevated PowerShell** prompt, on the account that will own the install:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Manage-FoundryStack.ps1
```

That's it. The script defaults to `-Mode Auto`, which:

- runs **Install** (full setup) if `C:\OpenWebUI` does not exist yet
- runs **Fix** (regenerate boot helper, re-register task) if it already does

Defaults: install at `C:\OpenWebUI`, Open WebUI on `:80`, Foundry on `:22334`,
model `qwen2.5-coder-1.5b-instruct-generic-gpu:4`. You will be prompted **once**
for the Windows password of the current user — see the next section for why.

After install, browse to `http://<server-ip>/`. Open WebUI asks you to create
a local admin account on first run; the model appears in the picker.

---

## Why this script asks for a Windows password

Foundry Local is shipped as an **AppX/MSIX** package — the same packaging
Microsoft Store apps use. The `foundry.exe` command on `PATH` is not a real
exe; it is an **AppX execution alias** that lives at
`C:\Users\<user>\AppData\Local\Microsoft\WindowsApps\foundry.exe`.

Windows can only invoke that alias when the user's profile is **fully loaded**
into the session. Without the profile loaded, AppX activation fails and any
direct call to `C:\Program Files\WindowsApps\Microsoft.FoundryLocal_*\foundry.exe`
is blocked by the kernel with `Access is denied`.

Scheduled tasks have several `LogonType` options. Two are relevant here:

| LogonType | Profile loaded? | Password required? | Foundry works? |
| --- | --- | --- | --- |
| `S4U` (Service-For-User) | No — token only | No | **No** — `Access is denied` at boot |
| `Password` | Yes — full logon | Yes | **Yes** |

So `LogonType=Password` is mandatory for Foundry Local to start at boot. There
is no workaround — it is a design requirement of the Windows AppX/MSIX
packaging model. NSSM-based Windows Services have the exact same constraint.

### Where the password goes

The password you enter is handed to the Task Scheduler API
(`Register-ScheduledTask -Password ...`). Windows stores it in the **Local
Security Authority (LSA) Secret** store:

- encrypted with **DPAPI** using machine-bound keys
- readable only by the `SYSTEM` account on this exact machine
- never written to the task XML, the registry in plaintext, the event log,
  or any file in this script's working directory
- never sent over the network

This is the same mechanism every Windows Service uses for its `Log On As`
account. It is the standard Windows pattern, not a workaround.

The password is used for **one thing only**: at every boot, Task Scheduler
logs the user on with this password to start the boot helper script. Nothing
else reads it.

This script never persists the password itself. The plaintext value is held
in a local PowerShell variable just long enough to call
`Register-ScheduledTask`, then overwritten and garbage-collected before the
script exits. No password is written to disk by this script.

### When you must re-run the script

If you change the Windows password of the run-as user:

- LSA still holds the old password.
- At next boot, Task Scheduler tries to log on, fails with
  `Logon failure: unknown user name or bad password` (`0x8007052E`),
  the boot helper does not run, and Open WebUI is unreachable.
- Fix: re-run `.\Manage-FoundryStack.ps1 -Mode Fix` to update LSA with the
  new password.

---

## Modes

| Mode | What it does | Prompts for password? |
| --- | --- | --- |
| `Auto` *(default)* | Install if not present, Fix if present | Yes |
| `Install` | Full setup from scratch | Yes |
| `Fix` | Regenerate boot helper, re-register task with current password | Yes |
| `Diag` | Read-only health check (task state, AppX alias, endpoints, logs) | No |
| `Test` | Simulate a boot run **without rebooting**, tail the live log | No |
| `Bootlog` | Gather all diagnostics from the **last cold boot** into a ZIP | No |
| `Nssm` | Convert from Scheduled Task to NSSM Windows Service | Yes |
| `Uninstall` | Remove task, service, firewall rule, env vars (optionally data) | No |

Examples:

```powershell
# Diagnose without changing anything
.\Manage-FoundryStack.ps1 -Mode Diag

# See exactly what will happen at boot, right now, without rebooting
.\Manage-FoundryStack.ps1 -Mode Test

# Gather everything about the last cold-boot for review (ZIPs to %TEMP%)
.\Manage-FoundryStack.ps1 -Mode Bootlog

# Re-register task after changing your Windows password
.\Manage-FoundryStack.ps1 -Mode Fix

# Convert to a real Windows Service (visible in services.msc)
.\Manage-FoundryStack.ps1 -Mode Nssm

# Full cleanup including data
.\Manage-FoundryStack.ps1 -Mode Uninstall -RemoveData
```

---

## Prerequisites

- Windows Server 2019 / 2022 / 2025, Windows 10, or Windows 11
- **winget** (App Installer). On Windows Server 2019 follow
  <https://rzetelnekursy.pl/winget-install-on-windows-2019/>.
- Administrator PowerShell (port 80, services, machine env vars, firewall
  rules, scheduled-task registration with password all need it)
- The script must be run from the **same Windows account** that will own the
  Foundry install — Foundry Local is per-user and the AppX execution alias
  only exists for accounts that ran `winget install Microsoft.FoundryLocal`.

---

## What the script does (Install mode in detail)

1. Verifies Administrator privileges.
2. Verifies `winget` is on `PATH`.
3. Installs Foundry Local via winget if missing, pins the Foundry service to
   the configured port (`foundry service set --port`), waits for the
   OpenAI-compatible endpoint, detects the API base path
   (`/v1`, `/openai/v1`, or `/openai`).
4. Downloads (if missing) and loads the model.
5. Locates a real Python 3.11+ (skipping the WindowsApps Microsoft-Store
   stub). Installs Python 3.11 via winget if no real install is found.
6. Creates a venv at `C:\OpenWebUI\venv` and runs `pip install open-webui`.
7. Sets machine-wide env vars so Open WebUI talks to Foundry, binds on every
   interface (`HOST=0.0.0.0`), and uses UTF-8 (avoids the cp1252
   `UnicodeEncodeError` during DB migrations).
8. Adds a firewall rule for the configured TCP port.
9. Stops IIS (`W3SVC`) if it is holding port 80.
10. Generates `C:\OpenWebUI\Start-Stack.ps1` (the boot helper).
11. Grants `SeBatchLogonRight`, `SeServiceLogonRight`, and
    `SeInteractiveLogonRight` to the run-as user via `secedit` (silently
    missing on many Server / Pro images, the #1 cause of "task registers fine
    but does nothing at boot").
12. Registers Scheduled Task `OpenWebUI` with `LogonType=Password` and a
    `PT30S` start-delay (gives the User Profile Service a head start so the
    profile is mounted before the boot helper runs).
13. Triggers the task once and waits for Open WebUI to actually respond on
    the configured port (full smoke test, not just "task started").

The script is idempotent — re-running just verifies/repairs the install.

---

## How the boot helper handles the cold-boot profile race

The single trickiest thing this script solves. On a cold boot:

1. Task Scheduler fires the `AtStartup` trigger (with a 30-second grace delay).
2. **At this point the User Profile Service may not yet have mounted the
   user's profile.** Until the profile is mounted, `$env:USERPROFILE` points
   to `C:\Users\Default` (the system profile template), `$env:LOCALAPPDATA`
   is empty, and the AppX alias for `foundry.exe` is missing because Foundry
   was installed under a real user, not Default.

The boot helper defends against this in three layers:

1. **Trigger delay (`PT30S`)** — gives `ProfSvc` a head start.
2. **Registry-based profile resolution** — the boot helper does NOT trust
   `$env:USERPROFILE` / `$env:LOCALAPPDATA`. It reads the run-as user's SID,
   queries
   `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\<SID>\ProfileImagePath`,
   and waits up to 180 seconds for that key to point to a real profile (not
   `\Default`). Then it overrides the env vars with the correct values.
3. **AppX alias polling** — even after the profile is mounted, the alias may
   take a few more seconds to be valid. The helper polls for up to 60s.

If the boot log ever shows
`USERPROFILE = C:\Users\Default` followed by `FATAL: ...alias not present`,
that's the profile race. The current boot helper handles it; older versions
generated by previous releases do not. `-Mode Bootlog` auto-detects this
pattern and tells you to run `-Mode Fix`.

---

## Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-Mode` | `Auto` | `Install` / `Fix` / `Diag` / `Test` / `Bootlog` / `Nssm` / `Uninstall` / `Auto` |
| `-Model` | `qwen2.5-coder-1.5b-instruct-generic-gpu:4` | Foundry model to download/load |
| `-InstallDir` | `C:\OpenWebUI` | venv + data + logs + boot helper |
| `-Port` | `80` | TCP port for Open WebUI |
| `-FoundryPort` | `22334` | Pinned port for the Foundry service |
| `-TaskName` | `OpenWebUI` | Scheduled task name |
| `-ServiceName` | `OpenWebUIStack` | NSSM Windows Service name (Nssm mode only) |
| `-ServiceUser` | current user | Run-as account (must have AppX-installed Foundry) |
| `-ServicePassword` | (prompts) | `SecureString` for unattended automation |
| `-RemoveData` | (off) | In Uninstall mode: also remove `InstallDir` |
| `-SkipStart` | (off) | In Install mode: don't start at end |

---

## Environment variables (machine scope)

The script writes these so Open WebUI uses Foundry as its OpenAI backend and
behaves correctly on Windows:

| Variable | Value |
| --- | --- |
| `OPENAI_API_BASE_URL` | `http://127.0.0.1:<foundry-port>/v1` |
| `OPENAI_API_KEY` | `foundry` (any non-empty string) |
| `WEBUI_PORT` | `80` |
| `HOST` / `WEBUI_HOST` | `0.0.0.0` (listen on every interface) |
| `DATA_DIR` | `C:\OpenWebUI\data` |
| `FOUNDRY_ENDPOINT` | The Foundry endpoint the script detected |
| `PYTHONUTF8` | `1` (avoids cp1252 `UnicodeEncodeError` during DB migrations) |
| `PYTHONIOENCODING` | `utf-8` |

---

## Boot helper

The boot helper at `C:\OpenWebUI\Start-Stack.ps1` is regenerated by every
`-Mode Install` and `-Mode Fix` run. At each boot it:

1. Reads its own SID and resolves the real profile path from the registry,
   waiting for the User Profile Service if necessary (see the cold-boot
   profile race section above).
2. Waits for the network to have a real IPv4 address (up to 60s).
3. Waits for the AppX execution alias to be ready
   (`%LocalAppData%\Microsoft\WindowsApps\foundry.exe`, up to 60s).
4. Refuses to call any direct `Program Files\WindowsApps\...\foundry.exe`
   path — those fail with `Access is denied`.
5. Sanity-checks `foundry --version` and verifies the output looks like a
   real version string (some PS / AppX combinations don't surface exit codes;
   the helper falls back to parsing output for a real version number).
6. Runs `foundry service start` and waits for the HTTP endpoint to respond.
7. Loads the model with **3 retries** and **per-attempt verification via
   `/v1/models`** — covers the common cold-boot race where
   `service start` returns before the inference subsystem is ready.
8. Launches `open-webui serve --host 0.0.0.0 --port <Port>` in the foreground
   (so the scheduled task stays in `Running` state while WebUI is up).

Boot logs are written to `C:\OpenWebUI\logs\` (one set per boot, timestamped):

| File | Contents |
| --- | --- |
| `boot-<stamp>.log` | Overall boot helper progress |
| `foundry-version-<stamp>.{out,err}` | `foundry --version` output |
| `foundry-start-<stamp>.{out,err}` | `foundry service start` output |
| `foundry-status-<stamp>.{out,err}` | `foundry service status` output |
| `foundry-load-<stamp>-<try>.{out,err}` | `foundry model load` output (per retry) |
| `webui-<stamp>.log` | Open WebUI / uvicorn output |

Each `foundry-*` step is wrapped with a hard timeout (30–600 s) so a hung
CLI cannot block boot indefinitely.

A successful cold-boot timeline looks like this (real run captured during
development, ~70 seconds power-on to operational):

```
00:00  System booted
00:37  Boot helper started   (PT30S trigger delay + dispatch)
00:37  Profile resolved via registry → C:\Users\<user>
00:38  Network ready
00:38  AppX alias found
00:39  foundry --version → 0.8.119
00:39  foundry service start → :22334
00:40  Foundry endpoint responding
01:06  Model loaded successfully (~26s first cold load)
01:09  /v1/models confirms model
01:09  Open WebUI launched on :80
```

---

## Verifying the stack is reachable

```powershell
# Bound to every interface?
Get-NetTCPConnection -LocalPort 80 -State Listen |
    Format-Table LocalAddress, LocalPort, OwningProcess
# Expect LocalAddress = 0.0.0.0 (or ::)

# From another machine
Test-NetConnection -ComputerName <server-ip> -Port 80
```

The most thorough verification is `-Mode Test`, which triggers the boot
helper exactly as it would run at boot, tails the log live, and probes both
endpoints to confirm both came up:

```powershell
.\Manage-FoundryStack.ps1 -Mode Test
```

If you're on a cloud VM (Azure / AWS / GCP), also open inbound TCP 80 in the
network security group / security group / firewall rules — the Windows
firewall rule alone is not enough.

---

## Diagnosing failed cold boots

When the machine reboots and Open WebUI does not come up, run:

```powershell
.\Manage-FoundryStack.ps1 -Mode Bootlog
```

This is read-only. It scopes everything to "since the last system boot" and
collects:

1. `boot-*.log` and all related `foundry-*` / `webui-*` files from this boot
2. Scheduled task state and full XML export
3. Task Scheduler operational events for `OpenWebUI` since boot, with
   auto-decoded common error codes (101, 103, 111, 201, 202, 203)
4. System log errors/warnings around boot (Service Control Manager, User
   Profile Service, Winlogon)
5. Application log errors mentioning foundry / python / open-webui
6. Current stack state (listening ports, processes, HTTP probes)
7. The boot helper script with hash and content sanity checks
8. Everything packaged into a single ZIP under `%TEMP%` for easy copy-off

Sections 3, 4, and 5 are interpreted intelligently: when those Windows logs
contain no events for the task or no errors at all, the script reports it
as **"Clean boot. IGNORE this section."** rather than as a failure. A
genuinely empty `Microsoft-Windows-TaskScheduler/Operational` log with the
boot helper still missing from section 1 is reported as a real problem
(disabled task, corrupted trigger, or Operational log disabled by Group
Policy).

The output also auto-detects symptomatic patterns in `boot-*.log`:

- `USERPROFILE = C:\Users\Default` → cold-boot profile race; run `-Mode Fix`
- Empty `LOCALAPPDATA` → same as above
- `Access is denied` → direct WindowsApps path attempted
- `Real profile path: ...Users\<user>` → registry resolution worked (good)
- `Launching Open WebUI on` → success milestone reached (good)

---

## Troubleshooting

Always start with diagnostics — they decode common error codes for you:

```powershell
.\Manage-FoundryStack.ps1 -Mode Diag
```

### Common failure modes

- **Task `LastResult = 0x8007052E`** — bad username/password. LSA holds a
  stale password. You probably changed the Windows password.
  Fix: `.\Manage-FoundryStack.ps1 -Mode Fix`

- **Task `LastResult = 0x80041315`** — `SeBatchLogonRight` missing for the
  run-as user. The current script grants the right automatically; if it
  still fails, run `secpol.msc` →
  *Local Policies → User Rights Assignment → Log on as a batch job* and add
  the user manually.

- **Task `LastResult = 0x800710E0`** (`SCHED_E_TASK_NOT_READY`) — task is
  already running. `-Mode Test` handles this, but if you get it elsewhere:
  `Stop-ScheduledTask -TaskName OpenWebUI` first.

- **Boot log: `USERPROFILE = C:\Users\Default`** — cold-boot profile race.
  Trigger fired before User Profile Service mounted the profile.
  Fix: re-run `.\Manage-FoundryStack.ps1 -Mode Fix` to regenerate the boot
  helper with registry-based profile resolution.

- **Boot log: `Access is denied` resolving `foundry.exe`** — the task is
  running with `LogonType=S4U` instead of `Password`. Re-run
  `-Mode Fix` to migrate it.

- **Boot log: model load fails with "Request to local service failed"** —
  cold-boot race; foundry service started but inference subsystem not yet
  ready. The current boot helper retries 3 times automatically. If all 3
  fail, manually run `foundry model load <model>` after login and add a
  longer warm-up delay if needed.

- **Model not visible in Open WebUI** — confirm `foundry service status` and
  `Invoke-RestMethod http://localhost:22334/v1/models` show the loaded
  model. If they do but the picker is empty, restart the boot helper:
  `Restart-ScheduledTask -TaskName OpenWebUI`.

- **`UnicodeEncodeError: 'charmap' codec ...`** — fixed by the `PYTHONUTF8=1`
  / `PYTHONIOENCODING=utf-8` env vars the script sets. If you ever launch
  Open WebUI manually, set them in your shell first.

- **`NativeCommandError` on log lines like `INFO [alembic ...]`** — those are
  not real errors; uvicorn writes logs to stderr. The boot helper merges
  stderr into stdout for the launch step.

- **"Python was not found ... Microsoft Store"** — that's the WindowsApps
  stub; the script's Python detection skips it and looks for a real install
  under `%LocalAppData%\Programs\Python\` and `%ProgramFiles%\Python31*`.

- **Service hangs on `foundry service start`** — every Foundry call is
  wrapped with a `Start-Process`-based helper that has timeouts, so it
  cannot get stuck on a never-closing stderr pipe.

- **Mojibake in logs (`ðŸŸ¢` instead of 🟢)** — cosmetic only; that's
  Foundry's UTF-8 emoji status indicators captured into a cp1252-default
  output file. The actual boot logic is unaffected.

- **Bootlog: `DistributedCOM 10016` warnings** — these fire on practically
  every Windows install ("application-specific permission settings do not
  grant Local Launch permission..."). Microsoft's official guidance is to
  ignore them. The Bootlog mode now filters them out of the relevant subset.

---

## NSSM mode (alternative to scheduled task)

If your operations workflow expects a "real" Windows Service visible in
`services.msc`:

```powershell
.\Manage-FoundryStack.ps1 -Mode Nssm
```

NSSM (open source, public domain) is downloaded automatically. The service
runs under the same `LogonType=Password` model — same security guarantees,
same password storage in LSA Secret, same constraints. The NSSM service is
also subject to the same cold-boot profile race; the same boot helper is
used and the same registry-based profile resolution applies.

```powershell
Get-Service OpenWebUIStack
Restart-Service OpenWebUIStack
Stop-Service OpenWebUIStack
```

---

## Uninstall

```powershell
# Remove task/service/firewall/env vars; keep the venv and data
.\Manage-FoundryStack.ps1 -Mode Uninstall

# Full cleanup including the install directory
.\Manage-FoundryStack.ps1 -Mode Uninstall -RemoveData
```

Foundry Local itself is left in place; remove with
`winget uninstall Microsoft.FoundryLocal`.

---

## Disclaimer — vibe coding

This script was written in collaboration with an LLM in the "vibe coding"
style: iterative, conversational, driven by what symptoms the live system
showed rather than by an upfront design. It works on the machine it was
debugged on (Windows Server 2022, build 20348, Foundry Local 0.8.119) and
each major failure mode encountered during development was reproduced and
verified-fixed end-to-end via `-Mode Bootlog` after a real cold reboot. But
**it has not been tested on every Windows edition, every build, every
Foundry version, or every account configuration**. Treat it as a starting
point, not a battle-hardened deployment artifact.

Read the code before running it on anything you care about. Open issues and
PRs are welcome — especially with logs from `-Mode Diag`, `-Mode Test`, or
`-Mode Bootlog` — and the diagnostic codepath is designed to make it easy to
narrow down failure modes without guessing.

No warranty. Use at your own risk.
