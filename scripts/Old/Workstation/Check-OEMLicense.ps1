#Requires -Version 5.1
<#
.SYNOPSIS
    Domech OEM License Checker
    Matrix IT Solutions | Rev 1 | 2026

.DESCRIPTION
    Checks Windows license status on branded machines:
      - Reads the OEM key embedded in BIOS/UEFI firmware (MSDM/SLIC table)
      - Reads the currently installed product key
      - Reports activation status and license channel (OEM / Retail / Volume)
      - Flags whether the firmware key matches the installed key

    Run per-machine locally, OR across the domain remotely (see bottom).
    Output: DomechScan_LicenseCheck_<timestamp>.txt

.NOTES
    Run as Administrator.
    Branded machines (HP/Dell/Lenovo) should show an OEM firmware key.
    Custom builds (Gigabyte boards) will show no firmware key — that's expected.
#>

[CmdletBinding()]
param(
    [string[]]$ComputerNames = @(),   # empty = check local machine only
    [string]$OutputDir = "C:\Scripts\Logs\LicenseCheck"
)

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$LogFile = Join-Path $OutputDir "DomechScan_LicenseCheck_$Timestamp.txt"

function Write-Log {
    param([string]$Message, [switch]$NoConsole)
    $line = $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    if (-not $NoConsole) { Write-Host $line }
}

function Get-LicenseInfo {
    param([string]$Computer = $env:COMPUTERNAME)

    $result = [ordered]@{
        Computer          = $Computer
        Reachable         = $false
        Make              = "unknown"
        Model             = "unknown"
        Serial            = "unknown"
        IsBranded         = $false
        FirmwareOEMKey    = "none"
        InstalledKeyLast5 = "unknown"
        LicenseChannel    = "unknown"
        ActivationStatus  = "unknown"
        Edition           = "unknown"
        Match             = "n/a"
        Notes             = ""
    }

    try {
        $cs  = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $Computer -ErrorAction Stop
        $bios= Get-CimInstance -ClassName Win32_BIOS -ComputerName $Computer -ErrorAction Stop
        $os  = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $Computer -ErrorAction Stop

        $result.Reachable = $true
        $result.Make   = $cs.Manufacturer
        $result.Model  = $cs.Model
        $result.Serial = $bios.SerialNumber
        $result.Edition= $os.Caption

        # Determine if branded (HP / Dell / Lenovo etc.)
        $brandedMakers = @("HP","Hewlett","Dell","Lenovo","Acer","ASUS","Micro-Star","MSI","Fujitsu","Toshiba","Samsung","LG")
        foreach ($b in $brandedMakers) {
            if ($result.Make -match $b) { $result.IsBranded = $true; break }
        }

        # ── Read OEM key embedded in firmware (MSDM table) ──────────────────
        try {
            $msdm = Get-CimInstance -Query "SELECT * FROM SoftwareLicensingService" -ComputerName $Computer -ErrorAction Stop
            $fwKey = $msdm.OA3xOriginalProductKey
            if ($fwKey) {
                $result.FirmwareOEMKey = "PRESENT (…$($fwKey.Substring([Math]::Max(0,$fwKey.Length-5)))): licensed OEM key in firmware"
            } else {
                $result.FirmwareOEMKey = "NONE (no MSDM key in firmware — normal for custom builds)"
            }
        } catch {
            $result.FirmwareOEMKey = "could not read"
        }

        # ── Read installed product key + license channel ────────────────────
        try {
            $lic = Get-CimInstance -Query "SELECT * FROM SoftwareLicensingProduct WHERE PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" -ComputerName $Computer -ErrorAction Stop | Select-Object -First 1
            if ($lic) {
                $result.InstalledKeyLast5 = $lic.PartialProductKey
                $result.LicenseChannel    = $lic.ProductKeyChannel   # OEM / Retail / Volume / MAK
                switch ($lic.LicenseStatus) {
                    0 { $result.ActivationStatus = "Unlicensed" }
                    1 { $result.ActivationStatus = "LICENSED (activated)" }
                    2 { $result.ActivationStatus = "OOB Grace" }
                    3 { $result.ActivationStatus = "OOT Grace" }
                    4 { $result.ActivationStatus = "Non-Genuine Grace" }
                    5 { $result.ActivationStatus = "Notification (NOT ACTIVATED)" }
                    6 { $result.ActivationStatus = "Extended Grace" }
                    default { $result.ActivationStatus = "Unknown ($($lic.LicenseStatus))" }
                }
            }
        } catch {
            $result.ActivationStatus = "could not read"
        }

        # ── Assessment ──────────────────────────────────────────────────────
        if ($result.IsBranded) {
            if ($result.FirmwareOEMKey -match "PRESENT") {
                if ($result.LicenseChannel -eq "OEM:DM" -or $result.LicenseChannel -match "OEM") {
                    $result.Match = "GOOD — branded machine with matching OEM firmware license"
                } else {
                    $result.Match = "CHECK — firmware has OEM key but installed license is $($result.LicenseChannel). May be running a different key."
                }
            } else {
                $result.Match = "WARNING — branded machine but NO OEM key in firmware. License may not be genuine or firmware was reflashed."
            }
        } else {
            $result.Match = "CUSTOM BUILD — no firmware key expected. Verify retail/OEM license separately."
        }

    } catch {
        $result.Notes = "Unreachable or access denied: $($_.Exception.Message)"
    }

    return [PSCustomObject]$result
}

