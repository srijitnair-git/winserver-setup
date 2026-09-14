#Requires -Version 5.1
<#
.SYNOPSIS
    Domech Network Scanner and Login Tester
    Matrix IT Solutions | Rev 1 | 2026

.DESCRIPTION
    Phase 1: Sweeps 192.168.0.0/24 and 192.168.1.0/24
             Tests common ports, grabs banners, resolves hostnames, reads
             MAC addresses from ARP, cross-references OUI against known vendors.
             Output: DomechScan_NetworkMap_<timestamp>.txt

    Phase 2: Finds every potential web login page on discovered hosts,
             attempts a curated list of default credentials per device type,
             and reports any that succeed.
             Output: DomechScan_LoginTest_<timestamp>.txt

.NOTES
    Run from the Windows Server as Administrator.
    No external tools required — pure PowerShell + .NET.
    Tested on PowerShell 5.1 and PowerShell 7.x.

    IMPORTANT: Run only on your own network. This script is built for
    the Domech Fabricators internal audit. Do not run it elsewhere.
#>

[CmdletBinding()]
param(
    [string[]]$Subnets       = @("192.168.0", "192.168.1"),
    [int]$StartHost          = 1,
    [int]$EndHost            = 254,
    [int]$PingTimeoutMs      = 800,
    [int]$PortTimeoutMs      = 1200,
    [int]$HttpTimeoutSec     = 8,
    [int]$MaxParallelPing    = 50,
    [int]$MaxParallelPort    = 30,
    [string]$OutputDir       = "C:\01_matrix\Logs\NetworkScan"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

# ─────────────────────────────────────────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────────────────────────────────────────
$Timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$NetworkLog  = Join-Path $OutputDir "DomechScan_NetworkMap_$Timestamp.txt"
$LoginLog    = Join-Path $OutputDir "DomechScan_LoginTest_$Timestamp.txt"

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

function Write-Log {
    param([string]$Path, [string]$Message, [switch]$NoConsole)
    $Line = "[$(Get-Date -Format 'HH:mm:ss')] $Message"
    Add-Content -Path $Path -Value $Line -Encoding UTF8
    if (-not $NoConsole) { Write-Host $Line }
}

function Write-Section {
    param([string]$Path, [string]$Title)
    $Bar = "=" * 78
    Add-Content -Path $Path -Value "" -Encoding UTF8
    Add-Content -Path $Path -Value $Bar -Encoding UTF8
    Add-Content -Path $Path -Value "  $Title" -Encoding UTF8
    Add-Content -Path $Path -Value $Bar -Encoding UTF8
    Add-Content -Path $Path -Value "" -Encoding UTF8
    Write-Host "`n$Bar`n  $Title`n$Bar" -ForegroundColor Cyan
}

# ─────────────────────────────────────────────────────────────────────────────
# OUI VENDOR TABLE  (top manufacturers seen in SMB environments)
# ─────────────────────────────────────────────────────────────────────────────
$OUI = @{
    # TP-Link
    "50D4F7"="TP-Link"; "54A703"="TP-Link"; "30DE4B"="TP-Link"; "98DAC4"="TP-Link"
    "E4FAC4"="TP-Link"; "C46E1F"="TP-Link"; "A42BB0"="TP-Link"; "B0487A"="TP-Link"
    "3056F7"="TP-Link"; "D8476B"="TP-Link"; "1C614B"="TP-Link"; "F4F26D"="TP-Link"
    "686FF2"="TP-Link"; "14EBA9"="TP-Link"; "4CED57"="TP-Link"
    # Ubiquiti
    "24A43C"="Ubiquiti"; "788A20"="Ubiquiti"; "FCECDA"="Ubiquiti"; "802AA8"="Ubiquiti"
    "E063DA"="Ubiquiti"; "44D9E7"="Ubiquiti"; "DC9FDB"="Ubiquiti"
    # D-Link
    "1CBDB9"="D-Link"; "B0A7B9"="D-Link"; "2CB05D"="D-Link"; "0026B9"="D-Link"
    "14D64D"="D-Link"; "F07D68"="D-Link"; "1CAFF7"="D-Link"
    # Netgear
    "A040A0"="Netgear"; "9C3DCF"="Netgear"; "28C68E"="Netgear"; "C03F0E"="Netgear"
    "744401"="Netgear"; "20E52A"="Netgear"
    # Dell
    "E454E8"="Dell"; "F8BC12"="Dell"; "001A4B"="Dell"; "D4BE89"="Dell"
    "185A58"="Dell"; "F04DA2"="Dell"; "B083FE"="Dell"
    # Gigabyte / Giga-Byte
    "30560F"="Gigabyte"; "1C872C"="Gigabyte"; "68B599"="Gigabyte"
    # HP
    "C01803"="HP"; "3C4A92"="HP"; "D850E6"="HP"; "A0B3CC"="HP"; "C8D3FF"="HP"
    # Lenovo
    "E4A8DF"="Lenovo"; "606720"="Lenovo"; "B88684"="Lenovo"; "484D7E"="Lenovo"
    # Hikvision
    "446086"="Hikvision"; "BC3400"="Hikvision"; "C8F74A"="Hikvision"
    "508DA0"="Hikvision"; "E0D04E"="Hikvision"; "282D46"="Hikvision"
    # eSSL / ZKTeco
    "001761"="eSSL/ZKTeco"; "AC172F"="ZKTeco"
    # Seagate (NAS)
    "0004CF"="Seagate"; "001F93"="Seagate"
    # Raspberry Pi
    "B827EB"="Raspberry Pi"; "DC A6 32"="Raspberry Pi"; "E45F01"="Raspberry Pi"
    # VMware
    "000C29"="VMware"; "000569"="VMware"; "001C14"="VMware"
    # Microsoft
    "7845C4"="Microsoft"; "000D3A"="Microsoft"; "001DD8"="Microsoft"
}

function Get-Vendor([string]$Mac) {
    if (-not $Mac) { return "Unknown" }
    $key = $Mac.Replace(":","").Replace("-","").Substring(0,[Math]::Min(6,$Mac.Replace(":","").Replace("-","").Length)).ToUpper()
    if ($OUI.ContainsKey($key)) { return $OUI[$key] }
    return "Unknown"
}

# ─────────────────────────────────────────────────────────────────────────────
# PORTS TO SCAN
# ─────────────────────────────────────────────────────────────────────────────
$PortsToScan = @{
    21   = "FTP"
    22   = "SSH"
    23   = "Telnet"
    25   = "SMTP"
    53   = "DNS"
    80   = "HTTP"
    110  = "POP3"
    135  = "RPC/WMI"
    139  = "NetBIOS"
    143  = "IMAP"
    443  = "HTTPS"
    445  = "SMB"
    554  = "RTSP (CCTV)"
    993  = "IMAPS"
    1433 = "MSSQL"
    1723 = "PPTP VPN"
    3306 = "MySQL"
    3389 = "RDP"
    4370 = "eSSL/ZKTeco (biometric)"
    5900 = "VNC"
    7080 = "HTTP-alt"
    7443 = "HTTPS-alt"
    8000 = "HTTP-alt (Hikvision)"
    8080 = "HTTP-alt"
    8081 = "HTTP-alt"
    8443 = "HTTPS-alt (TrueNAS)"
    8888 = "HTTP-alt"
    9090 = "HTTP-alt"
    9443 = "HTTPS-alt"
    49152= "UPnP"
}

# ─────────────────────────────────────────────────────────────────────────────
# DEFAULT CREDENTIALS  (per device type, expanded)
# ─────────────────────────────────────────────────────────────────────────────
# Format: @{ Username = "u"; Password = "p"; Note = "Source" }
$DefaultCreds = @{
    "Generic" = @(
        @{U="admin";    P="admin";     N="Factory default — most routers/switches/APs"}
        @{U="admin";    P="";          N="Blank password — D-Link, some Hikvision"}
        @{U="admin";    P="password";  N="Netgear factory default"}
        @{U="admin";    P="1234";      N="Common low-security default"}
        @{U="admin";    P="12345";     N="Hikvision DVR default"}
        @{U="admin";    P="123456";    N="Common low-security default"}
        @{U="admin";    P="admin123";  N="Common variation"}
        @{U="root";     P="root";      N="Linux device default"}
        @{U="root";     P="admin";     N="Linux device variation"}
        @{U="root";     P="";          N="Linux blank root"}
        @{U="user";     P="user";      N="Some consumer routers"}
        @{U="guest";    P="guest";     N="Guest accounts"}
        @{U="support";  P="support";   N="ISP modem support account"}
        @{U="Admin";    P="Admin";     N="Case-variant"}
        @{U="Administrator"; P="";    N="Windows default blank"}
        @{U="admin";    P="tplink";    N="TP-Link common"}
        @{U="admin";    P="ubnt";      N="Ubiquiti UniFi edge devices"}
        @{U="ubnt";     P="ubnt";      N="Ubiquiti older firmware"}
        @{U="admin";    P="airlive";   N="AirLive APs"}
        @{U="admin";    P="motorola";  N="Motorola/Arris modems"}
        @{U="cusadmin"; P="highspeed"; N="Virgin/Liberty modems"}
        @{U="admin";    P="broadband"; N="ISP modem generic"}
    )
}

# Web paths that commonly host login pages
$LoginPaths = @(
    "/", "/login", "/Login", "/admin", "/Admin", "/index.html", "/index.php",
    "/web/login", "/web/", "/ISAPI/Security/userCheck",
    "/cgi-bin/login.cgi", "/cgi-bin/admin.cgi",
    "/doc/page/login.asp",                      # Hikvision DVR
    "/webLogin.htm",                            # Hikvision NVR
    "/api/login", "/api/v1/login", "/api/auth",
    "/ui/", "/ui/login",                        # TrueNAS SCALE
    "/webman/login.cgi",                        # Synology
    "/manage/account/login",                    # Ubiquiti
    "/wp-login.php",                            # WordPress
    "/phpmyadmin/", "/pma/",
    "/pihole/", "/admin/index.php"              # Pi-hole
)

# Keywords in HTML that indicate a login form is present
$LoginKeywords = @(
    "password", "passwd", "log.?in", "sign.?in", "username", "user.?name",
    "email", "credentials", "authenticate", "auth", "<form", "input.*type.*password"
)

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — NETWORK SCAN
# ─────────────────────────────────────────────────────────────────────────────
Write-Section -Path $NetworkLog -Title "DOMECH FABRICATORS — NETWORK MAP SCAN"
Write-Log -Path $NetworkLog -Message "Script started on $(hostname) by $env:USERNAME"
Write-Log -Path $NetworkLog -Message "Subnets: $($Subnets -join ', ')  Range: .$StartHost — .$EndHost"
Write-Log -Path $NetworkLog -Message "Output: $NetworkLog"

# Refresh ARP table by pinging the broadcast (best-effort)
foreach ($subnet in $Subnets) {
    $null = Test-Connection "$subnet.255" -Count 1 -TimeoutSeconds 1 2>$null
}
Start-Sleep -Seconds 1

# Pull ARP table once — faster than calling arp.exe per host
$ArpRaw = arp -a 2>$null
$ArpTable = @{}
foreach ($line in $ArpRaw) {
    if ($line -match "(\d+\.\d+\.\d+\.\d+)\s+([\da-f]{2}[:-][\da-f]{2}[:-][\da-f]{2}[:-][\da-f]{2}[:-][\da-f]{2}[:-][\da-f]{2})") {
        $ArpTable[$matches[1]] = $matches[2].ToUpper()
    }
}

$AllHosts = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

foreach ($Subnet in $Subnets) {

    Write-Section -Path $NetworkLog -Title "SUBNET: $Subnet.0/24"

    # ── Ping sweep (parallel jobs — works around ICMP firewall rules) ──────────
    Write-Log -Path $NetworkLog -Message "Pinging $Subnet.$StartHost — $Subnet.$EndHost ..."

    $AliveList = [System.Collections.Generic.List[string]]::new()
    $jobs      = [System.Collections.Generic.List[object]]::new()

    # Launch one background job per host (PowerShell Jobs bypass the
    # .NET Ping firewall restriction that hit the previous version)
    foreach ($i in $StartHost..$EndHost) {
        $ip = "$Subnet.$i"
        $j  = Start-Job -ScriptBlock {
            param($addr, $ms)
            $ok = Test-Connection -ComputerName $addr -Count 1 -TimeToLive 64 `
                  -ErrorAction SilentlyContinue -Quiet
            if (-not $ok) {
                # Fallback: TCP port 80 or 445 — catches devices that block ICMP
                foreach ($p in @(80,443,445,22,23,8080)) {
                    $t = New-Object System.Net.Sockets.TcpClient
                    try {
                        $r = $t.BeginConnect($addr,$p,$null,$null)
                        $ok = $r.AsyncWaitHandle.WaitOne($ms,$false) -and $t.Connected
                    } catch {}
                    $t.Close()
                    if ($ok) { break }
                }
            }
            [PSCustomObject]@{ IP = $addr; Alive = $ok }
        } -ArgumentList $ip, $PingTimeoutMs
        $jobs.Add($j)

        # Throttle — wait when we have MaxParallelPing running
        if ($jobs.Count -ge $MaxParallelPing) {
            $done = $jobs | Wait-Job -Any -Timeout 5
            foreach ($d in ($jobs | Where-Object { $_.State -ne 'Running' })) {
                $r = Receive-Job $d
                if ($r.Alive) { $AliveList.Add($r.IP) }
                Remove-Job $d
                $jobs.Remove($d) | Out-Null
            }
        }
    }

    # Drain remaining jobs
    if ($jobs.Count -gt 0) {
        $null = Wait-Job -Job $jobs -Timeout 30
        foreach ($d in $jobs) {
            $r = Receive-Job $d
            if ($r -and $r.Alive) { $AliveList.Add($r.IP) }
            Remove-Job $d
        }
    }

    $AliveList = $AliveList | Sort-Object { [Version]$_ }
    Write-Log -Path $NetworkLog -Message "Found $($AliveList.Count) live host(s) on $Subnet.0/24"

    if ($AliveList.Count -eq 0) {
        Write-Log -Path $NetworkLog -Message "No live hosts — ICMP may be blocked. Check Windows Firewall on this server."
        Write-Log -Path $NetworkLog -Message "Try: netsh advfirewall firewall add rule name='ICMP Allow' protocol=icmpv4:8,any dir=out action=allow"
        continue
    }

    # ── Per-host detail ──────────────────────────────────────────────────────
    foreach ($IP in $AliveList) {

        $Mac    = if ($ArpTable.ContainsKey($IP)) { $ArpTable[$IP] } else { "unknown" }
        $Vendor = Get-Vendor -Mac $Mac
        $DNS    = try {
            ([System.Net.Dns]::GetHostEntry($IP)).HostName
        } catch { "unresolved" }

        Write-Log -Path $NetworkLog -Message "  HOST: $IP  |  DNS: $DNS  |  MAC: $Mac  |  Vendor: $Vendor"

        # Port scan this host
        $OpenPorts = [System.Collections.Generic.List[string]]::new()

        # Batch port connects
        $PortList = $PortsToScan.Keys | Sort-Object
        # Split port list into batches (compatible with PS 5.1 / .NET 4.x)
        $portBatches = for ($s=0; $s -lt $PortList.Count; $s+=$MaxParallelPort) {
            ,($PortList[$s..([Math]::Min($s+$MaxParallelPort-1,$PortList.Count-1))])
        }

        foreach ($pbatch in $portBatches) {
            $tasks = foreach ($port in $pbatch) {
                $tcp = [System.Net.Sockets.TcpClient]::new()
                [PSCustomObject]@{
                    Port   = $port
                    Task   = $tcp.ConnectAsync($IP, $port)
                    Client = $tcp
                }
            }
            # Wait with timeout
            $deadline = [DateTime]::UtcNow.AddMilliseconds($PortTimeoutMs + 200)
            while (($tasks | Where-Object { -not $_.Task.IsCompleted }) -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }
            foreach ($t in $tasks) {
                if ($t.Task.IsCompleted -and -not $t.Task.IsFaulted -and $t.Client.Connected) {
                    $svcName = $PortsToScan[$t.Port]
                    $OpenPorts.Add("$($t.Port)/$svcName")
                    Write-Log -Path $NetworkLog -Message "    OPEN  $($t.Port.ToString().PadLeft(5))  $svcName"
                }
                try { $t.Client.Close() } catch {}
            }
        }

        if ($OpenPorts.Count -eq 0) {
            Write-Log -Path $NetworkLog -Message "    No scanned ports open"
        }

        # Banner grab on key ports (80, 443, 8080, 8000, 8443, 22, 21)
        $BannerPorts = @(80, 443, 8080, 8000, 8443, 21, 22, 23, 554)
        foreach ($bp in $BannerPorts) {
            if ($OpenPorts -match "^$bp/") {
                try {
                    $scheme = if ($bp -in @(443, 8443, 9443)) { "https" } else { "http" }
                    if ($bp -in @(21, 22, 23)) {
                        # Raw TCP banner
                        $sock = New-Object System.Net.Sockets.TcpClient
                        $sock.Connect($IP, $bp)
                        $stream = $sock.GetStream()
                        $buf    = New-Object byte[] 512
                        $stream.ReadTimeout = 2000
                        $bytes  = $stream.Read($buf, 0, 512)
                        $banner = [System.Text.Encoding]::ASCII.GetString($buf, 0, $bytes).Trim() -replace "`r`n"," "
                        Write-Log -Path $NetworkLog -Message "    BANNER port $bp : $($banner.Substring(0,[Math]::Min(120,$banner.Length)))" -NoConsole
                        $sock.Close()
                    } else {
                        # HTTP HEAD
                        $wr = [System.Net.WebRequest]::Create("${scheme}://${IP}:${bp}/")
                        $wr.Method  = "HEAD"
                        $wr.Timeout = $HttpTimeoutSec * 1000
                        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                        [Net.ServicePointManager]::SecurityProtocol = 'Tls12,Tls11,Tls'
                        $resp   = $wr.GetResponse()
                        $server = $resp.Headers["Server"]
                        $title  = "HTTP $([int]$resp.StatusCode)"
                        Write-Log -Path $NetworkLog -Message "    BANNER port $bp : $title  Server: $server" -NoConsole
                        $resp.Close()
                    }
                } catch { }
            }
        }

        # Classify device based on vendor + open ports
        $Classification = switch -Regex ($Vendor) {
            "Hikvision" { "CCTV DVR / IP Camera — check CVE-2021-36260"; break }
            "TP-Link"   { "TP-Link device — router, switch or AP"; break }
            "Ubiquiti"  { "Ubiquiti — AP or edge device"; break }
            "D-Link"    { "D-Link — switch or AP"; break }
            "Dell"      { "Dell server or workstation"; break }
            "Gigabyte"  { "Gigabyte workstation"; break }
            "HP"        { "HP workstation or printer"; break }
            "Lenovo"    { "Lenovo workstation or AIO"; break }
            "eSSL"      { "eSSL / ZKTeco biometric device — check default credentials"; break }
            "Seagate"   { "Seagate NAS or external disk"; break }
            default {
                if ($OpenPorts -match "3389") { "Windows machine (RDP open)" }
                elseif ($OpenPorts -match "445")  { "Windows machine (SMB)" }
                elseif ($OpenPorts -match "22")   { "Linux / Unix device (SSH)" }
                elseif ($OpenPorts -match "554")  { "RTSP stream — likely CCTV" }
                elseif ($OpenPorts -match "4370") { "eSSL / ZKTeco biometric" }
                else { "Unknown" }
            }
        }

        Write-Log -Path $NetworkLog -Message "    CLASSIFICATION: $Classification" -NoConsole

        # Collect for Phase 2
        $AllHosts.Add([PSCustomObject]@{
            IP             = $IP
            DNS            = $DNS
            MAC            = $Mac
            Vendor         = $Vendor
            Classification = $Classification
            OpenPorts      = $OpenPorts -join ", "
            WebPorts       = ($OpenPorts | Where-Object { $_ -match "^(80|443|8000|8080|8081|8443|7080|7443|8888|9090|9443)/" } |
                              ForEach-Object { ($_ -split "/")[0] })
        })

        Add-Content -Path $NetworkLog -Value "" -Encoding UTF8
    }
}

# ── Summary table ────────────────────────────────────────────────────────────
Write-Section -Path $NetworkLog -Title "SUMMARY — ALL LIVE HOSTS"
$summary = $AllHosts | Sort-Object { [Version]$_.IP }
$col = "{0,-16} {1,-22} {2,-18} {3,-28} {4}"
Add-Content -Path $NetworkLog -Value ($col -f "IP","DNS","Vendor","Classification","Open Ports") -Encoding UTF8
Add-Content -Path $NetworkLog -Value ("-" * 120) -Encoding UTF8
foreach ($h in $summary) {
    Add-Content -Path $NetworkLog -Value ($col -f $h.IP, $h.DNS.Substring(0,[Math]::Min(22,$h.DNS.Length)), $h.Vendor.Substring(0,[Math]::Min(18,$h.Vendor.Length)), $h.Classification.Substring(0,[Math]::Min(28,$h.Classification.Length)), $h.OpenPorts) -Encoding UTF8
}
Add-Content -Path $NetworkLog -Value "" -Encoding UTF8
Write-Log -Path $NetworkLog -Message "Total live hosts: $($summary.Count)"
Write-Log -Path $NetworkLog -Message "Phase 1 complete. Network map written to: $NetworkLog"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — LOGIN PAGE DETECTION AND CREDENTIAL TEST
# ─────────────────────────────────────────────────────────────────────────────
Write-Section -Path $LoginLog -Title "DOMECH FABRICATORS — LOGIN PAGE DISCOVERY AND DEFAULT CREDENTIAL TEST"
Write-Log -Path $LoginLog -Message "Script started on $(hostname) by $env:USERNAME"
Write-Log -Path $LoginLog -Message "WARNING: Tests only default/factory credentials. Any success is a CRITICAL finding."
Write-Log -Path $LoginLog -Message "Source data: $($summary.Count) hosts from Phase 1"
Write-Log -Path $LoginLog -Message ""

[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[System.Net.ServicePointManager]::SecurityProtocol = 'Tls12,Tls11,Tls'

$LoginFindings = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($Host_ in ($summary | Where-Object { $_.WebPorts })) {

    $IP        = $Host_.IP
    $WebPorts  = @($Host_.WebPorts)
    $Vendor    = $Host_.Vendor
    $Class     = $Host_.Classification

    Write-Log -Path $LoginLog -Message "HOST: $IP ($($Host_.DNS))  Vendor: $Vendor"
    Write-Log -Path $LoginLog -Message "  Web ports: $($WebPorts -join ', ')"

    foreach ($Port in $WebPorts) {

        $Scheme = if ($Port -in @(443, 8443, 9443, 7443)) { "https" } else { "http" }
        $Base   = "${Scheme}://${IP}:${Port}"

        # ── Find login pages ─────────────────────────────────────────────────
        $LoginPages = [System.Collections.Generic.List[string]]::new()

        foreach ($Path in $LoginPaths) {
            $Url = "$Base$Path"
            try {
                $req = [System.Net.WebRequest]::Create($Url)
                $req.Method  = "GET"
                $req.Timeout = $HttpTimeoutSec * 1000
                $req.AllowAutoRedirect = $true
                $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
                $resp = $req.GetResponse()
                $stream = $resp.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $html   = $reader.ReadToEnd()
                $reader.Close(); $resp.Close()

                $isLogin = $false
                foreach ($kw in $LoginKeywords) {
                    if ($html -match $kw) { $isLogin = $true; break }
                }

                # Extract title
                $pageTitle = if ($html -match "<title[^>]*>([^<]+)</title>") { $matches[1].Trim() } else { "(no title)" }

                if ($isLogin) {
                    $LoginPages.Add($Url)
                    Write-Log -Path $LoginLog -Message "  FOUND LOGIN PAGE: $Url  Title: $pageTitle"
                }
            } catch { }
        }

        if ($LoginPages.Count -eq 0) {
            Write-Log -Path $LoginLog -Message "  No login pages found on port $Port"
            continue
        }

        # ── Test credentials ─────────────────────────────────────────────────
        foreach ($LoginUrl in $LoginPages) {

            Write-Log -Path $LoginLog -Message "  Testing credentials on: $LoginUrl"

            foreach ($Cred in $DefaultCreds["Generic"]) {
                $U = $Cred.U; $P = $Cred.P; $Note = $Cred.N

                $Success   = $false
                $Method    = "unknown"
                $EvidenceNote = ""

                # ── Method 1: HTTP Basic Auth ────────────────────────────────
                try {
                    $req = [System.Net.WebRequest]::Create($LoginUrl)
                    $req.Method      = "GET"
                    $req.Timeout     = $HttpTimeoutSec * 1000
                    $req.Credentials = New-Object System.Net.NetworkCredential($U, $P)
                    $req.PreAuthenticate = $true
                    $req.AllowAutoRedirect = $true
                    $resp = $req.GetResponse()
                    $code = [int]$resp.StatusCode
                    $resp.Close()
                    if ($code -ge 200 -and $code -lt 400) {
                        $Success = $true; $Method = "HTTP Basic Auth"
                        $EvidenceNote = "HTTP $code returned with Basic Auth header"
                    }
                } catch { }

                # ── Method 2: Form POST (application/x-www-form-urlencoded) ─
                if (-not $Success) {
                    # Common field name combinations
                    $FormPayloads = @(
                        "username=$U&password=$P"
                        "user=$U&pass=$P"
                        "user=$U&password=$P"
                        "loginName=$U&loginPassword=$P"
                        "name=$U&password=$P"
                        "admin_name=$U&admin_password=$P"
                        "login=$U&password=$P"
                        "Username=$U&Password=$P"
                    )
                    foreach ($payload in $FormPayloads) {
                        try {
                            $bytes   = [System.Text.Encoding]::UTF8.GetBytes($payload)
                            $req     = [System.Net.WebRequest]::Create($LoginUrl)
                            $req.Method        = "POST"
                            $req.ContentType   = "application/x-www-form-urlencoded"
                            $req.ContentLength = $bytes.Length
                            $req.Timeout       = $HttpTimeoutSec * 1000
                            $req.AllowAutoRedirect = $true
                            $req.UserAgent     = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
                            $stream = $req.GetRequestStream()
                            $stream.Write($bytes, 0, $bytes.Length)
                            $stream.Close()
                            $resp = $req.GetResponse()
                            $code = [int]$resp.StatusCode
                            # Read response body for failure keywords
                            $sr   = New-Object System.IO.StreamReader($resp.GetResponseStream())
                            $body = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
                            # Heuristic: success if no failure keywords and redirect happened
                            $failWords = @("invalid","incorrect","failed","error","wrong","denied","unauthorized","try again")
                            $hasFail   = $false
                            foreach ($fw in $failWords) { if ($body -match $fw) { $hasFail = $true; break } }
                            if ($code -ge 200 -and $code -lt 400 -and -not $hasFail) {
                                $Success = $true; $Method = "Form POST ($payload)"
                                $EvidenceNote = "HTTP $code, no failure keywords in response"
                                break
                            }
                        } catch { }
                        if ($Success) { break }
                    }
                }

                # ── Method 3: JSON POST ──────────────────────────────────────
                if (-not $Success) {
                    $JsonPayloads = @(
                        "{`"username`":`"$U`",`"password`":`"$P`"}"
                        "{`"user`":`"$U`",`"password`":`"$P`"}"
                        "{`"loginName`":`"$U`",`"loginPassword`":`"$P`"}"
                        "{`"name`":`"$U`",`"pass`":`"$P`"}"
                    )
                    $JsonEndpoints = @($LoginUrl, "$Base/api/login", "$Base/api/v1/login", "$Base/api/auth")
                    foreach ($ep in $JsonEndpoints) {
                        foreach ($jp in $JsonPayloads) {
                            try {
                                $bytes = [System.Text.Encoding]::UTF8.GetBytes($jp)
                                $req   = [System.Net.WebRequest]::Create($ep)
                                $req.Method        = "POST"
                                $req.ContentType   = "application/json"
                                $req.ContentLength = $bytes.Length
                                $req.Timeout       = $HttpTimeoutSec * 1000
                                $req.AllowAutoRedirect = $true
                                $stream = $req.GetRequestStream()
                                $stream.Write($bytes, 0, $bytes.Length)
                                $stream.Close()
                                $resp  = $req.GetResponse()
                                $code  = [int]$resp.StatusCode
                                $sr    = New-Object System.IO.StreamReader($resp.GetResponseStream())
                                $body  = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
                                # JSON success: status 200 + token/session in body, no error key
                                if ($code -eq 200 -and ($body -match 'token|session|success|data' -and $body -notmatch '"code"\s*:\s*[^0]|"error"')) {
                                    $Success = $true; $Method = "JSON POST to $ep"
                                    $EvidenceNote = "HTTP 200, response contains auth indicators"
                                    break
                                }
                            } catch { }
                            if ($Success) { break }
                        }
                        if ($Success) { break }
                    }
                }

                if ($Success) {
                    $finding = [PSCustomObject]@{
                        IP           = $IP
                        Port         = $Port
                        URL          = $LoginUrl
                        Username     = $U
                        Password     = if ($P -eq "") { "(blank)" } else { $P }
                        Method       = $Method
                        CredNote     = $Note
                        Evidence     = $EvidenceNote
                        Vendor       = $Vendor
                        Device       = $Class
                        TestedAt     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                        Severity     = "CRITICAL"
                    }
                    $LoginFindings.Add($finding)
                    $msg = "  !!!!!!!!!!!!!!!! SUCCESS !!!!!!!!!!!!!!!!  $U / '$P'  via $Method"
                    Write-Log -Path $LoginLog -Message $msg
                    Write-Host $msg -ForegroundColor Red -BackgroundColor Yellow
                } else {
                    Write-Log -Path $LoginLog -Message "    FAIL  $U / $(if($P -eq ''){'(blank)'}else{$P})  ($Note)" -NoConsole
                }
            }
        }
    }
    Add-Content -Path $LoginLog -Value "" -Encoding UTF8
}

# ── Login findings summary ────────────────────────────────────────────────────
Write-Section -Path $LoginLog -Title "LOGIN TEST RESULTS SUMMARY"

if ($LoginFindings.Count -eq 0) {
    Write-Log -Path $LoginLog -Message "No default credentials accepted on any tested page."
    Write-Log -Path $LoginLog -Message "NOTE: This does not mean login pages are secure — it means default"
    Write-Log -Path $LoginLog -Message "      credentials from this list did not work. Review manually"
    Write-Log -Path $LoginLog -Message "      for devices whose login pages were found."
} else {
    Write-Log -Path $LoginLog -Message "CRITICAL FINDINGS: $($LoginFindings.Count) default credential(s) accepted"
    Write-Log -Path $LoginLog -Message ""
    Add-Content -Path $LoginLog -Value ("=" * 78) -Encoding UTF8
    Add-Content -Path $LoginLog -Value "  ACTION REQUIRED IMMEDIATELY — Change these credentials before continuing" -Encoding UTF8
    Add-Content -Path $LoginLog -Value ("=" * 78) -Encoding UTF8
    Add-Content -Path $LoginLog -Value "" -Encoding UTF8

    foreach ($f in $LoginFindings) {
        Add-Content -Path $LoginLog -Value "  SEVERITY  : $($f.Severity)" -Encoding UTF8
        Add-Content -Path $LoginLog -Value "  DEVICE    : $($f.IP) — $($f.Vendor) ($($f.Device))" -Encoding UTF8
        Add-Content -Path $LoginLog -Value "  URL       : $($f.URL)" -Encoding UTF8
        Add-Content -Path $LoginLog -Value "  CREDENTIAL: $($f.Username) / $($f.Password)" -Encoding UTF8
        Add-Content -Path $LoginLog -Value "  METHOD    : $($f.Method)" -Encoding UTF8
        Add-Content -Path $LoginLog -Value "  EVIDENCE  : $($f.Evidence)" -Encoding UTF8
        Add-Content -Path $LoginLog -Value "  CRED NOTE : $($f.CredNote)" -Encoding UTF8
        Add-Content -Path $LoginLog -Value "  TESTED AT : $($f.TestedAt)" -Encoding UTF8
        Add-Content -Path $LoginLog -Value "" -Encoding UTF8
    }
}

# ── Pages found regardless of credential result ───────────────────────────────
Write-Section -Path $LoginLog -Title "ALL LOGIN PAGES DISCOVERED (MANUAL REVIEW REQUIRED)"
Write-Log -Path $LoginLog -Message "Review each of these manually — especially any that are unfamiliar."
Add-Content -Path $LoginLog -Value "" -Encoding UTF8

foreach ($Host_ in ($summary | Where-Object { $_.WebPorts })) {
    $IP = $Host_.IP
    foreach ($Port in @($Host_.WebPorts)) {
        $Scheme = if ($Port -in @(443,8443,9443,7443)) {"https"} else {"http"}
        $Base   = "${Scheme}://${IP}:${Port}"
        foreach ($Path in $LoginPaths) {
            $Url = "$Base$Path"
            try {
                $req = [System.Net.WebRequest]::Create($Url)
                $req.Method  = "GET"
                $req.Timeout = 3000
                $req.AllowAutoRedirect = $true
                $resp = $req.GetResponse()
                $stream = $resp.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $html   = $reader.ReadToEnd()
                $reader.Close(); $resp.Close()
                $isLogin = $false
                foreach ($kw in $LoginKeywords) { if ($html -match $kw) { $isLogin = $true; break } }
                if ($isLogin) {
                    $title = if ($html -match "<title[^>]*>([^<]+)</title>") { $matches[1].Trim() } else { "(no title)" }
                    Add-Content -Path $LoginLog -Value "  $Url  |  $($Host_.Vendor)  |  Title: $title" -Encoding UTF8
                }
            } catch { }
        }
    }
}

# ── Final summary ─────────────────────────────────────────────────────────────
Write-Section -Path $LoginLog -Title "SCAN COMPLETE"
Write-Log -Path $LoginLog -Message "Finished at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log -Path $LoginLog -Message "Network map  : $NetworkLog"
Write-Log -Path $LoginLog -Message "Login results: $LoginLog"
Write-Log -Path $LoginLog -Message ""
Write-Log -Path $LoginLog -Message "KNOWN DEVICES IN YOUR ENVIRONMENT TO VERIFY:"
Write-Log -Path $LoginLog -Message "  192.168.0.10  — DOMECH Windows Server (DC)"
Write-Log -Path $LoginLog -Message "  192.168.0.11  — TrueNAS (planned, may not appear yet)"
Write-Log -Path $LoginLog -Message "  192.168.0.46  — eSSL x2008 biometric (SSH port 22 + 4370)"
Write-Log -Path $LoginLog -Message "  192.168.0.1   — TP-Link TL-R480T+ router"
Write-Log -Path $LoginLog -Message "  192.168.0.?   — Hikvision DVR (port 80, 8000, 554)"
Write-Log -Path $LoginLog -Message "  192.168.0.?   — AP-1 and AP-2 (identify by MAC OUI)"
Write-Log -Path $LoginLog -Message ""
Write-Log -Path $LoginLog -Message "Any IP in the log NOT on this list is an UNIDENTIFIED HOST — investigate."

Write-Host "`nDone. Files written to:" -ForegroundColor Green
Write-Host "  $NetworkLog" -ForegroundColor Green
Write-Host "  $LoginLog"   -ForegroundColor Green
