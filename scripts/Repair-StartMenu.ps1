<#
Domech Fabricators - repair a broken Start Menu

Run LOGGED IN AS THE AFFECTED USER. It repairs that account's own settings and
components, so running it elevated as somebody else fixes the wrong profile.

WHY THIS HAPPENS HERE
The folder redirection that broke Explorer pointed shell folders at a share
that does not exist. Repair-UserProfile fixes the four the policy set, but the
Start Menu reads others too - Start Menu, Programs, Startup, AppData - and any
one of those pointing somewhere unreachable stops it opening. Windows logs
nothing useful when this happens; the button simply does not respond.

What it does, least invasive first:
  1. Checks EVERY shell folder, not just the four the policy touched, and
     resets only the ones whose target cannot be reached
  2. Restarts the services the Start Menu depends on
  3. Re-registers the Start Menu components for this user
  4. Rebuilds the tile database, keeping a copy of the old one
  5. Restarts Explorer

Nothing here deletes user data. The tile database is a cache of Start Menu
layout, and is backed up before being rebuilt.
#>

$logPath = Join-Path $env:TEMP "Domech-RepairStartMenu_$(Get-Date -Format yyyyMMdd_HHmmss).log"

function Say {
    param([string]$Message, [string]$Level = "Info")
    $color = switch ($Level) { "Good" {"Green"} "Bad" {"Red"} "Warn" {"Yellow"} default {"Cyan"} }
    Write-Host $Message -ForegroundColor $color
    Add-Content -Path $logPath -Value "$(Get-Date -Format 'HH:mm:ss')  $Message"
}

Say "===== Start Menu repair for $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME ====="
Say "Log: $logPath"
Say ""

# ---- 1. every shell folder, not just the four the policy set ----
Say "1. Checking all shell folder locations"
$userShellKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
$shellKey     = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"

$defaults = [ordered]@{
    "Desktop"                                = "%USERPROFILE%\Desktop"
    "Personal"                               = "%USERPROFILE%\Documents"
    "My Pictures"                            = "%USERPROFILE%\Pictures"
    "My Music"                               = "%USERPROFILE%\Music"
    "My Video"                               = "%USERPROFILE%\Videos"
    "Favorites"                              = "%USERPROFILE%\Favorites"
    "{374DE290-123F-4565-9164-39C4925E467B}" = "%USERPROFILE%\Downloads"
    "AppData"                                = "%USERPROFILE%\AppData\Roaming"
    "Local AppData"                          = "%USERPROFILE%\AppData\Local"
    "Start Menu"                             = "%APPDATA%\Microsoft\Windows\Start Menu"
    "Programs"                               = "%APPDATA%\Microsoft\Windows\Start Menu\Programs"
    "Startup"                                = "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
    "Recent"                                 = "%APPDATA%\Microsoft\Windows\Recent"
    "SendTo"                                 = "%APPDATA%\Microsoft\Windows\SendTo"
    "NetHood"                                = "%APPDATA%\Microsoft\Windows\Network Shortcuts"
    "PrintHood"                              = "%APPDATA%\Microsoft\Windows\Printer Shortcuts"
    "Templates"                              = "%APPDATA%\Microsoft\Windows\Templates"
}

$reset = 0
foreach ($name in $defaults.Keys) {
    $current = (Get-ItemProperty -Path $userShellKey -Name $name -ErrorAction SilentlyContinue).$name
    $expected = $defaults[$name]
    $expandedExpected = [Environment]::ExpandEnvironmentVariables($expected)

    if ($current) {
        $expandedCurrent = [Environment]::ExpandEnvironmentVariables($current)
        if (Test-Path $expandedCurrent -ErrorAction SilentlyContinue) {
            continue   # reachable, leave it alone
        }
        Say "   $name -> $expandedCurrent is UNREACHABLE, resetting" "Warn"
    } else {
        Say "   $name has no value, restoring default" "Warn"
    }

    if (-not (Test-Path $expandedExpected)) {
        New-Item -ItemType Directory -Path $expandedExpected -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Set-ItemProperty -Path $userShellKey -Name $name -Value $expected -Type ExpandString -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $shellKey     -Name $name -Value $expandedExpected -Type String -ErrorAction SilentlyContinue
    $reset++
}
if ($reset -eq 0) { Say "   All shell folders point somewhere reachable." "Good" }
else              { Say "   Reset $reset shell folder(s)." "Good" }

# ---- 2. services ----
Say ""
Say "2. Restarting the services the Start Menu relies on"
foreach ($svc in @("WSearch", "AppXSvc", "StateRepository")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { Say "   $svc not present on this machine (normal on Server)." ; continue }
    try {
        if ($s.Status -ne 'Running') {
            Start-Service -Name $svc -ErrorAction Stop
            Say "   Started $svc (was $($s.Status))." "Good"
        } elseif ($svc -eq "WSearch") {
            Restart-Service -Name $svc -Force -ErrorAction Stop
            Say "   Restarted $svc." "Good"
        } else {
            Say "   $svc already running." "Good"
        }
    } catch {
        Say "   Could not touch $svc : $($_.Exception.Message)" "Warn"
    }
}

# ---- 3. re-register the Start Menu components ----
Say ""
Say "3. Re-registering Start Menu components for this user"
# Server 2019 uses ShellExperienceHost; newer builds add StartMenuExperienceHost.
# Register whichever exist rather than assuming.
$targets = @("Microsoft.Windows.ShellExperienceHost", "Microsoft.Windows.StartMenuExperienceHost")
$registered = 0
foreach ($pkgName in $targets) {
    try {
        $pkgs = Get-AppxPackage -Name $pkgName -ErrorAction Stop
        if (-not $pkgs) { Say "   $pkgName not installed here." ; continue }
        foreach ($pkg in $pkgs) {
            $manifest = Join-Path $pkg.InstallLocation "AppXManifest.xml"
            if (Test-Path $manifest) {
                Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
                Say "   Re-registered $pkgName" "Good"
                $registered++
            }
        }
    } catch {
        Say "   $pkgName : $($_.Exception.Message)" "Warn"
    }
}
if ($registered -eq 0) {
    Say "   Nothing re-registered. On Server the Start Menu components are often absent as packages - that is normal, the shell folder fix above is the part that matters." "Warn"
}

# ---- 4. tile database ----
Say ""
Say "4. Start Menu tile database"
$tileDb = Join-Path $env:LOCALAPPDATA "TileDataLayer\Database"
if (Test-Path $tileDb) {
    $backup = "$tileDb.backup_$(Get-Date -Format yyyyMMdd_HHmmss)"
    try {
        Copy-Item $tileDb $backup -Recurse -Force -ErrorAction Stop
        Remove-Item $tileDb -Recurse -Force -ErrorAction Stop
        Say "   Rebuilt. Old copy kept at $backup" "Good"
        Say "   (This only resets the Start Menu tile layout, not any data.)"
    } catch {
        Say "   Could not rebuild it: $($_.Exception.Message)" "Warn"
    }
} else {
    Say "   Not present on this build - nothing to rebuild." "Good"
}

# ---- 5. explorer ----
Say ""
Say "5. Restarting Explorer"
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
Say "   Done." "Good"

Say ""
Say "===== Finished ====="
Say "Try the Start Menu now. If it still will not open, sign out completely and back in - some of these only take effect at a fresh logon." "Warn"
Say "If it is still broken after that, send me this log: $logPath" "Warn"
