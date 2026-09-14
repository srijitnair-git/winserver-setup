<#
Domech Fabricators - one-shot server repair
Run on the DC, elevated, as DF\Administrator. This is the only server script
you need - it runs everything in the order that actually works:

  1. Stop the staff GPOs applying to admin accounts (do this FIRST, or step 2
     just gets undone at the next logon)
  2. Repair this admin profile - Explorer / Settings / Control Panel / installers
  3. Archive the old pre-consolidation Salary and Purchase folders
  4. Users, groups, shares, NTFS permissions, drive maps, branding
  5. C: drive restriction for staff (admins excluded)
  6. Ensure Required Services GPO
  7. Refresh policy and report what still needs a manual logoff

Every step is safe to run again. Existing accounts, existing shares and
existing data are never overwritten or deleted.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

Import-Module ActiveDirectory -ErrorAction SilentlyContinue
Import-Module GroupPolicy -ErrorAction SilentlyContinue

if (-not (Get-Module ActiveDirectory)) {
    Write-DomechLog "The ActiveDirectory module isn't available - this script has to run ON the domain controller, elevated. Nothing has been changed." -Level Error
    exit 1
}

$domainDN = (Get-ADDomain).DistinguishedName
$staffGpos = @($Config.GPO.DriveMapGpoName, $Config.GPO.RestrictCDriveGpoName, $Config.GPO.BrandingGpoName)

Write-DomechLog "===== STEP 1/7: Stop staff GPOs applying to admin accounts =====" -Level Info
# Done before anything else: while these GPOs still apply to Domain Admins,
# every logon rewrites the broken Desktop/Documents paths into the admin
# profile, so repairing the profile first would achieve nothing.
foreach ($gpoName in $staffGpos) {
    if (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue) {
        Block-DomainAdminsFromGPO -GpoName $gpoName -DomainDN $domainDN
    } else {
        Write-DomechLog "GPO '$gpoName' doesn't exist yet - it gets created later in this run and excluded then." -Level Info
    }
}

Write-DomechLog "===== STEP 2/7: Repair this admin profile =====" -Level Info
& "$ScriptsRoot\Repair-UserProfile.ps1"

Write-DomechLog "===== STEP 3/7: Archive old Salary / Purchase folders =====" -Level Info
# Live data now lives under D:\Domech\Salary Wages & Purchase\. Anything found
# in the old top-level folders is MOVED aside, never deleted - check the
# archive yourself and remove it once you're satisfied it's junk.
foreach ($p in @("D:\Domech\Salary", "D:\Domech\Purchase")) {
    if (-not (Test-Path $p)) {
        Write-DomechLog "$p doesn't exist - nothing to do." -Level Info
        continue
    }
    $files = Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue
    if ($files) {
        $archive = "D:\Domech\_Archive_$(Split-Path $p -Leaf)_$(Get-Date -Format yyyyMMdd)"
        Write-DomechLog "$p holds $($files.Count) file(s) - moving to $archive rather than deleting. Review it, then delete by hand." -Level Warning
        Move-Item $p $archive
    } else {
        Write-DomechLog "$p is empty - removing." -Level Info
        Remove-Item $p -Recurse -Force
    }
}

Write-DomechLog "===== STEP 4/7: Users, groups, shares, permissions, drive maps =====" -Level Info
& "$PSScriptRoot\Setup-DFLocal-Full.ps1"

Write-DomechLog "===== STEP 5/7: Restrict C: drive for staff =====" -Level Info
& "$PSScriptRoot\Restrict-CDriveAccess.ps1"

Write-DomechLog "===== STEP 6/7: Ensure Required Services GPO =====" -Level Info
& "$PSScriptRoot\Deploy-EnsureServicesGPO.ps1"

Write-DomechLog "===== STEP 7/7: Re-check admin exclusions and refresh policy =====" -Level Info
# Steps 4-6 recreate the GPOs, so confirm the admin exclusion is still on all
# three afterwards rather than assuming it survived.
foreach ($gpoName in $staffGpos) {
    if (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue) {
        Block-DomainAdminsFromGPO -GpoName $gpoName -DomainDN $domainDN
    }
}
gpupdate /force | Out-String | Write-DomechLog -Level Info

Write-DomechLog "" -Level Info
Write-DomechLog "===== SERVER SIDE DONE =====" -Level Success
Write-DomechLog "Two things left that cannot be scripted from here:" -Level Warning
Write-DomechLog "  1. Sign out of this Administrator session completely (Start > user icon > Sign out - not lock, not restart-only), then sign back in. Windows only rebuilds Desktop/Documents and drive mappings at a fresh logon." -Level Warning
Write-DomechLog "  2. On each workstation, have the user sign out and back in. If anything is still wrong there, run the bootstrap URL on that machine and choose 'Fix THIS WORKSTATION'." -Level Warning
Write-DomechLog "" -Level Info
Write-DomechLog "Full log of this run: $Global:DomechLogFile" -Level Info
