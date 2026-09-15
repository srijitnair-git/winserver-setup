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

Runs everything by default. Use -Only to fix one thing at a time:
  -Only Shares      department folders, shares, groups, NTFS permissions
  -Only Users       user accounts + each person's personal folder and share
  -Only DriveMaps   the drive-mapping GPO and folder redirection
  -Only Branding    login splash, wallpaper, lock screen
Sections are independent but ordered - Shares before Users before DriveMaps -
so if you run them one at a time, run them in that order the first time.
#>

param(
    [ValidateSet('All','Shares','Users','DriveMaps','Branding')]
    [string]$Only = 'All',

    # Used ONLY for accounts that don't exist yet. ChangePasswordAtLogon is
    # enforced, so every new user must replace it at their first login.
    # Left empty on purpose: this repo is public, so no password is stored in
    # it. If not passed, it is read from Domain.TemporaryUserPassword in the
    # LOCAL config.json on this server (which updates never overwrite), and
    # only if that is absent does it ask.
    [string]$TemporaryPassword,

    # Re-apply folder permissions even when they already look correct. Needed
    # only if a previous run was interrupted part way through applying them,
    # which can leave the top folder correct while files inside it are not.
    [switch]$ForceAcl
)

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

if ($Only -in @('All','Shares')) {
Write-Host "### SECTION: folders, shares, groups, permissions ###" -ForegroundColor Magenta

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
    Write-Host "  $($d.FolderName):" -ForegroundColor White
    Revoke-SmbShareAccess -Name $d.ShareName -AccountName "Everyone" -Force -ErrorAction SilentlyContinue | Out-Null
    Grant-SmbShareAccess -Name $d.ShareName -AccountName "DF\$($d.GroupName)" -AccessRight $right -Force | Out-Null
    Write-Host "    share permissions set." -ForegroundColor Green

    $acl = Get-Acl $path
    $wantRights = if ($d.ReadOnly) {
        [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    } else {
        [System.Security.AccessControl.FileSystemRights]::Modify
    }

    # Break inheritance from D:\ and strip blanket access.
    # D:\ carries the Windows default permissions, which grant Users and
    # Authenticated Users access to everything beneath it. Those inherit into
    # every department folder, so ADDING group permissions on top restricted
    # nothing - any domain user who could connect to the share could open any
    # subfolder in it, and access-based enumeration correctly showed them
    # subfolders they were never meant to see. Access has to come from group
    # membership alone, so the inherited blanket grants are removed here.
    # SYSTEM and Domain Admins are always re-added, so the server and IT can
    # never be locked out of the data.
    $aclNeedsWrite = $false
    if (-not $acl.AreAccessRulesProtected -or $ForceAcl) {
        Write-Host "    removing inherited blanket access (this is what let everyone see everything)..." -ForegroundColor Yellow
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($ace in @($acl.Access | Where-Object { -not $_.IsInherited })) {
            [void]$acl.RemoveAccessRule($ace)
        }
        foreach ($keep in @(
            (New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")),
            (New-Object System.Security.AccessControl.FileSystemAccessRule("DF\Domain Admins", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"))
        )) { $acl.AddAccessRule($keep) }
        $aclNeedsWrite = $true
    }

    # Only write the folder ACL if something is actually missing. Writing an
    # inheritable ACE makes Windows rewrite permissions on every file beneath
    # it, which on a share full of live data runs for a long time - so a
    # re-run should not pay that cost again once it is already correct.
    if (-not (Test-NtfsAceExists -Acl $acl -Identity "DF\$($d.GroupName)" -Rights $wantRights) -or $ForceAcl) {
        $ntfsRight = if ($d.ReadOnly) { "ReadAndExecute" } else { "Modify" }
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "DF\$($d.GroupName)", $ntfsRight, "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.AddAccessRule($rule)
        $aclNeedsWrite = $true
    }

    # Sub-department groups (e.g. Purchase, SalaryWages inside SalaryWagesPurchase):
    # traverse-only on this parent folder so they can reach their own subfolder,
    # full rights on that subfolder itself. Access-based enumeration (below)
    # hides the subfolders they DON'T have rights to, rather than just denying
    # them on open - so Mansi never even sees "Salary Wages" listed, and vice versa.
    foreach ($sub in $d.SubDepartments) {
        $hasTraverse = Test-NtfsAceExists -Acl $acl -Identity "DF\$($sub.GroupName)" `
            -Rights ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute) -InheritanceFlags "None"
        if (-not $hasTraverse -or $ForceAcl) {
            $traverseRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "DF\$($sub.GroupName)", "ReadAndExecute", "None", "None", "Allow")
            $acl.AddAccessRule($traverseRule)
            $aclNeedsWrite = $true
        }
    }

    if ($aclNeedsWrite) {
        Write-Host "    applying folder permissions - on a big folder this can take a long time, leave it running..." -ForegroundColor Yellow
        $started = Get-Date
        Set-Acl -Path $path -AclObject $acl
        Write-Host "    done in $([int]((Get-Date) - $started).TotalSeconds)s." -ForegroundColor Green
    } else {
        Write-Host "    folder permissions already correct - skipped." -ForegroundColor Green
    }

    foreach ($sub in $d.SubDepartments) {
        Grant-SmbShareAccess -Name $d.ShareName -AccountName "DF\$($sub.GroupName)" -AccessRight Full -Force | Out-Null

        $subPath = Join-Path $path $sub.FolderName
        $subAcl = Get-Acl $subPath
        $subWant = [System.Security.AccessControl.FileSystemRights]::Modify
        if (-not (Test-NtfsAceExists -Acl $subAcl -Identity "DF\$($sub.GroupName)" -Rights $subWant) -or $ForceAcl) {
            Write-Host "    applying permissions to $($sub.FolderName) - may take a while..." -ForegroundColor Yellow
            $subRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "DF\$($sub.GroupName)", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
            $subAcl.AddAccessRule($subRule)
            Set-Acl -Path $subPath -AclObject $subAcl
            Write-Host "    $($sub.FolderName) done." -ForegroundColor Green
        } else {
            Write-Host "    $($sub.FolderName) already correct - skipped." -ForegroundColor Green
        }
    }

    if ($d.SubDepartments) {
        Set-SmbShare -Name $d.ShareName -FolderEnumerationMode AccessBased -Force
    }
}

}   # end SECTION Shares

if ($Only -in @('All','Users')) {
Write-Host "### SECTION: user accounts and personal folders ###" -ForegroundColor Magenta

# ---- Users ----
# Accounts that already exist are left completely alone - only their group
# membership is corrected below. The temporary password is used ONLY for
# accounts that don't exist yet; ChangePasswordAtLogon forces each new user
# onto their own password at their first login.
Write-Host "Creating users..." -ForegroundColor Cyan
$missingUsers = $Users | Where-Object {
    -not (Get-ADUser -Filter "SamAccountName -eq '$($_.Sam)'" -ErrorAction SilentlyContinue)
}

$secureTempPwd = $null
if ($missingUsers) {
    # Order: what was passed in, else the local config.json, else ask.
    $tempPwd = $TemporaryPassword
    if (-not $tempPwd) { $tempPwd = $Config.Domain.TemporaryUserPassword }
    if (-not $tempPwd) {
        Write-Host "  No temporary password set for new accounts." -ForegroundColor Yellow
        Write-Host "  To stop being asked, add this line inside the \"Domain\" section of $RepoRoot\config.json:" -ForegroundColor Yellow
        Write-Host "      `"TemporaryUserPassword`": `"YourPasswordHere`"," -ForegroundColor Yellow
        Write-Host "  That file is local to this server and is never uploaded." -ForegroundColor Yellow
        $tempPwd = Read-Host "  Temporary password to use for the new accounts"
    }
    $secureTempPwd = ConvertTo-SecureString $tempPwd -AsPlainText -Force
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
    Write-Host "   Created: $($missingUsers.Sam -join ', ')" -ForegroundColor Yellow
    Write-Host "   They all start with the temporary password you set." -ForegroundColor Yellow
    Write-Host "   Each must set their own password at first login." -ForegroundColor Yellow
    Write-Host "  ================================================================" -ForegroundColor Yellow
    Write-Host ""
} else {
    Write-Host "  All accounts already exist - passwords and settings untouched." -ForegroundColor Green
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

}   # end SECTION Users

if ($Only -in @('All','DriveMaps')) {
Write-Host "### SECTION: drive mappings and folder redirection ###" -ForegroundColor Magenta

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
    # Guard so this section can be run on its own with -Only DriveMaps: if the
    # groups haven't been created yet, skip rather than abort the whole run.
    $depGroup = Get-ADGroup -Filter "Name -eq '$($d.GroupName)'" -ErrorAction SilentlyContinue
    if (-not $depGroup) {
        Write-Host "  Skipping '$($d.GroupName)' drive - group doesn't exist yet (run -Only Shares first)." -ForegroundColor Yellow
        continue
    }
    $sid = $depGroup.SID.Value
    $uncPath = "\\$ServerHostname\$($d.ShareName)"
    # Escape anything going into an XML attribute. A folder name containing
    # "&" (e.g. "Salary Wages & Purchase") is not valid XML unescaped - the
    # Group Policy client stops parsing Drives.xml at that character and
    # silently drops every drive defined after it, with no error anywhere.
    $labelXml = [System.Security.SecurityElement]::Escape($d.FolderName)
    $pathXml  = [System.Security.SecurityElement]::Escape($uncPath)
    $groupXml = [System.Security.SecurityElement]::Escape($d.GroupName)
    @"
  <Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="$($d.DriveLetter):" status="$($d.DriveLetter):" image="2" changed="$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')" uid="{$([guid]::NewGuid())}">
    <Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="$pathXml" label="$labelXml" persistent="1" useLetter="1" letter="$($d.DriveLetter)"/>
    <Filters>
      <FilterGroup bool="AND" not="0" name="$groupXml" sid="$sid" userContext="1" primaryGroup="0" localGroup="0"/>
    </Filters>
  </Drive>
"@
    # Sub-department members (e.g. Purchase, SalaryWages) aren't in the main
    # group, so they need their own filtered entry for the SAME drive letter
    # and UNC path - access-based enumeration on the share means they'll only
    # ever see their own subfolder once mounted, not the other one.
    foreach ($sub in $d.SubDepartments) {
        $subGroup = Get-ADGroup -Filter "Name -eq '$($sub.GroupName)'" -ErrorAction SilentlyContinue
        if (-not $subGroup) {
            Write-Host "  Skipping '$($sub.GroupName)' drive - group doesn't exist yet." -ForegroundColor Yellow
            continue
        }
        $subSid = $subGroup.SID.Value
        $subGroupXml = [System.Security.SecurityElement]::Escape($sub.GroupName)
        @"
  <Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="$($d.DriveLetter):" status="$($d.DriveLetter):" image="2" changed="$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')" uid="{$([guid]::NewGuid())}">
    <Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="$pathXml" label="$labelXml" persistent="1" useLetter="1" letter="$($d.DriveLetter)"/>
    <Filters>
      <FilterGroup bool="AND" not="0" name="$subGroupXml" sid="$subSid" userContext="1" primaryGroup="0" localGroup="0"/>
    </Filters>
  </Drive>
"@
    }
}

# Personal drive per user - filtered by USER (not group), so each person
# only ever sees their own home drive, mounted at the same letter for everyone.
$personalDriveEntries = foreach ($u in $Users) {
    $adUser = Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue
    if (-not $adUser) {
        Write-Host "  Skipping personal drive for '$($u.Sam)' - account doesn't exist yet (run -Only Users first)." -ForegroundColor Yellow
        continue
    }
    $userSid = $adUser.SID.Value
    $uncPath = "\\$ServerHostname\$($u.Sam)$"
    $userPathXml = [System.Security.SecurityElement]::Escape($uncPath)
    $userNameXml = [System.Security.SecurityElement]::Escape("DF\$($u.Sam)")
    @"
  <Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="$($PersonalDriveLetter):" status="$($PersonalDriveLetter):" image="2" changed="$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')" uid="{$([guid]::NewGuid())}">
    <Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="$userPathXml" label="My Files" persistent="1" useLetter="1" letter="$($PersonalDriveLetter)"/>
    <Filters>
      <FilterUser bool="AND" not="0" name="$userNameXml" sid="$userSid" userContext="1"/>
    </Filters>
  </Drive>
"@
}

$drivesXml = @"
<?xml version="1.0" encoding="utf-8"?>
<Drives clsid="{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}">
$($departmentDriveEntries -join "`n")
$($personalDriveEntries -join "`n")
</Drives>
"@

# Prove the file is valid XML BEFORE publishing it. The Group Policy client
# gives no error on a malformed Drives.xml - it just stops reading at the bad
# character and silently ignores every drive defined after it. That is not
# something anyone can diagnose from the client side, so it gets caught here.
try {
    $parsed = [xml]$drivesXml
    $driveCount = $parsed.Drives.Drive.Count
    $drivesXml | Out-File "$gpoPath\Drives.xml" -Encoding UTF8
    Write-Host "  Drives.xml written and validated - $driveCount drive entries." -ForegroundColor Green
} catch {
    Write-Host "  REFUSING TO WRITE Drives.xml - the generated file is not valid XML:" -ForegroundColor Red
    Write-Host "    $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  The existing drive mappings have been left untouched. This is usually a name in config.json containing a character that is special in XML." -ForegroundColor Red
    throw
}

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
        Write-Host "  Drive Maps extension registered." -ForegroundColor Green
    } else {
        Write-Host "  Drive Maps extension already registered." -ForegroundColor Green
    }

    # Bump the version EVERY time, not only when first registering the
    # extension. Clients decide whether to re-read a GPO by comparing this
    # number - leave it unchanged after rewriting Drives.xml and they treat
    # the policy as unchanged and keep using the drive list they already have,
    # so a corrected file would never reach anyone.
    $newVersion = [int]$gpoAdObject.versionNumber + 65537   # bumps both the user and machine halves
    Set-ADObject -Identity $gpoAdObject.DistinguishedName -Replace @{ versionNumber = $newVersion }
    $gptIniPath = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id)}\gpt.ini"
    (Get-Content $gptIniPath) -replace '^Version=\d+', "Version=$newVersion" | Set-Content $gptIniPath
    Write-Host "  GPO version bumped to $newVersion so clients reprocess the new drive list." -ForegroundColor Green
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

}   # end SECTION DriveMaps

