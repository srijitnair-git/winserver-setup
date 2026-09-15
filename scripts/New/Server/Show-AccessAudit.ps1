<#
Domech Fabricators - who actually has access to what

Run on the DC, elevated. Read-only: it reports, it changes nothing.

Compares what config.json says against what Active Directory actually holds.
They drift apart because the setup only ever ADDS people to groups - it has
never removed anyone - so a membership granted at any point in the past stays
forever, even after config.json stops listing it.

That matters most for the shared department. Being in the parent
SalaryWagesPurchase group grants both subfolders; being in Purchase or
SalaryWages alone grants only that one. Someone left in the parent group sees
everything, whatever config.json says.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot
Assert-DomechAD

# Every group this toolkit manages, so unrelated AD groups are ignored.
$managed = @()
foreach ($d in $Config.Departments) {
    $managed += $d.GroupName
    foreach ($sub in $d.SubDepartments) { $managed += $sub.GroupName }
}
$managed += $Config.Workstation.GroupName
if ($Config.PrinterGroups) { $managed += $Config.PrinterGroups.PSObject.Properties.Name }

Write-DomechLog "Groups this toolkit manages: $($managed -join ', ')" -Level Info
Write-DomechLog "" -Level Info

$problems = 0

foreach ($u in $Config.Users) {
    $adUser = Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue
    if (-not $adUser) {
        Write-DomechLog "$($u.Sam) : no account in AD" -Level Warning
        $problems++
        continue
    }

    $actual = @()
    try {
        $actual = Get-ADPrincipalGroupMembership -Identity $adUser -ErrorAction Stop |
            Select-Object -ExpandProperty Name | Where-Object { $managed -contains $_ }
    } catch {
        Write-DomechLog "$($u.Sam) : could not read group membership - $($_.Exception.Message)" -Level Warning
        $problems++
        continue
    }

    # Printer groups are listed separately in config, so count them as expected.
    $expected = @($u.Groups)
    if ($Config.PrinterGroups) {
        foreach ($pg in $Config.PrinterGroups.PSObject.Properties.Name) {
            if ($Config.PrinterGroups.$pg -contains $u.Sam) { $expected += $pg }
        }
    }

    $extra   = $actual   | Where-Object { $expected -notcontains $_ }
    $missing = $expected | Where-Object { $actual   -notcontains $_ }

    if (-not $extra -and -not $missing) {
        Write-DomechLog "$($u.Sam.PadRight(10)) OK   $($actual -join ', ')" -Level Success
        continue
    }

    $problems++
    Write-DomechLog "$($u.Sam.PadRight(10)) MISMATCH" -Level Warning
    Write-DomechLog "    config says : $($expected -join ', ')" -Level Info
    Write-DomechLog "    AD actually : $($actual -join ', ')" -Level Info
    if ($extra) {
        Write-DomechLog "    IN AD BUT NOT IN CONFIG: $($extra -join ', ')  <- extra access nobody asked for" -Level Error
    }
    if ($missing) {
        Write-DomechLog "    IN CONFIG BUT NOT IN AD: $($missing -join ', ')  <- access they should have and do not" -Level Warning
    }
}

# Call out the specific case that makes a shared folder leak.
Write-DomechLog "" -Level Info
Write-DomechLog "===== Parent-and-sub overlaps =====" -Level Info
foreach ($d in $Config.Departments) {
    if (-not $d.SubDepartments) { continue }
    $parentMembers = @()
    try {
        $parentMembers = Get-ADGroupMember -Identity $d.GroupName -ErrorAction Stop |
            Where-Object { $_.objectClass -eq 'user' } | Select-Object -ExpandProperty SamAccountName
    } catch { continue }

    foreach ($sub in $d.SubDepartments) {
        $subMembers = @()
        try {
            $subMembers = Get-ADGroupMember -Identity $sub.GroupName -ErrorAction Stop |
                Where-Object { $_.objectClass -eq 'user' } | Select-Object -ExpandProperty SamAccountName
        } catch { continue }

        $both = $subMembers | Where-Object { $parentMembers -contains $_ }
        if ($both) {
            $problems++
            Write-DomechLog "$($both -join ', ') are in BOTH '$($d.GroupName)' and '$($sub.GroupName)'." -Level Error
            Write-DomechLog "   The parent group grants the whole '$($d.FolderName)' folder, so they see every subfolder - the sub-group restriction has no effect for them." -Level Error
        }
    }
    Write-DomechLog "'$($d.GroupName)' (whole folder): $(if ($parentMembers) { $parentMembers -join ', ' } else { 'nobody' })" -Level Info
    foreach ($sub in $d.SubDepartments) {
        $m = @()
        try { $m = Get-ADGroupMember -Identity $sub.GroupName -ErrorAction SilentlyContinue |
                Where-Object { $_.objectClass -eq 'user' } | Select-Object -ExpandProperty SamAccountName } catch {}
        Write-DomechLog "'$($sub.GroupName)' ($($sub.FolderName) only): $(if ($m) { $m -join ', ' } else { 'nobody' })" -Level Info
    }
}

# ---- who the FOLDERS actually let in ----
# Group membership being right does not mean access is right. A folder can
# carry an explicit permission of its own - typically left behind by a data
# migration - that grants people the group model never intended. That is
# invisible from the group side and is exactly the case where one person sees
# a subfolder another cannot.
Write-DomechLog "" -Level Info
Write-DomechLog "===== Permissions ON THE FOLDERS =====" -Level Info
Write-DomechLog "(Explicit entries only. Inherited ones come from the parent and are expected.)" -Level Info

