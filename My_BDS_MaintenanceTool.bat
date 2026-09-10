@echo off
setlocal EnableExtensions

cd /d "%~dp0"

title My BDS MaintenanceTool

if not exist "%~dp0My_BDS_MaintenanceTool.ps1" (
    echo.
    echo [ERROR] My_BDS_MaintenanceTool.ps1 was not found.
    echo.
    echo Please put My_BDS_MaintenanceTool.ps1 in the same directory as this BAT.
    echo.
    exit /b 1
)

powershell.exe ^
    -NoLogo ^
    -NoProfile ^
    -ExecutionPolicy Bypass ^
    -File "%~dp0My_BDS_MaintenanceTool.ps1"

set "EXITCODE=%ERRORLEVEL%"

echo.
echo ============================================================
echo My BDS Backup Manager exited with code %EXITCODE%
echo ============================================================
echo.

exit /b %EXITCODE%