if ($Only -in @('All','Branding')) {
Write-Host "### SECTION: branding (splash, wallpaper, lock screen) ###" -ForegroundColor Magenta

# These are set up by the DriveMaps section above, but this section has to work
# when run on its own with -Only Branding, so establish them here too.
$domain    = (Get-ADDomain).DNSRoot
$gpoAdPath = "CN=Policies,CN=System,$domainDN"
$gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $gpo) {
    $gpo = New-GPO -Name $GpoName
    New-GPLink -Name $GpoName -Target $domainDN -ErrorAction SilentlyContinue | Out-Null
}

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

    # Bake the quote list in, the same way the service list is injected into
    # Ensure-RequiredServices - the splash runs from NETLOGON as an ordinary
    # user and cannot read config.json off the server.
    $splashScript = Get-Content "$PSScriptRoot\..\Workstation\Show-LoginSplash.ps1" -Raw
    $quotes = $Config.Branding.Quotes
    if ($quotes) {
        # Escape embedded double quotes so one bad character can't break the script.
        $quoteLiteral = ($quotes | ForEach-Object { '    "' + ($_ -replace '"', '`"') + '"' }) -join "`n"
        $splashScript = $splashScript -replace '"__QUOTES_PLACEHOLDER__"', $quoteLiteral.TrimStart()
        Write-Host "  $($quotes.Count) quote(s) loaded - one shown per day." -ForegroundColor Green
    } else {
        Write-Host "  No Branding.Quotes in config.json - the splash keeps the quote painted into the artwork." -ForegroundColor Yellow
    }
    $splashScript | Out-File "$netlogonPath\Show-LoginSplash.ps1" -Encoding UTF8 -Force
    if ($SplashFontTtf -and (Test-Path $SplashFontTtf)) {
        New-Item -ItemType Directory -Path "$netlogonPath\Fonts" -Force | Out-Null
        Copy-Item $SplashFontTtf "$netlogonPath\Fonts\Geist-Bold.ttf" -Force
    }

    $userScriptsPath = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id)}\User\Scripts"
    New-Item -ItemType Directory -Path $userScriptsPath -Force | Out-Null
    # -WindowStyle Hidden, or a PowerShell console window flashes up on screen
    # at every single login, behind the splash.
    @"
