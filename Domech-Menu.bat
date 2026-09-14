@echo off
setlocal EnableDelayedExpansion
title Domech Fabricators - Setup Menu

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

if not exist "C:\01_matrix" mkdir "C:\01_matrix" >nul 2>&1

:main
cls
echo ============================================
echo   Domech Fabricators - DF.local Setup Menu
echo   Running from: %~dp0
echo   (edit config.json before running anything)
echo ============================================
echo.
echo   1. Old system  (DF.com - discovery / pre-format backup)
echo   2. New system  (DF.local - build and manage)
echo.
echo   3. Diagnostics
echo.
echo   4. Update scripts from GitHub
echo   5. Open Logs folder
echo   0. Exit
echo.
set /p c="Choose an option: "
if "%c%"=="1" goto oldmenu
if "%c%"=="2" goto newmenu
if "%c%"=="3" goto diagnostics
if "%c%"=="4" call :run "Update-Scripts.ps1"
if "%c%"=="5" start "" "%~dp0Logs"
if "%c%"=="0" exit /b
goto main

:diagnostics
cls
echo ==============================
echo   DIAGNOSTICS
echo ==============================
echo   1. Diagnose drive mapping (run ON the affected user's PC, logged in as them)
echo   2. Test workstation connectivity (WinRM check, run from server)
echo   0. Back
echo.
set /p c="Choose an option: "
if "%c%"=="1" call :run "New\Workstation\Diagnose-DriveMapping.ps1"
if "%c%"=="2" call :run "New\Workstation\Test-WorkstationConnectivity.ps1"
if "%c%"=="0" goto main
goto diagnostics

:oldmenu
cls
echo ==============================
echo   OLD system (DF.com)
echo ==============================
echo   1. Server scripts
echo   2. Workstation scripts
echo   0. Back
echo.
set /p c="Choose an option: "
if "%c%"=="1" goto oldserver
if "%c%"=="2" goto oldworkstation
if "%c%"=="0" goto main
goto oldmenu

:oldserver
cls
echo -- Old \ Server --
echo   1. Export old server state (users/groups/shares/ACLs) - read only
echo   2. Network scan (subnet sweep + default-credential test)
echo   0. Back
echo.
set /p c="Choose an option: "
if "%c%"=="1" call :run "Old\Server\Export-OldServer-FullState.ps1"
if "%c%"=="2" call :run "Old\Server\DomechNetworkScan.ps1"
if "%c%"=="0" goto oldmenu
goto oldserver

:oldworkstation
cls
echo -- Old \ Workstation --
echo   1. Check Windows OEM license
echo   2. Back up a workstation's local user data (before formatting)
echo   0. Back
echo.
set /p c="Choose an option: "
if "%c%"=="1" call :run "Old\Workstation\Check-OEMLicense.ps1"
if "%c%"=="2" (
    set /p pc="Computer name to back up: "
    call :runwithargs "Old\Workstation\Backup-WorkstationUserData.ps1" "-ComputerName !pc!"
)
if "%c%"=="0" goto oldmenu
goto oldworkstation

:newmenu
cls
echo ==============================
echo   NEW system (DF.local)
echo ==============================
echo   1. Server scripts
echo   2. Workstation scripts
echo   0. Back
echo.
set /p c="Choose an option: "
if "%c%"=="1" goto newserver
if "%c%"=="2" goto newworkstation
if "%c%"=="0" goto main
goto newmenu

:newserver
cls
echo -- New \ Server --
echo   1. Set server static IP (run FIRST - everything else assumes this)
echo   2. Prepare D: data drive (reclaim old RAID disk, extend, shadow copies)
echo   2b. Reformat D: disk fully to Basic/GPT (fixes Dynamic Disk quirks)
echo   3. Install AD Forest (Step 1 - NTDS/SYSVOL on D:, reboots after)
echo   4. Post-promotion setup (Step 2 - DNS/OUs/groups/hardening)
echo   5. Full DF.local setup (users, shares, ACLs, drive maps, branding)
echo   6. Deploy "Ensure Required Services" GPO (startup + logon task)
echo   7. Restrict C: drive access for standard users (D: + user folders only)
echo   0. Back
echo.
set /p c="Choose an option: "
if "%c%"=="1" call :run "New\Server\Set-ServerStaticIP.ps1"
if "%c%"=="2" call :run "New\Server\0-Prepare-DataDrive.ps1"
if "%c%"=="2b" call :run "New\Server\0b-Reformat-DataDrive-Basic.ps1"
if "%c%"=="3" call :run "New\Server\1-Install-ADForest.ps1"
if "%c%"=="4" call :run "New\Server\2-PostPromotion-Setup.ps1"
if "%c%"=="5" call :run "New\Server\Setup-DFLocal-Full.ps1"
if "%c%"=="6" call :run "New\Server\Deploy-EnsureServicesGPO.ps1"
if "%c%"=="7" call :run "New\Server\Restrict-CDriveAccess.ps1"
if "%c%"=="0" goto newmenu
goto newserver

:newworkstation
cls
echo -- New \ Workstation --
echo   1. Test workstation connectivity (WinRM check)
echo   2. Deploy standard software baseline (winget apps)
echo   3. Deploy RustDesk unattended access
echo   4. Onboard a freshly formatted workstation (run ON that PC)
echo   5. Set static IP + DNS only (run ON that PC)
echo   0. Back
echo.
set /p c="Choose an option: "
if "%c%"=="1" call :run "New\Workstation\Test-WorkstationConnectivity.ps1"
if "%c%"=="2" call :run "New\Workstation\Deploy-StandardBaseline.ps1"
if "%c%"=="3" (
    set /p pwd="Permanent RustDesk password to set: "
    call :runwithargs "New\Workstation\Deploy-RustDesk-Unattended.ps1" "-PermanentPassword !pwd!"
)
if "%c%"=="4" call :run "New\Workstation\Onboard-NewWorkstation.ps1"
if "%c%"=="5" call :run "New\Workstation\Set-StaticIP.ps1"
if "%c%"=="0" goto newmenu
goto newworkstation

:run
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\%~1"
echo.
pause
goto :eof

:runwithargs
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\%~1" %2
echo.
pause
goto :eof
