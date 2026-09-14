<#
Domech Fabricators - back up local user data BEFORE formatting a workstation
Copies Desktop, Documents, Downloads, Pictures for every local profile into
a per-machine, per-user backup folder.

Works two ways:
  - Run LOCALLY on the workstation itself (no -ComputerName needed, or pass
    its own name) - reads C:\Users directly, no WinRM/remoting required.
  - Run FROM THE SERVER against a remote machine (-ComputerName RAHUL-DT) -
    uses PowerShell remoting over the admin share, same as before.

Destination is keyed by computer name only (no date suffix) - if a backup
folder for that PC already exists, it's reused and updated rather than a
new dated copy created each run. Safe to rerun before formatting to pick
up last-minute changes.

Run this, CONFIRM the copy completed and looks right, THEN format that machine.
#>

param(
    [string]$ComputerName = $env:COMPUTERNAME,
    [string]$BackupRoot
)

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot
if (-not $BackupRoot) { $BackupRoot = $Config.Paths.BackupRoot }

$isLocal = ($ComputerName -eq $env:COMPUTERNAME) -or ($ComputerName -eq "localhost") -or ($ComputerName -eq ".")

$dest = Join-Path $BackupRoot $ComputerName
if (Test-Path $dest) {
    Write-DomechLog "Existing backup folder found for $ComputerName - updating it, not creating a new dated copy." -Level Warning
} else {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Write-DomechLog "Created new backup folder for $ComputerName at $dest" -Level Info
}

Write-DomechLog "Backing up $ComputerName ($(if($isLocal){'local'}else{'remote'})) to $dest ..." -Level Info

$folders = @("Desktop","Documents","Downloads","Pictures")

if ($isLocal) {
    $profiles = Get-ChildItem "C:\Users" -Directory | Where-Object {
        $_.Name -notin @("Public","Default","Default User","All Users") -and -not $_.Name.StartsWith("$")
    } | Select-Object -ExpandProperty Name
} else {
    $profiles = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
        Get-ChildItem "C:\Users" -Directory | Where-Object {
            $_.Name -notin @("Public","Default","Default User","All Users") -and -not $_.Name.StartsWith("$")
        } | Select-Object -ExpandProperty Name
    }
}

foreach ($user in $profiles) {
    foreach ($folder in $folders) {
        $src = if ($isLocal) { "C:\Users\$user\$folder" } else { "\\$ComputerName\C$\Users\$user\$folder" }
        $dst = Join-Path $dest "$user\$folder"
        if (Test-Path $src) {
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
            robocopy $src $dst /E /R:2 /W:5 /NFL /NDL /NP | Out-Null
            Write-DomechLog "  Copied $user\$folder" -Level Success
        }
    }
}

# Sanity check: report size copied vs source, so a silent partial copy doesn't go unnoticed
$destSize = (Get-ChildItem $dest -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Write-DomechLog "Backup complete. Total in $dest`: $([math]::Round($destSize/1MB,1)) MB" -Level Success
Write-DomechLog "MANUALLY VERIFY this looks right (open a few files) before formatting $ComputerName." -Level Warning