# ── MAIN ────────────────────────────────────────────────────────────────────
Write-Log "=============================================================================="
Write-Log "  DOMECH FABRICATORS — WINDOWS OEM LICENSE CHECK"
Write-Log "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "=============================================================================="
Write-Log ""

$targets = if ($ComputerNames.Count -gt 0) { $ComputerNames } else { @($env:COMPUTERNAME) }

$all = @()
foreach ($t in $targets) {
    Write-Host "`nChecking $t ..." -ForegroundColor Cyan
    $info = Get-LicenseInfo -Computer $t
    $all += $info

    Write-Log "------------------------------------------------------------------------------"
    Write-Log "COMPUTER      : $($info.Computer)"
    Write-Log "REACHABLE     : $($info.Reachable)"
    if ($info.Reachable) {
        Write-Log "MAKE / MODEL  : $($info.Make) / $($info.Model)"
        Write-Log "SERIAL        : $($info.Serial)"
        Write-Log "BRANDED       : $($info.IsBranded)"
        Write-Log "EDITION       : $($info.Edition)"
        Write-Log "FIRMWARE KEY  : $($info.FirmwareOEMKey)"
        Write-Log "INSTALLED KEY : ...$($info.InstalledKeyLast5)"
        Write-Log "CHANNEL       : $($info.LicenseChannel)"
        Write-Log "ACTIVATION    : $($info.ActivationStatus)"
        Write-Log "ASSESSMENT    : $($info.Match)"
    } else {
        Write-Log "NOTES         : $($info.Notes)"
    }
    Write-Log ""
}

# ── Summary table ─────────────────────────────────────────────────────────
Write-Log "=============================================================================="
Write-Log "  SUMMARY"
Write-Log "=============================================================================="
$fmt = "{0,-18} {1,-10} {2,-14} {3,-22} {4}"
Write-Log ($fmt -f "Computer","Branded","Channel","Activation","Assessment")
Write-Log ("-" * 110)
foreach ($i in $all) {
    if ($i.Reachable) {
        Write-Log ($fmt -f $i.Computer, $i.IsBranded, $i.LicenseChannel, $i.ActivationStatus, ($i.Match.Substring(0,[Math]::Min(40,$i.Match.Length))))
    } else {
        Write-Log ($fmt -f $i.Computer, "-", "-", "UNREACHABLE", "")
    }
}
Write-Log ""
Write-Log "Full report saved to: $LogFile"

Write-Host "`nDone. Report: $LogFile" -ForegroundColor Green

<#
─────────────────────────────────────────────────────────────────────────────
HOW TO RUN
─────────────────────────────────────────────────────────────────────────────

OPTION 1 — Check the local machine only (run on each PC):
    .\Check-OEMLicense.ps1

OPTION 2 — Check multiple machines remotely from the server
           (requires WinRM enabled on targets and domain admin rights):
    .\Check-OEMLicense.ps1 -ComputerNames "RAHUL-DF","BALAJI-DF","PRIYANKA-DF","AUDITOR-DF","NISHA-DF","SURESH-SIR","JOSEPH-LT","PRAKASH-DF"

OPTION 3 — Check every domain-joined computer automatically:
    Import-Module ActiveDirectory
    $pcs = (Get-ADComputer -Filter *).Name
    .\Check-OEMLicense.ps1 -ComputerNames $pcs

─────────────────────────────────────────────────────────────────────────────
READING THE RESULTS
─────────────────────────────────────────────────────────────────────────────

For BRANDED machines (HP/Dell/Lenovo), you want to see:
    FIRMWARE KEY : PRESENT
    CHANNEL      : OEM:DM  (or OEM)
    ACTIVATION   : LICENSED (activated)
    ASSESSMENT   : GOOD

If a branded machine shows:
    FIRMWARE KEY : NONE          → firmware may have been reflashed, or the
                                    machine is not genuinely branded. Investigate.
    ACTIVATION   : NOT ACTIVATED → needs a valid license before the rebuild
    CHANNEL      : Retail        → running a retail key on branded hardware;
                                    the embedded OEM key is unused (not a problem,
                                    but note it — the OEM key is the safer one to use)

For CUSTOM builds (Gigabyte — GOKUL, SUPRIYA, MANSI, SNEHA):
    FIRMWARE KEY : NONE          → expected, custom boards have no embedded key
    CHANNEL      : Retail/OEM    → verify you have the purchase record for these
#>
