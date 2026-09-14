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
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)][AllowEmptyString()][string]$Message,
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

    # Several scripts write one-off output files (passwords, CSVs, exports)
    # straight into Scratch without creating it first - Add-Content/Export-Csv
    # don't create missing parent folders themselves. Guarantee it exists here
    # once, rather than repeating a New-Item in every script that uses it.
    $scratchRoot = if ($config.Paths -and $config.Paths.ScratchRoot) { $config.Paths.ScratchRoot } else { "C:\01_matrix\Scratch" }
    New-Item -ItemType Directory -Path $scratchRoot -Force -ErrorAction SilentlyContinue | Out-Null

    return $config
}

function Block-DomainAdminsFromGPO {
    <#
    Denies "Apply Group Policy" to Domain Admins on the given GPO, so IT/admin
    accounts (Administrator, etc.) never receive settings meant for regular
    staff - department drive maps, personal folder redirection, C: drive
    restriction. Without this, Administrator gets folder redirection pointed
    at a personal share that doesn't exist for it (it's not in config.json's
    Users list), producing "Windows cannot access \\SERVER\Administrator$\..."
    errors on login.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$GpoName,
        [Parameter(Mandatory=$true)][string]$DomainDN
    )
    try {
        $domainAdminsSid = (Get-ADGroup "Domain Admins").SID
        $gpoAdPath = "CN=Policies,CN=System,$DomainDN"
        $gpoObject = Get-ADObject -Filter "displayName -eq '$GpoName'" -SearchBase $gpoAdPath -Properties nTSecurityDescriptor
        if ($gpoObject) {
            $acl = $gpoObject.nTSecurityDescriptor
            $denyRule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                $domainAdminsSid, "ExtendedRight", "Deny", [guid]"edacfd8f-ffb3-11d1-b41d-00a0c968f939")
            $acl.AddAccessRule($denyRule)
            Set-ADObject -Identity $gpoObject.DistinguishedName -Replace @{nTSecurityDescriptor = $acl}
            Write-DomechLog "Domain Admins excluded from '$GpoName' - IT/admin accounts won't get settings meant for regular staff." -Level Success
        } else {
            Write-DomechLog "Could not find '$GpoName' AD object to exclude Domain Admins - do this manually in GPMC: GPO Scope tab > Delegation > Advanced > Domain Admins > Deny 'Apply group policy'." -Level Warning
        }
    } catch {
        Write-DomechLog "Automatic exclusion of Domain Admins from '$GpoName' failed: $($_.Exception.Message)" -Level Warning
        Write-DomechLog "Do it manually in GPMC: edit '$GpoName' > Delegation tab > Advanced > Domain Admins > Deny 'Apply group policy'." -Level Warning
    }
}
