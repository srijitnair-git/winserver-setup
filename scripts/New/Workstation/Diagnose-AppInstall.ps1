<#
Domech Fabricators - why haven't the apps installed on this PC?

Run ON the affected workstation. Read-only: it reports, it changes nothing.

Checks, in the order things have to work:
  1. Can this PC see the deployed script on the server
  2. Has the script ever run here (its own log)
  3. Is the logon-triggered task registered
  4. Is winget present and usable
  5. Which of the expected apps are actually installed
  6. Did the App Deployment policy reach this machine
#>

$netlogonScript = "\\DF.local\NETLOGON\Install-StandardApps.ps1"
$localDir = "C:\ProgramData\Domech"
$logPath  = Join-Path $localDir "AppInstall.log"

function Say($msg, $level = "Info") {
    $color = switch ($level) { "Good" {"Green"} "Bad" {"Red"} "Warn" {"Yellow"} default {"Cyan"} }
    Write-Host $msg -ForegroundColor $color
}

Say "===== App deployment check on $env:COMPUTERNAME (as $env:USERNAME) ====="
Say ""

# 1. deployed script reachable
Say "1. Deployed script on the server"
if (Test-Path $netlogonScript) {
    $age = (Get-Item $netlogonScript).LastWriteTime
    Say "   Found, published $age" "Good"
} else {
    Say "   NOT reachable at $netlogonScript" "Bad"
    Say "   Either the server deployment has not been run, or this PC cannot reach NETLOGON." "Bad"
}

# 2. has it ever run here
Say ""
Say "2. Has it ever run on this PC"
if (Test-Path $logPath) {
    Say "   Yes - log exists. Last 12 lines:" "Good"
    Get-Content $logPath -Tail 12 | ForEach-Object { Say "      $_" }
} else {
    Say "   No log at $logPath - the script has never run on this machine." "Warn"
    Say "   Expected if the PC has not restarted since the deployment: the startup run is" "Warn"
    Say "   what registers the logon task, so until one restart happens, signing in does nothing." "Warn"
}

# 3. logon task
Say ""
Say "3. Logon-triggered task"
$task = Get-ScheduledTask -TaskName "Domech-InstallApps-Logon" -ErrorAction SilentlyContinue
if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName "Domech-InstallApps-Logon" -ErrorAction SilentlyContinue
    Say "   Registered. State: $($task.State). Last run: $($info.LastRunTime). Result: $($info.LastTaskResult)" "Good"
} else {
    Say "   Not registered yet - it is created by the first startup run. Restart this PC." "Warn"
}

# 4. winget
Say ""
Say "4. winget"
$winget = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
if (-not $winget) {
    try {
        $pkg = Get-AppxPackage -AllUsers -Name "Microsoft.DesktopAppInstaller" -ErrorAction Stop |
            Sort-Object Version -Descending | Select-Object -First 1
        if ($pkg) { $winget = Join-Path $pkg.InstallLocation "winget.exe" }
    } catch { }
}
if ($winget -and (Test-Path $winget)) {
    Say "   Found at $winget" "Good"
} else {
    Say "   NOT found. Windows 11 ships with it; if missing, install 'App Installer' from the Store once." "Bad"
}

# 5. what is actually installed
Say ""
Say "5. Expected apps"
$expected = @{
    "7-Zip"        = "7-Zip"
    "RustDesk"     = "RustDesk"
    "SumatraPDF"   = "Sumatra"
    "FastStone"    = "FastStone"
    "VLC"          = "VLC"
    "Chrome"       = "Google Chrome"
    "PowerShell 7" = "PowerShell 7"
    "Microsoft 365"= "Microsoft 365"
}
$installed = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                              "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
             Select-Object -ExpandProperty DisplayName -ErrorAction SilentlyContinue
foreach ($label in $expected.Keys | Sort-Object) {
    $match = $installed | Where-Object { $_ -like "*$($expected[$label])*" } | Select-Object -First 1
    if ($match) { Say "   [installed] $label  ($match)" "Good" }
    else        { Say "   [ missing ] $label" "Warn" }
}

# 6. did the policy reach this machine
Say ""
Say "6. Did the App Deployment policy reach this PC"
$gp = gpresult /r /scope:computer 2>&1 | Out-String
if ($gp -match "Domech - App Deployment") {
    Say "   Yes - the policy is applied to this computer." "Good"
} else {
    Say "   Not listed in applied computer policy." "Warn"
    Say "   Run 'gpupdate /force' then restart, and check again." "Warn"
}

Say ""
Say "===== What to do ====="
if (-not (Test-Path $logPath)) {
    Say "Restart this PC. The startup run installs the apps and registers the logon task;" "Warn"
    Say "after that first restart, logins keep it up to date on their own." "Warn"
    Say "To install right now without restarting, from an ELEVATED PowerShell here:" "Info"
    Say "    powershell -ExecutionPolicy Bypass -File $netlogonScript" "Info"
} else {
    Say "The script has run here - see the log lines above for what it did or could not do." "Info"
}
