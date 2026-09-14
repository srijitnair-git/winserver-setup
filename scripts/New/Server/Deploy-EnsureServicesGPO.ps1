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
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot
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

# Writing scripts.ini into SYSVOL alone does NOT tell clients this GPO has a
# Computer Startup script - same "silently skipped, nothing in gpresult"
# failure as the Drive Maps / login-splash GPOs elsewhere in this toolkit.
# Register the legacy Scripts CSE on the MACHINE side (gPCMachineExtensionNames,
# not gPCUserExtensionNames - this is a startup script, not a logon script)
# and bump the GPO version so already-booted machines pick it up.
Write-Host "Registering the Scripts extension on the GPO..." -ForegroundColor Cyan
$scriptsExtensionPair = "[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]"
$gpoAdPath = "CN=Policies,CN=System,$domainDN"
$gpoAdObject = Get-ADObject -Filter "displayName -eq '$GpoName'" -SearchBase $gpoAdPath -Properties gPCMachineExtensionNames, versionNumber
if ($gpoAdObject) {
    $currentExt = $gpoAdObject.gPCMachineExtensionNames
    if (-not $currentExt -or $currentExt -notlike "*42B5FAAE*") {
        Set-ADObject -Identity $gpoAdObject.DistinguishedName -Replace @{ gPCMachineExtensionNames = "$currentExt$scriptsExtensionPair" }
        $newVersion = [int]$gpoAdObject.versionNumber + 65537   # bumps both the user and machine version halves
        Set-ADObject -Identity $gpoAdObject.DistinguishedName -Replace @{ versionNumber = $newVersion }
        $gptIniPath = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id)}\gpt.ini"
        (Get-Content $gptIniPath) -replace '^Version=\d+', "Version=$newVersion" | Set-Content $gptIniPath
        Write-Host "  Scripts extension registered, GPO version bumped to $newVersion so it gets reprocessed." -ForegroundColor Green
    } else {
        Write-Host "  Scripts extension already registered." -ForegroundColor Green
    }
} else {
    Write-Host "  Could not find the GPO's AD object to register the extension - the startup script will NOT run until this is done. Investigate manually in ADSI Edit: CN=Policies,CN=System,$domainDN, find the GPO by displayName, add $scriptsExtensionPair to gPCMachineExtensionNames." -ForegroundColor Red
}

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
