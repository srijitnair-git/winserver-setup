<#
Domech Fabricators - diagnose why GPP drive maps aren't mounting
Run LOCALLY on the affected workstation, logged in as the affected user
(not as an admin on their behalf - the drive maps are user-context).

Reports, in order:
  1. Currently mapped drives (net use + Get-SmbMapping)
  2. Group Policy Drive Maps errors from the operational event log
  3. Confirms which GPOs applied for this logon (gpresult)
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

Write-DomechLog "===== Currently mapped drives =====" -Level Info
net use | Out-String | Write-DomechLog -Level Info
Get-SmbMapping | Format-Table -AutoSize | Out-String | Write-DomechLog -Level Info

Write-DomechLog "===== Group Policy operational log - Drive Maps / Preference entries (last 50) =====" -Level Info
try {
    $events = Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" -MaxEvents 200 -ErrorAction Stop |
        Where-Object { $_.Message -match "Drive|Preference" }
    if ($events) {
        $events | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List | Out-String | Write-DomechLog -Level Info
    } else {
        Write-DomechLog "No Drive/Preference related entries found in the last 200 GroupPolicy operational events." -Level Warning
    }
} catch {
    Write-DomechLog "Could not read the GroupPolicy operational log: $($_.Exception.Message)" -Level Warning
}

Write-DomechLog "===== gpresult /r (applied GPOs for this logon) =====" -Level Info
gpresult /r | Out-String | Write-DomechLog -Level Info

Write-DomechLog "Done. Full output saved to the log file for this run - send that file back rather than re-typing terminal output." -Level Success
