<#
Domech Fabricators - deploy shared printers to users

Run on the DC, elevated. Maps printers per security group using Group Policy
Preferences, the same mechanism as the drive mappings - so a person gets the
printers for the groups they are in, on any PC they sign into.

BEFORE THIS WORKS the printers must be installed on this server and SHARED.
Run Find-NetworkPrinters.ps1 first to see what exists, then fill in
config.json's Printers list:

  "Printers": [
    { "Name": "Office Ricoh", "Path": "\\\\DOMECH\\RicohMP2014",
      "Groups": ["Common"], "Default": true }
  ]

Groups lists which security groups receive it. An empty Groups list, or no
Groups key, means everyone. Default:true makes it that person's default
printer. Only one printer should be Default per group.
#>

Import-Module GroupPolicy
Import-Module ActiveDirectory

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot
Assert-DomechAD

$GpoName  = $Config.GPO.PrinterGpoName
if (-not $GpoName) { $GpoName = "Domech - Printers" }
$domain   = (Get-ADDomain).DNSRoot
$domainDN = (Get-ADDomain).DistinguishedName

$printers = $Config.Printers
if (-not $printers -or $printers.Count -eq 0) {
    Write-DomechLog "config.json's Printers list is empty - nothing to deploy." -Level Warning
    Write-DomechLog "Run 'Find printers on the network' first to see what exists, install and share them on this server, then add them to config.json." -Level Info
    exit 0
}

# Warn early rather than deploying a printer nobody can reach. A path can point
# at this server or at a workstation hosting a USB printer, so only check the
# ones that claim to be here.
$thisHost = $env:COMPUTERNAME
foreach ($p in $printers) {
    $pathHost  = ($p.Path -split '\\') | Where-Object { $_ } | Select-Object -First 1
    $shareName = ($p.Path -split '\\')[-1]

    if ($pathHost -ne $thisHost) {
        Write-DomechLog "'$($p.Name)' -> $($p.Path) : hosted on $pathHost, not this server. That PC must be switched on for anyone to print to it." -Level Warning
        continue
    }

    $local = Get-Printer -Name $shareName -ErrorAction SilentlyContinue
    if (-not $local) {
        $local = Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.ShareName -eq $shareName }
    }
    if (-not $local) {
        Write-DomechLog "'$($p.Name)' -> $($p.Path) : no matching shared printer found on this server. Users will get an error until it is installed and shared here - run 'Install and share the network printer' first." -Level Warning
    } elseif (-not $local.Shared) {
        Write-DomechLog "'$($p.Name)' is installed on this server but NOT shared - share it or users cannot connect." -Level Warning
    }
}

# ---- printer access groups ----
# These exist only to decide who gets which printer, and are kept in sync with
# config.json on every run - so access is managed here on the server rather
# than by touching individual PCs.
$groupsOU = "OU=Groups,OU=Domech,$domainDN"
if ($Config.PrinterGroups) {
    foreach ($groupName in $Config.PrinterGroups.PSObject.Properties.Name) {
        $members = $Config.PrinterGroups.$groupName
        if (-not (Get-ADGroup -Filter "Name -eq '$groupName'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $groupName -GroupScope Global -GroupCategory Security -Path $groupsOU
            Write-DomechLog "Created printer group '$groupName'." -Level Success
        }
        foreach ($sam in $members) {
            if (-not (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue)) {
                Write-DomechLog "  '$sam' does not exist - not added to $groupName." -Level Warning
                continue
            }
            Add-ADGroupMember -Identity $groupName -Members $sam -ErrorAction SilentlyContinue
        }
        # Remove anyone no longer listed, so config.json is the single source of
        # truth rather than only ever adding people.
        $current = Get-ADGroupMember -Identity $groupName -ErrorAction SilentlyContinue |
            Where-Object { $_.objectClass -eq 'user' }
        foreach ($existing in $current) {
            if ($members -notcontains $existing.SamAccountName) {
                Remove-ADGroupMember -Identity $groupName -Members $existing.SamAccountName -Confirm:$false -ErrorAction SilentlyContinue
                Write-DomechLog "  Removed '$($existing.SamAccountName)' from $groupName - no longer listed in config.json." -Level Warning
            }
        }
        Write-DomechLog "Printer group '$groupName': $($members -join ', ')" -Level Success
    }
}

$gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $gpo) { $gpo = New-GPO -Name $GpoName }
New-GPLink -Name $GpoName -Target $domainDN -ErrorAction SilentlyContinue | Out-Null

$gpoPath = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id)}\User\Preferences\Printers"
New-Item -ItemType Directory -Path $gpoPath -Force | Out-Null

