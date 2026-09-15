<#
Domech Fabricators - what can I actually see and open

Run ON the user's own PC, SIGNED IN AS THAT PERSON. Do not run it elevated as
an administrator: that reports on the administrator's access, not theirs, and
an administrator can open everything.

Read-only. It opens nothing it does not report on and writes nothing.

Every other check has been made on the server, from Active Directory and the
folder permissions. This measures the thing that actually matters - what this
person's Windows session can reach right now.

The two are allowed to disagree. Windows decides access from the groups stamped
into the session at sign-in, not from what Active Directory says this moment,
and it keeps network connections to a share alive across permission changes.
So somebody signed in before a change keeps their old access until they sign
out and back in. That is the usual reason the server says one thing and the
person at the desk sees another.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

$server = $env:COMPUTERNAME
try { $server = (Get-ADDomainController -Discover -ErrorAction SilentlyContinue).HostName } catch { }
if (-not $server -or $server -eq $env:COMPUTERNAME) { $server = "DOMECH" }
$nb = $Config.Domain.NetbiosName

Write-DomechLog "===== Access check for $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME =====" -Level Info

# Refuse outright when run by an administrator, rather than warning and then
# printing results anyway. Domain Admins has Full Control of every folder by
# design, so an admin session opens both subfolders and the report fills with
# alarming "NOT EXPECTED" lines that are simply describing correct behaviour.
# A diagnostic that produces convincing wrong answers when pointed at the wrong
# account is worse than no diagnostic.
$groupSids = ([Security.Principal.WindowsIdentity]::GetCurrent()).Groups.Value
$isDomainAdmin = @($groupSids | Where-Object { $_ -like 'S-1-5-21-*-512' }).Count -gt 0
$isLocalAdmin  = $groupSids -contains 'S-1-5-32-544'

if ($isDomainAdmin -or $isLocalAdmin) {
    Write-DomechLog "" -Level Info
    Write-DomechLog "This is running as $env:USERDOMAIN\$env:USERNAME, which is an administrator." -Level Error
    Write-DomechLog "" -Level Info
    Write-DomechLog "Administrators have full control of every folder, so this would report that" -Level Error
    Write-DomechLog "everything opens - which is correct for an administrator and says nothing at" -Level Error
    Write-DomechLog "all about the person you are checking. Stopping rather than giving you an" -Level Error
    Write-DomechLog "answer that looks meaningful and is not." -Level Error
    Write-DomechLog "" -Level Info
    Write-DomechLog "To check somebody's real access:" -Level Warning
    Write-DomechLog "  1. Sign out of this account completely" -Level Warning
    Write-DomechLog "  2. Sign in as that person, with their own username and password" -Level Warning
    Write-DomechLog "  3. Open PowerShell NORMALLY - not 'Run as administrator'" -Level Warning
    Write-DomechLog "  4. Run the toolkit link and choose this option again" -Level Warning
    Write-DomechLog "" -Level Info
    Write-DomechLog "Checking from an admin session is also the usual reason somebody appears to" -Level Warning
    Write-DomechLog "have access they should not - the folder opened for the administrator doing" -Level Warning
    Write-DomechLog "the checking, not for them." -Level Warning
    exit 1
}

# ---- 1. the groups in THIS session, which is what Windows actually uses ----
Write-DomechLog "" -Level Info
Write-DomechLog "1. Groups in this sign-in session" -Level Info
Write-DomechLog "   (Stamped in at sign-in. If these differ from the server, this person needs to sign out and back in.)" -Level Info
$tokenGroups = @()
foreach ($g in ([Security.Principal.WindowsIdentity]::GetCurrent()).Groups) {
    try {
        $n = $g.Translate([Security.Principal.NTAccount]).Value
        if ($n -like "$nb\*") { $tokenGroups += ($n -replace "^$nb\\", "") }
    } catch { }
}
if ($tokenGroups) {
    $tokenGroups | Sort-Object | ForEach-Object { Write-DomechLog "   $_" -Level Success }
} else {
    Write-DomechLog "   none found - is this PC actually joined to the domain?" -Level Warning
}

# ---- 2. what config.json expects ----
$me = $Config.Users | Where-Object { $_.Sam -eq $env:USERNAME }
if ($me) {
    Write-DomechLog "" -Level Info
    Write-DomechLog "2. What config.json expects for $($me.Sam)" -Level Info
    Write-DomechLog "   $($me.Groups -join ', ')" -Level Info
    $stale = $tokenGroups | Where-Object { $me.Groups -notcontains $_ -and $_ -ne 'Domain Users' }
    if ($stale) {
        Write-DomechLog "   IN THIS SESSION BUT NOT IN CONFIG: $($stale -join ', ')" -Level Error
        Write-DomechLog "   This session is carrying access it should not have. Sign out completely and back in." -Level Error
    }
}

