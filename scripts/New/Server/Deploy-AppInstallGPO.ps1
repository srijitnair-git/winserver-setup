<#
Domech Fabricators - deploy the standard app set fleet-wide

Run on the DC, elevated. Publishes Install-StandardApps.ps1 to NETLOGON with
the app list from config.json baked in, and registers it as a computer startup
script so every workstation installs and updates the set on its own.

Pull, not push: nothing here needs WinRM or for the server to reach the
workstation, so it also covers machines that are off or unreachable right now -
they pick it up at their next restart.

Edit config.json's WingetApps list and rerun this to change what is deployed.
#>

Import-Module GroupPolicy
Import-Module ActiveDirectory

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

$GpoName  = $Config.GPO.AppInstallGpoName
if (-not $GpoName) { $GpoName = "Domech - App Deployment" }
$domain   = (Get-ADDomain).DNSRoot
$domainDN = (Get-ADDomain).DistinguishedName

$apps = $Config.WingetApps
if (-not $apps) {
    Write-DomechLog "config.json has no WingetApps list - nothing to deploy." -Level Error
    exit 1
}
Write-DomechLog "Deploying $($apps.Count) app(s): $($apps -join ', ')" -Level Info

$gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $gpo) { $gpo = New-GPO -Name $GpoName }

# Link at the domain root, then deny it to Domain Controllers.
#
# Linking to the workstations OU instead looks tidier but silently misses any
# machine that was joined without being placed in that OU - they land in the
# default "Computers" container, which cannot have a GPO linked to it at all,
# so those PCs receive nothing and gpresult simply does not list the policy.
# A domain-root link reaches every machine regardless of where its account
# sits; denying Domain Controllers keeps Chrome, VLC and the rest off the
# server, which is the thing the OU link was protecting against.
New-GPLink -Name $GpoName -Target $domainDN -ErrorAction SilentlyContinue | Out-Null
Write-DomechLog "Linked at the domain root so it reaches every workstation whatever OU it is in." -Level Info
Block-DomainAdminsFromGPO -GpoName $GpoName -DomainDN $domainDN -GroupName "Domain Controllers"

# Report where the workstations actually live, since an account sitting in the
# default container is a good sign the domain join skipped the intended OU.
$expectedOU = $Config.Paths.ComputersOU
foreach ($pc in $Config.Workstations) {
    $comp = Get-ADComputer -Filter "Name -eq '$pc'" -ErrorAction SilentlyContinue
    if (-not $comp) {
        Write-DomechLog "  $pc : no computer account in AD - not domain joined under that name." -Level Warning
    } elseif ($expectedOU -and $comp.DistinguishedName -notlike "*$expectedOU") {
        Write-DomechLog "  $pc : sits in $($comp.DistinguishedName -replace '^CN=[^,]+,','') rather than the Domech Computers OU. Harmless now that the policy is linked domain-wide." -Level Info
    }
}

# Build the deployable copy with the app list baked in. Rebuilt from source
# every run rather than appended to, so rerunning after a config.json edit
# replaces the list instead of duplicating it.
$appLiteral = ($apps | ForEach-Object { "    `"$_`"" }) -join "`n"
$script = Get-Content "$PSScriptRoot\..\Workstation\Install-StandardApps.ps1" -Raw
$script = $script -replace '"__WINGET_APPS_PLACEHOLDER__"', $appLiteral.TrimStart()

# Also fire at logon, not only at boot.
#
# Installing software needs admin rights, and staff are standard users, so a
# plain logon script cannot do it - it would fail every time. A scheduled task
# triggered BY logon but running AS SYSTEM gets both: it reacts to someone
# signing in, with the rights to actually install. Same approach as the
# required-services deployment.
#
# The once-a-day guard inside the script means this costs nothing at a normal
# logon - it checks the timestamp and exits immediately. It matters for
# machines left on for days that rarely reboot.
$taskRegistration = @"

# Self-register the logon-triggered run on first execution on each machine.
`$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File \\$domain\NETLOGON\Install-StandardApps.ps1"
`$trigger   = New-ScheduledTaskTrigger -AtLogOn
`$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "Domech-InstallApps-Logon" -Action `$action -Trigger `$trigger -Principal `$principal -Force -ErrorAction SilentlyContinue
"@

$netlogonPath = "\\$domain\NETLOGON"
($script + $taskRegistration) | Out-File "$netlogonPath\Install-StandardApps.ps1" -Encoding UTF8 -Force
Write-DomechLog "Published to $netlogonPath\Install-StandardApps.ps1" -Level Success
Write-DomechLog "Runs at startup, and also at logon via a scheduled task running as SYSTEM - at most once a day either way." -Level Info

$scriptsPath = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id)}\Machine\Scripts"
New-Item -ItemType Directory -Path "$scriptsPath\Startup" -Force | Out-Null
@"
[Startup]
0CmdLine=powershell.exe
0Parameters=-ExecutionPolicy Bypass -File \\$domain\NETLOGON\Install-StandardApps.ps1
"@ | Out-File "$scriptsPath\scripts.ini" -Encoding Unicode

# Register the Scripts extension on the machine side and bump the version, or
# clients skip the startup script entirely with nothing logged anywhere.
$scriptsExtensionPair = "[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]"
$gpoAdPath   = "CN=Policies,CN=System,$domainDN"
$gpoAdObject = Get-ADObject -Filter "displayName -eq '$GpoName'" -SearchBase $gpoAdPath -Properties gPCMachineExtensionNames, versionNumber
if ($gpoAdObject) {
    $ext = $gpoAdObject.gPCMachineExtensionNames
    if (-not $ext -or $ext -notlike "*42B5FAAE*") {
        Set-ADObject -Identity $gpoAdObject.DistinguishedName -Replace @{ gPCMachineExtensionNames = "$ext$scriptsExtensionPair" }
        Write-DomechLog "Startup script extension registered on '$GpoName'." -Level Success
    }
    $newVersion = [int]$gpoAdObject.versionNumber + 65537
    Set-ADObject -Identity $gpoAdObject.DistinguishedName -Replace @{ versionNumber = $newVersion }
    $gptIni = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id)}\gpt.ini"
    (Get-Content $gptIni) -replace '^Version=\d+', "Version=$newVersion" | Set-Content $gptIni
    Write-DomechLog "GPO version bumped to $newVersion so workstations reprocess it." -Level Success
} else {
    Write-DomechLog "Could not find the '$GpoName' AD object - the startup script will NOT run until the extension is registered on it by hand in ADSI Edit (add $scriptsExtensionPair to gPCMachineExtensionNames)." -Level Error
}

Write-DomechLog "" -Level Info
Write-DomechLog "Done. Each workstation installs/updates the set at its next restart, then at most once a day after that." -Level Success
Write-DomechLog "Check progress on a workstation at C:\ProgramData\Domech\AppInstall.log" -Level Info
Write-DomechLog "Note: winget must exist on the workstation. It ships with Windows 11; on anything older, install 'App Installer' from the Microsoft Store once." -Level Warning
