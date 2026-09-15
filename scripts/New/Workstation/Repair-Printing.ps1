<#
Domech Fabricators - nothing prints on this PC

Run ON the affected PC, elevated.

When EVERY printer stops working at once - the network one and a USB one
plugged into this machine - the fault is almost never the printers. A USB
printer does not care about the network, so anything that breaks both is on
this PC: the print service has stopped, or one jammed job has blocked the
queue for everything behind it.

Checks and fixes, least invasive first:
  1. Is the print service running
  2. What printers exist and what state are they in
  3. Is anything stuck in the queue
  4. Clear the jam if there is one
  5. Can the network printer be reached

Clearing the queue discards jobs waiting to print. Anything already on paper is
unaffected; anything waiting has to be printed again.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

Write-DomechLog "===== Printing check on $env:COMPUTERNAME (as $env:USERNAME) =====" -Level Info

# ---- 1. the print service ----
Write-DomechLog "" -Level Info
Write-DomechLog "1. Print service" -Level Info
$spooler = Get-Service -Name Spooler -ErrorAction SilentlyContinue
if (-not $spooler) {
    Write-DomechLog "   The Print Spooler service is not present on this machine at all." -Level Error
    exit 1
}
Write-DomechLog "   Status: $($spooler.Status), starts: $($spooler.StartType)" -Level $(if ($spooler.Status -eq 'Running') { 'Success' } else { 'Error' })

if ($spooler.StartType -ne 'Automatic') {
    Set-Service -Name Spooler -StartupType Automatic -ErrorAction SilentlyContinue
    Write-DomechLog "   Set it to start automatically (was $($spooler.StartType)) - it was not coming back after a restart." -Level Warning
}
if ($spooler.Status -ne 'Running') {
    try {
        Start-Service -Name Spooler -ErrorAction Stop
        Write-DomechLog "   Started it. THIS IS ALMOST CERTAINLY THE FAULT - with the service stopped, no printer works and most of them vanish from the list." -Level Success
    } catch {
        Write-DomechLog "   Could not start it: $($_.Exception.Message)" -Level Error
    }
}

# ---- 2. what printers are here ----
Write-DomechLog "" -Level Info
Write-DomechLog "2. Printers on this PC" -Level Info
$printers = Get-Printer -ErrorAction SilentlyContinue
if (-not $printers) {
    Write-DomechLog "   NONE. If the service was just started above, sign out and back in - they should reappear." -Level Error
} else {
    foreach ($p in $printers) {
        $state = "$($p.PrinterStatus)"
        $level = if ($state -match 'Normal|Idle') { 'Success' } else { 'Warning' }
        Write-DomechLog "   $($p.Name)" -Level $level
        Write-DomechLog "      type: $($p.Type)   port: $($p.PortName)   state: $state" -Level Info
    }
    $default = Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Where-Object { $_.Default }
    Write-DomechLog "   Default printer: $(if ($default) { $default.Name } else { 'NONE SET - Windows will not know where to send a print' })" -Level $(if ($default) { 'Success' } else { 'Warning' })
}

# ---- 3. anything stuck ----
Write-DomechLog "" -Level Info
Write-DomechLog "3. Jobs waiting in the queue" -Level Info
$jobs = @()
foreach ($p in $printers) {
    try { $jobs += Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue } catch { }
}
if ($jobs) {
    foreach ($j in $jobs) {
        Write-DomechLog "   $($j.DocumentName) on $($j.PrinterName) - $($j.JobStatus), submitted $($j.SubmittedTime)" -Level Warning
    }
    Write-DomechLog "   $($jobs.Count) job(s) waiting. One job that cannot print blocks every job behind it, on every printer." -Level Warning
} else {
    Write-DomechLog "   Nothing waiting." -Level Success
}

# ---- 4. clear a jam ----
# Deleting the spool files is the reliable way to clear a stuck queue; removing
# jobs individually often fails on the very job that is jammed.
if ($jobs) {
    Write-DomechLog "" -Level Info
    Write-DomechLog "4. Clearing the queue" -Level Warning
    Write-DomechLog "   Jobs waiting to print will be discarded and must be sent again." -Level Warning
    try {
        Stop-Service -Name Spooler -Force -ErrorAction Stop
        $spoolDir = Join-Path $env:SystemRoot "System32\spool\PRINTERS"
        $files = Get-ChildItem $spoolDir -File -ErrorAction SilentlyContinue
        if ($files) {
            $files | Remove-Item -Force -ErrorAction SilentlyContinue
            Write-DomechLog "   Removed $($files.Count) stuck spool file(s)." -Level Success
        }
        Start-Service -Name Spooler -ErrorAction Stop
        Write-DomechLog "   Print service restarted with an empty queue." -Level Success
    } catch {
        Write-DomechLog "   Could not clear it: $($_.Exception.Message)" -Level Error
        Start-Service -Name Spooler -ErrorAction SilentlyContinue
    }
} else {
    Write-DomechLog "" -Level Info
    Write-DomechLog "4. Nothing to clear." -Level Success
}

# ---- 5. the network printer ----
Write-DomechLog "" -Level Info
Write-DomechLog "5. Network printer" -Level Info
$netPrinter = $Config.Printers | Where-Object { $_.IPAddress } | Select-Object -First 1
if (-not $netPrinter) {
    Write-DomechLog "   None configured." -Level Info
} else {
    if (Test-Connection -ComputerName $netPrinter.IPAddress -Count 2 -Quiet -ErrorAction SilentlyContinue) {
        Write-DomechLog "   $($netPrinter.Name) answers at $($netPrinter.IPAddress)." -Level Success
        $installed = $printers | Where-Object { $_.PortName -like "*$($netPrinter.IPAddress)*" -or $_.Name -like "*$($netPrinter.Name)*" }
        if (-not $installed) {
            Write-DomechLog "   It is reachable but NOT installed on this PC - that is why it cannot be printed to." -Level Warning
            Write-DomechLog "   Deploy it from the server: install its driver there, then options 14 and 15." -Level Warning
        }
    } else {
        Write-DomechLog "   $($netPrinter.Name) does NOT answer at $($netPrinter.IPAddress) from this PC." -Level Error
        Write-DomechLog "   Check this PC's network first with 'Check this PC's network'." -Level Warning
    }
}

# ---- 6. recent spooler errors ----
Write-DomechLog "" -Level Info
Write-DomechLog "6. Recent print errors" -Level Info
try {
    $events = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-PrintService/Admin'; StartTime=(Get-Date).AddDays(-2) } -ErrorAction Stop |
        Select-Object -First 5
    if ($events) {
        foreach ($e in $events) { Write-DomechLog "   $($e.TimeCreated): $($e.Message -replace "`r?`n",' ' )" -Level Warning }
    } else {
        Write-DomechLog "   None in the last 2 days." -Level Success
    }
} catch {
    Write-DomechLog "   No print error log available on this machine." -Level Info
}

Write-DomechLog "" -Level Info
Write-DomechLog "===== Done - try printing a test page now =====" -Level Success
