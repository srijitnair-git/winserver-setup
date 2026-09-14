<#
Domech Fabricators - RustDesk unattended access deployment
Installs RustDesk as a background service on each workstation with a
permanent password so admin can connect anytime without anyone at the
keyboard approving it.

READ BEFORE RUNNING:
- $PermanentPassword must be set to a strong password known ONLY to IT.
  Do not leave it hardcoded in this file after first run - move it to a
  password manager and blank it here, or pass it as a parameter instead.
- Strongly recommended: self-host RustDesk's hbbs/hbbr server (Docker,
  same TrueNAS box as the WiFi portal / control room) instead of using
  RustDesk's public relay servers, so remote-access traffic never leaves
  your own network. Set $RendezvousServer once that's built; leave blank
  to use RustDesk's public servers (works, but not recommended long-term).
- This only prevents a NON-admin user from tampering with it. It relies on
  2.5 Set-LocalAdministrators.ps1 already having removed local admin
  rights from regular users - otherwise they can still stop the service
  or reinstall over it.
#>

param(
    [string[]]$ComputerName,

    [Parameter(Mandatory=$true)]
    [string]$PermanentPassword,

    [string]$RendezvousServer   # e.g. "192.168.0.11:21116" once self-hosted - blank = RustDesk public servers
)

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot
if (-not $ComputerName) { $ComputerName = $Config.Workstations }
if (-not $PSBoundParameters.ContainsKey('RendezvousServer')) { $RendezvousServer = $Config.RustDesk.RendezvousServer }

$deployScript = {
    param($plainPwd, $server)

    $wingetPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    if (-not (Test-Path $wingetPath)) {
        Write-Output "$env:COMPUTERNAME : winget not found - install App Installer first."
        return
    }

    Write-Output "$env:COMPUTERNAME : installing RustDesk..."
    & $wingetPath install --id RustDesk.RustDesk --silent --accept-package-agreements --accept-source-agreements --scope machine -h

    $rdExe = "C:\Program Files\RustDesk\rustdesk.exe"
    if (-not (Test-Path $rdExe)) {
        Write-Output "$env:COMPUTERNAME : RustDesk.exe not found after install - check winget output above."
        return
    }

    Write-Output "$env:COMPUTERNAME : installing as background service..."
    Start-Process $rdExe -ArgumentList "--silent-install" -Wait

    Start-Sleep -Seconds 3   # let the service finish registering before configuring it

    Write-Output "$env:COMPUTERNAME : setting permanent password..."
    Start-Process $rdExe -ArgumentList "--password `"$plainPwd`"" -Wait

    if ($server) {
        Write-Output "$env:COMPUTERNAME : pointing at self-hosted server $server..."
        Start-Process $rdExe -ArgumentList "--set-id-server `"$server`"" -Wait -ErrorAction SilentlyContinue
        Start-Process $rdExe -ArgumentList "--set-relay-server `"$server`"" -Wait -ErrorAction SilentlyContinue
    }

    $id = & $rdExe --get-id
    Write-Output "$env:COMPUTERNAME : RustDesk ID = $id"
}

Write-Host "Deploying RustDesk unattended access to $($ComputerName -join ', ')..." -ForegroundColor Cyan
$results = Invoke-Command -ComputerName $ComputerName -ScriptBlock $deployScript -ArgumentList $PermanentPassword,$RendezvousServer

$results | Out-File "C:\01_matrix\Scratch\RustDeskIDs.txt"
Write-Host "`nDone. RustDesk IDs written to C:\01_matrix\Scratch\RustDeskIDs.txt." -ForegroundColor Green
Write-Host "IMPORTANT - do these two things manually, once, per machine (or via the GUI 'Export Config' / 'Import Config' feature to standardize):" -ForegroundColor Yellow
Write-Host "  1. In RustDesk Settings > Security: set Verification Method to 'Use permanent password only' and disable temporary password." -ForegroundColor Yellow
Write-Host "  2. Confirm the machine still shows Enabled under 'Unattended Access' after this - some versions require the settings step above before permanent-password access actually works without a click-to-approve." -ForegroundColor Yellow
Write-Host "`nStore the permanent password in your password manager now, then clear it from any script/history that has it in plaintext." -ForegroundColor Red
