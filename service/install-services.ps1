<#
    EagleCraft — install as Windows services (survives reboots)

    Installs two services:
      eaglecraft   the web panel, which supervises Paper 1.20.4 + the
                   BungeeCord/EaglerXServer proxy
      cloudflared  the tunnel that publishes them

    MUST be run from an ELEVATED PowerShell. Installing a service talks to the
    Service Control Manager, which denies non-administrators — that is the
    "Cannot establish a connection to the service control manager: Access is
    denied" error, and it is the only reason it fails.

        Right-click PowerShell -> Run as Administrator, then:
        cd "C:\ai shit\eaglecraft-src"
        .\service\install-services.ps1

    Uninstall:
        .\service\install-services.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [int]$Port = 8081,
    [int]$SmpPort = 25577,
    [int]$RamMb = 8192,
    [int]$ProxyRamMb = 512,
    [string]$CloudflaredConfig = (Join-Path $env:USERPROFILE '.cloudflared\config.yml')
)

$ErrorActionPreference = 'Stop'

function Say  ($m) { Write-Host "==> $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  !! $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "  !! $m" -ForegroundColor Red; exit 1 }

function Run([string]$Exe, [string[]]$ArgList) {
    # Windows PowerShell 5.1 turns redirected native stderr into TERMINATING
    # errors under ErrorActionPreference=Stop, and lets unpiped native output
    # bypass Start-Transcript. WinSW and cloudflared both log to stderr, so
    # route everything through Write-Host and hand back only the exit code.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @ArgList 2>&1 | ForEach-Object { Write-Host "    $_" }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Wait-Until([scriptblock]$Test, [int]$Seconds, [string]$What) {
    for ($i = 0; $i -le $Seconds; $i += 2) {
        if (& $Test) { Write-Host "  ok: $What (${i}s)"; return $true }
        Start-Sleep -Seconds 2
    }
    Warn "${What}: not within ${Seconds}s"
    return $false
}

function Test-Listening([int]$p) {
    [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)
}

# --- elevation ------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Die @"
This script must run as Administrator.

  Close this window, right-click PowerShell -> 'Run as Administrator',
  then re-run:

      cd "$(Split-Path -Parent $PSScriptRoot)"
      .\service\install-services.ps1
"@
}

$Repo    = Split-Path -Parent $PSScriptRoot
$Runtime = Join-Path $Repo 'runtime'
$WinSW   = Join-Path $Runtime 'eaglecraft-service.exe'
$SvcXml  = Join-Path $Runtime 'eaglecraft-service.xml'
$CfExe   = Join-Path $Runtime 'cloudflared.exe'
$CfLog   = Join-Path $Repo 'logs\cloudflared-service.log'

Say "Repository: $Repo"

# --- uninstall path -------------------------------------------------------
if ($Uninstall) {
    Say 'Removing services'
    if (Get-Service -Name 'eaglecraft' -ErrorAction SilentlyContinue) {
        # WinSW's stop runs server.py --shutdown, so the world is saved.
        Run $WinSW @('stop') | Out-Null
        Run $WinSW @('uninstall') | Out-Null
        Write-Host '  eaglecraft removed'
    }
    if (Get-Service -Name 'cloudflared' -ErrorAction SilentlyContinue) {
        Stop-Service -Name 'cloudflared' -Force -ErrorAction SilentlyContinue
        Run $CfExe @('service', 'uninstall') | Out-Null
        Write-Host '  cloudflared removed'
    }
    Say 'Done.'
    exit 0
}

# --- locate a REAL python -------------------------------------------------
# Not "python3": in Git Bash that resolves to a Microsoft Store app-execution
# alias under %LOCALAPPDATA%\Microsoft\WindowsApps, which is a per-user
# reparse point that a LocalSystem service cannot follow.
Say 'Locating a real Python interpreter'
$candidates = @()
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $candidates += @(& py -0p 2>$null |
        ForEach-Object { ($_ -replace '^\s*-V:\S+\s*\*?\s*', '').Trim() })
} catch { } finally { $ErrorActionPreference = $prev }
$candidates += @(
    'C:\Python314\python.exe', 'C:\Python313\python.exe',
    'C:\Python312\python.exe', 'C:\Python311\python.exe',
    "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
)
$Python = $null
foreach ($c in $candidates) {
    if ([string]::IsNullOrWhiteSpace($c)) { continue }
    if ($c -like '*WindowsApps*') { continue }   # Store alias: unusable as a service
    if (Test-Path $c) { $Python = $c; break }
}
if (-not $Python) {
    Die 'No usable python.exe found. Install Python from python.org (not the Microsoft Store).'
}
Write-Host "  $Python"

