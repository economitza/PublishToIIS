@echo off
REM Arranca el dashboard ELEVADO para poder ejecutar Publish en local (se auto-eleva por UAC).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DashboardAdmin.ps1"