[Logon]
0CmdLine=powershell.exe
0Parameters=-ExecutionPolicy Bypass -WindowStyle Hidden -File \\$domain\NETLOGON\Show-LoginSplash.ps1
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

# The previous version set these through Group Policy registry values, which
# did not work here for two reasons:
#   - the wallpaper was written to Policies\ActiveDesktop. The "Desktop
#     Wallpaper" policy actually lives under Policies\System, so it was
#     writing to a key Windows never reads for that setting.
#   - the lock screen policy ("Force a specific default lock screen image")
#     only applies on Enterprise and Education. These workstations are OEM
#     Pro, where it is silently ignored.
# Both are now applied by Apply-Branding.ps1 running as a computer startup
# script, which uses PersonalizationCSP - machine-wide, works on Pro, and
# covers users who have never signed into that machine before.
$copied = $true
foreach ($img in @(@{Path=$WallpaperPng; Name="Wallpaper.png"}, @{Path=$LockScreenPng; Name="LockScreen.png"})) {
    if (Test-Path $img.Path) {
        Copy-Item $img.Path "$netlogonPath\$($img.Name)" -Force
        Write-Host "  $($img.Name) published to NETLOGON." -ForegroundColor Green
    } else {
        Write-Host "  $($img.Name) not found at $($img.Path) - branding will skip it." -ForegroundColor Yellow
        $copied = $false
    }
}