# ---- 3. what can actually be opened ----
Write-DomechLog "" -Level Info
Write-DomechLog "3. What this session can actually open" -Level Info
Write-DomechLog "   (Item counts matter: connecting to a share and seeing NOTHING is very" -Level Info
Write-DomechLog "    different from actually reading it, and both look like success.)" -Level Info

function Test-RealAccess {
    <#
    Distinguishes three outcomes that a simple success/fail check confuses:
      denied      - cannot get in at all
      no content  - got in but can read nothing, which is what correct
                    permissions look like from the outside
      real access - can list items AND open one to read
    Reading a file is the only proof of genuine access. An empty listing is
    ambiguous: it looks identical whether the folder is empty or everything in
    it is hidden.
    #>
    param([string]$Path)
    $r = [ordered]@{ Reachable = $false; Items = 0; CanReadFile = $false; Error = $null }
    try {
        $items = @(Get-ChildItem $Path -Force -ErrorAction Stop)
        $r.Reachable = $true
        $r.Items = $items.Count
        $file = $items | Where-Object { -not $_.PSIsContainer } | Select-Object -First 1
        if ($file) {
            try {
                $fs = [System.IO.File]::OpenRead($file.FullName)
                $null = $fs.ReadByte()
                $fs.Close()
                $r.CanReadFile = $true
            } catch { }
        }
    } catch {
        $r.Error = $_.Exception.Message
    }
    return $r
}

foreach ($d in $Config.Departments) {
    $unc = "\\$server\$($d.ShareName)"
    $shouldHaveShare = $me -and (
        $me.Groups -contains $d.GroupName -or
        @($d.SubDepartments | Where-Object { $me.Groups -contains $_.GroupName }).Count -gt 0
    )

    $res = Test-RealAccess -Path $unc
    if (-not $res.Reachable) {
        Write-DomechLog "   $($d.FolderName.PadRight(26)) no access to the share - correct" -Level Success
    } else {
        $detail = "$($res.Items) item(s)$(if ($res.CanReadFile) { ', and can read a file' })"
        if ($shouldHaveShare) {
            Write-DomechLog "   $($d.FolderName.PadRight(26)) opens - $detail (expected)" -Level Success
        } elseif ($res.Items -eq 0) {
            Write-DomechLog "   $($d.FolderName.PadRight(26)) connects but sees nothing - $detail. Not real access." -Level Info
        } else {
            Write-DomechLog "   $($d.FolderName.PadRight(26)) OPENS AND SEES CONTENT - $detail  <- NOT EXPECTED" -Level Error
        }
    }

    foreach ($sub in $d.SubDepartments) {
        $subUnc = Join-Path $unc $sub.FolderName
        $listedInParent = $false
        try {
            $listedInParent = @(Get-ChildItem $unc -Directory -ErrorAction SilentlyContinue |
                                Where-Object { $_.Name -eq $sub.FolderName }).Count -gt 0
        } catch { }

        $sr = Test-RealAccess -Path $subUnc
        $shouldHave = $me -and ($me.Groups -contains $sub.GroupName -or $me.Groups -contains $d.GroupName)

        if (-not $sr.Reachable) {
            $state = if ($listedInParent) { "listed but cannot open - correct" } else { "hidden - correct" }
            Write-DomechLog "      \$($sub.FolderName.PadRight(20)) $state" -Level Success
        } elseif ($shouldHave) {
            Write-DomechLog "      \$($sub.FolderName.PadRight(20)) opens - $($sr.Items) item(s)$(if ($sr.CanReadFile) { ', can read a file' }) (expected)" -Level Success
        } elseif ($sr.Items -eq 0) {
            Write-DomechLog "      \$($sub.FolderName.PadRight(20)) connects but sees nothing (0 items). Not real access - permissions are holding." -Level Info
        } else {
            Write-DomechLog "      \$($sub.FolderName.PadRight(20)) OPENS AND SEES $($sr.Items) ITEM(S)$(if ($sr.CanReadFile) { ', CAN READ A FILE' })  <- NOT EXPECTED" -Level Error
        }
    }
}

# ---- 4. live connections to the server ----
# A connection opened before a permission change keeps the old access until it
# is dropped, which is why signing out is what fixes it rather than a refresh.
Write-DomechLog "" -Level Info
Write-DomechLog "4. Existing connections to the server" -Level Info
$sessions = net use 2>&1 | Select-String -Pattern "\\\\" | ForEach-Object { $_.ToString().Trim() }
if ($sessions) {
    $sessions | ForEach-Object { Write-DomechLog "   $_" -Level Info }
    Write-DomechLog "   These were opened earlier and keep whatever access they had then." -Level Warning
} else {
    Write-DomechLog "   none" -Level Info
}

Write-DomechLog "" -Level Info
Write-DomechLog "===== Done =====" -Level Success
Write-DomechLog "If anything above says NOT EXPECTED, sign out completely (not lock, not restart) and run this again. If it still says it after a clean sign-in, the server needs another look." -Level Warning
