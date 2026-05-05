#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    All-in-one manager for the Foundry Local + Open WebUI stack on TCP :80, auto-starting at boot.

.DESCRIPTION
    One script, five modes. Simplest usage:

        # From the account that installed Foundry (winget per-user), elevated PS
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
        .\Manage-FoundryStack.ps1               # Auto - detects what to do

    Modes:
      -Mode Install    Full setup from scratch: Foundry + venv + open-webui + boot service.
      -Mode Fix        Repairs boot startup (changes task LogonType from S4U to Password).
                       Default mode when an install already exists (Auto).
      -Mode Diag       Read-only: status, logs, AppX, ports, processes.
      -Mode Nssm       Converts the scheduled task into a real Windows Service via NSSM.
      -Mode Uninstall  Cleans up scheduled task / service / data (with -RemoveData).
      -Mode Auto       (Default) - Install if no venv exists, otherwise Fix.

    Why the Fix mode is needed:
    Foundry Local is an AppX/MSIX package. foundry.exe must be invoked through the
    AppX execution alias at
        %LocalAppData%\Microsoft\WindowsApps\
    which only exists when the user profile is fully loaded. LogonType=S4U (the
    default in many tutorials) only provides a token, it does not load the
    profile. As a result the boot helper falls back to
    'Program Files\WindowsApps\...\foundry.exe' and Windows blocks direct execution
    of MSIX binaries -> 'Access is denied' at boot. LogonType=Password (password
    in LSA Secret/DPAPI) loads the profile normally.

.PARAMETER Mode
    Install|Fix|Diag|Nssm|Uninstall|Auto. Default: Auto.

.PARAMETER InstallDir
    Directory for venv, data, logs, boot helper. Default: 'C:\OpenWebUI'.

.PARAMETER Model
    Foundry model to download/load. Use the model ID, not the alias.

.PARAMETER FoundryPort
    Pinned Foundry port. Default: 22334.

.PARAMETER Port
    Public Open WebUI port. Default: 80.

.PARAMETER TaskName
    Scheduled task name. Default: 'OpenWebUI'.

.PARAMETER ServiceName
    Windows Service name (used only in Nssm mode). Default: 'OpenWebUIStack'.

.PARAMETER ServiceUser
    Service run-as account. Defaults to the current user. MUST be the account
    that installed Foundry via winget.

.PARAMETER ServicePassword
    Password as SecureString (for automation). If omitted, Get-Credential is used.

.PARAMETER RemoveData
    In Uninstall mode: also remove InstallDir (venv, data, logs).

.PARAMETER SkipStart
    In Install mode: don't start at the end, just prepare.

.EXAMPLE
    .\Manage-FoundryStack.ps1
    Auto-detect: install if missing, fix if already present.

.EXAMPLE
    .\Manage-FoundryStack.ps1 -Mode Diag
    Diagnostics only.

.EXAMPLE
    .\Manage-FoundryStack.ps1 -Mode Nssm
    Migrate scheduled task -> NSSM Windows Service.

.EXAMPLE
    .\Manage-FoundryStack.ps1 -Mode Install -Port 8080 -Model 'phi-4-mini-instruct-generic-gpu:4'
    Full install on a different port and with a different model.

.EXAMPLE
    .\Manage-FoundryStack.ps1 -Mode Uninstall -RemoveData
    Full cleanup.

.NOTES
    Requires: Windows 10/11/Server 2019+, Administrator, winget. Foundry will be
    installed via winget if missing (Install mode only).
#>

[CmdletBinding()]
param(
    [ValidateSet('Install','Fix','Diag','Nssm','Test','Uninstall','Auto')]
    [string]       $Mode            = 'Auto',
    [string]       $InstallDir      = 'C:\OpenWebUI',
    [string]       $Model           = 'qwen2.5-coder-1.5b-instruct-generic-gpu:4',
    [int]          $FoundryPort     = 22334,
    [int]          $Port            = 80,
    [string]       $TaskName        = 'OpenWebUI',
    [string]       $ServiceName     = 'OpenWebUIStack',
    [string]       $ServiceUser     = "$env:USERDOMAIN\$env:USERNAME",
    [SecureString] $ServicePassword,
    [switch]       $RemoveData,
    [switch]       $SkipStart,
    [string]       $NssmUrl         = 'https://nssm.cc/release/nssm-2.24.zip'
)

$ErrorActionPreference = 'Stop'


# ============================================================================
# HELPERS
# ============================================================================

function Hdr   { param($m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Step  { param($m) Write-Host "==> $m"      -ForegroundColor Cyan }
function Info  { param($m) Write-Host "    $m"      -ForegroundColor Gray }
function Ok    { param($m) Write-Host "    $m"      -ForegroundColor Green }
function Warn2 { param($m) Write-Host "    $m"      -ForegroundColor Yellow }
function Bad   { param($m) Write-Host "    $m"      -ForegroundColor Red }

function Test-Cmd { param([string]$n) [bool](Get-Command $n -ErrorAction SilentlyContinue) }

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
}

function Invoke-Exe {
    <#
    Run native exe with timeout, capture stdout+stderr.
    Avoids the "exe | Out-Null hangs because child holds stderr pipe" pitfall.
    #>
    param(
        [Parameter(Mandatory)] [string]   $FilePath,
        [string[]]                        $Arguments      = @(),
        [int]                             $TimeoutSec     = 120,
        [switch]                          $IgnoreExitCode
    )
    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    try {
        $sp = @{
            FilePath               = $FilePath
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $stdout
            RedirectStandardError  = $stderr
        }
        if ($Arguments.Count -gt 0) { $sp.ArgumentList = $Arguments }
        $p = Start-Process @sp
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch {}
            throw "Timed out after ${TimeoutSec}s: $FilePath $($Arguments -join ' ')"
        }
        $out = (Get-Content $stdout -Raw) + (Get-Content $stderr -Raw)
        if (-not $IgnoreExitCode -and $p.ExitCode -ne 0) {
            throw "Command failed (exit $($p.ExitCode)): $FilePath $($Arguments -join ' ')`n$out"
        }
        return $out
    } finally {
        Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue
    }
}

function Find-RealPython {
    # Skips the WindowsApps Microsoft-Store stub which only prints an install hint.
    $candidates = @()
    $candidates += Get-Command python.exe -All -ErrorAction SilentlyContinue |
                   Where-Object { $_.Source -and $_.Source -notmatch '\\WindowsApps\\' } |
                   ForEach-Object { $_.Source }
    $globs = @(
        "$env:LocalAppData\Programs\Python\Python31*\python.exe",
        "$env:ProgramFiles\Python31*\python.exe",
        "${env:ProgramFiles(x86)}\Python31*\python.exe",
        'C:\Python31*\python.exe'
    )
    foreach ($g in $globs) {
        $candidates += Get-ChildItem -Path $g -ErrorAction SilentlyContinue |
                       ForEach-Object { $_.FullName }
    }
    foreach ($exe in ($candidates | Select-Object -Unique)) {
        $v = & $exe --version 2>&1
        if ($LASTEXITCODE -eq 0 -and $v -match 'Python 3\.(1[1-9]|[2-9][0-9])\.') {
            return [pscustomobject]@{ Path = $exe; Version = "$v".Trim() }
        }
    }
    return $null
}

