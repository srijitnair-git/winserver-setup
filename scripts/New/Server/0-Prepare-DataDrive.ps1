<#
Domech Fabricators - reclaim the old RAID disk (Disk 1) as the new server's
D: data drive. Run BEFORE 1-Install-ADForest.ps1, since that script now
expects D: to already exist (NTDS/SYSVOL go there).

What this does, in order:
  1. Finds the disk that currently has a volume with drive letter D:
  2. DELETES every other partition on that disk (old OS, EFI, Recovery)
  3. Extends the D: partition to fill the entire disk
  4. Enables Shadow Copies (VSS) on D: with a scheduled twice-daily snapshot

IRREVERSIBLE. The old Server 2022 OS on this disk is gone once step 2 runs.
Confirmed with the client before this script was written: the 4TB backup
of D:\Domech has already been taken AND verified by test restore, and the
old OS/data on this disk is not needed - only the RAID array's D: data
partition is being kept, everything else on it is reclaimed as free space.

Requires explicitly typing CONFIRM at the prompt - no -Force flag to skip it.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

$dPartition = Get-Partition | Where-Object { $_.DriveLetter -eq 'D' }
if (-not $dPartition) {
    Write-DomechLog "No D: drive found on this machine - nothing to reclaim around. Aborting." -Level Error
    exit 1
}
$diskNumber = $dPartition.DiskNumber

Write-DomechLog "D: found on Disk $diskNumber. Partitions on that disk:" -Level Info
$allPartitions = Get-Partition -DiskNumber $diskNumber | Sort-Object PartitionNumber
$allPartitions | Format-Table PartitionNumber, DriveLetter, Type, @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}} | Out-String | Write-DomechLog -Level Info

$toDelete = $allPartitions | Where-Object { $_.PartitionNumber -ne $dPartition.PartitionNumber }
if (-not $toDelete) {
    Write-DomechLog "D: is already the only partition on Disk $diskNumber - nothing to delete. Skipping to extend/shadow-copy steps." -Level Warning
} else {
    Write-DomechLog "About to PERMANENTLY DELETE $($toDelete.Count) partition(s) on Disk $diskNumber (everything except D:)." -Level Warning
    $answer = Read-Host "Type CONFIRM to proceed, anything else to abort"
    if ($answer -ne "CONFIRM") {
        Write-DomechLog "Aborted by operator - typed '$answer', not CONFIRM." -Level Error
        exit 1
    }
    foreach ($p in $toDelete) {
        Write-DomechLog "Deleting partition $($p.PartitionNumber) ($([math]::Round($p.Size/1GB,1)) GB)..." -Level Warning
        Remove-Partition -DiskNumber $diskNumber -PartitionNumber $p.PartitionNumber -Confirm:$false
    }
    Write-DomechLog "Old partitions removed." -Level Success
}

# ---- Extend D: to use the freed space ----
Write-DomechLog "Extending D: to fill Disk $diskNumber..." -Level Info
$maxSize = (Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $dPartition.PartitionNumber).SizeMax
Resize-Partition -DiskNumber $diskNumber -PartitionNumber $dPartition.PartitionNumber -Size $maxSize
$newSize = (Get-Partition -DiskNumber $diskNumber -PartitionNumber $dPartition.PartitionNumber).Size
Write-DomechLog "D: is now $([math]::Round($newSize/1GB,1)) GB." -Level Success

# ---- Enable Shadow Copies on D: ----
# vssadmin's output/exit code is checked explicitly here - a prior version
# of this script piped it to Out-Null and logged success unconditionally,
# which silently let the 10% cap fail to apply (association stayed
# UNBOUNDED) without anyone knowing.
Write-DomechLog "Enabling Shadow Copies on D:..." -Level Info
$maxStoragePercent = $Config.ShadowCopy.MaxStoragePercent

$existing = vssadmin list shadowstorage /for=D: 2>&1
if ($LASTEXITCODE -eq 0 -and $existing -match "Shadow Copy Storage association") {
    Write-DomechLog "Shadow storage association already exists - resizing to ${maxStoragePercent}%." -Level Info
    $result = vssadmin resize shadowstorage /for=D: /on=D: /maxsize=${maxStoragePercent}% 2>&1
} else {
    Write-DomechLog "No shadow storage association yet - creating one at ${maxStoragePercent}%." -Level Info
    $result = vssadmin add shadowstorage /for=D: /on=D: /maxsize=${maxStoragePercent}% 2>&1
}
Write-DomechLog ($result | Out-String) -Level Info
if ($LASTEXITCODE -ne 0) {
    Write-DomechLog "vssadmin reported an error (exit code $LASTEXITCODE) - shadow storage may not be capped correctly. Check the output above." -Level Error
} else {
    Write-DomechLog "Shadow storage configured." -Level Success
}

# Verify the cap actually took, rather than trusting the exit code alone
$verify = vssadmin list shadowstorage /for=D: 2>&1 | Out-String
if ($verify -match "Maximum Shadow Copy Storage space:\s*(.+)") {
    $actualMax = $Matches[1].Trim()
    if ($actualMax -match "UNBOUNDED") {
        Write-DomechLog "Verification failed: maximum is still UNBOUNDED, the ${maxStoragePercent}% cap did not apply. Run 'vssadmin resize shadowstorage /for=D: /on=D: /maxsize=${maxStoragePercent}%' manually and check its error output." -Level Error
    } else {
        Write-DomechLog "Verified cap: $actualMax" -Level Success
    }
}

foreach ($time in $Config.ShadowCopy.Schedule) {
    $taskName = "Domech-ShadowCopy-D-$($time -replace ':','')"
    $triggerTime = [datetime]::ParseExact($time, "HH:mm", $null)
    $action    = New-ScheduledTaskAction -Execute "vssadmin.exe" -Argument "create shadow /for=D:"
    $trigger   = New-ScheduledTaskTrigger -Daily -At $triggerTime
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force -ErrorAction Stop | Out-Null
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Write-DomechLog "  Scheduled shadow copy at $time daily (verified: task exists)." -Level Success
        } else {
            Write-DomechLog "  Register-ScheduledTask for $time did not error but the task isn't showing up - investigate manually." -Level Error
        }
    } catch {
        Write-DomechLog "  Failed to register scheduled task for $time : $($_.Exception.Message)" -Level Error
    }
}

Write-DomechLog "Done. D: is ready. Next: run 1-Install-ADForest.ps1 - it now places NTDS/SYSVOL on D:." -Level Success