$entries = foreach ($p in $printers) {
    # Escape everything going into an attribute. An unescaped "&" in a printer
    # name silently truncates the file and every printer after it is lost -
    # exactly what an ampersand in a folder name did to the drive mappings.
    $nameXml = [System.Security.SecurityElement]::Escape($p.Name)
    $pathXml = [System.Security.SecurityElement]::Escape($p.Path)
    $default = if ($p.Default) { "1" } else { "0" }

    # Filter by group, by named user, or both. Named users suit a printer that
    # belongs to one person; a group suits one shared between several.
    $filterLines = @()

    foreach ($g in ($p.Groups | Where-Object { $_ })) {
        $adGroup = Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue
        if (-not $adGroup) {
            Write-DomechLog "  Group '$g' does not exist - '$($p.Name)' will not be filtered to it." -Level Warning
            continue
        }
        $gXml = [System.Security.SecurityElement]::Escape($g)
        $filterLines += "      <FilterGroup bool=`"OR`" not=`"0`" name=`"$gXml`" sid=`"$($adGroup.SID.Value)`" userContext=`"1`" primaryGroup=`"0`" localGroup=`"0`"/>"
    }

    foreach ($u in ($p.Users | Where-Object { $_ })) {
        $adUser = Get-ADUser -Filter "SamAccountName -eq '$u'" -ErrorAction SilentlyContinue
        if (-not $adUser) {
            Write-DomechLog "  User '$u' does not exist - '$($p.Name)' will not be filtered to them." -Level Warning
            continue
        }
        $uXml = [System.Security.SecurityElement]::Escape("$($Config.Domain.NetbiosName)\$u")
        $filterLines += "      <FilterUser bool=`"OR`" not=`"0`" name=`"$uXml`" sid=`"$($adUser.SID.Value)`" userContext=`"1`"/>"
    }

    $filter = ""
    if ($filterLines.Count -gt 0) {
        $filter = "    <Filters>`n$($filterLines -join "`n")`n    </Filters>`n"
    }

    $who = if ($p.Groups -or $p.Users) {
        (@($p.Groups) + @($p.Users) | Where-Object { $_ }) -join ', '
    } else { 'everyone' }
    Write-DomechLog "  $($p.Name) -> $($p.Path)$(if ($p.Default) { ' (default)' }) for: $who" -Level Info

    @"
  <SharedPrinter clsid="{9A5E9697-9095-436d-A0EE-4D128FDFBCE5}" name="$nameXml" status="$nameXml" image="0" changed="$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')" uid="{$([guid]::NewGuid())}">
    <Properties action="U" comment="" path="$pathXml" location="" default="$default" skipLocal="0" deleteAll="0" persistent="0" deleteMaps="0" port=""/>
$filter  </SharedPrinter>
"@
}

$printersXml = @"
<?xml version="1.0" encoding="utf-8"?>
<Printers clsid="{1F577D12-3D1B-471e-A1B7-060317597B9C}">
$($entries -join "`n")
</Printers>
"@

# Prove it parses before publishing. A malformed preferences file is ignored
# from the bad character onwards with no error anywhere, so it gets caught here
# rather than by someone wondering why half their printers vanished.
try {
    $parsed = [xml]$printersXml
    $count = $parsed.Printers.SharedPrinter.Count
    $printersXml | Out-File "$gpoPath\Printers.xml" -Encoding UTF8
    Write-DomechLog "Printers.xml written and validated - $count printer entries." -Level Success
} catch {
    Write-DomechLog "REFUSING TO WRITE Printers.xml - generated file is not valid XML: $($_.Exception.Message)" -Level Error
    Write-DomechLog "Existing printer deployment left untouched. Usually a printer name in config.json containing a character that is special in XML." -Level Error
    throw
}

# Register the Printers extension on the user side and bump the version, or
# clients skip the file entirely with nothing logged.
$printersExtensionPair = "[{5794DAFD-BE60-433f-88A2-1A31939AC01F}{BC75B1ED-5833-4858-9BB8-CBF0B166DF9D}]"
$gpoAdPath   = "CN=Policies,CN=System,$domainDN"
$gpoAdObject = Get-ADObject -Filter "displayName -eq '$GpoName'" -SearchBase $gpoAdPath -Properties gPCUserExtensionNames, versionNumber
if ($gpoAdObject) {
    $ext = $gpoAdObject.gPCUserExtensionNames
    if (-not $ext -or $ext -notlike "*BC75B1ED*") {
        Set-ADObject -Identity $gpoAdObject.DistinguishedName -Replace @{ gPCUserExtensionNames = "$ext$printersExtensionPair" }
        Write-DomechLog "Printers extension registered on '$GpoName'." -Level Success
    }
    $newVersion = [int]$gpoAdObject.versionNumber + 65537
    Set-ADObject -Identity $gpoAdObject.DistinguishedName -Replace @{ versionNumber = $newVersion }
    $gptIni = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id)}\gpt.ini"
    (Get-Content $gptIni) -replace '^Version=\d+', "Version=$newVersion" | Set-Content $gptIni
    Write-DomechLog "GPO version bumped to $newVersion so clients reprocess it." -Level Success
} else {
    Write-DomechLog "Could not find the '$GpoName' AD object - printers will NOT deploy until $printersExtensionPair is added to gPCUserExtensionNames by hand in ADSI Edit." -Level Error
}

# Admins should not inherit staff printer mappings.
Block-DomainAdminsFromGPO -GpoName $GpoName -DomainDN $domainDN

Write-DomechLog "" -Level Info
Write-DomechLog "Done. Printers appear after the user signs out and back in." -Level Success
