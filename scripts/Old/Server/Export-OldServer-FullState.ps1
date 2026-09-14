<#
Domech Fabricators - Old server (DF.com, Server 2022) read-only extraction
Run as Domain Admin on the OLD server. Makes NO changes.
Exports users, groups, computers, OUs, share permissions, NTFS ACLs,
and GPO drive-map (auto-mount) settings to timestamped CSV/JSON files.

Reference only - DF.local is being built fresh, not migrated. This just
gives you the old state to compare against / manually recreate from.
#>

[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
Import-Module ActiveDirectory
$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Get-Content "$RepoRoot\config.json" -Raw | ConvertFrom-Json
Start-DomechLog -ScriptName $MyInvocation.MyCommand.Name -LogRoot $Config.Paths.LogsRoot

$stamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$outRoot = "C:\01_matrix\Scratch\OldServerExport_$stamp"
New-Item -ItemType Directory -Path $outRoot -Force | Out-Null
Write-Host "Exporting to $outRoot" -ForegroundColor Cyan

# ---- Users ----
Write-Host "Exporting AD users..." -ForegroundColor Cyan
Get-ADUser -Filter * -Properties DisplayName,EmailAddress,Enabled,LastLogonDate,Department,Title,MemberOf,ScriptPath,HomeDirectory,HomeDrive |
    Select-Object SamAccountName,Name,DisplayName,EmailAddress,Enabled,LastLogonDate,Department,Title,ScriptPath,HomeDirectory,HomeDrive,
        @{N='MemberOf';E={($_.MemberOf | ForEach-Object { ($_ -split ',')[0] -replace 'CN=' }) -join ';'}} |
    Export-Csv "$outRoot\Users.csv" -NoTypeInformation

# ---- Groups + membership ----
Write-Host "Exporting AD groups and membership..." -ForegroundColor Cyan
$groupRows = foreach ($g in Get-ADGroup -Filter * -Properties Description) {
    $members = (Get-ADGroupMember -Identity $g -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName) -join ';'
    [PSCustomObject]@{ GroupName = $g.Name; Description = $g.Description; Scope = $g.GroupScope; Members = $members }
}
$groupRows | Export-Csv "$outRoot\Groups.csv" -NoTypeInformation

# ---- Computers ----
Write-Host "Exporting AD computers..." -ForegroundColor Cyan
Get-ADComputer -Filter * -Properties OperatingSystem,OperatingSystemVersion,LastLogonDate,Enabled |
    Select-Object Name,OperatingSystem,OperatingSystemVersion,LastLogonDate,Enabled |
    Export-Csv "$outRoot\Computers.csv" -NoTypeInformation

# ---- OUs ----
Write-Host "Exporting OU structure..." -ForegroundColor Cyan
Get-ADOrganizationalUnit -Filter * | Select-Object Name,DistinguishedName |
    Export-Csv "$outRoot\OUs.csv" -NoTypeInformation

# ---- Shares: definitions, share-level permissions, NTFS ACLs ----
Write-Host "Exporting shares, permissions, and NTFS ACLs..." -ForegroundColor Cyan
# NOTE: this server shares folders as hidden ($) shares (Common$, Tally$, etc).
# Use the .Special flag (true only for OS auto-shares like C$/ADMIN$/IPC$) to
# filter those out instead of excluding anything ending in $.
$shares = Get-SmbShare | Where-Object { -not $_.Special -and $_.Name -notin @('NETLOGON','SYSVOL') }
$shares | Select-Object Name,Path,Description | Export-Csv "$outRoot\Shares.csv" -NoTypeInformation

$shareAclRows = foreach ($s in $shares) {
    Get-SmbShareAccess -Name $s.Name | Select-Object @{N='ShareName';E={$s.Name}},AccountName,AccessControlType,AccessRight
}
$shareAclRows | Export-Csv "$outRoot\ShareLevelPermissions.csv" -NoTypeInformation

$ntfsAclRows = foreach ($s in $shares) {
    if (Test-Path $s.Path) {
        (Get-Acl $s.Path).Access | Select-Object @{N='ShareName';E={$s.Name}},@{N='Path';E={$s.Path}},
            IdentityReference,FileSystemRights,AccessControlType,IsInherited
    }
}
$ntfsAclRows | Export-Csv "$outRoot\NTFS_ACLs_ShareRoots.csv" -NoTypeInformation

# ---- GPOs and drive-map (auto-mount) settings ----
Write-Host "Exporting GPOs and drive mappings..." -ForegroundColor Cyan
try {
    Import-Module GroupPolicy -ErrorAction Stop
    Get-GPO -All | Select-Object DisplayName,Id,GpoStatus,CreationTime,ModificationTime |
        Export-Csv "$outRoot\GPOs.csv" -NoTypeInformation

    # Group Policy Preferences drive maps live as Drives.xml under SYSVOL per GPO
    $domain = (Get-ADDomain).DNSRoot
    $driveMapFiles = Get-ChildItem "\\$domain\SYSVOL\$domain\Policies" -Recurse -Filter "Drives.xml" -ErrorAction SilentlyContinue
    if ($driveMapFiles) {
        New-Item -ItemType Directory -Path "$outRoot\DriveMaps" -Force | Out-Null
        foreach ($f in $driveMapFiles) {
            $gpoGuid = ($f.FullName -split '\\Policies\\')[1].Split('\')[0]
            Copy-Item $f.FullName "$outRoot\DriveMaps\Drives_$gpoGuid.xml"
        }
        Write-Host "  Found $($driveMapFiles.Count) GPO drive-map file(s) - copied to $outRoot\DriveMaps" -ForegroundColor Green
    } else {
        Write-Host "  No GPO Preference drive maps found (mapped drives may be via logon script instead - check Users.csv ScriptPath column)." -ForegroundColor Yellow
    }
} catch {
    Write-Host "  GroupPolicy module unavailable - skipped GPO export." -ForegroundColor Yellow
}

# ---- Logon script contents, if referenced via AD ScriptPath ----
$scriptUsers = Import-Csv "$outRoot\Users.csv" | Where-Object { $_.ScriptPath }
New-Item -ItemType Directory -Path "$outRoot\LogonScripts" -Force | Out-Null
if ($scriptUsers) {
    $domain = (Get-ADDomain).DNSRoot
    $scriptUsers.ScriptPath | Sort-Object -Unique | ForEach-Object {
        $src = "\\$domain\NETLOGON\$_"
        if (Test-Path $src) { Copy-Item $src "$outRoot\LogonScripts\" -ErrorAction SilentlyContinue }
    }
}

# ---- Logon-style scripts sitting loose on desktops (not referenced by AD) ----
Write-Host "Checking desktops for loose .bat/.vbs/.cmd/.ps1 scripts (common place for manual drive-map scripts)..." -ForegroundColor Cyan
$desktopPaths = @("C:\Users\Public\Desktop") + (Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName "Desktop" } | Where-Object { Test-Path $_ })
foreach ($d in $desktopPaths | Select-Object -Unique) {
    Get-ChildItem $d -Include *.bat,*.vbs,*.cmd,*.ps1 -File -ErrorAction SilentlyContinue | ForEach-Object {
        $destName = "{0}_{1}" -f (Split-Path $d -Parent | Split-Path -Leaf), $_.Name
        Copy-Item $_.FullName (Join-Path "$outRoot\LogonScripts" $destName) -ErrorAction SilentlyContinue
    }
}

Write-Host "`nDone. Review the CSVs in $outRoot before recreating anything on DF.local." -ForegroundColor Green
Write-Host "Mapped drives may show up in: DriveMaps\*.xml (GPO), LogonScripts\*.* (net use scripts, incl. ones found on desktops), or Users.csv HomeDrive/HomeDirectory columns." -ForegroundColor Green

# ---- Zip the whole export ----
Write-Host "Zipping export..." -ForegroundColor Cyan
$zipPath = "$outRoot.zip"
Compress-Archive -Path "$outRoot\*" -DestinationPath $zipPath -Force
Write-Host "Zipped to $zipPath" -ForegroundColor Green
