<#
Domech Fabricators - DF.local forest promotion (Step 1)
Run as local Administrator on the fresh Server 2019 SSD.
No D: drive exists yet - NTDS/SYSVOL go on C:. Reboots automatically at the end.
#>

[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Get-Content "$RepoRoot\config.json" -Raw | ConvertFrom-Json
Start-DomechLog -ScriptName $MyInvocation.MyCommand.Name -LogRoot $Config.Paths.LogsRoot

$DomainName  = $Config.Domain.Name
$NetbiosName = $Config.Domain.NetbiosName
$DbPath      = "C:\Windows\NTDS"
$LogPath     = "C:\Windows\NTDS"
$SysvolPath  = "C:\Windows\SYSVOL"

Write-Host "Installing AD DS role..." -ForegroundColor Cyan
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools

Write-Host "Set the Directory Services Restore Mode (DSRM) password when prompted." -ForegroundColor Yellow
$SafeModePwd = Read-Host "Enter DSRM password" -AsSecureString

Write-Host "Promoting to first DC of new forest $DomainName ..." -ForegroundColor Cyan
Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetbiosName `
    -DatabasePath $DbPath `
    -LogPath $LogPath `
    -SysvolPath $SysvolPath `
    -SafeModeAdministratorPassword $SafeModePwd `
    -InstallDns:$true `
    -ForestMode WinThreshold `
    -DomainMode WinThreshold `
    -NoRebootOnCompletion:$false `
    -Force:$true
