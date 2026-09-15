<#
Domech Fabricators - make sure the server can look up internet names

Run on the DC, elevated.

Every workstation points its DNS at this server, because that is how it finds
the domain. Internet lookups then go: workstation -> this server -> forwarder
-> internet. If the forwarders are missing or unreachable, the workstations
keep working on the domain but lose the internet entirely - which looks like
setting a static IP broke their connection, when the address was never the
problem.

The wrong fix is to put a public DNS server on the workstations. That restores
browsing and quietly breaks the domain: the PC starts asking a public server
where the domain controller is, gets no answer, and logons, drive mappings and
printers begin failing intermittently. Fix the forwarding here instead.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

if (-not (Get-Command Get-DnsServerForwarder -ErrorAction SilentlyContinue)) {
    Write-DomechLog "The DNS server tools are not available here - run this on the domain controller." -Level Error
    exit 1
}

# ---- 1. can the server itself get out ----
Write-DomechLog "1. Can this server reach the internet at all" -Level Info
$rawOut = Test-Connection -ComputerName "1.1.1.1" -Count 2 -Quiet -ErrorAction SilentlyContinue
if ($rawOut) {
    Write-DomechLog "   Yes." -Level Success
} else {
    Write-DomechLog "   NO - this server cannot reach the internet, so it can never resolve internet names for anyone." -Level Error
    Write-DomechLog "   Check the server's own gateway and the router before going further." -Level Error
}

# ---- 2. what forwarders are configured ----
Write-DomechLog "" -Level Info
Write-DomechLog "2. Configured forwarders" -Level Info
$current = (Get-DnsServerForwarder -ErrorAction SilentlyContinue).IPAddress | ForEach-Object { $_.IPAddressToString }
if ($current) {
    Write-DomechLog "   $($current -join ', ')" -Level Success
} else {
    Write-DomechLog "   NONE. This is why internet names do not resolve for any workstation." -Level Error
}

# ---- 3. do they actually answer ----
Write-DomechLog "" -Level Info
Write-DomechLog "3. Do the forwarders respond" -Level Info
$working = @()
foreach ($f in @($current) + @("1.1.1.1", "8.8.8.8", "9.9.9.9") | Select-Object -Unique) {
    if (-not $f) { continue }
    try {
        Resolve-DnsName -Name "google.com" -Server $f -ErrorAction Stop -QuickTimeout | Out-Null
        Write-DomechLog "   $f responds" -Level Success
        $working += $f
    } catch {
        Write-DomechLog "   $f does not respond" -Level Warning
    }
}

# ---- 4. fix if needed ----
Write-DomechLog "" -Level Info
Write-DomechLog "4. Testing a lookup through this server" -Level Info
$resolves = $false
try {
    Resolve-DnsName -Name "google.com" -Server "127.0.0.1" -ErrorAction Stop -QuickTimeout | Out-Null
    $resolves = $true
    Write-DomechLog "   Works - internet names resolve. Workstations pointed here will have internet." -Level Success
} catch {
    Write-DomechLog "   FAILS: $($_.Exception.Message)" -Level Error
}

if (-not $resolves) {
    if (-not $working) {
        Write-DomechLog "" -Level Info
        Write-DomechLog "No forwarder responded, and this server may not be able to reach the internet itself. Nothing changed - fix the server's own connection first." -Level Error
        exit 1
    }
    $use = @($working | Where-Object { $_ -in @("1.1.1.1","8.8.8.8","9.9.9.9") } | Select-Object -First 2)
    if (-not $use) { $use = @($working | Select-Object -First 2) }

    Write-DomechLog "" -Level Info
    Write-DomechLog "Setting forwarders to $($use -join ', ')" -Level Warning
    try {
        Set-DnsServerForwarder -IPAddress $use -PassThru -ErrorAction Stop | Out-Null
        Clear-DnsServerCache -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Resolve-DnsName -Name "google.com" -Server "127.0.0.1" -ErrorAction Stop -QuickTimeout | Out-Null
        Write-DomechLog "Fixed - internet names now resolve through this server." -Level Success
        Write-DomechLog "Workstations get this immediately; no restart needed on them." -Level Success
    } catch {
        Write-DomechLog "Still failing after setting forwarders: $($_.Exception.Message)" -Level Error
        Write-DomechLog "Check whether the router or ISP is blocking outbound DNS on port 53 from this server." -Level Warning
    }
}

# ---- 5. the server's own DNS client ----
Write-DomechLog "" -Level Info
Write-DomechLog "5. This server's own DNS setting" -Level Info
$own = (Get-DnsClientServerAddress -AddressFamily IPv4 |
        Where-Object { $_.ServerAddresses } | Select-Object -First 1).ServerAddresses
Write-DomechLog "   $($own -join ', ')" -Level Info
if ($own -contains "127.0.0.1" -or $own -contains $Config.Network.DnsServer) {
    Write-DomechLog "   Correct - it points at itself." -Level Success
} else {
    Write-DomechLog "   A domain controller should point at itself for DNS, not at the router or a public server." -Level Warning
}

Write-DomechLog "" -Level Info
Write-DomechLog "Done. Re-test from the affected PC with 'Check this PC's network'." -Level Info