$expectedEverywhere = @("NT AUTHORITY\SYSTEM", "BUILTIN\Administrators", "CREATOR OWNER", "$($Config.Domain.NetbiosName)\Domain Admins")

function Show-FolderAcl {
    param([string]$Path, [string[]]$Allowed, [string]$Label)
    if (-not (Test-Path $Path)) {
        Write-DomechLog "  $Label : folder missing - $Path" -Level Warning
        return 0
    }
    $acl = Get-Acl $Path
    $explicit = $acl.Access | Where-Object { -not $_.IsInherited }
    Write-DomechLog "  $Label" -Level Info
    Write-DomechLog "    inheritance blocked: $($acl.AreAccessRulesProtected)" -Level Info
    $bad = 0
    foreach ($ace in $explicit) {
        $who = $ace.IdentityReference.Value
        $ok = ($Allowed -contains $who) -or ($expectedEverywhere -contains $who)
        if ($ok) {
            Write-DomechLog "    ok        $who = $($ace.FileSystemRights)" -Level Success
        } else {
            Write-DomechLog "    UNWANTED  $who = $($ace.FileSystemRights)   <- grants access the groups never intended" -Level Error
            $bad++
        }
    }
    if (-not $explicit) { Write-DomechLog "    (no explicit entries - inherits everything)" -Level Info }
    return $bad
}

$nb = $Config.Domain.NetbiosName
foreach ($d in $Config.Departments) {
    $path = Join-Path $Config.Paths.DataRoot $d.FolderName
    $allowed = @("$nb\$($d.GroupName)") + ($d.SubDepartments | ForEach-Object { "$nb\$($_.GroupName)" })
    $problems += Show-FolderAcl -Path $path -Allowed $allowed -Label "$($d.FolderName)  [$($d.ShareName)]"

    foreach ($sub in $d.SubDepartments) {
        $subPath = Join-Path $path $sub.FolderName
        # Only its own sub-group belongs here explicitly. The parent group
        # reaches it by inheritance, which is intended.
        $problems += Show-FolderAcl -Path $subPath -Allowed @("$nb\$($sub.GroupName)") -Label "   \$($sub.FolderName)"
    }
}

# ---- is access-based enumeration actually on ----
# This is what hides a subfolder someone has no rights to. With it off they
# still cannot open the folder, but they SEE it listed - which looks exactly
# like a permissions failure and is the usual reason for "why can they see
# that folder" when the permissions themselves are correct.
Write-DomechLog "" -Level Info
Write-DomechLog "===== Share settings =====" -Level Info
foreach ($d in $Config.Departments) {
    $share = Get-SmbShare -Name $d.ShareName -ErrorAction SilentlyContinue
    if (-not $share) {
        Write-DomechLog "  $($d.ShareName) : share does not exist" -Level Error
        $problems++
        continue
    }
    if ($d.SubDepartments) {
        if ($share.FolderEnumerationMode -eq 'AccessBased') {
            Write-DomechLog "  $($d.ShareName) : access-based enumeration ON - people only see subfolders they can open" -Level Success
        } else {
            Write-DomechLog "  $($d.ShareName) : access-based enumeration is $($share.FolderEnumerationMode) - EVERYONE SEES EVERY SUBFOLDER LISTED, even ones they cannot open. This alone explains the symptom." -Level Error
            $problems++
        }
    } else {
        Write-DomechLog "  $($d.ShareName) : $($share.FolderEnumerationMode) (no subfolders, so it does not matter)" -Level Info
    }
}

# ---- who can actually open each subfolder ----
# Computed from AD membership against the folder's real permissions, so it does
# not depend on anybody being signed in to test it.
Write-DomechLog "" -Level Info
Write-DomechLog "===== Who can actually open each subfolder =====" -Level Info
foreach ($d in $Config.Departments) {
    if (-not $d.SubDepartments) { continue }
    $path = Join-Path $Config.Paths.DataRoot $d.FolderName

    foreach ($sub in $d.SubDepartments) {
        $subPath = Join-Path $path $sub.FolderName
        if (-not (Test-Path $subPath)) { continue }
        $acl = Get-Acl $subPath
        $granted = @()

        foreach ($u in $Config.Users) {
            $ids = @("$nb\$($u.Sam)")
            try {
                $ids += Get-ADPrincipalGroupMembership -Identity $u.Sam -ErrorAction Stop |
                    ForEach-Object { "$nb\$($_.Name)" }
            } catch { }

            $canOpen = $acl.Access | Where-Object {
                $_.AccessControlType -eq 'Allow' -and
                ($ids -contains $_.IdentityReference.Value) -and
                ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::ReadData)
            }
            if ($canOpen) { $granted += $u.Sam }
        }
        Write-DomechLog "  $($sub.FolderName) : $(if ($granted) { $granted -join ', ' } else { 'nobody' })" -Level Info
    }
}

Write-DomechLog "" -Level Info
if ($problems -eq 0) {
    Write-DomechLog "Everything matches config.json." -Level Success
} else {
    Write-DomechLog "$problems thing(s) to look at above." -Level Warning
    Write-DomechLog "To make AD match config.json exactly, run 'Fix folder permissions and shares' - it now removes memberships config.json no longer lists, as well as adding missing ones." -Level Info
}
