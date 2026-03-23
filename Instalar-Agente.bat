@echo off
:: WSL Manager  Launcher
:: Duplo-clique aqui para instalar o agente (sem precisar tocar na poltica do PowerShell)

NET SESSION >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo Elevando para Administrador...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo  WSL Manager Agent  Instalador
echo  ================================
echo.

:: Desbloqueia o script se o Windows marcou como "baixado da internet"
powershell -Command "Unblock-File -Path '%~dp0wsl-agent.ps1'" 2>nul

:: Instala o agente com bypass da execution policy (sem alterar a poltica global)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wsl-agent.ps1" -Install

echo.
pause
