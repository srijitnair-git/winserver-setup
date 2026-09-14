<#
Domech Fabricators - pull the latest scripts from GitHub
Only the contents of THIS folder (scripts\) are versioned in the repo -
config.json and Logs stay local and are never touched by this.

Uses git if available (incremental, preferred). Falls back to downloading
the branch as a zip if git isn't installed.
#>

. "$PSScriptRoot\DomechCommon.ps1"
$Config = Get-Content "$PSScriptRoot\..\config.json" -Raw | ConvertFrom-Json
Start-DomechLog -ScriptName $MyInvocation.MyCommand.Name -LogRoot $Config.Paths.LogsRoot

$repoUrl = $Config.GitHubRepo.Url
$branch  = $Config.GitHubRepo.Branch
if (-not $repoUrl -or $repoUrl -like "*YOUR-ORG*") {
    Write-DomechLog "GitHubRepo.Url is not set in config.json - edit that first." -Level Error
    exit 1
}

$gitAvailable = (Get-Command git -ErrorAction SilentlyContinue) -ne $null

if ($gitAvailable -and (Test-Path "$PSScriptRoot\.git")) {
    Write-DomechLog "Running git pull in $PSScriptRoot ..." -Level Info
    Push-Location $PSScriptRoot
    $output = git pull origin $branch 2>&1
    Pop-Location
    Write-DomechLog ($output -join "`n") -Level Info
    Write-DomechLog "Scripts updated via git pull." -Level Success
}
elseif ($gitAvailable) {
    Write-DomechLog "No existing git repo here - cloning fresh into a temp folder and merging in..." -Level Warning
    $tmp = Join-Path $env:TEMP "domech-scripts-clone"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    git clone --branch $branch $repoUrl $tmp 2>&1 | ForEach-Object { Write-DomechLog $_ -Level Info }
    if (Test-Path $tmp) {
        Copy-Item "$tmp\*" $PSScriptRoot -Recurse -Force -Exclude "config.json"
        Remove-Item $tmp -Recurse -Force
        Write-DomechLog "Scripts updated via fresh git clone." -Level Success
    } else {
        Write-DomechLog "git clone failed - check the URL/branch and network access." -Level Error
        exit 1
    }
}
else {
    Write-DomechLog "git not found - falling back to zip download." -Level Warning
    $zipUrl = ($repoUrl -replace '\.git$','') + "/archive/refs/heads/$branch.zip"
    $zipPath = Join-Path $env:TEMP "domech-scripts.zip"
    $extractPath = Join-Path $env:TEMP "domech-scripts-extract"
    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        $innerFolder = Get-ChildItem $extractPath -Directory | Select-Object -First 1
        Copy-Item "$($innerFolder.FullName)\*" $PSScriptRoot -Recurse -Force
        Remove-Item $zipPath, $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-DomechLog "Scripts updated via zip download." -Level Success
    } catch {
        Write-DomechLog "Zip download failed: $($_.Exception.Message)" -Level Error
        exit 1
    }
}

Write-DomechLog "Update complete." -Level Success
