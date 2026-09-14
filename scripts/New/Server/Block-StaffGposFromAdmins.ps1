<#
Domech Fabricators - stop staff policies applying to admin accounts

Run on the DC, elevated. Denies "Apply group policy" to Domain Admins on
every GPO meant for regular staff, and verifies the setting actually saved.

This is the fix for: Administrator getting folder redirection pointed at
\\SERVER\Administrator$\... (a share that does not exist), which breaks
Explorer, the Settings app, Control Panel applets, Open/Save dialogs and
installers all at once.

This only stops it happening again. Damage already written into an admin
profile has to be repaired separately - run Repair-UserProfile.ps1 after
this, signed in as the affected account.
#>

Import-Module ActiveDirectory
Import-Module GroupPolicy

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

$domainDN = (Get-ADDomain).DistinguishedName
$staffGpos = @(
    $Config.GPO.DriveMapGpoName,
    $Config.GPO.RestrictCDriveGpoName,
    $Config.GPO.BrandingGpoName
) | Where-Object { $_ }

foreach ($gpoName in $staffGpos) {
    if (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue) {
        Block-DomainAdminsFromGPO -GpoName $gpoName -DomainDN $domainDN
    } else {
        Write-DomechLog "GPO '$gpoName' doesn't exist - nothing to exclude." -Level Info
    }
}

gpupdate /force | Out-String | Write-DomechLog -Level Info

Write-DomechLog "" -Level Info
Write-DomechLog "Done. Check above: every GPO should say 'Verified'. Anything red means it did not save and needs setting by hand in GPMC (select the GPO > Delegation > Advanced > Domain Admins > tick Deny on 'Apply group policy')." -Level Warning
Write-DomechLog "Next: sign out of this admin account and back in, then run the profile repair if Explorer is still broken." -Level Warning
