<#
Domech Fabricators - diagnose why shares/drives on the server are unreachable
Run on the SERVER, elevated. Checks disk health, share definitions, and the
services that make \\DOMECH browsable at all - covers the "can't even see
\\domech on the network" symptom, not just individual drive-map failures.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

Write-DomechLog "===== Disk volumes =====" -Level Info
Get-Volume | Format-Table DriveLetter, FileSystemLabel, FileSystem, HealthStatus, OperationalStatus, SizeRemaining, Size -AutoSize | Out-String | Write-DomechLog -Level Info

Write-DomechLog "===== Physical disks =====" -Level Info
Get-Disk | Format-Table Number, FriendlyName, OperationalStatus, HealthStatus, PartitionStyle, Size -AutoSize | Out-String | Write-DomechLog -Level Info

Write-DomechLog "===== SMB shares defined on this server =====" -Level Info
Get-SmbShare | Format-Table Name, Path, Description, FolderEnumerationMode -AutoSize | Out-String | Write-DomechLog -Level Info

Write-DomechLog "===== Networking services (make \\DOMECH browsable) =====" -Level Info
Get-Service LanmanServer, LanmanWorkstation, Server, Browser, netlogon, DNS, ADWS -ErrorAction SilentlyContinue |
    Format-Table Name, DisplayName, Status, StartType -AutoSize | Out-String | Write-DomechLog -Level Info

Write-DomechLog "===== Recent unexpected shutdown/crash events (last 48h) =====" -Level Info
try {
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 6008; StartTime = (Get-Date).AddHours(-48) } -ErrorAction Stop |
        Format-Table TimeCreated, Id, LevelDisplayName, Message -Wrap | Out-String | Write-DomechLog -Level Info
} catch {
    Write-DomechLog "No unexpected shutdown events (ID 41 / 6008) found in the last 48 hours." -Level Info
}

Write-DomechLog "===== Network profile + File/Printer Sharing firewall status =====" -Level Info
# The single most common cause of "everything local looks fine but \\SERVER
# is unreachable from the network" after an unclean shutdown: Windows
# reclassified the network adapter as "Public" on restart (it briefly looked
# unidentified during boot), and the Public profile blocks inbound SMB by
# default even though nothing else changed.
$profiles = Get-NetConnectionProfile
$profiles | Format-Table InterfaceAlias, NetworkCategory, IPv4Connectivity -AutoSize | Out-String | Write-DomechLog -Level Info

$publicProfiles = $profiles | Where-Object { $_.NetworkCategory -eq 'Public' }
if ($publicProfiles) {
    Write-DomechLog "FOUND THE PROBLEM: this server's network is classified 'Public', not 'DomainAuthenticated'. Windows blocks inbound file sharing on Public by default - this alone explains 'can't see \\DOMECH' from any workstation while everything local reports healthy." -Level Error
    foreach ($p in $publicProfiles) {
        Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
        Write-DomechLog "  Fixed: set '$($p.InterfaceAlias)' to Private. It should become DomainAuthenticated automatically now that AD DS is reachable - verify below." -Level Success
    }
    Start-Sleep -Seconds 2
    Get-NetConnectionProfile | Format-Table InterfaceAlias, NetworkCategory -AutoSize | Out-String | Write-DomechLog -Level Info
} else {
    Write-DomechLog "Network profile is not Public - that's not the cause here." -Level Info
}

$smbFirewallRules = Get-NetFirewallRule -DisplayGroup "File and Printer Sharing" -ErrorAction SilentlyContinue
$smbFirewallRules | Format-Table DisplayName, Enabled, Direction, Profile, Action -AutoSize | Out-String | Write-DomechLog -Level Info
$disabledInbound = $smbFirewallRules | Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq $false }
if ($disabledInbound) {
    Write-DomechLog "Some inbound File and Printer Sharing rules are disabled - enabling them now." -Level Warning
    $disabledInbound | Enable-NetFirewallRule
    Write-DomechLog "  Enabled $($disabledInbound.Count) rule(s)." -Level Success
}

$logFile = $Global:DomechLogFile
Write-DomechLog "Done. Full output saved to: $logFile - send that file, not pasted terminal text." -Level Success
