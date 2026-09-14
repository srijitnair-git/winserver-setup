@echo off
title Domech Fabricators - Diagnostics (runs as YOU, no admin prompt)

:: Deliberately does NOT elevate, unlike Domech-Menu.bat. Diagnostics like
:: drive-mapping checks must run as the actual logged-in user - if this
:: self-elevated, Windows would prompt for admin credentials and the whole
:: session would switch to THAT account's context (e.g. Administrator's
:: drives/GPOs instead of the person actually sitting at the PC), making
:: the results meaningless. None of these checks need admin rights.

:menu
cls
echo ==============================
echo   DIAGNOSTICS (running as %USERNAME%)
echo ==============================
echo   1. Diagnose drive mapping
echo   2. Test workstation connectivity (WinRM check)
echo   0. Exit
echo.
set /p c="Choose an option: "
if "%c%"=="1" call :run "New\Workstation\Diagnose-DriveMapping.ps1"
if "%c%"=="2" call :run "New\Workstation\Test-WorkstationConnectivity.ps1"
if "%c%"=="0" exit /b
goto menu

:run
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\%~1"
echo.
pause
goto :eof
