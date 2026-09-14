<#
Domech Fabricators - repair a Windows profile broken by folder redirection

Run this LOGGED IN AS THE AFFECTED USER. It fixes that user's own registry,
so it has to run inside their session - running it elevated as somebody else
repairs the wrong account.

WHY THIS IS NEEDED
The drive-mapping GPO redirects Desktop/Documents/Downloads/Pictures to
\\SERVER\<username>$\... by writing them into
HKCU\...\Explorer\User Shell Folders. That is a plain registry key, not a
policy key - Windows "tattoos" those values permanently into the profile.
They do NOT revert on their own when the GPO stops applying to the account.

For any account with no personal share on the server (Administrator and
other admin accounts), those paths point at nothing that exists. One broken
value there is enough to break Explorer, the Settings app, old Control Panel
applets, Open/Save dialogs, installers and browser downloads simultaneously.

SAFE TO RUN AS ANYONE: a value is only reset if its current target is
actually unreachable. Normal staff accounts point at a share that works, so
theirs are reported and left alone.

Use -Force to reset all four to local folders no matter what they currently
point at - for an admin account that should never be redirected anywhere.
#>

param([switch]$Force)

$folders = [ordered]@{
    "Desktop"                                = "Desktop"
    "Personal"                               = "Documents"     # registry name for Documents
    "{374DE290-123F-4565-9164-39C4925E467B}" = "Downloads"
    "My Pictures"                            = "Pictures"
}

$userShellKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
$shellKey     = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
$logPath      = Join-Path $env:TEMP "Domech-RepairUserProfile_$(Get-Date -Format yyyyMMdd_HHmmss).log"

function Write-Line {
    param([string]$Message, [string]$Level = "Info")
    $color = switch ($Level) { "Success" {"Green"} "Warning" {"Yellow"} "Error" {"Red"} default {"Cyan"} }
    Write-Host $Message -ForegroundColor $color
    Add-Content -Path $logPath -Value "$(Get-Date -Format 'HH:mm:ss')  [$Level]  $Message"
}

Write-Line "Repairing profile for: $env:USERDOMAIN\$env:USERNAME" -Level Info
Write-Line "Log: $logPath" -Level Info
Write-Line ""

# ---- 1. Shell folders ----
$fixed = 0
foreach ($name in $folders.Keys) {
    $leaf         = $folders[$name]
    $localDefault = Join-Path $env:USERPROFILE $leaf
    $current      = (Get-ItemProperty -Path $userShellKey -Name $name -ErrorAction SilentlyContinue).$name

    if (-not $current) {
        Write-Line "$leaf : no value set - restoring local default." -Level Warning
    }
    elseif ($Force) {
        Write-Line "$leaf : currently -> $([Environment]::ExpandEnvironmentVariables($current)) - forcing back to local." -Level Warning
    }
    else {
        $expanded = [Environment]::ExpandEnvironmentVariables($current)
        Write-Line "$leaf : currently -> $expanded" -Level Info
        # Reachability check. A UNC pointing at a share that doesn't exist fails
        # fast; a genuinely redirected staff folder resolves and is left alone.
        if (Test-Path $expanded -ErrorAction SilentlyContinue) {
            Write-Line "$leaf : target is reachable - leaving it alone." -Level Success
            continue
        }
        Write-Line "$leaf : target is UNREACHABLE - this is what breaks Explorer/Settings. Resetting to local." -Level Warning
    }

    if (-not (Test-Path $localDefault)) { New-Item -ItemType Directory -Path $localDefault -Force | Out-Null }
    New-Item -Path $userShellKey -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -Path $shellKey     -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $userShellKey -Name $name -Value "%USERPROFILE%\$leaf" -Type ExpandString
    Set-ItemProperty -Path $shellKey     -Name $name -Value $localDefault         -Type String

    # Read back rather than trusting the write - this is the value that decides
    # whether Explorer works, so it is worth proving it landed.
    $after = (Get-ItemProperty -Path $userShellKey -Name $name -ErrorAction SilentlyContinue).$name
    if ($after -eq "%USERPROFILE%\$leaf") {
        Write-Line "$leaf : reset to $localDefault" -Level Success
        $fixed++
    } else {
        Write-Line "$leaf : WRITE FAILED - still reads '$after'. Tell your admin; this needs fixing by hand in regedit at $userShellKey" -Level Error
    }
}

# ---- 2. C: drive restriction ----
# NoDrives / NoViewOnDrive hide and block C: in Explorer AND in every
# Open/Save dialog - that's the empty file-browser dialogs and the installers
# that can't write where they need to. This restriction has been dropped
# entirely, so clear it for whoever runs this, admin or not.
$policyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
foreach ($value in @("NoDrives", "NoViewOnDrive")) {
    if ($null -ne (Get-ItemProperty -Path $policyKey -Name $value -ErrorAction SilentlyContinue).$value) {
        Remove-ItemProperty -Path $policyKey -Name $value -Force -ErrorAction SilentlyContinue
        Write-Line "Cleared '$value' - C: was hidden or blocked for this account." -Level Success
        $fixed++
    }
}

# ---- 3. Restart Explorer so the changes take effect now ----
if ($fixed -gt 0) {
    Write-Line ""
    Write-Line "Restarting Explorer to apply $fixed fix(es)..." -Level Info
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Write-Line ""
    Write-Line "DONE - $fixed item(s) repaired." -Level Success
    Write-Line "Log off and log back on once to make it stick." -Level Warning
    Write-Line "IMPORTANT: if the server-side fix hasn't run yet, the GPO will just" -Level Warning
    Write-Line "re-break this at next logon. Run 'Fix THIS SERVER' on the DC first." -Level Warning
} else {
    Write-Line ""
    Write-Line "Nothing needed repairing on this profile." -Level Success
}
