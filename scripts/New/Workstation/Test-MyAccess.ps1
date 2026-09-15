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

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-DomechLog "WARNING: this session is elevated. Administrators can open everything, so these results do not reflect a normal user's access. Run it without elevation, signed in as the person concerned." -Level Warning
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
