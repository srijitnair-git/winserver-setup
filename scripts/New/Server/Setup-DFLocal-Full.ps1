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

# ---- Remove stale shares from before the Salary/Purchase consolidation ----
# Setup only ever creates shares, never removes ones no longer in config -
# these two were separate top-level shares before Salary/Purchase became
# subfolders inside SalaryWagesPurchase$. Named explicitly rather than
# diffing against config, since blindly removing "any share not in config"
# could delete something unrelated an admin added by hand.
foreach ($staleShare in @("Salary$", "Purchase$")) {
    if (Get-SmbShare -Name $staleShare -ErrorAction SilentlyContinue) {
        Remove-SmbShare -Name $staleShare -Force
        Write-Host "Removed stale share '$staleShare' (superseded by SalaryWagesPurchase\$ subfolders)." -ForegroundColor Yellow
    }
}

# ---- Folders + shares ----
Write-Host "Creating data folders and shares..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
foreach ($d in $Departments) {
    $path = Join-Path $DataRoot $d.FolderName
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    if (-not (Get-SmbShare -Name $d.ShareName -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $d.ShareName -Path $path -FullAccess "DF\Domain Admins" | Out-Null
    }
    foreach ($sub in $d.SubDepartments) {
        New-Item -ItemType Directory -Path (Join-Path $path $sub.FolderName) -Force | Out-Null
    }
}

# ---- Groups ----
Write-Host "Creating security groups..." -ForegroundColor Cyan
foreach ($d in $Departments) {
    if (-not (Get-ADGroup -Filter "Name -eq '$($d.GroupName)'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $d.GroupName -GroupScope Global -GroupCategory Security -Path $groupsOU
    }
    foreach ($sub in $d.SubDepartments) {
        if (-not (Get-ADGroup -Filter "Name -eq '$($sub.GroupName)'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $sub.GroupName -GroupScope Global -GroupCategory Security -Path $groupsOU
        }
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

    # Sub-department groups (e.g. Purchase, SalaryWages inside SalaryWagesPurchase):
    # traverse-only on this parent folder so they can reach their own subfolder,
    # full rights on that subfolder itself. Access-based enumeration (below)
    # hides the subfolders they DON'T have rights to, rather than just denying
    # them on open - so Mansi never even sees "Salary Wages" listed, and vice versa.
    foreach ($sub in $d.SubDepartments) {
        $traverseRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "DF\$($sub.GroupName)", "ReadAndExecute", "None", "None", "Allow")
        $acl.AddAccessRule($traverseRule)
    }
    Set-Acl -Path $path -AclObject $acl

    foreach ($sub in $d.SubDepartments) {
        Grant-SmbShareAccess -Name $d.ShareName -AccountName "DF\$($sub.GroupName)" -AccessRight Full -Force | Out-Null

        $subPath = Join-Path $path $sub.FolderName
        $subAcl = Get-Acl $subPath
        $subRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "DF\$($sub.GroupName)", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
        $subAcl.AddAccessRule($subRule)
        Set-Acl -Path $subPath -AclObject $subAcl
    }

    if ($d.SubDepartments) {
        Set-SmbShare -Name $d.ShareName -FolderEnumerationMode AccessBased -Force
    }
}

# ---- Users ----
# Accounts that already exist are left completely alone (only their group
# membership is corrected below). A temporary password is generated here only
# if there are genuinely new accounts to create - it is never stored in
# config.json or git, and ChangePasswordAtLogon forces each new user onto
# their own password at first login, so it lives for one login only.
Write-Host "Creating users..." -ForegroundColor Cyan
$missingUsers = $Users | Where-Object {
    -not (Get-ADUser -Filter "SamAccountName -eq '$($_.Sam)'" -ErrorAction SilentlyContinue)
}

$secureTempPwd = $null
if ($missingUsers) {
    # Ambiguous characters (0/O, 1/l/I) left out - these get read aloud and typed by hand.
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!#$%&*+-')
    $chars = foreach ($s in $sets) { $s[(Get-Random -Maximum $s.Length)] }        # one of each class
    $all = -join $sets
    $chars += 1..12 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }  # pad to 16
    $tempPassword = -join ($chars | Sort-Object { Get-Random })
    $secureTempPwd = ConvertTo-SecureString $tempPassword -AsPlainText -Force

    $pwdFile = Join-Path $Config.Paths.ScratchRoot "NewUserTempPassword.txt"
    "Temporary password for accounts created $(Get-Date -Format 'yyyy-MM-dd HH:mm'):`r`n$tempPassword`r`n`r`nAccounts: $($missingUsers.Sam -join ', ')`r`nEach user must change it at first login." |
        Out-File $pwdFile -Encoding UTF8
    Write-Host "  Creating $($missingUsers.Count) new account(s): $($missingUsers.Sam -join ', ')" -ForegroundColor Cyan
}

foreach ($u in $Users) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $u.Name -SamAccountName $u.Sam -UserPrincipalName "$($u.Sam)@DF.local" `
            -Path $usersOU -AccountPassword $secureTempPwd -Enabled $true -ChangePasswordAtLogon $true
    }
    foreach ($g in $u.Groups) {
        Add-ADGroupMember -Identity $g -Members $u.Sam -ErrorAction SilentlyContinue
    }
}

if ($missingUsers) {
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor Yellow
    Write-Host "   TEMPORARY PASSWORD for the new accounts: $tempPassword" -ForegroundColor Yellow
    Write-Host "   Give it to: $($missingUsers.Sam -join ', ')" -ForegroundColor Yellow
    Write-Host "   Each is forced to set their own password at first login." -ForegroundColor Yellow
    Write-Host "   Also saved to: $pwdFile" -ForegroundColor Yellow
    Write-Host "  ================================================================" -ForegroundColor Yellow
    Write-Host ""
} else {
    Write-Host "  All accounts already exist - no new passwords needed, existing ones untouched." -ForegroundColor Green
}

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
    # Sub-department members (e.g. Purchase, SalaryWages) aren't in the main
    # group, so they need their own filtered entry for the SAME drive letter
    # and UNC path - access-based enumeration on the share means they'll only
    # ever see their own subfolder once mounted, not the other one.
    foreach ($sub in $d.SubDepartments) {
        $subSid = (Get-ADGroup $sub.GroupName).SID.Value
        @"
  <Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="$($d.DriveLetter):" status="$($d.DriveLetter):" image="2" changed="$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')" uid="{$([guid]::NewGuid())}">
    <Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="$uncPath" label="$($d.FolderName)" persistent="1" useLetter="1" letter="$($d.DriveLetter)"/>
    <Filters>
      <FilterGroup bool="AND" not="0" name="$($sub.GroupName)" sid="$subSid" userContext="1" primaryGroup="0" localGroup="0"/>
    </Filters>
  </Drive>
"@
    }
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

# Writing Drives.xml into SYSVOL alone does NOT tell Windows clients that
# this GPO contains Drive Maps preferences - there's no New-GPPref cmdlet
# for it, and unlike Set-GPRegistryValue (which self-registers its own
# extension), a hand-written XML file needs the extension pair added to
# the GPO's AD object manually, or clients skip it entirely - which is
# exactly the "drives don't mount, no error, nothing in gpresult" symptom
# seen on-site. This registers Drive Maps and bumps the GPO version so
# already-logged-on machines pick up the change on their next refresh.
Write-Host "Registering the Drive Maps extension on the GPO..." -ForegroundColor Cyan
$driveMapsExtensionPair = "[{5794DAFD-BE60-433f-88A2-1A31939AC01F}{935D1B74-9CB8-4e3c-9914-7DD559B7A417}]"
$gpoAdPath = "CN=Policies,CN=System,$domainDN"
$gpoAdObject = Get-ADObject -Filter "displayName -eq '$GpoName'" -SearchBase $gpoAdPath -Properties gPCUserExtensionNames, versionNumber
if ($gpoAdObject) {
    $currentExt = $gpoAdObject.gPCUserExtensionNames
    if (-not $currentExt -or $currentExt -notlike "*935D1B74-9CB8-4e3c-9914-7DD559B7A417*") {
        $newExt = "$currentExt$driveMapsExtensionPair"
        Set-ADObject -Identity $gpoAdObject.DistinguishedName -Replace @{ gPCUserExtensionNames = $newExt }
        $newVersion = [int]$gpoAdObject.versionNumber + 65537   # bumps both the user and machine version halves
        Set-ADObject -Identity $gpoAdObject.DistinguishedName -Replace @{ versionNumber = $newVersion }
        $gptIniPath = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id)}\gpt.ini"
        (Get-Content $gptIniPath) -replace '^Version=\d+', "Version=$newVersion" | Set-Content $gptIniPath
        Write-Host "  Drive Maps extension registered, GPO version bumped to $newVersion so it gets reprocessed." -ForegroundColor Green
    } else {
        Write-Host "  Drive Maps extension already registered." -ForegroundColor Green
    }
} else {
    Write-Host "  Could not find the GPO's AD object to register the extension - drives will NOT mount until this is done. Investigate manually in ADSI Edit: CN=Policies,CN=System,$domainDN, find the GPO by displayName, add $driveMapsExtensionPair to gPCUserExtensionNames." -ForegroundColor Red
}

Write-Host "Drive mapping GPO created: department drives + a personal '$($PersonalDriveLetter):' drive per user pointing at their own \\$ServerHostname\<username>`$ share." -ForegroundColor Green

# Exclude Domain Admins - without this, Administrator (not in config.json's
# Users list, so no personal share exists for it) gets its Desktop/Documents
# folder redirection pointed at a share that doesn't exist, producing
# "Windows cannot access \\SERVER\Administrator$\Desktop" on login.
Block-DomainAdminsFromGPO -GpoName $GpoName -DomainDN $domainDN

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

# ---- Post-login splash (image popup, registered directly as a GPO User Logon script) ----
# Previously this just copied the files to NETLOGON with a note to link it
# manually in GPMC - that manual step was never done on-site, so the splash
# never ran. Registered automatically now, the same way as the Drive Maps
# fix above: write scripts.ini directly AND register the legacy Scripts
# client-side extension on the GPO's AD object, since an unregistered
# extension is silently skipped by clients with no error anywhere.
Write-Host "Setting up post-login splash..." -ForegroundColor Cyan
if (Test-Path $SplashPng) {
    $netlogonPath = "\\$domain\NETLOGON"
    Copy-Item $SplashPng "$netlogonPath\LoginSplash.png" -Force
    Copy-Item "$PSScriptRoot\..\Workstation\Show-LoginSplash.ps1" "$netlogonPath\Show-LoginSplash.ps1" -Force
    if ($SplashFontTtf -and (Test-Path $SplashFontTtf)) {
        New-Item -ItemType Directory -Path "$netlogonPath\Fonts" -Force | Out-Null
        Copy-Item $SplashFontTtf "$netlogonPath\Fonts\Geist-Bold.ttf" -Force
    }

    $userScriptsPath = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id)}\User\Scripts"
    New-Item -ItemType Directory -Path $userScriptsPath -Force | Out-Null
    @"
[Logon]
0CmdLine=powershell.exe
0Parameters=-ExecutionPolicy Bypass -File \\$domain\NETLOGON\Show-LoginSplash.ps1
"@ | Out-File "$userScriptsPath\scripts.ini" -Encoding Unicode

    $scriptsExtensionPair = "[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]"
    $gpoAdObject2 = Get-ADObject -Filter "displayName -eq '$GpoName'" -SearchBase $gpoAdPath -Properties gPCUserExtensionNames, versionNumber
    if ($gpoAdObject2) {
        $currentExt2 = $gpoAdObject2.gPCUserExtensionNames
        if (-not $currentExt2 -or $currentExt2 -notlike "*42B5FAAE*") {
            Set-ADObject -Identity $gpoAdObject2.DistinguishedName -Replace @{ gPCUserExtensionNames = "$currentExt2$scriptsExtensionPair" }
            $newVersion2 = [int]$gpoAdObject2.versionNumber + 65537
            Set-ADObject -Identity $gpoAdObject2.DistinguishedName -Replace @{ versionNumber = $newVersion2 }
            $gptIniPath2 = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id)}\gpt.ini"
            (Get-Content $gptIniPath2) -replace '^Version=\d+', "Version=$newVersion2" | Set-Content $gptIniPath2
        }
    }
    Write-Host "  Splash registered as a User Logon script on '$GpoName' - the employee's real name is drawn on top live at logon, no separate image per person needed." -ForegroundColor Green
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