function Get-ServiceCredential {
    param(
        [string]       $UserName,
        [SecureString] $Password
    )
    if ($Password) {
        return [PSCredential]::new($UserName, $Password)
    }

    Hdr 'Windows password prompt - WHY this is needed'
    Write-Host @"
    The next dialog will ask for the Windows password of '$UserName'.
    Here is exactly why, what happens with it, and what is at stake.

    THE PROBLEM (why a simple "run as user" task is not enough)
    ----------------------------------------------------------
    Foundry Local is shipped as an AppX/MSIX package - the same packaging
    Microsoft Store apps use. The 'foundry.exe' command on PATH is not a
    real exe; it is an AppX execution alias that lives in
        C:\Users\<USER>\AppData\Local\Microsoft\WindowsApps\
    Windows can only invoke that alias when the user's profile is fully
    loaded into the session. Without the profile:
      - the alias directory is not on PATH,
      - the AppX activation context is not initialized,
      - any direct call to the binary under 'C:\Program Files\WindowsApps\'
        is blocked by the kernel with 'Access is denied'.

    Scheduled tasks have several LogonType options. The two relevant here:
      - S4U  (Service-For-User): no password required, but Windows only
              issues a token. The user profile is NOT loaded. AppX fails.
      - Password: Windows performs a real logon at boot using the stored
              credentials. The full user profile IS loaded. AppX works.

    There is no way around this for AppX/MSIX apps - it is a design
    requirement of the Windows packaging model. NSSM-based Windows
    Services have the same problem and the same fix (run-as user with
    stored password).

    WHERE YOUR PASSWORD GOES
    ------------------------
    The password you enter is handed to the Task Scheduler API
    (Register-ScheduledTask -Password ...). Windows stores it in the
    Local Security Authority (LSA) Secret store:
      - encrypted with DPAPI using machine-bound keys,
      - readable only by the SYSTEM account on this exact machine,
      - never written to the task XML, the registry in plaintext, the
        event log, or any file in this script's working directory,
      - never sent over the network.

    This is the same mechanism every Windows Service uses for its
    'Log On As' account. It is the standard Windows pattern, not a
    workaround.

    WHAT THE PASSWORD WILL BE USED FOR
    ----------------------------------
      - At every boot, Task Scheduler logs '$UserName' on with this
        password to start the boot helper script.
      - That is the ONLY use. It is not used for anything else.

    THIS SCRIPT NEVER STORES THE PASSWORD ITSELF
    --------------------------------------------
      - The plaintext value is held in a local PowerShell variable just
        long enough to call Register-ScheduledTask, then overwritten and
        garbage-collected before the script exits.
      - Nothing is written to disk by this script.

    WHEN YOU MUST RE-RUN THIS SCRIPT
    --------------------------------
    If you ever change the Windows password of '$UserName':
      - LSA still holds the old password.
      - At next boot Task Scheduler tries to log on, fails with
        'Logon failure: unknown user name or bad password' (0x8007052E),
        the boot helper does not run, and Open WebUI is unreachable.
      - Fix:  re-run  '.\Manage-FoundryStack.ps1 -Mode Fix'  (or -Mode Nssm).

    IF YOU DO NOT WANT TO ENTER A PASSWORD
    --------------------------------------
    Press Cancel in the next dialog. The script will abort without
    making changes. Alternative deployment patterns then are:
      - Run the boot helper manually after each login (no autostart).
      - Use a service account with a non-expiring password just for this.
      - Use a gMSA (group Managed Service Account) - requires AD and
        a different code path; not implemented in this script.

"@ -ForegroundColor Gray

    Write-Host "    Press Enter to open the credential dialog, or Ctrl+C to abort..." -ForegroundColor Yellow
    [void](Read-Host)

    $cred = Get-Credential -UserName $UserName `
                           -Message "Windows password for '$UserName'. Stored in LSA Secret (DPAPI). Used only by Task Scheduler at boot."
    if (-not $cred) {
        throw 'No credentials provided - aborting. Re-run when ready or pass -ServicePassword as a SecureString for unattended runs.'
    }
    return $cred
}

function Stop-LeftoverProcesses {
    param([int]$WebPort = 80)

    # WebUI / Python uvicorn on the port
    Get-NetTCPConnection -LocalPort $WebPort -State Listen -ErrorAction SilentlyContinue |
        ForEach-Object {
            $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -match '^(python|pythonw|open-webui|uvicorn)$') {
                Info "Stopping $($proc.ProcessName) PID $($proc.Id) on :$WebPort"
                try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch {}
            }
        }

    # Foundry runtime
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match '^(Inference\.Service\.Agent|Inference\.Server|onnxruntime_genai_e2e|llama-server)$' } |
        ForEach-Object {
            Info "Stopping $($_.ProcessName) PID $($_.Id)"
            try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {}
        }
    Start-Sleep -Seconds 2
}


# ============================================================================
# BOOT SCRIPT GENERATOR (key piece - fixed AppX path resolution)
# ============================================================================

function New-BootScriptContent {
    param(
        [string]$InstallDir,
        [string]$Model,
        [int]   $FoundryPort,
        [int]   $Port,
        [string]$OpenWebUiExe,
        [string]$LogDir
    )

    @"
# AUTOGENERATED by Manage-FoundryStack.ps1 - this script regenerates it.
`$ErrorActionPreference = 'Continue'

`$Model        = '$Model'
`$FoundryPort  = $FoundryPort
`$Port         = $Port
`$InstallDir   = '$InstallDir'
`$openWebUiExe = '$OpenWebUiExe'
`$logDir       = '$LogDir'
`$stamp        = (Get-Date).ToString('yyyyMMdd-HHmmss')
`$bootLog      = Join-Path `$logDir "boot-`$stamp.log"

function Log { param(`$m) `$line = "[`$(Get-Date -Format s)] `$m"; Add-Content -Path `$bootLog -Value `$line; Write-Host `$line }

function Run-WithTimeout {
    param([string]`$Exe,[string[]]`$ExeArgs=@(),[int]`$TimeoutSec=60,[string]`$LogBase)
    `$outFile = "`$LogBase.out"
    `$errFile = "`$LogBase.err"
    Log "RUN: `$Exe `$(`$ExeArgs -join ' ')   (timeout=`${TimeoutSec}s)"
    try {
        `$sp = @{ FilePath = `$Exe; PassThru = `$true; NoNewWindow = `$true
                 RedirectStandardOutput = `$outFile; RedirectStandardError = `$errFile }
        if (`$ExeArgs.Count -gt 0) { `$sp.ArgumentList = `$ExeArgs }
        `$p = Start-Process @sp
    } catch { Log "  failed to start: `$_"; return -1 }
    if (-not `$p.WaitForExit(`$TimeoutSec * 1000)) {
        Log "  TIMEOUT after `${TimeoutSec}s, killing PID `$(`$p.Id)"
        try { Stop-Process -Id `$p.Id -Force -ErrorAction Stop } catch {}
        return -1
    }
    # Force ExitCode to populate. PS 5.1 + Start-Process + RedirectStandardOutput
    # + AppX execution alias proxy = ExitCode can come back null even on success
    # because the alias handoff loses the real exit code.
    try { `$p.WaitForExit() } catch {}
    `$exit = `$p.ExitCode

    `$out = ''
    if (Test-Path `$outFile) { `$out += (Get-Content `$outFile -Raw) }
    if (Test-Path `$errFile) { `$out += (Get-Content `$errFile -Raw) }
    if (`$out) { Log ("  out/err: " + (`$out -replace '\r?\n',' | ').Trim()) }

    # If exit code came back null/empty but the process exited cleanly (we got
    # here past WaitForExit), treat it as 0. This is the AppX alias quirk.
    if (`$null -eq `$exit -or "`$exit" -eq '') {
        Log "  exit code = <null/empty - treating as 0 due to AppX alias quirk>"
        return 0
    }
    Log "  exit code = `$exit"
    return `$exit
}

# ----------------------------------------------------------------- start ----
Log "=== Boot helper starting (model=`$Model, foundryPort=`$FoundryPort, webPort=`$Port) ==="
Log "User: `$env:USERNAME   SID: `$([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"
Log "USERPROFILE  = `$env:USERPROFILE"
Log "LOCALAPPDATA = `$env:LOCALAPPDATA"

# Wait for network to be up (Tcpip dependency only ensures the stack loads,
# not that interfaces have IPs). Without this, 'foundry service start' can
# fail with binding errors on slow-booting machines.
Log 'Waiting for network (up to 60s)...'
for (`$i = 0; `$i -lt 30; `$i++) {
    `$net = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { `$_.IPAddress -notlike '169.254.*' -and `$_.IPAddress -ne '127.0.0.1' }
    if (`$net) { Log "Network ready: `$((`$net | Select-Object -First 1).IPAddress)"; break }
    Start-Sleep -Seconds 2
}

# AppX execution aliases - prepend manually to PATH.
# This directory only exists when the user profile is fully loaded
# (LogonType=Password, NOT S4U). On very early boot the alias directory may
# exist but the AppX activation context may not be ready yet, so we poll.
`$aliasDir = Join-Path `$env:LOCALAPPDATA 'Microsoft\WindowsApps'
`$aliasReady = `$false
for (`$i = 0; `$i -lt 30; `$i++) {
    if (Test-Path (Join-Path `$aliasDir 'foundry.exe')) {
        `$aliasReady = `$true
        break
    }
    if (`$i -eq 0) { Log "Waiting for AppX alias at `$aliasDir (up to 60s)..." }
    Start-Sleep -Seconds 2
}
if (`$aliasReady) {
    if (`$env:Path -notlike "*`$aliasDir*") {
        `$env:Path = "`$aliasDir;`$env:Path"
        Log "PATH+= `$aliasDir"
    }
} else {
    Log "FATAL: `$aliasDir/foundry.exe not present after 60s wait."
    Log "Possible causes:"
    Log "  1. Task LogonType is S4U, not Password (re-run installer with -Mode Fix)."
    Log "  2. Foundry was not installed under the run-as user (winget per-user)."
    Log "  3. The user profile is genuinely broken - try logging in interactively once."
    exit 1
}

# Resolve foundry.exe ONLY through the AppX alias - direct
# 'Program Files\WindowsApps\...' paths do not work without AppX activation
# (Access is denied).
`$foundryExe = `$null
`$candidates = @(
    (Join-Path `$aliasDir 'foundry.exe'),
    (Get-Command foundry -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
) | Where-Object { `$_ -and (Test-Path `$_) }

foreach (`$c in `$candidates) {
    if (`$c -like '*\Program Files\WindowsApps\*') {
        Log "Skipping direct AppX path (won't work without alias): `$c"
        continue
    }
    `$foundryExe = `$c
    break
}
Log "foundry.exe = `$foundryExe"

if (-not `$foundryExe) {
    Log 'FATAL: foundry.exe not found via AppX alias. Aborting.'
    Log 'Check: 1) task LogonType (must be Password, not S4U), 2) Foundry installed under the account the task runs as.'
    exit 2
}

# Sanity check
`$probe = Run-WithTimeout -Exe `$foundryExe -ExeArgs @('--version') -TimeoutSec 30 ``
    -LogBase (Join-Path `$logDir "foundry-version-`$stamp")

# Belt-and-braces verification: read the captured output and look for an
# actual version string. AppX alias proxies sometimes don't surface exit
# codes properly, so we trust output content over exit code.
`$verOut = ''
foreach (`$f in @((Join-Path `$logDir "foundry-version-`$stamp.out"),
                  (Join-Path `$logDir "foundry-version-`$stamp.err"))) {
    if (Test-Path `$f) { `$verOut += (Get-Content `$f -Raw) }
}
`$looksGood = (`$probe -eq 0) -or (`$verOut -match '\d+\.\d+\.\d+')
if (-not `$looksGood) {
    Log "FATAL: foundry --version exit=`$probe, output='`$(`$verOut.Trim())'. AppX is not activating correctly."
    exit 3
}
Log "Foundry sanity OK (version=`$(`$verOut.Trim()))"

Log 'foundry service start...'
`$null = Run-WithTimeout -Exe `$foundryExe -ExeArgs @('service','start') -TimeoutSec 90 ``
    -LogBase (Join-Path `$logDir "foundry-start-`$stamp")

`$endpoint = "http://127.0.0.1:`$FoundryPort"
`$ready = `$false
for (`$i = 0; `$i -lt 60; `$i++) {
    foreach (`$probe in @("`$endpoint/openai/status","`$endpoint/v1/models","`$endpoint/openai/v1/models")) {
        try {
            `$null = Invoke-WebRequest -Uri `$probe -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            `$ready = `$true; break
        } catch { }
    }
    if (`$ready) { break }
    Start-Sleep -Seconds 2
}
Log "Foundry endpoint ready = `$ready (`$endpoint)"

`$null = Run-WithTimeout -Exe `$foundryExe -ExeArgs @('service','status') -TimeoutSec 30 ``
    -LogBase (Join-Path `$logDir "foundry-status-`$stamp")

Log "Loading model `$Model..."
# Model load can fail at boot if 'foundry service start' returned but the
# inference subsystem is not yet ready to serve requests. Retry up to 3
# times and verify via /v1/models that the model actually appears.
`$modelLoaded = `$false
for (`$try = 1; `$try -le 3; `$try++) {
    Log "  attempt `$try/3"
    `$null = Run-WithTimeout -Exe `$foundryExe -ExeArgs @('model','load',"`$Model") -TimeoutSec 600 ``
        -LogBase (Join-Path `$logDir "foundry-load-`$stamp-`$try")

    # Verify by querying the OpenAI-compatible models endpoint
    Start-Sleep -Seconds 3
    try {
        `$resp = Invoke-RestMethod -Uri "`$endpoint/v1/models" -TimeoutSec 10 -ErrorAction Stop
        `$ids  = @(`$resp.data.id)
        Log "  /v1/models reports: `$(`$ids -join ', ')"
        # Match either the full id or the family prefix (before ':')
        `$prefix = (`$Model -split ':')[0]
        if (`$ids -contains `$Model -or (`$ids | Where-Object { `$_ -like "*`$prefix*" })) {
            `$modelLoaded = `$true
            Log "  Model verified loaded."
            break
        }
        Log "  Model not yet visible in /v1/models."
    } catch {
        Log "  /v1/models query failed: `$(`$_.Exception.Message)"
    }
    if (`$try -lt 3) {
        Log "  Waiting 15s before retry (foundry inference subsystem may still be warming up)..."
        Start-Sleep -Seconds 15
    }
}
if (-not `$modelLoaded) {
    Log "WARNING: Model load did not verify after 3 attempts. Open WebUI will start but the model dropdown may be empty."
    Log "         Manual fix once the system is up:  foundry model load `$Model"
}

`$env:PYTHONUTF8       = '1'
`$env:PYTHONIOENCODING = 'utf-8'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try { chcp 65001 | Out-Null } catch {}

Log "Launching Open WebUI on 0.0.0.0:`$Port -> `$endpoint"
& `$openWebUiExe serve --host 0.0.0.0 --port `$Port 2>&1 |
    Tee-Object -FilePath (Join-Path `$logDir "webui-`$stamp.log")
Log "Open WebUI exited (`$LASTEXITCODE)"
"@
}


function Write-BootScript {
    param(
        [string]$InstallDir,
        [string]$Model,
        [int]   $FoundryPort,
        [int]   $Port
    )
    $venv         = Join-Path $InstallDir 'venv'
    $openWebUiExe = Join-Path $venv 'Scripts\open-webui.exe'
    $logDir       = Join-Path $InstallDir 'logs'
    $bootScript   = Join-Path $InstallDir 'Start-Stack.ps1'

    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

    $content = New-BootScriptContent -InstallDir $InstallDir -Model $Model `
                  -FoundryPort $FoundryPort -Port $Port `
                  -OpenWebUiExe $openWebUiExe -LogDir $logDir
    Set-Content -Path $bootScript -Value $content -Encoding UTF8
    return $bootScript
}


# ============================================================================
# MODE: INSTALL
# ============================================================================

function Invoke-Install {
    Step 'Mode: INSTALL (full setup from scratch)'

    # ---- winget ----
    if (-not (Test-Cmd 'winget')) {
        throw 'winget not found. Install App Installer from the Store or https://github.com/microsoft/winget-cli/releases'
    }

    # ---- Foundry Local ----
    Step 'Foundry Local'
    if (-not (Test-Cmd 'foundry')) {
        Info 'foundry CLI missing - installing via winget...'
        winget install --id Microsoft.FoundryLocal --accept-source-agreements --accept-package-agreements --silent
        Refresh-Path
        if (-not (Test-Cmd 'foundry')) {
            throw 'foundry CLI is still not on PATH. Open a new PowerShell window and re-run.'
        }
    }
    Ok ('foundry: ' + ((& foundry --version 2>&1) -join ' '))

    Info 'Pinning Foundry port...'
    $current = Invoke-Exe -FilePath 'foundry' -Arguments @('service','status') -TimeoutSec 30 -IgnoreExitCode
    if ($current -notmatch [regex]::Escape(":$FoundryPort")) {
        $null = Invoke-Exe -FilePath 'foundry' -Arguments @('service','set','--port',"$FoundryPort") -TimeoutSec 90 -IgnoreExitCode
        Start-Sleep -Seconds 5
    }
    $endpoint = "http://127.0.0.1:$FoundryPort"
    $up = $false
    for ($i = 1; $i -le 5; $i++) {
        foreach ($probe in @("$endpoint/openai/status","$endpoint/v1/models")) {
            try { $null = Invoke-WebRequest -Uri $probe -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop; $up = $true; break } catch {}
        }
        if ($up) { break }
        $null = Invoke-Exe -FilePath 'foundry' -Arguments @('service','start') -TimeoutSec 60 -IgnoreExitCode
        Start-Sleep -Seconds (3 * $i)
    }
    if (-not $up) { throw "Foundry did not come up on $endpoint" }
    Ok "Foundry: $endpoint"

    # API base detection
    $apiBase = $null
    foreach ($c in @("$endpoint/v1","$endpoint/openai/v1","$endpoint/openai")) {
        try {
            $r = Invoke-WebRequest -Uri "$c/models" -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -eq 200) { $apiBase = $c; break }
        } catch {}
    }
    if (-not $apiBase) { $apiBase = "$endpoint/v1"; Warn2 "Could not verify /models, defaulting to $apiBase" }
    Ok "API base: $apiBase"

    # ---- Model ----
    Step "Model: $Model"
    $cached = Invoke-Exe -FilePath 'foundry' -Arguments @('cache','list') -TimeoutSec 30 -IgnoreExitCode
    if ($cached -match [regex]::Escape($Model)) {
        Ok 'Model already cached.'
    } else {
        Info 'Downloading (up to 30 minutes on slow links)...'
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & foundry model download $Model 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } } finally { $ErrorActionPreference = $prev }
        if ($LASTEXITCODE -ne 0) { throw "foundry model download failed (exit $LASTEXITCODE)" }
    }
    $null = Invoke-Exe -FilePath 'foundry' -Arguments @('model','load',$Model) -TimeoutSec 300 -IgnoreExitCode
    Ok 'Model loaded.'

    # ---- Python ----
    Step 'Python 3.11+'
    $pythonInfo = Find-RealPython
    if (-not $pythonInfo) {
        Info 'No usable Python >=3.11 (the Microsoft-Store stub does not count). Installing via winget...'
        winget install --id Python.Python.3.11 --accept-source-agreements --accept-package-agreements --silent --scope machine
        Refresh-Path
        $pythonInfo = Find-RealPython
        if (-not $pythonInfo) { throw 'Python install completed but cannot locate python.exe. Open a new PowerShell window.' }
    }
    Ok "Python: $($pythonInfo.Version) at $($pythonInfo.Path)"

    # ---- venv + open-webui ----
    Step "venv + open-webui in $InstallDir"
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir | Out-Null }
    $venv = Join-Path $InstallDir 'venv'
    if (-not (Test-Path $venv)) { & $pythonInfo.Path -m venv $venv }
    $py           = Join-Path $venv 'Scripts\python.exe'
    $pip          = Join-Path $venv 'Scripts\pip.exe'
    $openWebUiExe = Join-Path $venv 'Scripts\open-webui.exe'

    & $py -m pip install --upgrade pip wheel --quiet
    & $pip install --upgrade open-webui
    if (-not (Test-Path $openWebUiExe)) { throw "open-webui install failed; expected $openWebUiExe" }
    Ok 'open-webui installed.'

    # ---- Machine env vars ----
    Step 'Machine env vars for Open WebUI'
    $envVars = @{
        OPENAI_API_BASE_URL = $apiBase
        OPENAI_API_KEY      = 'foundry'
        WEBUI_PORT          = "$Port"
        HOST                = '0.0.0.0'
        WEBUI_HOST          = '0.0.0.0'
        DATA_DIR            = (Join-Path $InstallDir 'data')
        FOUNDRY_ENDPOINT    = $endpoint
        PYTHONUTF8          = '1'
        PYTHONIOENCODING    = 'utf-8'
    }
    foreach ($k in $envVars.Keys) {
        [System.Environment]::SetEnvironmentVariable($k, $envVars[$k], 'Machine')
        Set-Item -Path "Env:$k" -Value $envVars[$k]
    }
    Ok 'env vars saved.'

    # ---- Firewall ----
    if (-not (Get-NetFirewallRule -DisplayName "Open WebUI (TCP $Port)" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Open WebUI (TCP $Port)" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
        Ok "Firewall: Open WebUI (TCP $Port)"
    }

    # ---- IIS / W3SVC conflict ----
    $w3svc = Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue
    if ($w3svc -and $w3svc.Status -eq 'Running') {
        Warn2 'IIS (W3SVC) is running - stopping it and setting startup to Manual.'
        Stop-Service W3SVC -Force
        Set-Service  W3SVC -StartupType Manual
    }

    # ---- Boot script ----
    Step 'Boot script + Scheduled Task (LogonType=Password)'
    Stop-LeftoverProcesses -WebPort $Port
    $bootScriptPath = Write-BootScript -InstallDir $InstallDir -Model $Model -FoundryPort $FoundryPort -Port $Port
    Ok "Boot script: $bootScriptPath"

    Register-FoundryStackTask -BootScriptPath $bootScriptPath

    if ($SkipStart) {
        Ok 'SkipStart - not starting. Reboot or run: Start-ScheduledTask -TaskName ' + $TaskName
        return
    }

    Start-ScheduledTask -TaskName $TaskName
    Wait-ForBoot -InstallDir $InstallDir
}


# ============================================================================
# MODE: FIX (Migrate S4U -> Password + regen boot script)
# ============================================================================

function Invoke-Fix {
    Step 'Mode: FIX (boot service repair)'

    if (-not (Test-Path $InstallDir)) {
        throw "InstallDir '$InstallDir' does not exist. Run -Mode Install first."
    }
    $venv = Join-Path $InstallDir 'venv\Scripts\open-webui.exe'
    if (-not (Test-Path $venv)) {
        throw "Missing $venv. Run -Mode Install first."
    }

    # Inspect current task
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Info "Current task: LogonType=$($existing.Principal.LogonType), UserId=$($existing.Principal.UserId)"
        if ($existing.Principal.LogonType -eq 'Password') {
            Info 'Task already has LogonType=Password - just regenerating boot script.'
        }
    } else {
        Info "No task '$TaskName' - will create new."
    }

    # Verify AppX alias for current user
    if ($ServiceUser -ieq "$env:USERDOMAIN\$env:USERNAME") {
        $aliasExe = Join-Path $env:LocalAppData 'Microsoft\WindowsApps\foundry.exe'
        if (Test-Path $aliasExe) {
            Ok "AppX alias: $aliasExe"
        } else {
            Warn2 "Missing '$aliasExe' - Foundry was not installed under '$ServiceUser'. Run -Mode Install."
        }
    } else {
        Info "ServiceUser='$ServiceUser' differs from current user - cannot verify AppX."
        Info "Make sure 'winget install Microsoft.FoundryLocal' was run under that account."
    }

    # Regenerate boot script
    Step 'Regenerating Start-Stack.ps1'
    # Preserve parameters from existing boot script if present
    $bootScriptPath = Join-Path $InstallDir 'Start-Stack.ps1'
    if (Test-Path $bootScriptPath) {
        $old = Get-Content $bootScriptPath -Raw
        if ($old -match "(?m)^\s*\`$Model\s*=\s*'([^']+)'")   { $script:Model       = $Matches[1] }
        if ($old -match "(?m)^\s*\`$FoundryPort\s*=\s*(\d+)") { $script:FoundryPort = [int]$Matches[1] }
        if ($old -match "(?m)^\s*\`$Port\s*=\s*(\d+)")        { $script:Port        = [int]$Matches[1] }
        Info "From existing script: Model=$Model FoundryPort=$FoundryPort Port=$Port"
    }
    $bootScriptPath = Write-BootScript -InstallDir $InstallDir -Model $Model -FoundryPort $FoundryPort -Port $Port
    Ok "Wrote $bootScriptPath"

    # Re-register task
    Step "Registering '$TaskName' with LogonType=Password"
    Stop-LeftoverProcesses -WebPort $Port
    Register-FoundryStackTask -BootScriptPath $bootScriptPath

    # Smoke test
    Start-ScheduledTask -TaskName $TaskName
    Wait-ForBoot -InstallDir $InstallDir
}


# ============================================================================
# SHARED: REGISTER SCHEDULED TASK WITH LOGONTYPE=PASSWORD
# ============================================================================

function Grant-LogonRights {
    <#
    Grants SeBatchLogonRight (Log on as a batch job) AND SeServiceLogonRight
    (Log on as a service) to the given account. WITHOUT these rights, a
    Scheduled Task with LogonType=Password registers successfully but at
    boot fails silently with 'A specified logon session does not exist'
    (Task Scheduler History) or simply 'Last Run Result: 0x4' / '0x103'.

    This is the #1 reason "the install worked, but reboot does nothing":
    standard non-admin user accounts often have Service rights but not
    Batch rights on Windows Server / Pro editions.
    #>
    param([string]$User)

    $sid = (New-Object System.Security.Principal.NTAccount($User)).Translate([System.Security.Principal.SecurityIdentifier]).Value

    $tmp     = New-TemporaryFile
    $sdb     = Join-Path $env:TEMP 'manage-foundrystack-secedit.sdb'
    $infFile = "$env:TEMP\manage-foundrystack-secedit.inf"

    try {
        secedit /export /cfg $tmp /quiet | Out-Null
        $cfg     = Get-Content $tmp -Raw
        $changed = $false

        foreach ($right in @('SeBatchLogonRight','SeServiceLogonRight','SeInteractiveLogonRight')) {
            if ($cfg -match "(?m)^$right\s*=\s*([^\r\n]+)") {
                $current = $Matches[1].Trim()
                # secedit exports SIDs prefixed with '*' for SID form, or as account names
                if ($current -notmatch [regex]::Escape($sid) -and $current -notmatch [regex]::Escape($User)) {
                    Info "Granting '$right' to $User"
                    $cfg = $cfg -replace "(?m)^$right\s*=\s*[^\r\n]+", "$right = $current,*$sid"
                    $changed = $true
                } else {
                    Info "Already has '$right'."
                }
            } else {
                # Right not in export - add it
                Info "Adding '$right' for $User"
                if ($cfg -match '\[Privilege Rights\]') {
                    $cfg = $cfg -replace '\[Privilege Rights\]', "[Privilege Rights]`r`n$right = *$sid"
                    $changed = $true
                }
            }
        }

        if ($changed) {
            Set-Content -Path $infFile -Value $cfg -Encoding Unicode
            $applied = secedit /configure /db $sdb /cfg $infFile /areas USER_RIGHTS /quiet 2>&1
            if ($LASTEXITCODE -ne 0) {
                Warn2 "secedit returned $LASTEXITCODE - logon rights may not have been applied. Output: $applied"
            } else {
                Ok 'Logon rights applied via secedit.'
            }
        } else {
            Ok 'All required logon rights already present.'
        }
    } catch {
        Warn2 "Could not grant logon rights automatically: $_"
        Warn2 "Manual fix: secpol.msc -> Local Policies -> User Rights Assignment -> 'Log on as a batch job' -> Add '$User'"
    } finally {
        Remove-Item $tmp, $infFile, $sdb -ErrorAction SilentlyContinue
    }
}


function Register-FoundryStackTask {
    param([string]$BootScriptPath)

    $cred  = Get-ServiceCredential -UserName $ServiceUser -Password $ServicePassword
    $user  = $cred.UserName
    $plain = $cred.GetNetworkCredential().Password

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    # Clean up old variants from previous setup iterations
    foreach ($t in @('OpenWebUI-Boot','OpenWebUIStack','FoundryStack')) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            try { Stop-ScheduledTask  -TaskName $t -ErrorAction SilentlyContinue } catch {}
            try { Unregister-ScheduledTask -TaskName $t -Confirm:$false } catch {}
        }
    }

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$BootScriptPath`"" `
        -WorkingDirectory $InstallDir

    $trigger  = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)

    # Critical: grant Batch + Service logon rights BEFORE registering.
    # Without SeBatchLogonRight, the scheduled task with LogonType=Password
    # registers fine but fails silently at boot (Last Run Result 0x4 / 0x103,
    # Task Scheduler History: 'A specified logon session does not exist').
    Grant-LogonRights -User $user

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger $trigger -Settings $settings `
        -User $user -Password $plain -RunLevel Highest `
        -Description "Boot stack: Foundry Local + Open WebUI on TCP $Port. LogonType=Password (LSA Secret) so user profile loads at boot - required for AppX activation of foundry.exe." | Out-Null

    $plain = $null; [System.GC]::Collect()

    $check = Get-ScheduledTask -TaskName $TaskName
    if ($check.Principal.LogonType -ne 'Password') {
        throw "Registration completed but LogonType=$($check.Principal.LogonType) (expected Password)."
    }
    Ok "Task '$TaskName': UserId=$($check.Principal.UserId), LogonType=$($check.Principal.LogonType)"
}


function Wait-ForBoot {
    param([string]$InstallDir,[int]$TimeoutSec = 180)

    Step "Wait-ForBoot (smoke test, up to ${TimeoutSec}s)"
    Info 'Waiting for the boot helper to progress through:'
    Info '  1. AppX alias resolution (foundry.exe found)'
    Info '  2. foundry service start'
    Info '  3. Foundry endpoint responding'
    Info "  4. Model load (can take a minute or two on first run)"
    Info '  5. Open WebUI launch'
    Info ''

    $logDir    = Join-Path $InstallDir 'logs'
    $start     = Get-Date
    $reported  = @{}
    $done      = $false
    $latestLog = $null

    while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 3

        $latestLog = Get-ChildItem $logDir -Filter 'boot-*.log' -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latestLog -or ((Get-Date) - $latestLog.LastWriteTime).TotalSeconds -gt 60) { continue }

        $c = Get-Content $latestLog.FullName -Raw

        # Report progress milestones once each
        $milestones = @{
            'foundry_alias'  = 'foundry\.exe = .*WindowsApps\\foundry\.exe'
            'sanity_ok'      = 'Foundry sanity OK \(version='
            'service_start'  = 'foundry service start'
            'endpoint_up'    = 'Foundry endpoint ready = True'
            'model_load'     = 'Loading model '
            'webui_launch'   = 'Launching Open WebUI'
        }
        foreach ($k in $milestones.Keys) {
            if (-not $reported[$k] -and $c -match $milestones[$k]) {
                Ok "  [+] $k reached"
                $reported[$k] = $true
            }
        }

        # Hard failure?
        if ($c -match 'FATAL:') {
            $fatalLine = ($c -split "`r?`n" | Where-Object { $_ -match 'FATAL:' } | Select-Object -First 1)
            Bad "  Boot helper FATAL: $fatalLine"
            Bad "  Full log: $($latestLog.FullName)"
            return $false
        }

        # Real success: Open WebUI actually responds
        try {
            $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/version" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            $done = $true
            break
        } catch {}
    }

    if ($done) {
        Ok "Smoke OK: Open WebUI is responding on :$Port. Stack ready."
        return $true
    }

    # Timed out without WebUI responding - report progress
    Warn2 "Boot helper did not finish within ${TimeoutSec}s."
    if ($reported.Count -gt 0) {
        Warn2 "Last reached milestones: $($reported.Keys -join ', ')"
    }
    if ($latestLog) {
        Warn2 "Inspect:  Get-Content '$($latestLog.FullName)' -Tail 40"
    }
    return $false
}


