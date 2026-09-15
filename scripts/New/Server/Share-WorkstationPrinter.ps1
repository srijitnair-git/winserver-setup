<#
Domech Fabricators - share a USB printer from the PC it is plugged into

Run on the DC, elevated. Shares a printer that is attached to one workstation
so other people can print to it.

  .\Share-WorkstationPrinter.ps1 -ComputerName GOKUL-DF
      lists the printers on that PC, changes nothing

  .\Share-WorkstationPrinter.ps1 -ComputerName GOKUL-DF -PrinterName "HP LaserJet Tank MFP 260x" -ShareName HPTank
      shares it and prints the path to put in config.json

READ THIS BEFORE SHARING A USB PRINTER

  - The host PC must be switched on and awake, or nobody else can print.
    A printer shared from someone's desktop is only as available as that desk.
  - Printing routes through that person's PC and will slow them down.
  - Windows 11 blocks installing a printer driver from a shared printer unless
    the person connecting is a local admin. Your staff are not. So the driver
    has to already be on each PC that will print to it, or the connection
    silently fails or asks for admin credentials nobody has.

For anything more than occasional use the Brother is the better answer: it is
a real network printer, always available, and its driver comes from the server
automatically.
#>

param(
    [Parameter(Mandatory=$true)][string]$ComputerName,
    [string]$PrinterName,
    [string]$ShareName
)

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

if (-not (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
    Write-DomechLog "$ComputerName is not reachable - switched off, or the name is wrong." -Level Error
    exit 1
}

# ---- no printer named: just list what is there ----
if (-not $PrinterName) {
    Write-DomechLog "Printers on $ComputerName :" -Level Info
    try {
        Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {
            Get-Printer | Where-Object { $_.Name -notmatch 'OneNote|Microsoft Print to PDF|Microsoft XPS|Fax' } |
                Select-Object Name, DriverName, PortName, Shared, ShareName
        } | Format-Table -AutoSize | Out-String | Write-DomechLog -Level Info
        Write-DomechLog "Rerun with -PrinterName '<name>' to share one." -Level Info
    } catch {
        Write-DomechLog "Could not query $ComputerName (WinRM down?): $($_.Exception.Message)" -Level Error
    }
    exit 0
}

# ---- share it ----
if (-not $ShareName) { $ShareName = ($PrinterName -replace '[^A-Za-z0-9]', '') }

try {
    $result = Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ArgumentList $PrinterName, $ShareName -ScriptBlock {
        param($name, $share)
        $printer = Get-Printer -Name $name -ErrorAction SilentlyContinue
        if (-not $printer) { return "NOTFOUND" }

        Set-Printer -Name $name -Shared $true -ShareName $share
        # Without this the share exists but nothing can reach it.
        Enable-NetFirewallRule -DisplayGroup "File and Printer Sharing" -ErrorAction SilentlyContinue

        $check = Get-Printer -Name $name
        if ($check.Shared -and $check.ShareName -eq $share) { return "OK" } else { return "FAILED" }
    }

    switch ($result) {
        "OK" {
            Write-DomechLog "Shared '$PrinterName' on $ComputerName as '$ShareName'." -Level Success
            Write-DomechLog "" -Level Info
            Write-DomechLog "To give it to people, add this to config.json's Printers list and run 'Deploy printers to users':" -Level Info
            Write-DomechLog "    { `"Name`": `"$PrinterName`", `"Path`": `"\\\\$ComputerName\\$ShareName`", `"Groups`": [], `"Default`": false }" -Level Info
            Write-DomechLog "" -Level Info
            Write-DomechLog "Remember: $ComputerName must be switched on, and the driver must already be installed on each PC that prints to it - Windows 11 will not let a standard user install one from a shared printer." -Level Warning
        }
        "NOTFOUND" { Write-DomechLog "No printer called '$PrinterName' on $ComputerName. Run without -PrinterName to list them." -Level Error }
        default    { Write-DomechLog "Sharing did not take on $ComputerName - check it by hand on that PC." -Level Error }
    }
} catch {
    Write-DomechLog "Could not reach $ComputerName over WinRM: $($_.Exception.Message)" -Level Error
}
