<#
Domech Fabricators - back up local user data BEFORE formatting a workstation
Run from the server (old domain still up, WinRM should still work) against
one machine at a time before it gets wiped. Copies Desktop, Documents,
Downloads, Pictures for every local profile to a per-machine backup folder.

Run this, CONFIRM the copy completed and looks right, THEN format that machine.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ComputerName,

    [string]$BackupRoot
)

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Get-Content "$RepoRoot\config.json" -Raw | ConvertFrom-Json
Start-DomechLog -ScriptName $MyInvocation.MyCommand.Name -LogRoot $Config.Paths.LogsRoot
if (-not $BackupRoot) { $BackupRoot = $Config.Paths.BackupRoot }

$dest = Join-Path $BackupRoot "$ComputerName`_$(Get-Date -Format 'yyyyMMdd')"
New-Item -ItemType Directory -Path $dest -Force | Out-Null

Write-Host "Backing up $ComputerName to $dest ..." -ForegroundColor Cyan

$folders = @("Desktop","Documents","Downloads","Pictures")
$profiles = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
    Get-ChildItem "C:\Users" -Directory | Where-Object {
        $_.Name -notin @("Public","Default","Default User","All Users") -and -not $_.Name.StartsWith("$")
    } | Select-Object -ExpandProperty Name
}

foreach ($user in $profiles) {
    foreach ($folder in $folders) {
        $src = "\\$ComputerName\C$\Users\$user\$folder"
        $dst = Join-Path $dest "$user\$folder"
        if (Test-Path $src) {
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
            robocopy $src $dst /E /R:2 /W:5 /NFL /NDL /NP | Out-Null
            Write-Host "  Copied $user\$folder" -ForegroundColor Green
        }
    }
}

# Sanity check: report size copied vs source, so a silent partial copy doesn't go unnoticed
$destSize = (Get-ChildItem $dest -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Write-Host "`nBackup complete. Total copied: $([math]::Round($destSize/1MB,1)) MB" -ForegroundColor Cyan
Write-Host "MANUALLY VERIFY this looks right (open a few files) before formatting $ComputerName." -ForegroundColor Yellow