# ============================================================================
# MODE: DIAG
# ============================================================================

function Invoke-Diag {
    Step 'Mode: DIAG (read-only)'

    Hdr 'Scheduled Task'
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Info ("Task '$TaskName' state=$($task.State), LastResult=0x{0:X}" -f $info.LastTaskResult)
        Info "  UserId      = $($task.Principal.UserId)"
        Info "  LogonType   = $($task.Principal.LogonType)"
        Info "  LastRunTime = $($info.LastRunTime)"
        $lrr = $info.LastTaskResult
        $lrrMeaning = switch ($lrr) {
            0       { 'Success (0x0)' }
            267009  { 'Currently running (0x41301)' }
            267011  { 'Has not run (0x41303)' }
            1       { 'Incorrect function (0x1) - script error' }
            2       { 'File not found (0x2) - check boot script path' }
            267008  { 'Ready, never run (0x41300)' }
            267014  { 'User terminated (0x41306)' }
            2147750687 { 'Logon failure (0x80041315) - SeBatchLogonRight missing or password wrong' }
            2147943726 { 'Logon failure: bad username or password (0x8007052E) - LSA password stale, re-run -Mode Fix' }
            default { ("0x{0:X}" -f $lrr) }
        }
        Info "  LastResult  = $lrrMeaning"
        if ($task.Principal.LogonType -eq 'S4U') {
            Bad '  LogonType=S4U - profile will NOT load at boot, AppX will fail. Run -Mode Fix.'
        } elseif ($task.Principal.LogonType -eq 'Password') {
            Ok '  LogonType=Password - correct.'
        }

        # Verify the run-as account has Batch logon right (the silent killer
        # when "everything looks configured but task does nothing at boot").
        $runAs = $task.Principal.UserId
        try {
            $tmp = New-TemporaryFile
            secedit /export /cfg $tmp /quiet /areas USER_RIGHTS | Out-Null
            $cfg = Get-Content $tmp -Raw
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            $sid = (New-Object System.Security.Principal.NTAccount($runAs)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            if ($cfg -match "(?m)^SeBatchLogonRight\s*=\s*([^\r\n]+)") {
                $batch = $Matches[1]
                if ($batch -match [regex]::Escape($sid) -or $batch -match [regex]::Escape($runAs)) {
                    Ok "  '$runAs' has 'Log on as a batch job' right."
                } else {
                    Bad "  '$runAs' does NOT have 'Log on as a batch job' right - task will fail at boot. Run -Mode Fix."
                }
            }
        } catch { Info "  Could not verify batch logon right: $_" }
    } else {
        Info "No scheduled task '$TaskName'."
    }

    Hdr 'Windows Service (NSSM)'
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        Info "Service '$ServiceName' Status=$($svc.Status), StartType=$($svc.StartType)"
        $wmi = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
        if ($wmi) { Info "  StartName = $($wmi.StartName)" }
    } else {
        Info "No Windows Service '$ServiceName'."
    }

    Hdr 'Latest boot-*.log'
    $logDir = Join-Path $InstallDir 'logs'
    if (Test-Path $logDir) {
        $latest = Get-ChildItem $logDir -Filter 'boot-*.log' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            Info "File: $($latest.FullName)"
            Info "Time: $($latest.LastWriteTime)"
            Info '------ last 30 lines: ------'
            Get-Content $latest.FullName -Tail 30 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            $content = Get-Content $latest.FullName -Raw
            if ($content -match 'Access is denied')                   { Bad 'DETECTED "Access is denied" - classic S4U+AppX symptom. Run -Mode Fix.' }
            if ($content -match 'Program Files\\WindowsApps\\.+foundry\.exe' -and
                $content -notmatch 'AppData\\Local\\Microsoft\\WindowsApps\\foundry\.exe') {
                Bad 'Boot helper only hit the raw WindowsApps path. -Mode Fix regenerates the script.'
            }
            if ($content -match '\\AppData\\Local\\Microsoft\\WindowsApps\\foundry\.exe') {
                Ok 'Boot helper used AppX execution alias.'
            }
        } else {
            Info 'No boot-*.log found.'
        }
    }

    Hdr 'AppX execution alias (current user)'
    $aliasExe = Join-Path $env:LocalAppData 'Microsoft\WindowsApps\foundry.exe'
    if (Test-Path $aliasExe) {
        Ok "Alias: $aliasExe"
        try { $v = & $aliasExe --version 2>&1; Info "  --version: $($v -join ' ')" } catch { Bad "  Execution failed: $_" }
    } else {
        Bad "Missing '$aliasExe'."
    }

    Hdr 'Foundry endpoint'
    $endpoint = "http://127.0.0.1:$FoundryPort"
    $reach = $false
    foreach ($p in @("$endpoint/openai/status","$endpoint/v1/models")) {
        try {
            $r = Invoke-WebRequest -Uri $p -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            Ok "$p -> HTTP $($r.StatusCode)"
            $reach = $true
            if ($p -like '*models*') {
                try {
                    $j = $r.Content | ConvertFrom-Json
                    $ids = @($j.data.id)
                    if ($ids.Count -gt 0) { Info "  Models: $($ids -join ', ')" }
                    else                  { Bad '  /models returned empty - no model loaded.' }
                } catch {}
            }
        } catch { Info "$p -> $($_.Exception.Message)" }
    }
    if (-not $reach) { Bad "Foundry not responding on :$FoundryPort" }

    Hdr "Open WebUI :$Port"
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/version" -UseBasicParsing -TimeoutSec 5
        Ok "/api/version -> $($r.StatusCode), $($r.Content)"
    } catch { Bad "Open WebUI not responding: $($_.Exception.Message)" }

    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $listener) {
        $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        Info "  Listening: $($c.LocalAddress):$($c.LocalPort) PID=$($c.OwningProcess) ($($proc.ProcessName))"
    }

    Hdr 'Foundry runtime processes'
    $procs = Get-Process -ErrorAction SilentlyContinue |
             Where-Object { $_.ProcessName -match 'foundry|Inference\.Service|onnxruntime|llama-server' }
    if ($procs) {
        $procs | ForEach-Object { Info ("  {0,-30} PID={1,-6} CPU={2:N1}s WS={3:N0} MB" -f
            $_.ProcessName, $_.Id, $_.CPU, ($_.WorkingSet64 / 1MB)) }
    } else {
        Bad 'No Foundry processes in memory.'
    }

    Hdr 'Task Scheduler event log (last 10)'
    try {
        Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 200 -ErrorAction Stop |
            Where-Object { $_.Message -match $TaskName } |
            Select-Object -First 10 |
            ForEach-Object { Info ("  [{0}] {1}: {2}" -f $_.TimeCreated.ToString('s'), $_.Id,
                           ($_.Message -split "`n" | Select-Object -First 1)) }
    } catch { Info "Cannot read Task Scheduler log: $_" }

    Write-Host "`nDiagnostics complete." -ForegroundColor Green
}


