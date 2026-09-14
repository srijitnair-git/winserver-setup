<#
Domech Fabricators - clear out the old Salary / Purchase folders

Run on the DC, elevated. These two top-level folders are left over from
before Salary and Purchase were consolidated. The live data now lives in:

  D:\Domech\Salary Wages & Purchase\Purchase
  D:\Domech\Salary Wages & Purchase\Salary Wages

An empty leftover folder is removed. A folder with anything in it is MOVED
to a dated _Archive_ folder instead of being deleted, so nothing can be lost
by running this - review the archive yourself and delete it when satisfied.

Nothing inside "Salary Wages & Purchase" is touched.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

$DataRoot = $Config.Paths.DataRoot

foreach ($leaf in @("Salary", "Purchase")) {
    $p = Join-Path $DataRoot $leaf
    if (-not (Test-Path $p)) {
        Write-DomechLog "$p doesn't exist - nothing to do." -Level Info
        continue
    }
    $files = Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue
    if ($files) {
        $archive = Join-Path $DataRoot "_Archive_${leaf}_$(Get-Date -Format yyyyMMdd)"
        Write-DomechLog "$p holds $($files.Count) file(s) - moving to $archive rather than deleting. Check it, then delete by hand." -Level Warning
        Move-Item $p $archive
    } else {
        Remove-Item $p -Recurse -Force
        Write-DomechLog "$p was empty - removed." -Level Success
    }
}

# Also drop the old share definitions if they're still published. This removes
# only the network share, never any files.
foreach ($staleShare in @("Salary$", "Purchase$")) {
    if (Get-SmbShare -Name $staleShare -ErrorAction SilentlyContinue) {
        Remove-SmbShare -Name $staleShare -Force
        Write-DomechLog "Removed the old '$staleShare' share (replaced by SalaryWagesPurchase`$)." -Level Success
    }
}

Write-DomechLog "" -Level Info
Write-DomechLog "Done. Everyone reaches this data through the W: drive -> \\$env:COMPUTERNAME\SalaryWagesPurchase`$" -Level Success
