@echo off
setlocal
cd /d "%~dp0"
title Narou Web Manager

echo ========================================================
echo   Narou Web Novel Manager
echo   Starting server and launching browser...
echo ========================================================
echo.

ruby ./narou.rb web
if errorlevel 1 (
    echo.
    echo [ERROR] Failed to run narou.rb.
    echo Please ensure Ruby is installed and available in PATH.
    echo.
    pause
)
