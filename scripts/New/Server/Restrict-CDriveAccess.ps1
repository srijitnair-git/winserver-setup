<#
Domech Fabricators - restrict standard users from browsing C: in Explorer
Run once from the server as DF\Administrator, after DF.local is promoted.

IMPORTANT - read this before running:
Windows itself, and every installed program, needs the Users group to be
able to READ C:\Windows, C:\Program Files, etc. at the filesystem (NTFS)
level - actually removing that access breaks the OS and every app. Real
lockdown of "no C: access at all" is not something you can safely do to a
Windows workstation.

What THIS script does instead - the standard, safe approach - is block
ACCESS THROUGH EXPLORER: hides the C: drive icon and blocks browsing to it
via Explorer, Open/Save dialogs, and typing C:\ in the address bar, for
regular domain users. D: stays fully visible and usable. Each user's own
profile stays reachable normally via their Desktop/Documents/Downloads
shortcuts in Explorer's sidebar (those use special folder shortcuts, not
C:\ browsing) and via the mapped department drives from the drive-mapping
GPO. Programs still run fine - this only affects manual Explorer browsing.

Domain Admins are excluded from this policy (see the permission step at
the end) so IT can still work normally on C: when needed.
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
if (-not $gpo) { $gpo = New-GPO -Name $GpoName }
New-GPLink -Name $GpoName -Target $domainDN -ErrorAction SilentlyContinue | Out-Null

# Drive letter bitmask: A=1, B=2, C=4, D=8 ... only C: (bit 3) is set here.
$cDriveOnly = 4

# "Hide these specified drives in My Computer" - removes the C: icon entirely
Set-GPRegistryValue -Name $GpoName -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" `
    -ValueName "NoDrives" -Type DWord -Value $cDriveOnly | Out-Null

# "Prevent access to drives from My Computer" - blocks navigating to C: even
# by typing the path directly, showing a policy-restriction message instead
Set-GPRegistryValue -Name $GpoName -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" `
    -ValueName "NoViewOnDrive" -Type DWord -Value $cDriveOnly | Out-Null

Write-DomechLog "GPO '$GpoName' created/updated: C: hidden and blocked in Explorer for anyone this GPO applies to." -Level Success

# Exclude Domain Admins from this policy so IT retains normal C: access.
Block-DomainAdminsFromGPO -GpoName $GpoName -DomainDN $domainDN

Write-DomechLog "Test on one non-admin user login: C: should be hidden/blocked, D: and mapped drives should work normally." -Level Info
