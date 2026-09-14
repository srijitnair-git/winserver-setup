<#
Domech Fabricators - ensure required services are running
Deployed via GPO as a COMPUTER startup script (runs as SYSTEM, before any
user logs in - works even if WinRM is currently off, since this doesn't
rely on remoting). Also safe to link as a logon-triggered scheduled task
as a backup for machines that sleep for days without rebooting.

The service list below is injected from config.json's RequiredServices array
by Deploy-EnsureServicesGPO.ps1 at deploy time - edit config.json, not this
placeholder, then rerun that deploy script to push the update to NETLOGON.
#>

$RequiredServices = @(
    "__REQUIRED_SERVICES_PLACEHOLDER__"
)

$logPath = "C:\ProgramData\Domech\ServiceCheck.log"
New-Item -ItemType Directory -Path (Split-Path $logPath) -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Out-File $logPath -Append
}

# Make sure WinRM is actually enabled for remoting, not just installed
try {
    if ((Get-Service WinRM).Status -ne 'Running') {
        Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop
        Write-Log "WinRM was down - ran Enable-PSRemoting."
    }
} catch {
    Write-Log "Enable-PSRemoting failed: $($_.Exception.Message)"
}

foreach ($svcName in $RequiredServices) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "Service '$svcName' not found on this machine - check the name or whether it's installed here."
        continue
    }
    if ($svc.StartType -ne 'Automatic') {
        Set-Service -Name $svcName -StartupType Automatic
        Write-Log "Set '$svcName' startup type to Automatic (was $($svc.StartType))."
    }
    if ($svc.Status -ne 'Running') {
        try {
            Start-Service -Name $svcName -ErrorAction Stop
            Write-Log "Started '$svcName' (was $($svc.Status))."
        } catch {
            Write-Log "Failed to start '$svcName': $($_.Exception.Message)"
        }
    }
}
