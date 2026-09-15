<#
Domech Fabricators - install and update the standard app set on this workstation

Runs as a COMPUTER startup script via GPO, in SYSTEM context. No WinRM needed,
so it works on machines the server cannot reach remotely.

The app list is injected from config.json's WingetApps by
Deploy-AppInstallGPO.ps1 at deploy time - edit config.json and rerun that
script, never this placeholder.

WHY IT RESOLVES WINGET BY PATH
winget ships as a per-user MSIX app, so the "winget" command does not exist in
SYSTEM context - a startup script calling it directly finds nothing and does
nothing, silently. The real executable is resolved out of WindowsApps below
and invoked by full path, with --scope machine so packages install for every
user rather than into a profile that SYSTEM does not have.

Runs at most once per day. A startup script that reinstalls the whole app set
on every boot would make every restart slow for no benefit.
#>

$AppIds = @(
    "__WINGET_APPS_PLACEHOLDER__"
)

$localDir  = "C:\ProgramData\Domech"
$logPath   = Join-Path $localDir "AppInstall.log"
$stampPath = Join-Path $localDir "AppInstall.lastrun"
New-Item -ItemType Directory -Path $localDir -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Out-File $logPath -Append -Encoding UTF8
}

# ---- must be able to install machine-wide ----
# Run by the startup script or the logon task this is SYSTEM and fine. Run by
# hand in an ordinary PowerShell window it is the logged-in user, who cannot
# install machine-wide software - every install then fails while still looking
# like it tried. Stop up front and say so, rather than filling the log with
# failures that read like winget problems.
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
              ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) {
    Write-Log "NOT RUNNING AS ADMINISTRATOR (running as $env:USERNAME). Machine-wide installs cannot work from a standard user account, so nothing was attempted."
    Write-Log "This is only a problem when run by hand - the startup script and logon task both run as SYSTEM. To run it manually, open PowerShell as Administrator first."
    Write-Host "Not elevated - nothing attempted. Open PowerShell as Administrator and run this again." -ForegroundColor Red
    return
}

# ---- once a day is enough ----
if (Test-Path $stampPath) {
    $last = (Get-Item $stampPath).LastWriteTime
    if ((Get-Date) - $last -lt [TimeSpan]::FromHours(20)) {
        Write-Log "Last run was $last - skipping (runs at most once per day)."
        return
    }
}

Write-Log "--- App install/update starting on $env:COMPUTERNAME ---"

# ---- find winget ----
# Three ways, because none is reliable on its own:
#  1. on PATH - true for an interactive user, never for SYSTEM
#  2. the package's own InstallLocation - the documented way, and the one that
#     works in SYSTEM context
#  3. scanning WindowsApps - last resort. That folder is ACL'd to
#     TrustedInstaller and is not even enumerable by a normal admin, though
#     SYSTEM can usually read it.
$wingetExe = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source

if (-not $wingetExe) {
    try {
        $pkg = Get-AppxPackage -AllUsers -Name "Microsoft.DesktopAppInstaller" -ErrorAction Stop |
            Sort-Object Version -Descending | Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation) {
            $candidate = Join-Path $pkg.InstallLocation "winget.exe"
            if (Test-Path $candidate) { $wingetExe = $candidate }
        }
    } catch {
        Write-Log "Could not query App Installer package: $($_.Exception.Message)"
    }
}

if (-not $wingetExe) {
    $wingetExe = Get-ChildItem "$env:ProgramFiles\WindowsApps" -Filter "winget.exe" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*Microsoft.DesktopAppInstaller*" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

if (-not $wingetExe) {
    Write-Log "winget not found on this machine. It ships with Windows 11; on older builds install 'App Installer' from the Microsoft Store once, then this starts working by itself."
    return
}
Write-Log "Using winget at $wingetExe"

# Office is the one app here that must never be installed over an existing one.
# A machine already carrying OEM or perpetual Office would end up with two
# conflicting suites, or lose the one people actually use. winget's own check
# only recognises Office installed through winget, so it is not enough on its
# own. Install only where there is no Office at all, and say so when skipping
# so it can be dealt with by hand.
function Test-OfficeInstalled {
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration") { return $true }
    foreach ($p in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )) {
        $hit = Get-ItemProperty $p -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'Microsoft (Office|365)' }
        if ($hit) { return $true }
    }
    return $false
}

# ---- install anything missing, update anything outdated ----
$common = @("--silent", "--accept-package-agreements", "--accept-source-agreements", "--scope", "machine")

$failures = 0

foreach ($id in $AppIds) {
    if ([string]::IsNullOrWhiteSpace($id)) { continue }

    if ($id -eq "Microsoft.Office" -and (Test-OfficeInstalled)) {
        Write-Log "$id : Office is already on this machine - skipping, so an existing install is never overwritten. Upgrade it by hand if that is wanted."
        continue
    }
    try {
        $listed = & $wingetExe list --id $id --exact --accept-source-agreements 2>&1 | Out-String
        if ($listed -match [regex]::Escape($id)) {
            Write-Log "$id : present - checking for updates"
            $out = & $wingetExe upgrade --id $id --exact @common 2>&1 | Out-String
        } else {
            Write-Log "$id : not installed - installing"
            $out = & $wingetExe install --id $id --exact @common 2>&1 | Out-String
        }
        # winget returns non-zero for "no applicable upgrade", which is not a failure
        $tail = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        if (-not $tail) { $tail = "(no output - the command produced nothing, treating as a failure)"; $failures++ }
        Write-Log "$id : $tail"
    } catch {
        Write-Log "$id : FAILED - $($_.Exception.Message)"
        $failures++
    }
}

# Only mark the day done if it actually worked. Stamping after a failed run
# blocked every retry for the next 20 hours, which is exactly what happened
# when a non-elevated run failed every install and then silently locked itself
# out - the next legitimate startup run just reported "skipping".
if ($failures -eq 0) {
    Set-Content -Path $stampPath -Value (Get-Date).ToString("o")
    Write-Log "--- App install/update finished cleanly ---"
} else {
    Write-Log "--- App install/update finished with $failures failure(s) - NOT marking today as done, so the next startup or logon retries ---"
}