# ============================================================================
# MODE: TEST (simulate a boot run without rebooting)
# ============================================================================

function Invoke-Test {
    Step 'Mode: TEST (simulate boot without restarting)'

    Info 'This triggers the scheduled task right now, exactly as it would run at boot.'
    Info 'Useful to see failures live instead of guessing after a reboot.'

    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        throw "No scheduled task '$TaskName'. Run -Mode Install or -Mode Fix first."
    }

    # If the task is already running (e.g. from a previous Fix smoke test),
    # stop it first - Start-ScheduledTask on a running task returns
    # SCHED_E_TASK_NOT_READY (0x800710E0) and silently does nothing.
    $tBefore = Get-ScheduledTask -TaskName $TaskName
    if ($tBefore.State -eq 'Running') {
        Info 'Task is already Running (probably from a previous Fix/Test smoke test).'
        Info 'Stopping the existing instance first...'
        Stop-ScheduledTask -TaskName $TaskName
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Seconds 2
            if ((Get-ScheduledTask -TaskName $TaskName).State -ne 'Running') { break }
        }
        $stillRunning = (Get-ScheduledTask -TaskName $TaskName).State -eq 'Running'
        if ($stillRunning) {
            Warn2 'Task still showing Running after Stop-ScheduledTask. Hunting orphan processes...'
        } else {
            Ok 'Task stopped.'
        }
    }

    Info "Stopping any leftover processes on :$Port..."
    Stop-LeftoverProcesses -WebPort $Port
    Start-Sleep -Seconds 2

    $logDir   = Join-Path $InstallDir 'logs'
    $beforeT  = Get-Date

    Step "Triggering Scheduled Task '$TaskName' (simulating boot)"
    Start-ScheduledTask -TaskName $TaskName

    # Watch the task transition
    Step 'Watching task state for 20 seconds...'
    for ($i = 0; $i -lt 20; $i++) {
        $t = Get-ScheduledTask -TaskName $TaskName
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Info ("  [t+{0,2}s] State={1}  LastResult=0x{2:X}" -f $i, $t.State, $info.LastTaskResult)
        if ($t.State -eq 'Running') { break }
        Start-Sleep -Seconds 1
    }

    $tNow = Get-ScheduledTask -TaskName $TaskName
    if ($tNow.State -ne 'Running') {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Bad "Task did NOT start. Final state=$($tNow.State), LastResult=0x$('{0:X}' -f $info.LastTaskResult)"
        Bad ''
        Bad 'Most common causes:'
        Bad '  0x8007052E - bad username/password (LSA stale). Re-run -Mode Fix.'
        Bad '  0x80041315 - SeBatchLogonRight missing for run-as user. Re-run -Mode Fix.'
        Bad '  0x800710E0 - SCHED_E_TASK_NOT_READY (already running). This script handles that;'
        Bad '               if you still see it, kill orphan processes manually:'
        Bad "               Get-Process powershell | Where-Object { `$_.CommandLine -match 'Start-Stack' } | Stop-Process -Force"
        Bad '  0x2        - boot script path wrong. Check Start-Stack.ps1 exists.'
        Bad ''
        Bad 'Check Task Scheduler History:'
        Bad '  Get-WinEvent -LogName Microsoft-Windows-TaskScheduler/Operational -MaxEvents 30 |'
        Bad "    Where-Object { `$_.Message -match '$TaskName' } | Format-List TimeCreated, Id, Message"
        return
    }

    Ok 'Task is running. Tailing boot log...'
    Step 'Live boot log (Ctrl+C to stop watching, task keeps running)'

    # Wait for the new boot log to appear
    $latest = $null
    for ($i = 0; $i -lt 15; $i++) {
        $latest = Get-ChildItem $logDir -Filter 'boot-*.log' -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTime -gt $beforeT } |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { break }
        Start-Sleep -Seconds 1
    }

    if (-not $latest) {
        Warn2 'No fresh boot-*.log appeared in 15s. Falling back to most recent existing log.'
        $latest = Get-ChildItem $logDir -Filter 'boot-*.log' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) {
            Bad "No boot-*.log files at all in $logDir."
            return
        }
        Info "Most recent log: $($latest.FullName) (mtime: $($latest.LastWriteTime))"
    } else {
        Info "Tailing fresh log: $($latest.FullName)"
    }

    Write-Host ''
    Write-Host '----- LIVE LOG (last 80s, Ctrl+C to exit) -----' -ForegroundColor Yellow

    $deadline = (Get-Date).AddSeconds(80)
    $position = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $latest.FullName) {
            $content = Get-Content $latest.FullName -Raw
            if ($content -and $content.Length -gt $position) {
                Write-Host $content.Substring($position) -NoNewline -ForegroundColor DarkGray
                $position = $content.Length
            }
        }
        # Stop early if Open WebUI is up (verdict will pass)
        try {
            $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/version" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            Write-Host ''
            Write-Host '----- Open WebUI responded - exiting tail early -----' -ForegroundColor Green
            break
        } catch {}
        Start-Sleep -Milliseconds 1000
    }
    Write-Host ''
    Write-Host '----- END OF LIVE LOG (test window expired) -----' -ForegroundColor Yellow

    # Final verdict
    Step 'Verdict'
    $endpoint = "http://127.0.0.1:$FoundryPort/v1/models"
    $foundryUp = $false
    try { $null = Invoke-WebRequest -Uri $endpoint -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop; $foundryUp = $true } catch {}
    if ($foundryUp) { Ok "Foundry is responding on :$FoundryPort" } else { Bad "Foundry NOT responding on :$FoundryPort" }

    $webuiUp = $false
    try { $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/version" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop; $webuiUp = $true } catch {}
    if ($webuiUp) { Ok "Open WebUI is responding on :$Port" } else { Bad "Open WebUI NOT responding on :$Port" }

    if ($foundryUp -and $webuiUp) {
        Ok 'Both services up. After reboot they should come up automatically.'
    } else {
        Bad ''
        Bad 'Stack did not fully come up. Read the live log above for the failing step.'
        Bad "Full log: Get-Content '$($latest.FullName)' | more"
    }
}


