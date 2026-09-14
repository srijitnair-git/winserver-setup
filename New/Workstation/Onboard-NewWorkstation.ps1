<#
Domech Fabricators - one-machine onboarding, run right after a fresh Windows
install and before handing the PC back to the user.

Run LOCALLY on the freshly formatted machine (elevated PowerShell), since it
isn't domain-joined yet and the server can't reach it remotely until it is.
Copy the WHOLE C:\01_matrix folder over via USB first (not just this file) -
it walks back up to the root to read config.json for the domain name.

Sequence per machine:
  1. Format Windows (done manually / via install media - not scripted here)
  2. Run THIS script locally - joins DF.local, enables WinRM
  3. From the server: run the fleet scripts against this one machine
     (software baseline, RustDesk, ensure-services)
  4. GPOs (drive maps, wallpaper, lock screen, ensure-services) apply
     automatically on next login/reboot - nothing else to do
#>

param(
    [string]$DomainUserForJoin,     # e.g. DF\Administrator - needs rights to join computers

    [string]$TargetOU
)

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Get-Content "$RepoRoot\config.json" -Raw | ConvertFrom-Json
Start-DomechLog -ScriptName $MyInvocation.MyCommand.Name -LogRoot $Config.Paths.LogsRoot
if (-not $DomainUserForJoin) { $DomainUserForJoin = $Config.Domain.AdminUser }
if (-not $TargetOU) { $TargetOU = $Config.Paths.ComputersOU }

Write-Host "Enabling WinRM locally..." -ForegroundColor Cyan
Enable-PSRemoting -Force -SkipNetworkProfileCheck

Write-Host "Joining DF.local..." -ForegroundColor Cyan
$cred = Get-Credential -UserName $DomainUserForJoin -Message "Enter password to join DF.local"
Add-Computer -DomainName $Config.Domain.Name -OUPath $TargetOU -Credential $cred -Restart -Force

# Machine reboots here to complete the domain join.
# After reboot, log in once as a domain user on this machine to confirm GPOs
# apply, then run the fleet-wide scripts below FROM THE SERVER, targeting
# just this machine's hostname:
#
#   .\Test-WorkstationConnectivity.ps1 -ComputerName "NEWHOSTNAME"
#   .\Deploy-StandardBaseline.ps1      -ComputerName "NEWHOSTNAME"
#   .\Deploy-RustDesk-Unattended.ps1   -ComputerName "NEWHOSTNAME" -PermanentPassword "..."
#
# GPOs already linked at the domain level (drive maps, wallpaper, lock
# screen, Ensure-RequiredServices startup script) apply automatically -
# no separate step needed for those.