# --- WinSW ----------------------------------------------------------------
if (-not (Test-Path $WinSW)) {
    Say 'Downloading WinSW service wrapper'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing `
        -Uri 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe' `
        -OutFile $WinSW
}
Write-Host "  wrapper: $WinSW"

# --- stop anything already running from a terminal ------------------------
Say 'Stopping any panel started from a terminal (saves the world first)'
Push-Location $Repo
try { Run $Python @('server.py', '--shutdown') | Out-Null } finally { Pop-Location }

# Anything still holding our ports is a leftover from an old hard kill. Our
# own Java children (command line points into runtime\) are safe to clear;
# anything else is a genuine conflict the operator must resolve.
foreach ($p in @($Port, 25565, $SmpPort)) {
    $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $conn) { continue }
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($conn.OwningProcess)"
    if (-not $proc) { continue }
    if ($proc.CommandLine -and $proc.CommandLine -like "*$Runtime*") {
        Warn "port $p held by leftover $($proc.Name) pid $($proc.ProcessId) - stopping it"
        Stop-Process -Id $proc.ProcessId -Force
        Start-Sleep -Seconds 2
    } else {
        Die "port $p is in use by $($proc.Name) (pid $($proc.ProcessId)). Free it, or re-run with -Port."
    }
}

# --- generate the service definition --------------------------------------
Say 'Writing service definition'
$xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by service\install-services.ps1. Edit that, not this. -->
<service>
  <id>eaglecraft</id>
  <name>EagleCraft SMP</name>
  <description>EagleCraft vanilla SMP: web panel supervising Paper 1.20.4 and the BungeeCord/EaglerXServer proxy.</description>

  <executable>$Python</executable>
  <arguments>server.py</arguments>
  <workingdirectory>$Repo</workingdirectory>

  <env name="PORT" value="$Port" />
  <env name="SMP_PORT" value="$SmpPort" />
  <env name="SMP_RAM_MB" value="$RamMb" />
  <env name="SMP_PROXY_RAM_MB" value="$ProxyRamMb" />
  <env name="AUTOSTART_SMP" value="1" />
  <env name="PYTHONUNBUFFERED" value="1" />

  <!-- Never hard-kill the panel: that kills Paper with no save, rolling the
       world back to the last autosave and risking region corruption.
       The stop action runs server.py with its shutdown flag, which stops the
       proxy, flushes the world, then stops Paper, and blocks until done
       (about 65s measured). No double hyphens in XML comments. -->
  <stopexecutable>$Python</stopexecutable>
  <stoparguments>server.py --shutdown</stoparguments>
  <stoptimeout>150 sec</stoptimeout>
  <stopparentprocessfirst>false</stopparentprocessfirst>

  <startmode>Automatic</startmode>
  <delayedAutoStart>true</delayedAutoStart>
  <onfailure action="restart" delay="30 sec" />
  <resetfailure>1 hour</resetfailure>

  <logpath>$Repo\logs</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>5</keepFiles>
  </log>
</service>
"@
# Validate before WinSW sees it: a malformed definition makes WinSW die
# with a .NET stack trace, after we have already stopped the running panel.
try { [xml]$xml | Out-Null } catch { Die "generated service XML is invalid: $($_.Exception.Message)" }
[IO.File]::WriteAllText($SvcXml, $xml)
Write-Host "  $SvcXml"

# --- install + start the panel service ------------------------------------
Say 'Installing service: eaglecraft'
if (Get-Service -Name 'eaglecraft' -ErrorAction SilentlyContinue) {
    Warn 'already installed - reinstalling to pick up config changes'
    Run $WinSW @('stop') | Out-Null
    Run $WinSW @('uninstall') | Out-Null
    Start-Sleep -Seconds 3
}
if ((Run $WinSW @('install')) -ne 0) { Die 'WinSW install failed' }
if ((Run $WinSW @('start')) -ne 0) { Die 'WinSW start failed - see logs\eaglecraft.wrapper.log' }

