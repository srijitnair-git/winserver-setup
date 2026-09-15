<#
Domech Fabricators - stop this PC signing in to the server as somebody else

Run ON the affected PC, SIGNED IN AS THE PERSON WHO USES IT. Not elevated -
elevating clears the administrator's saved credentials instead of theirs, which
is the opposite of what is wanted.

Windows allows one identity per server per session. If anybody ever connected
to the server from this PC and ticked "remember my credentials" - during setup,
or over a remote session - those credentials are stored against the server and
every later connection from this machine uses them. The person sitting here
then reads whatever THAT account can read, no matter what their own group
membership says, and every permission on the server is correct throughout. It
cannot be seen from the server at all.

This removes saved credentials for the server, drops the current connections,
and leaves the person to sign in again as themselves.

Mapped drives disappear until the next sign-in, when Group Policy maps them
again. Nothing is deleted from the server and no permission is changed.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

$serverNames = @("DOMECH", $Config.Domain.Name, $Config.Network.DnsServer) | Where-Object { $_ } | Select-Object -Unique

Write-DomechLog "===== Clearing saved server logins for $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME =====" -Level Info

$groupSids = ([Security.Principal.WindowsIdentity]::GetCurrent()).Groups.Value
if (($groupSids -contains 'S-1-5-32-544') -or (@($groupSids | Where-Object { $_ -like 'S-1-5-21-*-512' }).Count -gt 0)) {
    Write-DomechLog "" -Level Info
    Write-DomechLog "This is running as an administrator ($env:USERNAME). It would clear THIS account's" -Level Error
    Write-DomechLog "saved logins, not the staff member's - their stored credentials live in their own" -Level Error
    Write-DomechLog "profile and are untouched by this." -Level Error
    Write-DomechLog "Sign in as the person who uses this PC and run it again, without elevation." -Level Warning
    exit 1
}

# ---- what is stored ----
Write-DomechLog "" -Level Info
Write-DomechLog "Saved credentials before:" -Level Info
$before = cmdkey /list 2>&1 | Out-String
$targets = @()
foreach ($line in ($before -split "`r?`n")) {
    if ($line -match 'Target:\s*(.+)$') {
        $t = $Matches[1].Trim()
        $isServer = $false
        foreach ($s in $serverNames) { if ($t -match [regex]::Escape($s)) { $isServer = $true } }
        if ($isServer) {
            Write-DomechLog "   $t   <- for the server" -Level Error
            $targets += $t
        } else {
            Write-DomechLog "   $t" -Level Info
        }
    }
}

if (-not $targets) {
    Write-DomechLog "" -Level Info
    Write-DomechLog "Nothing saved for the server - this is not the problem on this PC." -Level Success
    exit 0
}

# ---- remove them ----
# The stored name carries a prefix such as "Domain:target=DOMECH"; cmdkey wants
# the part after the last '=', so strip it rather than passing the whole label.
Write-DomechLog "" -Level Info
Write-DomechLog "Removing $($targets.Count) saved server login(s)..." -Level Warning
foreach ($t in $targets) {
    $name = ($t -split '=')[-1].Trim()
    $out = cmdkey /delete:$name 2>&1 | Out-String
    if ($out -match 'deleted successfully') {
        Write-DomechLog "   removed $name" -Level Success
    } else {
        # Some entries only delete under their full stored label.
        $out2 = cmdkey /delete:$t 2>&1 | Out-String
        if ($out2 -match 'deleted successfully') {
            Write-DomechLog "   removed $t" -Level Success
        } else {
            Write-DomechLog "   could not remove $name - $($out.Trim())" -Level Warning
        }
    }
}

# ---- drop the live connections, which still hold the old identity ----
Write-DomechLog "" -Level Info
Write-DomechLog "Disconnecting current connections to the server..." -Level Info
Write-DomechLog "   Mapped drives will vanish until the next sign-in, when they are mapped again." -Level Warning
net use * /delete /y 2>&1 | Out-String | Write-DomechLog -Level Info

# ---- confirm ----
Write-DomechLog "" -Level Info
Write-DomechLog "Saved credentials after:" -Level Info
$after = cmdkey /list 2>&1 | Out-String
$stillThere = @()
foreach ($line in ($after -split "`r?`n")) {
    if ($line -match 'Target:\s*(.+)$') {
        $t = $Matches[1].Trim()
        foreach ($s in $serverNames) { if ($t -match [regex]::Escape($s)) { $stillThere += $t } }
    }
}
if ($stillThere) {
    Write-DomechLog "   STILL SAVED: $($stillThere -join ', ')" -Level Error
    Write-DomechLog "   Remove these by hand: Control Panel > Credential Manager > Windows Credentials." -Level Warning
} else {
    Write-DomechLog "   None left for the server." -Level Success
}

Write-DomechLog "" -Level Info
Write-DomechLog "===== Done =====" -Level Success
Write-DomechLog "Now sign out completely and back in as $env:USERNAME." -Level Warning
Write-DomechLog "After signing back in, run 'What can I actually open?' again - the folders this" -Level Warning
Write-DomechLog "person should not reach should no longer open." -Level Warning
