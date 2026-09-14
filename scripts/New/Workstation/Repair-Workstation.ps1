<#
Domech Fabricators - one-shot workstation repair
Run ON the workstation, signed in as the person who actually uses it.

Do the server first. Almost everything a workstation gets - drive mappings,
folder redirection, the C: drive restriction - is handed down by the server,
so repairing a workstation before the server is fixed just gets undone at the
next logon.

What it does:
  1. Repairs this user's profile if folder redirection points somewhere dead
  2. Forces a policy refresh
  3. Reports which drives actually mounted, so you can see if it worked
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

Write-Host ""
Write-Host "Repairing workstation for: $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host ""

Write-Host "===== STEP 1/3: Repair this user's profile =====" -ForegroundColor Cyan
& "$ScriptsRoot\Repair-UserProfile.ps1"

Write-Host ""
Write-Host "===== STEP 2/3: Refresh Group Policy =====" -ForegroundColor Cyan
gpupdate /force | Out-String | Write-Host

Write-Host ""
Write-Host "===== STEP 3/3: Which drives are actually mapped =====" -ForegroundColor Cyan
$mapped = Get-SmbMapping -ErrorAction SilentlyContinue
if ($mapped) {
    $mapped | Format-Table LocalPath, RemotePath, Status -AutoSize | Out-String | Write-Host
} else {
    Write-Host "No network drives are mapped right now." -ForegroundColor Yellow
    Write-Host "That is expected until you sign out and back in - Windows only applies drive maps at logon." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "DONE. Now sign out completely and sign back in (not lock, not restart-only)." -ForegroundColor Green
Write-Host "After signing back in you should see: your department drives, your P: drive," -ForegroundColor Green
Write-Host "and a working Desktop/Documents." -ForegroundColor Green
Write-Host ""
Write-Host "If drives are still missing after that, run this on the same machine as the same user:" -ForegroundColor Yellow
Write-Host "  C:\01_matrix\Run-Diagnostics.bat   -> option 1" -ForegroundColor Yellow
Write-Host "and send the log file it writes - that shows exactly which policy did or didn't arrive." -ForegroundColor Yellow
