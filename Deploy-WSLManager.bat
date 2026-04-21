@echo off
:: =============================================================================
:: WSL Manager v3 — Deploy Launcher
:: Autor: Diego Regis M. F. dos Santos
:: Email: diego-f-santos@openlabs.com.br
:: Time:  OpenLabs - DevOps | Infra
:: Versão: 3.0.0
::
:: Duplo-clique para fazer build + push + deploy no Rancher
:: Requer: Docker Desktop, WSL2, kubectl configurado
:: =============================================================================
setlocal enabledelayedexpansion
title WSL Manager v3 — Deploy

echo.
echo  WSL Manager v3 ^| Deploy
echo  ====================================
echo.

:: Caminho do projecto (Windows e WSL)
set WIN_PATH=C:\APP\wsl-manager3.0
set WSL_PATH=/mnt/c/APP/wsl-manager3.0

:: Verifica se o Docker Desktop está rodando
docker info >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo  [ERRO] Docker Desktop nao esta rodando.
    echo  Inicia o Docker Desktop e tenta novamente.
    pause
    exit /b 1
)
echo  [OK] Docker Desktop ativo

:: Verifica se o WSL está disponível
wsl --status >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo  [ERRO] WSL nao disponivel.
    pause
    exit /b 1
)
echo  [OK] WSL disponivel

:: Verifica se o diretório existe
if not exist "%WIN_PATH%\deploy.sh" (
    echo  [ERRO] deploy.sh nao encontrado em %WIN_PATH%
    echo  Certifica-te de que o projecto esta em C:\APP\wsl-manager3.0
    pause
    exit /b 1
)
echo  [OK] Projecto encontrado em %WIN_PATH%

echo.
echo  Iniciando deploy via WSL...
echo  (O script vai pedir o GitHub Token e a ADMIN_PASSWORD)
echo.

:: Executa o deploy.sh via WSL
:: Usa o user padrão do WSL (não root) para ter acesso ao Docker socket
wsl bash -c "cd %WSL_PATH% && chmod +x deploy.sh && ./deploy.sh"

if %ERRORLEVEL% equ 0 (
    echo.
    echo  [OK] Deploy concluido com sucesso!
    echo  Acesse: http://wsl-manager.drmsantos.local
) else (
    echo.
    echo  [ERRO] Deploy falhou. Verifica os logs acima.
)

echo.
pause