if ($copied) {
    $brandingScript = Get-Content "$PSScriptRoot\..\Workstation\Apply-Branding.ps1" -Raw
    $brandingScript = $brandingScript -replace '__NETLOGON_PLACEHOLDER__', $netlogonPath
    $brandingScript | Out-File "$netlogonPath\Apply-Branding.ps1" -Encoding UTF8 -Force

    $machineScriptsPath = "\\$domain\SYSVOL\$domain\Policies\{$($brandingGpo.Id)}\Machine\Scripts"
    New-Item -ItemType Directory -Path "$machineScriptsPath\Startup" -Force | Out-Null
    @"
[Startup]
0CmdLine=powershell.exe
0Parameters=-ExecutionPolicy Bypass -File \\$domain\NETLOGON\Apply-Branding.ps1
"@ | Out-File "$machineScriptsPath\scripts.ini" -Encoding Unicode

    # Register the Scripts extension on the MACHINE side and bump the version,
    # or clients skip the startup script with no error - the same silent
    # failure that stopped the drive maps and the services script running.
    $scriptsExtensionPair = "[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]"
    $brandingAd = Get-ADObject -Filter "displayName -eq '$BrandingGpoName'" -SearchBase $gpoAdPath -Properties gPCMachineExtensionNames, versionNumber
    if ($brandingAd) {
        $ext = $brandingAd.gPCMachineExtensionNames
        if (-not $ext -or $ext -notlike "*42B5FAAE*") {
            Set-ADObject -Identity $brandingAd.DistinguishedName -Replace @{ gPCMachineExtensionNames = "$ext$scriptsExtensionPair" }
            Write-Host "  Startup script extension registered on '$BrandingGpoName'." -ForegroundColor Green
        }
        $bVersion = [int]$brandingAd.versionNumber + 65537
        Set-ADObject -Identity $brandingAd.DistinguishedName -Replace @{ versionNumber = $bVersion }
        $bGptIni = "\\$domain\SYSVOL\$domain\Policies\{$($brandingGpo.Id)}\gpt.ini"
        (Get-Content $bGptIni) -replace '^Version=\d+', "Version=$bVersion" | Set-Content $bGptIni
        Write-Host "  Wallpaper and lock screen will apply at each workstation's next restart." -ForegroundColor Green
    } else {
        Write-Host "  Could not find the '$BrandingGpoName' AD object - wallpaper and lock screen will NOT apply until the startup script extension is registered on it." -ForegroundColor Red
    }
}

}   # end SECTION Branding

Write-Host "`nDone (-Only $Only). Sign a user out and back in on a workstation to test: department drives and their personal '$($PersonalDriveLetter):' drive should mount, and Desktop/Documents/Downloads/Pictures should point at their personal share." -ForegroundColor Green
