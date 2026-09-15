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
foreach ($d in $Config.Departments) {
    $unc = "\\$server\$($d.ShareName)"
    $canSee = $false
    try { $null = Get-ChildItem $unc -ErrorAction Stop; $canSee = $true } catch { }

    if (-not $canSee) {
        Write-DomechLog "   $($d.FolderName.PadRight(26)) no access to the share itself" -Level Info
        continue
    }
    Write-DomechLog "   $($d.FolderName.PadRight(26)) share opens" -Level Success

    foreach ($sub in $d.SubDepartments) {
        $subUnc = Join-Path $unc $sub.FolderName
        $listed = $false
        $opened = $false
        try { $listed = (Get-ChildItem $unc -Directory -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -eq $sub.FolderName }).Count -gt 0 } catch { }
        try { $null = Get-ChildItem $subUnc -ErrorAction Stop; $opened = $true } catch { }

        $verdict = if ($opened)      { "CAN OPEN" }
                   elseif ($listed)  { "visible but cannot open" }
                   else              { "hidden - no access" }
        $level   = if ($opened) { "Error" } else { "Success" }

        # Only the person's own sub-department should be openable, so flag the
        # other one being reachable rather than quietly listing it.
        $shouldHave = $me -and ($me.Groups -contains $sub.GroupName -or $me.Groups -contains $d.GroupName)
        if ($opened -and $shouldHave) { $level = "Success"; $verdict = "CAN OPEN (expected)" }
        elseif ($opened)              { $level = "Error";   $verdict = "CAN OPEN - NOT EXPECTED" }
        else                          { $level = "Success" }

        Write-DomechLog "      \$($sub.FolderName.PadRight(20)) $verdict" -Level $level
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
