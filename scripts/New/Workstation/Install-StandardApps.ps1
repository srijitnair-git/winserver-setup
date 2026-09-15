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

# ---- install anything missing, update anything outdated ----
$common = @("--silent", "--accept-package-agreements", "--accept-source-agreements", "--scope", "machine")

foreach ($id in $AppIds) {
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
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
        Write-Log "$id : $tail"
    } catch {
        Write-Log "$id : FAILED - $($_.Exception.Message)"
    }
}

Set-Content -Path $stampPath -Value (Get-Date).ToString("o")
Write-Log "--- App install/update finished ---"