# ============================================================================
# MODE: NSSM (Windows Service instead of scheduled task)
# ============================================================================

function Invoke-Nssm {
    Step 'Mode: NSSM (real Windows Service)'

    $bootScriptPath = Join-Path $InstallDir 'Start-Stack.ps1'
    if (-not (Test-Path $bootScriptPath)) {
        Info 'No Start-Stack.ps1 found - regenerating (using parameters from param block).'
        $bootScriptPath = Write-BootScript -InstallDir $InstallDir -Model $Model `
                                            -FoundryPort $FoundryPort -Port $Port
    }

    # NSSM
    $nssmDir = Join-Path $InstallDir 'nssm'
    $nssmExe = Join-Path $nssmDir 'nssm.exe'
    if (-not (Test-Path $nssmExe)) {
        if (-not (Test-Path $nssmDir)) { New-Item -ItemType Directory -Path $nssmDir | Out-Null }
        $zip = Join-Path $env:TEMP 'nssm-2.24.zip'
        Info "Downloading $NssmUrl"
        Invoke-WebRequest -Uri $NssmUrl -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $nssmDir -Force
        $found = Get-ChildItem -Path $nssmDir -Recurse -Filter 'nssm.exe' |
                 Where-Object { $_.FullName -match 'win64' } | Select-Object -First 1
        if (-not $found) {
            $found = Get-ChildItem -Path $nssmDir -Recurse -Filter 'nssm.exe' | Select-Object -First 1
        }
        if (-not $found) { throw 'nssm.exe not found in downloaded ZIP.' }
        Copy-Item -Path $found.FullName -Destination $nssmExe -Force
        Remove-Item $zip -Force
    }
    Ok "nssm.exe = $nssmExe"

    # Disable competing tasks
    foreach ($t in @($TaskName,'OpenWebUI-Boot','FoundryStack')) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Info "Disabling competing scheduled task '$t' (replaced by NSSM)"
            try { Stop-ScheduledTask  -TaskName $t -ErrorAction SilentlyContinue } catch {}
            try { Disable-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
    }

    # Credentials
    $cred  = Get-ServiceCredential -UserName $ServiceUser -Password $ServicePassword
    $user  = $cred.UserName
    $plain = $cred.GetNetworkCredential().Password

    # (Re)create
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Info 'Old service exists - removing.'
        & $nssmExe stop   $ServiceName confirm 2>&1 | Out-Null
        & $nssmExe remove $ServiceName confirm 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    }

    $ps     = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $logDir = Join-Path $InstallDir 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $svcOut = Join-Path $logDir 'service-stdout.log'
    $svcErr = Join-Path $logDir 'service-stderr.log'

    & $nssmExe install $ServiceName $ps "-NoProfile -ExecutionPolicy Bypass -File `"$bootScriptPath`"" 2>&1 | Out-Null
    & $nssmExe set $ServiceName ObjectName    $user $plain                              2>&1 | Out-Null
    $plain = $null; [System.GC]::Collect()
    & $nssmExe set $ServiceName Start         SERVICE_AUTO_START                        2>&1 | Out-Null
    & $nssmExe set $ServiceName AppDirectory  $InstallDir                                2>&1 | Out-Null
    & $nssmExe set $ServiceName DisplayName   "AI Stack: Foundry Local + Open WebUI"     2>&1 | Out-Null
    & $nssmExe set $ServiceName Description   "Boot stack: Foundry Local AppX + Open WebUI on :$Port. Runs as $user." 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppStdout     $svcOut                                    2>&1 | Out-Null
    & $nssmExe set $ServiceName AppStderr     $svcErr                                    2>&1 | Out-Null
    & $nssmExe set $ServiceName AppStdoutCreationDisposition 4                           2>&1 | Out-Null
    & $nssmExe set $ServiceName AppStderrCreationDisposition 4                           2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateFiles  1                                        2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateOnline 1                                        2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateBytes  10485760                                 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppExit       Default Restart                            2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRestartDelay 10000                                    2>&1 | Out-Null
    & $nssmExe set $ServiceName AppThrottle     30000                                    2>&1 | Out-Null
    & $nssmExe set $ServiceName DependOnService Tcpip                                    2>&1 | Out-Null

    # 'Log on as a service' right
    $tmp = New-TemporaryFile
    secedit /export /cfg $tmp /quiet | Out-Null
    $cfg = Get-Content $tmp -Raw
    if ($cfg -match 'SeServiceLogonRight\s*=\s*([^\r\n]+)') {
        $current = $Matches[1]
        if ($current -notmatch [regex]::Escape($user)) {
            Info "Granting 'Log on as a service' to $user"
            $newRight = "$current,$user"
            $cfg = $cfg -replace 'SeServiceLogonRight\s*=\s*[^\r\n]+', "SeServiceLogonRight = $newRight"
            $tmp2 = "$env:TEMP\secupdate.inf"
            Set-Content -Path $tmp2 -Value $cfg -Encoding Unicode
            secedit /configure /db (Join-Path $env:TEMP 'sec.sdb') /cfg $tmp2 /quiet | Out-Null
            Remove-Item $tmp2 -Force
        }
    }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue

    Ok "Service '$ServiceName' registered."

    Stop-LeftoverProcesses -WebPort $Port
    Start-Service -Name $ServiceName
    Start-Sleep -Seconds 5
    $svc = Get-Service -Name $ServiceName
    if ($svc.Status -eq 'Running') {
        Ok 'Service is running.'
    } else {
        Bad "Status=$($svc.Status). Check $svcErr"
    }
}


# ============================================================================
# MODE: UNINSTALL
# ============================================================================

function Invoke-Uninstall {
    Step 'Mode: UNINSTALL'

    foreach ($t in @($TaskName,'OpenWebUI-Boot','OpenWebUIStack','FoundryStack')) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            try { Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue } catch {}
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
            Ok "Removed task '$t'"
        }
    }

    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        $nssmExe = Join-Path $InstallDir 'nssm\nssm.exe'
        if (Test-Path $nssmExe) {
            & $nssmExe stop   $ServiceName confirm 2>&1 | Out-Null
            & $nssmExe remove $ServiceName confirm 2>&1 | Out-Null
            Ok "Removed service '$ServiceName'"
        } else {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            sc.exe delete $ServiceName | Out-Null
            Ok "Removed service '$ServiceName' (sc.exe)"
        }
    }

    Stop-LeftoverProcesses -WebPort $Port

    if (Get-NetFirewallRule -DisplayName "Open WebUI (TCP $Port)" -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -DisplayName "Open WebUI (TCP $Port)"
        Ok "Firewall: removed rule 'Open WebUI (TCP $Port)'"
    }

    foreach ($k in @('OPENAI_API_BASE_URL','OPENAI_API_KEY','WEBUI_PORT','HOST','WEBUI_HOST',
                     'DATA_DIR','FOUNDRY_ENDPOINT','PYTHONUTF8','PYTHONIOENCODING')) {
        [System.Environment]::SetEnvironmentVariable($k, $null, 'Machine')
    }
    Ok 'Machine env vars removed.'

    if ($RemoveData) {
        if (Test-Path $InstallDir) {
            Remove-Item -Path $InstallDir -Recurse -Force
            Ok "Removed $InstallDir"
        }
    } else {
        Info "InstallDir '$InstallDir' kept. Pass -RemoveData to remove it as well."
    }

    Info 'Foundry is left in place - remove with: winget uninstall Microsoft.FoundryLocal'
}


