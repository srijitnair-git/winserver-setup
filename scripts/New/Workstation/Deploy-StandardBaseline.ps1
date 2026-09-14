<#
Domech Fabricators - standard workstation software baseline
Run from the server against each workstation, or locally on each machine.
DO NOT run this against the DC/SERVER - browsers/media apps are deliberately
excluded from the domain controller (see 1.8 Set-ServerHardening.ps1).

Bitdefender and Office 365 need their own setup (see notes below) - everything
else installs via winget.
#>

param(
    [string[]]$ComputerName
)

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot
if (-not $ComputerName) { $ComputerName = $Config.Workstations }
$WingetApps = $Config.WingetApps   # edit the list in config.json, not here

$installScript = {
    param($apps)
    $wingetPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    if (-not (Test-Path $wingetPath)) {
        Write-Output "$env:COMPUTERNAME : winget not found - install App Installer from Microsoft Store first."
        return
    }
    foreach ($id in $apps) {
        Write-Output "$env:COMPUTERNAME : installing $id ..."
        & $wingetPath install --id $id --silent --accept-package-agreements --accept-source-agreements --scope machine -h
    }
}

Write-Host "Deploying baseline to $($ComputerName -join ', ')..." -ForegroundColor Cyan
Invoke-Command -ComputerName $ComputerName -ScriptBlock $installScript -ArgumentList (,$WingetApps)

Write-Host @"

Done with winget apps. Two more to handle separately:

1. BITDEFENDER
   Download the customer-specific installer from your GravityZone console
   (Network > Packages), then push it the same way:
     Invoke-Command -ComputerName <PC> -ScriptBlock {
         Start-Process "\\SERVER\Software`$\Bitdefender\installer.exe" -ArgumentList "/silent" -Wait
     }
   Silent flag depends on the package GravityZone generates - check its docs page.

2. OFFICE 365 (Microsoft 365 Apps)
   Needs the Office Deployment Tool, not winget:
     a. Download ODT from Microsoft, place setup.exe + a config.xml on a share.
     b. config.xml example:
        <Configuration>
          <Add Channel="MonthlyEnterprise">
            <Product ID="O365ProPlusRetail">
              <Language ID="en-us" />
            </Product>
          </Add>
          <Display Level="None" AcceptEULA="TRUE" />
        </Configuration>
     c. Deploy:
        Invoke-Command -ComputerName <PC> -ScriptBlock {
            Start-Process "\\SERVER\Software`$\ODT\setup.exe" -ArgumentList "/configure \\SERVER\Software`$\ODT\config.xml" -Wait
        }
   Needs a valid Microsoft 365 licence assigned to each user's account first.

3. TALLYPRIME
   No installer - copy the TallyPrime folder to each machine and create a
   shortcut, or run it from a shared network path if your licence allows
   multi-seat network use (check your Tally licence terms).
"@ -ForegroundColor Yellow
