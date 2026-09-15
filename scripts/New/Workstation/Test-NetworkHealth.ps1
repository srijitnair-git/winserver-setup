<#
Domech Fabricators - where exactly is the network broken on this PC

Run ON the affected PC. Read-only: it reports, it changes nothing.

Written for the "static IP killed the internet" case. On a domain PC, DNS must
point at the server - that is how it finds the domain at all - and the server
then forwards internet lookups outward. If that forwarding is not working, the
PC has a perfectly good network and no internet, which looks exactly like the
static IP broke something. It did not; the server's DNS forwarding is the
thing to fix.

Putting a public DNS server on the PC "fixes" browsing and quietly breaks the
domain: the PC starts asking a public server where the domain controller is,
gets no answer, and drive mappings, logons and printers fail intermittently in
ways that are very hard to trace. Leave DNS pointing at the server.

Checks each link in order, so the first failure is the thing to fix.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

$gateway   = $Config.Network.Gateway
$dnsServer = $Config.Network.DnsServer
$domain    = $Config.Domain.Name
$expected  = $Config.Network.WorkstationIPs.$env:COMPUTERNAME

function Step($n, $text) { Write-DomechLog "" -Level Info; Write-DomechLog "$n. $text" -Level Info }

Write-DomechLog "===== Network check on $env:COMPUTERNAME =====" -Level Info

# ---- 1. what address has it got ----
Step 1 "This PC's address"
$adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
if (-not $adapter) {
    Write-DomechLog "   No network adapter is up. Check the cable first - nothing below can work." -Level Error
    exit 1
}
$ip = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
$cfg = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue

if (-not $ip) {
    Write-DomechLog "   NO VALID ADDRESS. The adapter is up but has no usable IP (or a 169.254 self-assigned one)." -Level Error
    Write-DomechLog "   That means DHCP gave it nothing and no static address is set - it can reach nothing at all." -Level Error
    if ($expected) { Write-DomechLog "   config.json expects this PC at $expected. Use 'Set this PC's static IP' to apply it." -Level Warning }
    exit 1
}
Write-DomechLog "   $($ip.IPAddress)/$($ip.PrefixLength) via $($adapter.Name)  (assigned by: $($ip.PrefixOrigin))" -Level Success
if ($expected -and $ip.IPAddress -ne $expected) {
    Write-DomechLog "   config.json expects $expected for this PC - it is currently on $($ip.IPAddress)." -Level Warning
}
Write-DomechLog "   gateway: $($cfg.IPv4DefaultGateway.NextHop)   DNS: $($cfg.DNSServer.ServerAddresses -join ', ')" -Level Info

# ---- 2. the gateway ----
Step 2 "Can it reach the router ($gateway)"
if (Test-Connection -ComputerName $gateway -Count 2 -Quiet -ErrorAction SilentlyContinue) {
    Write-DomechLog "   Yes." -Level Success
} else {
    Write-DomechLog "   NO. Wrong subnet, wrong gateway, or a cabling/switch problem. Fix this before anything else." -Level Error
}

# ---- 3. the server ----
Step 3 "Can it reach the server ($dnsServer)"
$serverOk = Test-Connection -ComputerName $dnsServer -Count 2 -Quiet -ErrorAction SilentlyContinue
if ($serverOk) {
    Write-DomechLog "   Yes." -Level Success
} else {
    Write-DomechLog "   NO. Without this there are no drives, no logon and no printers." -Level Error
}

# ---- 4. is DNS pointed at the server ----
Step 4 "Is DNS pointed at the server"
$dnsList = @($cfg.DNSServer.ServerAddresses)
if ($dnsList -contains $dnsServer) {
    if ($dnsList.Count -gt 1) {
        Write-DomechLog "   Yes, but there are others too: $($dnsList -join ', ')" -Level Warning
        Write-DomechLog "   Remove the extras. A public DNS server alongside the domain one makes logons and drive mappings fail intermittently, because the PC sometimes asks the public server where the domain is." -Level Warning
    } else {
        Write-DomechLog "   Yes, and only the server. Correct." -Level Success
    }
} else {
    Write-DomechLog "   NO - DNS is $($dnsList -join ', '). The domain will not work properly until this points at $dnsServer." -Level Error
}

# ---- 5. internal name resolution ----
Step 5 "Can it look up the domain ($domain)"
try {
    $r = Resolve-DnsName -Name $domain -ErrorAction Stop | Select-Object -First 1
    Write-DomechLog "   Yes - $(if ($r.IPAddress) { $r.IPAddress } else { $r.NameHost })" -Level Success
} catch {
    Write-DomechLog "   NO: $($_.Exception.Message)" -Level Error
    Write-DomechLog "   Drives, logon scripts and printers all depend on this." -Level Error
}

# ---- 6. raw internet, no DNS involved ----
Step 6 "Raw internet reachable (ping 1.1.1.1, no DNS)"
$rawNet = Test-Connection -ComputerName "1.1.1.1" -Count 2 -Quiet -ErrorAction SilentlyContinue
if ($rawNet) {
    Write-DomechLog "   Yes - the connection out is fine." -Level Success
} else {
    Write-DomechLog "   NO - nothing is getting out. Router or ISP problem, not a DNS one." -Level Error
}

# ---- 7. internet names, which is the one that usually fails ----
Step 7 "Can it look up an internet name (google.com)"
try {
    $r = Resolve-DnsName -Name "google.com" -ErrorAction Stop | Select-Object -First 1
    Write-DomechLog "   Yes - $(if ($r.IPAddress) { $r.IPAddress } else { $r.NameHost }). Internet is working." -Level Success
} catch {
    Write-DomechLog "   NO: $($_.Exception.Message)" -Level Error
    if ($rawNet) {
        Write-DomechLog "   THIS IS THE PROBLEM, and it is on the SERVER, not this PC." -Level Error
        Write-DomechLog "   The connection out works (step 6 passed) but names cannot be resolved, so the server is not forwarding lookups to the internet." -Level Error
        Write-DomechLog "   Fix it on the server with 'Check internet name lookups on the server'. Do NOT add a public DNS server here - that breaks the domain." -Level Warning
    }
}

# ---- 8. the printer ----
Step 8 "Can it reach the Brother printer"
$printer = $Config.Printers | Where-Object { $_.IPAddress } | Select-Object -First 1
if (-not $printer) {
    Write-DomechLog "   No network printer with an address in config.json - skipping." -Level Info
} else {
    if (Test-Connection -ComputerName $printer.IPAddress -Count 2 -Quiet -ErrorAction SilentlyContinue) {
        Write-DomechLog "   Yes - $($printer.Name) answers at $($printer.IPAddress)." -Level Success
    } else {
        Write-DomechLog "   NO - nothing answers at $($printer.IPAddress)." -Level Error
        Write-DomechLog "   Either the printer is off, or it is still on its old DHCP address rather than the fixed one. Run 'Find printers on the network' from the server to locate it." -Level Warning
    }
}

Write-DomechLog "" -Level Info
Write-DomechLog "===== Done - fix the FIRST failure above; the later ones usually follow from it =====" -Level Success
