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
    # "Apply Group Policy" extended right.
    $applyGpoRight = [guid]"edacfd8f-ffb3-11d1-b41d-00a0c968f939"
    try {
        $domainAdminsSid = (Get-ADGroup "Domain Admins").SID
        $gpoObject = Get-ADObject -Filter "displayName -eq '$GpoName'" -SearchBase "CN=Policies,CN=System,$DomainDN"
        if (-not $gpoObject) {
            Write-DomechLog "Could not find '$GpoName' AD object to exclude Domain Admins - do this manually in GPMC: select the GPO > Delegation tab > Advanced > Domain Admins > tick Deny on 'Apply group policy'." -Level Warning
            return
        }

        # Write the ACE through the AD: drive with Set-Acl. The previous version
        # used Set-ADObject -Replace nTSecurityDescriptor, which does not reliably
        # persist a modified descriptor - the deny silently never landed, and
        # Administrator kept receiving the staff folder redirection and C: drive
        # restriction. Always verify by reading it back (below) rather than
        # trusting that the write succeeded.
        $adPath = "AD:\$($gpoObject.DistinguishedName)"
        $acl = Get-Acl -Path $adPath
        $denyRule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $domainAdminsSid, "ExtendedRight", "Deny", $applyGpoRight)
        $acl.AddAccessRule($denyRule)
        Set-Acl -Path $adPath -AclObject $acl

        $confirmed = (Get-Acl -Path $adPath).Access | Where-Object {
            $_.ObjectType          -eq $applyGpoRight -and
            $_.AccessControlType   -eq 'Deny'         -and
            $_.IdentityReference.Value -like "*Domain Admins*"
        }
        if ($confirmed) {
            Write-DomechLog "Verified: Domain Admins are denied 'Apply group policy' on '$GpoName' - admin accounts no longer receive staff settings." -Level Success
        } else {
            Write-DomechLog "WROTE the deny on '$GpoName' but reading it back does NOT show it - the exclusion did not take. Set it by hand in GPMC: select the GPO > Delegation tab > Advanced > Domain Admins > tick Deny on 'Apply group policy'." -Level Error
        }
    } catch {
        Write-DomechLog "Automatic exclusion of Domain Admins from '$GpoName' failed: $($_.Exception.Message)" -Level Error
        Write-DomechLog "Do it by hand in GPMC: select '$GpoName' > Delegation tab > Advanced > Domain Admins > tick Deny on 'Apply group policy'." -Level Warning
    }
}