Say 'Waiting for the stack to come up'
Wait-Until { try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "http://127.0.0.1:$Port/").StatusCode -eq 200 } catch { $false } } 60 "panel answering on :$Port" | Out-Null
Wait-Until { Test-Listening 25565 } 180 'Paper listening on 127.0.0.1:25565' | Out-Null
Wait-Until { Test-Listening $SmpPort } 180 "proxy listening on :$SmpPort" | Out-Null

# --- install + configure cloudflared --------------------------------------
if (-not (Test-Path $CfExe)) {
    Warn 'cloudflared.exe not in runtime\ - run cloudflare.sh first'
} elseif (-not (Test-Path $CloudflaredConfig)) {
    Warn "no $CloudflaredConfig - run 'bash cloudflare.sh named <game-host> <web-host>' first"
} else {
    Say 'Preparing tunnel config for a LocalSystem service'
    $cfDir = Split-Path -Parent $CloudflaredConfig
    $cred  = Get-ChildItem -Path $cfDir -Filter '*.json' | Select-Object -First 1
    if (-not $cred) { Die "no tunnel credentials json in $cfDir" }
    $tunnelId = [IO.Path]::GetFileNameWithoutExtension($cred.Name)
    $cert = Join-Path $cfDir 'cert.pem'

    # A LocalSystem service has its OWN profile, so it cannot find cert.pem
    # in this user's .cloudflared. Running the tunnel by NAME needs that cert
    # to look the name up; running by UUID with a credentials file does not.
    $cfg = [IO.File]::ReadAllText($CloudflaredConfig)
    $cfg = [regex]::Replace($cfg, '(?m)^tunnel:.*$', "tunnel: $tunnelId")
    if (($cfg -notmatch '(?m)^origincert:') -and (Test-Path $cert)) {
        $cfg = [regex]::Replace($cfg, '(?m)^(tunnel:.*)$', "`$1`norigincert: $($cert -replace '\\', '/')")
    }
    [IO.File]::WriteAllText($CloudflaredConfig, $cfg)
    Write-Host "  tunnel pinned to UUID $tunnelId"

    if ((Run $CfExe @('--config', $CloudflaredConfig, 'tunnel', 'ingress', 'validate')) -ne 0) {
        Die 'ingress config failed validation'
    }

    $svc = Get-Service -Name 'cloudflared' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Say 'Installing service: cloudflared'
        Run $CfExe @('service', 'install') | Out-Null
        Start-Sleep -Seconds 3
        $svc = Get-Service -Name 'cloudflared' -ErrorAction SilentlyContinue
    } else {
        Warn 'cloudflared service already exists - reconfiguring it'
    }
    if (-not $svc) { Die 'cloudflared service did not register' }

    # `service install` without a token registers a bare cloudflared.exe with
    # no subcommand, which starts and does nothing. Point it at our config
    # and tell it to actually run the tunnel.
    Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
    $img = '"{0}" --config "{1}" tunnel --no-autoupdate --logfile "{2}" run' -f $CfExe, $CloudflaredConfig, $CfLog
    Set-ItemProperty -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $svc.Name) -Name ImagePath -Value $img
    Set-Service -Name $svc.Name -StartupType Automatic
    Remove-Item $CfLog -ErrorAction SilentlyContinue
    Start-Service -Name $svc.Name
    Wait-Until {
        (Test-Path $CfLog) -and (Select-String -Path $CfLog -Pattern 'Registered tunnel connection' -Quiet)
    } 60 'tunnel connected to the Cloudflare edge' | Out-Null
}

# --- report ---------------------------------------------------------------
Say 'Status'
Get-Service -Name 'eaglecraft', 'cloudflared' -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String | Write-Host

Write-Host '  The SMP now starts automatically at boot.' -ForegroundColor Green
Write-Host "  Panel:    http://localhost:$Port"
Write-Host "  Logs:     $Repo\logs\eaglecraft.out.log, $CfLog"
Write-Host '  Control:  Restart-Service eaglecraft   (Administrator)'
Write-Host '  Remove:   .\service\install-services.ps1 -Uninstall'
Write-Host ''
Write-Host '  Do NOT also run start.sh while the service is running -' -ForegroundColor Yellow
Write-Host '  both would fight over ports 8081 / 25565 / 25577.' -ForegroundColor Yellow
exit 0
