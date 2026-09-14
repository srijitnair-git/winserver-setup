<#
Domech Fabricators - DF.local full setup (users, groups, shares, ACLs, auto-mount drives)
Run as DF\Administrator on the DC, AFTER 1-Install-ADForest.ps1 and 2-PostPromotion-Setup.ps1.

All names/paths come from config.json in this same folder - edit that, not this file.
imran and DELL are deliberately NOT in config.json's Users list - unexplained
domain-admin accounts on the old server, confirm with owner before adding
anyone with elevated rights on DF.local.

Folder layout under D:\Domech:
  <Department shares>       group-based, e.g. Common, Accounts, Tally,
                             SalaryWagesPurchase, Backup
  Workstation\Personal\<user>   each user's own share/drive (P: by default),
                                 Desktop/Documents/Downloads/Pictures redirect
                                 here. Everyone in Users is a member of the
                                 "Workstation" group, which can browse the
                                 Workstation folder itself but not into
                                 anyone else's Personal subfolder.
  Workstation\Systems\<pcname>  per-machine data (pre-format backups etc,
                                 see config.json Paths.BackupRoot), admin-only.

Drive mapping is done via Group Policy Preferences (GPP) - no logon script needed,
works on ANY domain PC the user logs into.
#>

[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
Import-Module ActiveDirectory
Import-Module GroupPolicy

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

$Departments = $Config.Departments
$Users       = $Config.Users
$DataRoot    = $Config.Paths.DataRoot
$GpoName     = $Config.GPO.DriveMapGpoName
$BrandingGpoName = $Config.GPO.BrandingGpoName
$SplashPng      = $Config.Branding.SplashPng
$SplashFontTtf  = $Config.Branding.SplashFontTtf
$WallpaperPng   = $Config.Branding.WallpaperPng
$LockScreenPng  = $Config.Branding.LockScreenPng
$WorkstationGroupName = $Config.Workstation.GroupName
$WorkstationFolderName = $Config.Workstation.FolderName
$PersonalFolderName  = $Config.Workstation.PersonalFolderName
$SystemsFolderName   = $Config.Workstation.SystemsFolderName
$PersonalDriveLetter = $Config.Workstation.PersonalDriveLetter
$ServerHostname = $env:COMPUTERNAME

$domainDN = (Get-ADDomain).DistinguishedName
$usersOU  = "OU=Users,OU=Domech,$domainDN"
$groupsOU = "OU=Groups,OU=Domech,$domainDN"

# ---- Folders + shares ----
Write-Host "Creating data folders and shares..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
foreach ($d in $Departments) {
    $path = Join-Path $DataRoot $d.FolderName
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    if (-not (Get-SmbShare -Name $d.ShareName -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $d.ShareName -Path $path -FullAccess "DF\Domain Admins" | Out-Null
    }
}

# ---- Groups ----
Write-Host "Creating security groups..." -ForegroundColor Cyan
foreach ($d in $Departments) {
    if (-not (Get-ADGroup -Filter "Name -eq '$($d.GroupName)'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $d.GroupName -GroupScope Global -GroupCategory Security -Path $groupsOU
    }
}
if (-not (Get-ADGroup -Filter "Name -eq '$WorkstationGroupName'" -ErrorAction SilentlyContinue)) {
    New-ADGroup -Name $WorkstationGroupName -GroupScope Global -GroupCategory Security -Path $groupsOU
}

# ---- Share + NTFS ACLs (group-based, explicit grants only, no Deny ACEs) ----
Write-Host "Applying share and NTFS permissions..." -ForegroundColor Cyan
foreach ($d in $Departments) {
    $path   = Join-Path $DataRoot $d.FolderName
    $right  = if ($d.ReadOnly) { "Read" } else { "Full" }
    Revoke-SmbShareAccess -Name $d.ShareName -AccountName "Everyone" -Force -ErrorAction SilentlyContinue
    Grant-SmbShareAccess -Name $d.ShareName -AccountName "DF\$($d.GroupName)" -AccessRight $right -Force | Out-Null

    $acl = Get-Acl $path
    $ntfsRight = if ($d.ReadOnly) { "ReadAndExecute" } else { "Modify" }
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "DF\$($d.GroupName)", $ntfsRight, "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl -Path $path -AclObject $acl
}

# ---- Users ----
Write-Host "Creating users..." -ForegroundColor Cyan
foreach ($u in $Users) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue)) {
        $randomPwd = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 16 | ForEach-Object {[char]$_})
        $securePwd = ConvertTo-SecureString $randomPwd -AsPlainText -Force
        New-ADUser -Name $u.Name -SamAccountName $u.Sam -UserPrincipalName "$($u.Sam)@DF.local" `
            -Path $usersOU -AccountPassword $securePwd -Enabled $true -ChangePasswordAtLogon $true
        Add-Content -Path "C:\01_matrix\Scratch\NewUserPasswords.txt" -Value "$($u.Sam): $randomPwd"
    }
    foreach ($g in $u.Groups) {
        Add-ADGroupMember -Identity $g -Members $u.Sam -ErrorAction SilentlyContinue
    }
}
Write-Host "Initial passwords written to C:\01_matrix\Scratch\NewUserPasswords.txt - hand these out securely and delete the file after." -ForegroundColor Yellow

# ---- Workstation folder tree: Personal (per-user) + Systems (per-PC) ----
# Runs AFTER user creation above, since the ACL grants below need the AD
# account to already exist.
Write-Host "Creating Workstation folder tree..." -ForegroundColor Cyan
$workstationRoot = Join-Path $DataRoot $WorkstationFolderName
$personalRoot = Join-Path $workstationRoot $PersonalFolderName
$systemsRoot  = Join-Path $workstationRoot $SystemsFolderName
New-Item -ItemType Directory -Path $workstationRoot -Force | Out-Null
New-Item -ItemType Directory -Path $personalRoot -Force | Out-Null
New-Item -ItemType Directory -Path $systemsRoot -Force | Out-Null

# The Workstation group gets traverse/list only at the parent level - so
# Explorer navigation into the tree works - never into other users' Personal
# subfolders, which stay locked to their owner alone below.
$acl = Get-Acl $workstationRoot
$listRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "DF\$WorkstationGroupName", "ReadAndExecute", "None", "None", "Allow")
$acl.AddAccessRule($listRule)
Set-Acl -Path $workstationRoot -AclObject $acl
# Membership in $WorkstationGroupName is handled by the Users loop above,
# via each user's "Workstation" entry in config.json's Groups list.

Write-Host "Creating personal folders and shares..." -ForegroundColor Cyan
$redirectedFolders = @("Desktop","Documents","Downloads","Pictures")
foreach ($u in $Users) {
    $path = Join-Path $personalRoot $u.Sam
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    foreach ($rf in $redirectedFolders) {
        New-Item -ItemType Directory -Path (Join-Path $path $rf) -Force | Out-Null
    }
    $shareName = "$($u.Sam)$"
    if (-not (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $shareName -Path $path -FullAccess "DF\Domain Admins" | Out-Null
    }
    Revoke-SmbShareAccess -Name $shareName -AccountName "Everyone" -Force -ErrorAction SilentlyContinue
    Grant-SmbShareAccess -Name $shareName -AccountName "DF\$($u.Sam)" -AccessRight Full -Force | Out-Null

    $acl = Get-Acl $path
    $acl.SetAccessRuleProtection($true, $false)   # break inheritance - this folder is that user's alone
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "DF\$($u.Sam)", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "DF\Domain Admins", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($rule)
    $acl.AddAccessRule($adminRule)
    $acl.AddAccessRule($systemRule)
    Set-Acl -Path $path -AclObject $acl
}
Write-Host "  $($Users.Count) personal folders/shares ready under $personalRoot" -ForegroundColor Green

# ---- Systems: one folder per PC, admin-only, not user-mapped ----
# Not a per-user share/drive - this is where per-machine data (pre-format
# backups etc, see Paths.BackupRoot) lives, for IT/backup scripts to use.
Write-Host "Creating per-PC Systems folders..." -ForegroundColor Cyan
foreach ($hostname in $Config.Workstations) {
    $pcPath = Join-Path $systemsRoot $hostname
    New-Item -ItemType Directory -Path $pcPath -Force | Out-Null
    $pcAcl = Get-Acl $pcPath
    $pcAcl.SetAccessRuleProtection($true, $false)
    $adminOnlyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "DF\Domain Admins", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $pcSystemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $pcAcl.AddAccessRule($adminOnlyRule)
    $pcAcl.AddAccessRule($pcSystemRule)
    Set-Acl -Path $pcPath -AclObject $pcAcl
}
Write-Host "  $($Config.Workstations.Count) per-PC Systems folders ready under $systemsRoot" -ForegroundColor Green

# ---- Auto-mount drives via Group Policy Preferences ----
# GPP Drive Maps live in the GPO's Drives.xml under SYSVOL, keyed by group SID.
# There is no native New-GPPref cmdlet for drive maps, so we write the XML directly.
Write-Host "Creating drive-mapping GPO..." -ForegroundColor Cyan
$gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $gpo) { $gpo = New-GPO -Name $GpoName }
New-GPLink -Name $GpoName -Target $domainDN -ErrorAction SilentlyContinue | Out-Null

$domain = (Get-ADDomain).DNSRoot
$gpoPath = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id)}\User\Preferences\Drives"
New-Item -ItemType Directory -Path $gpoPath -Force | Out-Null

$departmentDriveEntries = foreach ($d in $Departments) {
    $sid = (Get-ADGroup $d.GroupName).SID.Value
    $uncPath = "\\$ServerHostname\$($d.ShareName)"
    @"
  <Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="$($d.DriveLetter):" status="$($d.DriveLetter):" image="2" changed="$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')" uid="{$([guid]::NewGuid())}">
    <Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="$uncPath" label="$($d.FolderName)" persistent="1" useLetter="1" letter="$($d.DriveLetter)"/>
    <Filters>
      <FilterGroup bool="AND" not="0" name="$($d.GroupName)" sid="$sid" userContext="1" primaryGroup="0" localGroup="0"/>
    </Filters>
  </Drive>
"@
}

# Personal drive per user - filtered by USER (not group), so each person
# only ever sees their own home drive, mounted at the same letter for everyone.
$personalDriveEntries = foreach ($u in $Users) {
    $userSid = (Get-ADUser $u.Sam).SID.Value
    $uncPath = "\\$ServerHostname\$($u.Sam)$"
    @"
  <Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="$($PersonalDriveLetter):" status="$($PersonalDriveLetter):" image="2" changed="$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')" uid="{$([guid]::NewGuid())}">
    <Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="$uncPath" label="My Files" persistent="1" useLetter="1" letter="$($PersonalDriveLetter)"/>
    <Filters>
      <FilterUser bool="AND" not="0" name="DF\$($u.Sam)" sid="$userSid" userContext="1"/>
    </Filters>
  </Drive>
"@
}

@"
<?xml version="1.0" encoding="utf-8"?>
<Drives clsid="{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}">
$($departmentDriveEntries -join "`n")
$($personalDriveEntries -join "`n")
</Drives>
"@ | Out-File "$gpoPath\Drives.xml" -Encoding UTF8

Write-Host "Drive mapping GPO created: department drives + a personal '$($PersonalDriveLetter):' drive per user pointing at their own \\$ServerHostname\<username>`$ share." -ForegroundColor Green

# ---- Redirect Desktop/Documents/Downloads/Pictures to the personal share ----
# This is what actually makes it "backup all the user folder" - files land
# on the server the moment they're saved, not on a schedule. Uses
# ExpandString registry values with %USERNAME% so one GPO setting resolves
# to a different path per person automatically - no per-user GPO needed.
Write-Host "Setting up folder redirection to personal drives..." -ForegroundColor Cyan
$shellFolderMap = @{
    "Desktop"   = "Desktop"
    "Personal"  = "Documents"    # registry name for the Documents folder is "Personal"
    "{374DE290-123F-4565-9164-39C4925E467B}" = "Downloads"
    "My Pictures" = "Pictures"
}
foreach ($regName in $shellFolderMap.Keys) {
    $targetUnc = "\\$ServerHostname\%USERNAME%`$\$($shellFolderMap[$regName])"
    Set-GPRegistryValue -Name $GpoName -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" `
        -ValueName $regName -Type ExpandString -Value $targetUnc | Out-Null
    Set-GPRegistryValue -Name $GpoName -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" `
        -ValueName $regName -Type ExpandString -Value $targetUnc | Out-Null
}
Write-Host "  Desktop/Documents/Downloads/Pictures will redirect to each user's personal share after next login." -ForegroundColor Green

# ---- Post-login splash (image popup, deployed via GPO logon script) ----
Write-Host "Setting up post-login splash..." -ForegroundColor Cyan
if (Test-Path $SplashPng) {
    $netlogonPath = "\\$domain\NETLOGON"
    Copy-Item $SplashPng "$netlogonPath\LoginSplash.png" -Force
    Copy-Item "$PSScriptRoot\..\Workstation\Show-LoginSplash.ps1" "$netlogonPath\Show-LoginSplash.ps1" -Force
    if ($SplashFontTtf -and (Test-Path $SplashFontTtf)) {
        New-Item -ItemType Directory -Path "$netlogonPath\Fonts" -Force | Out-Null
        Copy-Item $SplashFontTtf "$netlogonPath\Fonts\Geist-Bold.ttf" -Force
    }
    Write-Host "  Splash background + font copied to NETLOGON. The employee's real name is drawn on top live at logon - it doesn't need a separate image per person. Link Show-LoginSplash.ps1 as a User Logon script in the '$GpoName' GPO (or a separate GPO): powershell.exe -ExecutionPolicy Bypass -File Show-LoginSplash.ps1" -ForegroundColor Yellow
} else {
    Write-Host "  Splash image not found at $SplashPng - export a PNG from your Illustrator file and place it there, then rerun this section." -ForegroundColor Yellow
}


# ---- Default wallpaper + lock screen (GPO, applies fleet-wide) ----
Write-Host "Setting up wallpaper and lock screen branding..." -ForegroundColor Cyan
$brandingGpo = Get-GPO -Name $BrandingGpoName -ErrorAction SilentlyContinue
if (-not $brandingGpo) { $brandingGpo = New-GPO -Name $BrandingGpoName }
New-GPLink -Name $BrandingGpoName -Target $domainDN -ErrorAction SilentlyContinue | Out-Null

$netlogonPath = "\\$domain\NETLOGON"

if (Test-Path $WallpaperPng) {
    Copy-Item $WallpaperPng "$netlogonPath\Wallpaper.png" -Force
    # User Config > Admin Templates > Desktop > Desktop > "Desktop Wallpaper"
    Set-GPRegistryValue -Name $BrandingGpoName -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" `
        -ValueName "Wallpaper" -Type String -Value "$netlogonPath\Wallpaper.png" | Out-Null
    Set-GPRegistryValue -Name $BrandingGpoName -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" `
        -ValueName "WallpaperStyle" -Type String -Value "10" | Out-Null   # 10 = Fill
    Write-Host "  Wallpaper policy set." -ForegroundColor Green
} else {
    Write-Host "  Wallpaper image not found at $WallpaperPng - export one and rerun this section." -ForegroundColor Yellow
}

if (Test-Path $LockScreenPng) {
    Copy-Item $LockScreenPng "$netlogonPath\LockScreen.png" -Force
    # Computer Config > Admin Templates > Control Panel > Personalization >
    # "Force a specific default lock screen and logon image"
    Set-GPRegistryValue -Name $BrandingGpoName -Key "HKLM\Software\Policies\Microsoft\Windows\Personalization" `
        -ValueName "LockScreenImage" -Type String -Value "$netlogonPath\LockScreen.png" | Out-Null
    Set-GPRegistryValue -Name $BrandingGpoName -Key "HKLM\Software\Policies\Microsoft\Windows\Personalization" `
        -ValueName "NoChangingLockScreen" -Type DWord -Value 1 | Out-Null
    Write-Host "  Lock screen policy set." -ForegroundColor Green
} else {
    Write-Host "  Lock screen image not found at $LockScreenPng - export one and rerun this section." -ForegroundColor Yellow
}

Write-Host "`nDone. Test by logging in as one user on one workstation: department drives + their personal '$($PersonalDriveLetter):' drive should auto-mount, Desktop/Documents/Downloads/Pictures should redirect to their personal share, the splash should appear, and wallpaper/lock screen should apply - after 'gpupdate /force' + relogin." -ForegroundColor Green
