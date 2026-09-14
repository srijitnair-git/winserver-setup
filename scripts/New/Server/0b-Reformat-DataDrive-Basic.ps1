<#
Domech Fabricators - fully wipe Disk 1 and rebuild it as a plain Basic disk
with a single GPT partition, instead of the current Dynamic Disk (Intel RST
RAID-1) setup that Get-Partition/Get-Disk can't see reliably.

The RAID-1 mirroring itself is done by the Intel RST firmware BELOW Windows
- this script only changes how WINDOWS sees the resulting single disk
(Dynamic -> Basic). Redundancy is untouched either way.

IRREVERSIBLE - this is a full diskpart CLEAN, not just deleting partitions.
Everything currently on D: is gone once this runs. Confirm your 4TB backup
covers whatever's on D: right now before running this - the toolkit's own
company-data shares (D:\Domech) haven't been populated from that backup
yet at this point in the build, so what's on D: today is still the old
data, already verified-restorable from the 4TB backup per earlier steps.

Requires explicitly typing CONFIRM at the prompt - no -Force flag to skip it.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

# Find the disk by size rather than assuming "Disk 1" - Get-Disk can't see
# this disk type reliably either, so we parse diskpart's own listing.
$listOutput = "list disk" | diskpart
$diskLine = $listOutput | Where-Object { $_ -match "Disk\s+(\d+)\s+Online\s+(\d+)\s*(GB|TB)" }
Write-DomechLog "diskpart list disk output:" -Level Info
Write-DomechLog ($listOutput | Out-String) -Level Info

$candidateDisks = foreach ($line in $diskLine) {
    if ($line -match "Disk\s+(\d+)\s+Online\s+(\d+)\s*(GB|TB)") {
        $sizeGB = if ($Matches[3] -eq 'TB') { [int]$Matches[2] * 1024 } else { [int]$Matches[2] }
        if ($sizeGB -gt 1000) {   # the RAID array is ~1863GB; the OS SSD is ~477GB
            [PSCustomObject]@{ DiskNumber = [int]$Matches[1]; SizeGB = $sizeGB }
        }
    }
}

if (-not $candidateDisks -or $candidateDisks.Count -ne 1) {
    Write-DomechLog "Could not uniquely identify the RAID data disk from diskpart's listing (found $($candidateDisks.Count) candidate(s) over 1000GB). Check the log above and edit this script's DiskNumber manually rather than guess." -Level Error
    exit 1
}
$diskNumber = $candidateDisks[0].DiskNumber
Write-DomechLog "Target: Disk $diskNumber ($($candidateDisks[0].SizeGB) GB) - this will be COMPLETELY WIPED." -Level Warning

Write-DomechLog "Confirm: has the 4TB backup of the old server data been verified (test restore passed)? This script assumes yes, per earlier steps in this build." -Level Warning
$answer = Read-Host "Type CONFIRM to wipe and rebuild Disk $diskNumber as Basic/GPT, anything else to abort"
if ($answer -ne "CONFIRM") {
    Write-DomechLog "Aborted by operator - typed '$answer', not CONFIRM." -Level Error
    exit 1
}

$diskpartScript = @"
select disk $diskNumber
clean
convert gpt
create partition primary
format fs=ntfs quick label="Data"
assign letter=D
"@

$scriptPath = Join-Path $env:TEMP "domech-reformat-disk$diskNumber.txt"
$diskpartScript | Out-File $scriptPath -Encoding ASCII

Write-DomechLog "Running diskpart..." -Level Info
$result = diskpart /s $scriptPath 2>&1
Write-DomechLog ($result | Out-String) -Level Info
Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 3
$dVolume = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
if ($dVolume) {
    Write-DomechLog "D: rebuilt successfully: $([math]::Round($dVolume.Size/1GB,1)) GB, Basic/GPT." -Level Success
    Write-DomechLog "Next: re-run 0-Prepare-DataDrive.ps1 to set up Shadow Copies on the fresh D: (the partition-deletion part will just skip, since there's nothing else on this disk now)." -Level Info
    Write-DomechLog "Also: nothing is on D: yet - restore what you need from the verified 4TB backup before proceeding to AD promotion if any of it is needed there." -Level Warning
} else {
    Write-DomechLog "D: did not come up after the diskpart run - check the output above for errors." -Level Error
    exit 1
}
