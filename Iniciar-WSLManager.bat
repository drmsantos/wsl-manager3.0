@echo off
title WSL Manager
echo.
echo  ╔═══════════════════════════════════╗
echo  ║       WSL Manager v2.0.0          ║
echo  ║   Iniciando agente na porta 7745  ║
echo  ╚═══════════════════════════════════╝
echo.

:: Verifica se ja esta rodando
netstat -an 2>nul | findstr ":7745 " | findstr "LISTENING" >nul
if %errorlevel%==0 (
    echo  [OK] Agente ja esta rodando!
    echo.
    start "" "http://localhost:7745/app"
    timeout /t 2 >nul
    exit
)

:: Inicia o agente em background
echo  Iniciando agente...
PowerShell -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\wsl-manager\wsl-agent.ps1" -Silent

:: Aguarda agente iniciar
echo  Aguardando agente iniciar...
timeout /t 3 >nul

:: Verifica se iniciou
netstat -an 2>nul | findstr ":7745 " | findstr "LISTENING" >nul
if %errorlevel%==0 (
    echo  [OK] Agente iniciado com sucesso!
    echo.
    start "" "http://localhost:7745/app"
) else (
    echo  [ERRO] Agente nao iniciou. Tentando com privilegios de admin...
    PowerShell -Command "Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File C:\wsl-manager\wsl-agent.ps1 -Silent'"
    timeout /t 4 >nul
    start "" "http://localhost:7745/app"
)

timeout /t 2 >nul
