<#
Domech Fabricators - WinRM reachability check
Run from the server before any Invoke-Command deployment, to see which
machines are reachable and which need manual/GPO remediation first.
#>

param(
    [string[]]$ComputerName
)

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Get-Content "$RepoRoot\config.json" -Raw | ConvertFrom-Json
Start-DomechLog -ScriptName $MyInvocation.MyCommand.Name -LogRoot $Config.Paths.LogsRoot
if (-not $ComputerName) { $ComputerName = $Config.Workstations }

$results = foreach ($pc in $ComputerName) {
    $reachable = $false
    $pingOk = Test-Connection -ComputerName $pc -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($pingOk) {
        try {
            Test-WSMan -ComputerName $pc -ErrorAction Stop | Out-Null
            $reachable = $true
        } catch { $reachable = $false }
    }
    [PSCustomObject]@{
        Computer     = $pc
        Pingable     = $pingOk
        WinRM_OK     = $reachable
        Status       = if ($reachable) { "Ready" } elseif ($pingOk) { "Online, WinRM DOWN - needs GPO fix, can't remote-enable" } else { "Unreachable - offline or wrong name/IP" }
    }
}

$results | Format-Table -AutoSize
$results | Export-Csv "C:\01_matrix\Scratch\WorkstationConnectivity.csv" -NoTypeInformation
Write-Host "`nSaved to C:\01_matrix\Scratch\WorkstationConnectivity.csv" -ForegroundColor Cyan

$failed = $results | Where-Object { -not $_.WinRM_OK }
if ($failed) {
    Write-Host "`n$($failed.Count) machine(s) not ready for remote deployment:" -ForegroundColor Yellow
    $failed | ForEach-Object { Write-Host "  $($_.Computer): $($_.Status)" -ForegroundColor Yellow }
    Write-Host "Deploy Ensure-RequiredServices.ps1 via GPO startup script (see Deploy-EnsureServicesGPO.ps1) - it doesn't need WinRM to already work." -ForegroundColor Yellow
}
