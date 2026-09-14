<#
Domech Fabricators - deploy Ensure-RequiredServices.ps1 fleet-wide
Copies the script to NETLOGON, creates a GPO, and links a Computer Startup
script (primary - runs at boot, before login, no WinRM dependency) plus a
Scheduled Task that also fires at any user logon (backup, for machines that
sleep for days instead of rebooting).

Run once from the server as DF\Administrator.
#>

Import-Module GroupPolicy
Import-Module ActiveDirectory

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config   = Get-Content "$RepoRoot\config.json" -Raw | ConvertFrom-Json
Start-DomechLog -ScriptName $MyInvocation.MyCommand.Name -LogRoot $Config.Paths.LogsRoot
$GpoName  = $Config.GPO.EnsureServicesGpoName
$domain   = (Get-ADDomain).DNSRoot
$domainDN = (Get-ADDomain).DistinguishedName

$gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $gpo) { $gpo = New-GPO -Name $GpoName }
New-GPLink -Name $GpoName -Target $domainDN -ErrorAction SilentlyContinue | Out-Null

# ---- Build the deployable copy: inject config.json's service list, since
# the version running on each workstation can't read the server's config
# live. Built fresh from source every run - not appended to - so rerunning
# this after a config.json edit updates the list instead of duplicating code.
$netlogonPath = "\\$domain\NETLOGON"
$serviceListLiteral = ($Config.RequiredServices | ForEach-Object { "    `"$_`"" }) -join "`n"
$scriptContent = Get-Content "$PSScriptRoot\..\Workstation\Ensure-RequiredServices.ps1" -Raw
$scriptContent = $scriptContent -replace '"__REQUIRED_SERVICES_PLACEHOLDER__"', $serviceListLiteral.TrimStart()

# ---- Register as a Computer Startup script ----
# GPMC doesn't expose a direct cmdlet for this - it's done by writing the
# scripts.ini under the GPO's Machine\Scripts\Startup folder.
$scriptsPath = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id)}\Machine\Scripts"
New-Item -ItemType Directory -Path "$scriptsPath\Startup" -Force | Out-Null

@"
[Startup]
0CmdLine=powershell.exe
0Parameters=-ExecutionPolicy Bypass -File \\$domain\NETLOGON\Ensure-RequiredServices.ps1
"@ | Out-File "$scriptsPath\scripts.ini" -Encoding Unicode

Write-Host "Computer Startup script registered in GPO '$GpoName'." -ForegroundColor Green
Write-Host "IMPORTANT: open Group Policy Management, edit '$GpoName' > Computer Configuration > Policies > Windows Settings > Scripts > Startup once, click OK without changes - this forces Windows to re-read scripts.ini and pick it up. (A GPMC quirk; the file alone is sometimes not enough until the GPO is touched once.)" -ForegroundColor Yellow

# ---- Backup: Scheduled Task that also runs at any user logon ----
# Deployed via GPO Preferences > Scheduled Tasks would need GPMC too, so
# this uses a simpler, reliable path: a GPO computer startup script (above)
# that itself REGISTERS a local scheduled task on first run of each machine.
$taskRegistration = @"

# Self-register the logon-triggered backup task on first run of each machine
`$action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File \\$domain\NETLOGON\Ensure-RequiredServices.ps1"
`$trigger = New-ScheduledTaskTrigger -AtLogOn
`$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "Domech-EnsureServices-Logon" -Action `$action -Trigger `$trigger -Principal `$principal -Force -ErrorAction SilentlyContinue
"@

($scriptContent + $taskRegistration) | Out-File "$netlogonPath\Ensure-RequiredServices.ps1" -Encoding UTF8 -Force

Write-Host "`nDone. Every machine will now: (1) run the service check at every boot via GPO, and (2) register a local scheduled task that reruns it at every user logon too." -ForegroundColor Green
Write-Host "Test on one machine with 'gpupdate /force' + reboot, then check C:\ProgramData\Domech\ServiceCheck.log there." -ForegroundColor Green
