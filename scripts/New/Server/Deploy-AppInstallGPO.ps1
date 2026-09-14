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
New-GPLink -Name $GpoName -Target $domainDN -ErrorAction SilentlyContinue | Out-Null

# Build the deployable copy with the app list baked in. Rebuilt from source
# every run rather than appended to, so rerunning after a config.json edit
# replaces the list instead of duplicating it.
$appLiteral = ($apps | ForEach-Object { "    `"$_`"" }) -join "`n"
$script = Get-Content "$PSScriptRoot\..\Workstation\Install-StandardApps.ps1" -Raw
$script = $script -replace '"__WINGET_APPS_PLACEHOLDER__"', $appLiteral.TrimStart()

$netlogonPath = "\\$domain\NETLOGON"
$script | Out-File "$netlogonPath\Install-StandardApps.ps1" -Encoding UTF8 -Force
Write-DomechLog "Published to $netlogonPath\Install-StandardApps.ps1" -Level Success

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
