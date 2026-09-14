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
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("Info","Success","Warning","Error")][string]$Level = "Info"
    )
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

# Register a summary line at process exit so every run's outcome is visible
# at a glance without opening the log file.
$Global:DomechErrorCount = 0
$Global:DomechWarningCount = 0
