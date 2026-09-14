<#
Domech Fabricators - shared logging, dot-sourced by every script in this folder.
Not meant to be run directly.
#>

$Global:DomechLogFile = $null

function Start-DomechLog {
    param(
        [string]$ScriptName,
        [string]$LogRoot = "C:\01_matrix\Logs"
    )
    New-Item -ItemType Directory -Path $LogRoot -Force -ErrorAction SilentlyContinue | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $Global:DomechLogFile = Join-Path $LogRoot "$($ScriptName)_$stamp.log"
    Write-DomechLog "===== Starting $ScriptName =====" -Level Info
}

function Write-DomechLog {
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)][string]$Message,
        [ValidateSet("Info","Success","Warning","Error")][string]$Level = "Info"
    )
    process {
        $color = switch ($Level) {
            "Success" { "Green" }
            "Warning" { "Yellow" }
            "Error"   { "Red" }
            default   { "Cyan" }
        }
        Write-Host $Message -ForegroundColor $color

        if ($Global:DomechLogFile) {
            $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [$Level]  $Message"
            Add-Content -Path $Global:DomechLogFile -Value $line
        }
    }
}

function Initialize-DomechContext {
    <#
    Loads config.json and starts logging - the two things every script needs
    before it does anything else. Centralized here so a missing/broken
    config.json fails with ONE clear message instead of cascading into
    confusing empty-path errors in every cmdlet that touches $Config.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ScriptName,
        [Parameter(Mandatory=$true)][string]$RepoRoot
    )
    $configPath = Join-Path $RepoRoot "config.json"
    if (-not (Test-Path $configPath)) {
        Write-Host "FATAL: config.json not found at $configPath" -ForegroundColor Red
        Write-Host "This file is deliberately not in the GitHub repo - copy it in manually from your source machine before running any script. See README.md." -ForegroundColor Red
        exit 1
    }
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Host "FATAL: config.json exists but isn't valid JSON: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    $logRoot = if ($config.Paths -and $config.Paths.LogsRoot) { $config.Paths.LogsRoot } else { "C:\01_matrix\Logs" }
    Start-DomechLog -ScriptName $ScriptName -LogRoot $logRoot
    return $config
}
