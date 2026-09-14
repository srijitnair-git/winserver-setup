<#
Domech Fabricators - apply wallpaper and lock screen on this workstation

Runs as a COMPUTER startup script via GPO, in SYSTEM context, so it covers
every user who signs into the machine including ones who have never logged
in before.

Uses PersonalizationCSP rather than the "Desktop Wallpaper" / "Force a
specific default lock screen image" Group Policy settings, because:

  - the lock screen policy only takes effect on Enterprise and Education.
    These workstations are OEM Pro, where it is silently ignored.
  - PersonalizationCSP is machine-wide, so one setting covers all users
    instead of a per-user policy that has to reach each profile.
  - it needs a LOCAL image path. A UNC path is not reliably readable at boot
    or at the lock screen, since that runs before a user session exists - so
    the images are copied down from NETLOGON first.

The NETLOGON source path is passed in by the deploy script, since this runs
before any user context exists and cannot read config.json.
#>

param(
    [string]$SourceUnc = "__NETLOGON_PLACEHOLDER__"
)

$localDir = "C:\ProgramData\Domech"
$logPath  = Join-Path $localDir "Branding.log"
New-Item -ItemType Directory -Path $localDir -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Out-File $logPath -Append -Encoding UTF8
}

Write-Log "--- Apply-Branding starting on $env:COMPUTERNAME ---"

$images = @{
    "Wallpaper.png"  = "DesktopImage"
    "LockScreen.png" = "LockScreenImage"
}

$cspKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
New-Item -Path $cspKey -Force -ErrorAction SilentlyContinue | Out-Null

foreach ($file in $images.Keys) {
    $source = Join-Path $SourceUnc $file
    $dest   = Join-Path $localDir $file
    $prefix = $images[$file]

    if (-not (Test-Path $source)) {
        Write-Log "SKIP $file - not found at $source"
        continue
    }

    # Copy only when it actually changed, so a startup script on every boot
    # isn't needlessly pulling images across the network.
    $needCopy = $true
    if (Test-Path $dest) {
        $srcTime = (Get-Item $source).LastWriteTimeUtc
        $dstTime = (Get-Item $dest).LastWriteTimeUtc
        if ($srcTime -le $dstTime) { $needCopy = $false }
    }
    if ($needCopy) {
        try {
            Copy-Item $source $dest -Force -ErrorAction Stop
            Write-Log "Copied $file to $dest"
        } catch {
            Write-Log "FAILED to copy $file : $($_.Exception.Message)"
            continue
        }
    }

    try {
        Set-ItemProperty -Path $cspKey -Name "${prefix}Status" -Value 1 -Type DWord
        Set-ItemProperty -Path $cspKey -Name "${prefix}Path"   -Value $dest -Type String
        Set-ItemProperty -Path $cspKey -Name "${prefix}Url"    -Value $dest -Type String
        Write-Log "Set $prefix to $dest"
    } catch {
        Write-Log "FAILED to set $prefix : $($_.Exception.Message)"
    }
}

Write-Log "--- Apply-Branding finished ---"