# ============================================================================
# MAIN: banner + dispatch
# ============================================================================

# ---- Startup banner -------------------------------------------------------
Write-Host ''
Write-Host '#############################################################' -ForegroundColor Cyan
Write-Host '#  Manage-FoundryStack.ps1                                  #' -ForegroundColor Cyan
Write-Host '#  Foundry Local + Open WebUI - install, fix, diagnose      #' -ForegroundColor Cyan
Write-Host '#############################################################' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Running as : $env:USERDOMAIN\$env:USERNAME (elevated)"          -ForegroundColor Gray
Write-Host "  Machine    : $env:COMPUTERNAME"                                  -ForegroundColor Gray
Write-Host "  InstallDir : $InstallDir"                                        -ForegroundColor Gray
Write-Host "  Mode arg   : $Mode"                                              -ForegroundColor Gray
Write-Host ''

# ---- Auto-detect ----------------------------------------------------------
if ($Mode -eq 'Auto') {
    $venv = Join-Path $InstallDir 'venv\Scripts\open-webui.exe'
    if (Test-Path $venv) {
        Info "Auto-detect: '$venv' exists -> Mode=Fix"
        $Mode = 'Fix'
    } else {
        Info "Auto-detect: '$venv' missing -> Mode=Install"
        $Mode = 'Install'
    }
    Write-Host ''
}

