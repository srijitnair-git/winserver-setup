<#
Domech Fabricators - one-shot site repair
Run this ONE script on the DC (elevated PowerShell, as DF\Administrator)
instead of chaining menu items 4/5/6/7 by hand. It runs them in the
correct order:

  1. Pull latest scripts from GitHub
  2. Archive pre-consolidation Salary/Purchase folders (D:\Domech\Salary,
     D:\Domech\Purchase) if they still exist - the live data already lives
     under D:\Domech\Salary Wages & Purchase\ now
  3. Full DF.local setup (users, groups, shares, ACLs, drive-map GPO)
  4. Restrict C: drive access GPO
  5. Ensure Required Services GPO

Each of these is independently idempotent/safe to rerun - this script just
saves you from having to run them one at a time and get the order right.
Safe to rerun this whole thing again later too.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot | Out-Null

Write-DomechLog "===== STEP 1/5: Update scripts from GitHub =====" -Level Info
& "$ScriptsRoot\Update-Scripts.ps1"

Write-DomechLog "===== STEP 2/5: Archive pre-consolidation Salary/Purchase folders =====" -Level Info
foreach ($p in @("D:\Domech\Salary", "D:\Domech\Purchase")) {
    if (-not (Test-Path $p)) {
        Write-DomechLog "$p doesn't exist - nothing to do." -Level Info
        continue
    }
    $files = Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue
    if ($files) {
        $archive = "D:\Domech\_Archive_$(Split-Path $p -Leaf)_$(Get-Date -Format yyyyMMdd)"
        Write-DomechLog "$p has $($files.Count) file(s) - moving to $archive instead of deleting (review it, delete manually once confirmed it's junk)." -Level Warning
        Move-Item $p $archive
    } else {
        Write-DomechLog "$p is empty - removing." -Level Info
        Remove-Item $p -Recurse -Force
    }
}

Write-DomechLog "===== STEP 3/5: Full DF.local setup (users/groups/shares/ACLs/drive maps) =====" -Level Info
& "$PSScriptRoot\Setup-DFLocal-Full.ps1"

Write-DomechLog "===== STEP 4/5: Restrict C: drive access =====" -Level Info
& "$PSScriptRoot\Restrict-CDriveAccess.ps1"

Write-DomechLog "===== STEP 5/5: Deploy Ensure Required Services GPO =====" -Level Info
& "$PSScriptRoot\Deploy-EnsureServicesGPO.ps1"

Write-DomechLog "`n===== ALL STEPS DONE =====" -Level Success
Write-DomechLog "Remaining, can't be scripted from here:" -Level Warning
Write-DomechLog "  1. Fully log off (not lock, not just gpupdate) the Administrator session on this DC, then log back in." -Level Warning
Write-DomechLog "  2. On each workstation, fully log off/on the actual user (rahul, gokul, priyanka, supriya, mansi, sneha, nisha, and the newly created accounts) so they pick up the corrected group membership, drive maps, and P: personal drive." -Level Warning
Write-DomechLog "  3. Spot-check with Run-Diagnostics.bat -> 1 (Diagnose drive mapping) while logged in as one of them." -Level Warning
