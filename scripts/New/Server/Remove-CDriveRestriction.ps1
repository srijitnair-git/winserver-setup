<#
Domech Fabricators - undo the C: drive restriction everywhere

Run on the DC, elevated. Removes the "hide and block C:" policy completely:
unlinks it from the domain, then deletes the GPO itself.

The policy hid C: and blocked it in Explorer AND in every Open/Save dialog,
which is what made file dialogs look empty and stopped installers writing
where they needed to. It was meant for staff only, but an admin account
receiving it gets the same symptoms.

The GPO is fully reproducible - Restrict-CDriveAccess.ps1 recreates it from
scratch if this is ever wanted again, so deleting it loses nothing.

Each affected user also needs the leftover value cleared from their own
profile: have them run Repair-UserProfile.ps1 (or the "Repair my profile"
option in fix.ps1), or just sign out and back in once this has run.
#>

Import-Module GroupPolicy
Import-Module ActiveDirectory

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

$GpoName  = $Config.GPO.RestrictCDriveGpoName
$domainDN = (Get-ADDomain).DistinguishedName

$gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $gpo) {
    Write-DomechLog "GPO '$GpoName' doesn't exist - the C: restriction was never applied, or has already been removed. Nothing to do." -Level Success
} else {
    # Unlink first: that alone stops it applying, so if the delete fails for
    # any reason the restriction is still lifted.
    try {
        Remove-GPLink -Name $GpoName -Target $domainDN -ErrorAction Stop | Out-Null
        Write-DomechLog "Unlinked '$GpoName' from the domain - it no longer applies to anyone." -Level Success
    } catch {
        Write-DomechLog "Could not unlink '$GpoName' (it may already be unlinked): $($_.Exception.Message)" -Level Warning
    }

    try {
        Remove-GPO -Name $GpoName -ErrorAction Stop
        Write-DomechLog "Deleted the '$GpoName' GPO." -Level Success
    } catch {
        Write-DomechLog "Unlinked but could not delete '$GpoName': $($_.Exception.Message). It no longer applies, so this is not urgent - delete it by hand in GPMC when convenient." -Level Warning
    }
}

# Clear it from the account running this right now, so the admin session sees
# C: come back without waiting for a logoff.
$policyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
$cleared = 0
foreach ($value in @("NoDrives", "NoViewOnDrive")) {
    if ($null -ne (Get-ItemProperty -Path $policyKey -Name $value -ErrorAction SilentlyContinue).$value) {
        Remove-ItemProperty -Path $policyKey -Name $value -Force -ErrorAction SilentlyContinue
        $cleared++
    }
}
if ($cleared -gt 0) {
    Write-DomechLog "Cleared $cleared leftover restriction value(s) from this account's profile." -Level Success
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}

gpupdate /force | Out-String | Write-DomechLog -Level Info

Write-DomechLog "" -Level Info
Write-DomechLog "Done. C: is no longer hidden or blocked for anyone." -Level Success
Write-DomechLog "Anyone already signed in keeps the old setting until they sign out and back in once." -Level Warning