# ---- Per-mode "what I am about to do" preview -----------------------------
$preview = switch ($Mode) {
    'Install'   { @"
INSTALL mode - full setup from scratch. I will:
  1. Verify winget is on PATH (required to install Foundry).
  2. Install 'Microsoft.FoundryLocal' via winget if foundry CLI is missing.
  3. Pin the Foundry service to TCP $FoundryPort (foundry service set --port).
  4. Download + load model '$Model' (can take up to ~30 minutes on first run).
  5. Install Python 3.11 via winget if no real Python >=3.11 is found
     (the Microsoft-Store stub does not count - it is not a real Python).
  6. Create a venv in '$InstallDir\venv' and pip-install 'open-webui'.
  7. Set machine-scope environment variables that Open WebUI reads at start
     (OPENAI_API_BASE_URL, DATA_DIR, HOST, PORT, PYTHONUTF8, ...).
  8. Open Windows Firewall for inbound TCP $Port.
  9. Stop the IIS service (W3SVC) if it is running and conflicting on port $Port.
 10. Generate '$InstallDir\Start-Stack.ps1' (the boot helper).
 11. Register Scheduled Task '$TaskName' with LogonType=Password
     (you will be asked for the Windows password of '$ServiceUser' - the
     prompt explains in detail why this is required and where the password
     goes; press Ctrl+C in that prompt to abort).
 12. Start the task once and verify boot success (smoke test).
"@ }
    'Fix'       { @"
FIX mode - repair existing install so it actually starts at boot. I will:
  1. Verify '$InstallDir' contains a working venv (no install changes).
  2. Inspect existing Scheduled Task '$TaskName':
     - LogonType=S4U  -> the boot failure cause, will be migrated to Password.
     - LogonType=Password -> already correct, just regenerate boot helper.
  3. Verify the AppX execution alias exists for the current user:
     '$env:LocalAppData\Microsoft\WindowsApps\foundry.exe'
  4. Regenerate '$InstallDir\Start-Stack.ps1' with corrected AppX path
     resolution (preferring the alias, refusing the raw 'Program Files\
     WindowsApps\...' path that triggers 'Access is denied').
  5. Re-register Scheduled Task '$TaskName' with LogonType=Password.
     You will be prompted for the Windows password of '$ServiceUser' -
     the prompt explains in detail why this is required and how the
     password is protected.
  6. Run the task once and verify in the boot log that foundry.exe
     resolves through the AppX alias (smoke test).
NOTHING is uninstalled or downloaded in this mode. No data is touched.
"@ }
    'Diag'      { @"
DIAG mode - read-only. I will inspect and report:
  - Scheduled Task '$TaskName' (state, LogonType, last result).
  - Windows Service '$ServiceName' (if NSSM was used).
  - Most recent boot-*.log under '$InstallDir\logs' (last 30 lines, with
    auto-detection of the 'Access is denied' / 'S4U+AppX' failure mode).
  - AppX execution alias for foundry.exe under the current user.
  - Foundry HTTP endpoint on :$FoundryPort and the list of loaded models.
  - Open WebUI HTTP endpoint on :$Port and the process listening on it.
  - Foundry runtime processes (Inference.Service.Agent.exe etc.).
  - Last 10 Task Scheduler events related to '$TaskName'.
NOTHING is changed. No password is requested.
"@ }
    'Test'      { @"
TEST mode - simulate a boot run RIGHT NOW without rebooting. I will:
  1. Trigger Scheduled Task '$TaskName' (the same one that runs at boot).
  2. Watch its state for 20 seconds and report the LastResult code with
     a human-readable interpretation (e.g. 0x8007052E = bad password).
  3. Tail the live boot log for 80 seconds so you see exactly what is
     happening (or where it fails).
  4. Probe both Foundry (:$FoundryPort) and Open WebUI (:$Port) endpoints
     to confirm the stack actually came up.
This is the FASTEST way to diagnose 'works manually but not after reboot'
because you see the failure live, with the same identity and environment
that boot-time Task Scheduler will use. NO password is requested.
"@ }
    'Nssm'      { @"
NSSM mode - convert to a real Windows Service. I will:
  1. Download nssm.exe from $NssmUrl (if not already in '$InstallDir\nssm').
     NSSM is open-source (public domain), used to wrap arbitrary processes
     as Windows Services.
  2. Disable any existing Scheduled Task '$TaskName' so the two do not race.
  3. (Re)create Windows Service '$ServiceName' under user '$ServiceUser'.
     You will be prompted for the Windows password - same reason as Fix
     mode (AppX needs a fully loaded user profile, which means a real
     logon at service start, which means stored credentials in LSA).
  4. Configure auto-start, restart-on-failure, log rotation, and a
     dependency on the Tcpip service.
  5. Grant '$ServiceUser' the 'Log on as a service' privilege if missing.
  6. Start the service and verify it is running.
After this, you can manage the stack with standard tools:
     Get-Service $ServiceName
     Restart-Service $ServiceName
     services.msc
"@ }
    'Uninstall' { @"
UNINSTALL mode - cleanup. I will:
  1. Remove Scheduled Task '$TaskName' (and any stale variants).
  2. Stop and remove Windows Service '$ServiceName' (if present).
  3. Stop any leftover open-webui / python / Inference.Service.Agent process.
  4. Remove the firewall rule 'Open WebUI (TCP $Port)'.
  5. Clear machine-scope environment variables created by Install mode.
  6. $(if ($RemoveData) { "REMOVE the entire directory '$InstallDir' (data, venv, logs, models cache copy)." } else { "Leave '$InstallDir' intact (pass -RemoveData to delete it)." })
Foundry Local itself is NOT uninstalled - it remains a per-user winget
package; remove with: winget uninstall Microsoft.FoundryLocal
"@ }
}

Hdr "Plan ($Mode mode)"
Write-Host $preview -ForegroundColor Gray

if ($Mode -in @('Install','Fix','Nssm','Uninstall')) {
    Write-Host ''
    Write-Host '    Press Enter to proceed, or Ctrl+C to abort.' -ForegroundColor Yellow
    [void](Read-Host)
}

Write-Host ''
switch ($Mode) {
    'Install'   { Invoke-Install   }
    'Fix'       { Invoke-Fix       }
    'Diag'      { Invoke-Diag      }
    'Test'      { Invoke-Test      }
    'Nssm'      { Invoke-Nssm      }
    'Uninstall' { Invoke-Uninstall }
}

Write-Host ''
Write-Host '====================== DONE ======================' -ForegroundColor Green
@"
Useful commands:
  .\Manage-FoundryStack.ps1 -Mode Diag             # check status
  Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
  Get-Content '$InstallDir\logs\boot-*.log' -Tail 30 | sort LastWriteTime
  curl http://localhost:$Port/                      # Open WebUI
  curl http://localhost:$FoundryPort/v1/models      # Foundry

Windows password change:
  After changing the Windows password you MUST re-run this script (-Mode Fix or -Mode Nssm).
  LSA Secret holds the old password - the task/service stops starting with 'Logon failure'.
"@ | Write-Host
