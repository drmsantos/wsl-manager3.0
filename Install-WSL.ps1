#Requires -Version 5.1
# ============================================================
#  WSL Manager — Install-WSL.ps1
#  Orquestra instalação completa do WSL a partir de config.json
#  Uso: .\Install-WSL.ps1 [-Config .\config.json] [-DryRun]
# ============================================================
param(
    [string]$Config  = "$PSScriptRoot\config.json",
    [string]$LogFile = "$PSScriptRoot\wsl-install.log",
    [switch]$DryRun,
    [switch]$SkipDistro,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ── CORES ────────────────────────────────────────────────────────────────────
function Write-Step  { param($m) Write-Host "`n  ▸ $m" -ForegroundColor Cyan    ; Log "STEP  $m" }
function Write-Ok    { param($m) Write-Host "  [OK]   $m" -ForegroundColor Green  ; Log "OK    $m" }
function Write-Warn  { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow ; Log "WARN  $m" }
function Write-Err   { param($m) Write-Host "  [ERR]  $m" -ForegroundColor Red    ; Log "ERR   $m" }
function Write-Info  { param($m) Write-Host "  [INFO] $m" -ForegroundColor Gray   ; Log "INFO  $m" }
function Log         { param($m) Add-Content $LogFile "[$(Get-Date -f 'HH:mm:ss')] $m" -ErrorAction SilentlyContinue }

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║          WSL Manager — Instalação Automática      ║" -ForegroundColor Cyan
    Write-Host "  ║          PC: $env:COMPUTERNAME$((' ' * (36 - $env:COMPUTERNAME.Length)))║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    if ($DryRun) { Write-Host "  [DRY RUN — nenhuma alteração será feita]" -ForegroundColor Yellow ; Write-Host "" }
}

# ── VALIDAÇÕES ───────────────────────────────────────────────────────────────
function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "`n  Execute como Administrador!" -ForegroundColor Red
        Write-Host "  Clique direito em PowerShell → 'Executar como Administrador'" -ForegroundColor Yellow
        Write-Host "  Ou: Start-Process powershell -Verb RunAs -ArgumentList `"-File '$($MyInvocation.ScriptName)'`"" -ForegroundColor Gray
        exit 1
    }
}

function Assert-WSLAvailable {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
    if ($feature.State -ne 'Enabled') {
        Write-Step "Habilitando WSL no Windows..."
        if (-not $DryRun) {
            dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
            dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
        }
        Write-Ok "WSL habilitado (reinicialização pode ser necessária)"
    }
}

# ── LER CONFIG ───────────────────────────────────────────────────────────────
function Read-Config {
    if (-not (Test-Path $Config)) {
        Write-Err "config.json não encontrado: $Config"
        Write-Host "  Gere o config.json pelo WSL Manager dashboard." -ForegroundColor Yellow
        exit 1
    }
    try {
        $c = Get-Content $Config -Raw | ConvertFrom-Json
        Write-Ok "config.json carregado"
        return $c
    } catch {
        Write-Err "config.json inválido: $_"
        exit 1
    }
}

# ── INSTALAR DISTRO ──────────────────────────────────────────────────────────
function Install-Distro {
    param($c)
    $distroId   = $c.distro.id
    $distroName = $c.distro.wslName  # ex: Ubuntu-24.04

    Write-Step "Verificando distro: $distroName"

    $installed = wsl --list --quiet 2>$null | ForEach-Object { $_ -replace '\x00','' } | Where-Object { $_ -match '\S' }
    if ($installed -contains $distroName -and -not $Force) {
        Write-Warn "$distroName já instalada. Use -Force para reinstalar."
        return $distroName
    }

    Write-Step "Instalando $distroName via wsl --install..."
    Write-Info "Isso pode levar alguns minutos..."
    if (-not $DryRun) {
        $proc = Start-Process "wsl.exe" -ArgumentList "--install -d $distroName --no-launch" -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            Write-Warn "wsl --install retornou $($proc.ExitCode). Tentando via winget..."
            winget install --id "Canonical.Ubuntu.2404" --accept-source-agreements --accept-package-agreements --silent 2>$null
        }
        Start-Sleep -Seconds 5
    }
    Write-Ok "$distroName instalada"
    return $distroName
}

# ── CONFIGURAR .WSLCONFIG ────────────────────────────────────────────────────
function Set-WslConfig {
    param($c)
    Write-Step "Escrevendo .wslconfig em %USERPROFILE%"

    $wslConfigPath = "$env:USERPROFILE\.wslconfig"
    $content = @"
[wsl2]
memory=$($c.wsl.memoryGB)GB
processors=$($c.wsl.cpus)
swap=$($c.wsl.swapGB)GB
localhostForwarding=true
"@
    if (-not $DryRun) {
        Set-Content $wslConfigPath $content -Encoding UTF8
    }
    Write-Ok ".wslconfig → $wslConfigPath"
    Write-Info "  memory=$($c.wsl.memoryGB)GB  cpus=$($c.wsl.cpus)  swap=$($c.wsl.swapGB)GB"
}

# ── AGUARDAR WSL INICIALIZAR ─────────────────────────────────────────────────
function Wait-WSLReady {
    param([string]$distro)
    Write-Step "Aguardando WSL inicializar ($distro)..."

    $attempts = 0
    while ($attempts -lt 30) {
        try {
            $out = wsl -d $distro -- echo "ready" 2>$null
            if ($out -match "ready") { Write-Ok "WSL pronto"; return }
        } catch {}
        $attempts++
        Write-Info "  Tentativa $attempts/30..."
        Start-Sleep -Seconds 5
    }
    Write-Warn "WSL demorou para responder, continuando..."
}

# ── INJETAR wsl.conf ─────────────────────────────────────────────────────────
function Set-WslConf {
    param($c, [string]$distro)
    Write-Step "Configurando /etc/wsl.conf"

    $hostname  = $c.wsl.hostname
    $systemd   = ($c.wsl.systemd).ToString().ToLower()
    $automount = ($c.wsl.automount).ToString().ToLower()
    $interop   = ($c.wsl.interop).ToString().ToLower()
    $resolv    = ($c.wsl.generateResolvConf).ToString().ToLower()
    $hosts     = ($c.wsl.generateHosts).ToString().ToLower()

    $conf = @"
[boot]
systemd=$systemd

[automount]
enabled=$automount
root=/mnt/
options=metadata,umask=22,fmask=11

[network]
hostname=$hostname
generateHosts=$hosts
generateResolvConf=$resolv

[interop]
enabled=$interop
appendWindowsPath=false
"@
    $escaped = $conf -replace "'", "'\''"
    if (-not $DryRun) {
        wsl -d $distro -- bash -c "echo '$escaped' | sudo tee /etc/wsl.conf > /dev/null"
    }
    Write-Ok "/etc/wsl.conf escrito (hostname=$hostname, systemd=$systemd)"
}

# ── GERAR provision.sh ───────────────────────────────────────────────────────
function New-ProvisionScript {
    param($c)

    $user    = $c.user.name
    $shell   = $c.user.shell
    $shellBin = if ($shell -eq 'zsh') { '/usr/bin/zsh' } else { '/bin/bash' }
    $theme   = $c.user.zshTheme
    $gname   = $c.user.gitName
    $gemail  = $c.user.gitEmail
    $sudo    = $c.user.sudo
    $tz      = $c.wsl.timezone
    $tools   = $c.tools

    $lines = [System.Collections.Generic.List[string]]::new()
    $L = { param($s) $lines.Add($s) }

    & $L "#!/usr/bin/env bash"
    & $L "# Auto-gerado por WSL Manager — $(Get-Date -f 'yyyy-MM-dd HH:mm')"
    & $L "set -euo pipefail"
    & $L "RED='\033[0;31m';GREEN='\033[0;32m';YELLOW='\033[1;33m';CYAN='\033[0;36m';BOLD='\033[1m';NC='\033[0m'"
    & $L "ok()   { echo -e ""`${GREEN}[OK]`${NC}    `$*""; }"
    & $L "info() { echo -e ""`${CYAN}[INFO]`${NC}  `$*""; }"
    & $L "warn() { echo -e ""`${YELLOW}[WARN]`${NC}  `$*""; }"
    & $L "step() { echo -e ""`n`${BOLD}▸ `$*`${NC}""; }"
    & $L "[[ `$EUID -ne 0 ]] && { echo -e ""`${RED}Precisa de root`${NC}""; exit 1; }"
    & $L "USERNAME=`"$user`""
    & $L "SHELL_BIN=`"$shellBin`""
    & $L ""

    # Timezone
    & $L "step `"Timezone: $tz`""
    & $L "timedatectl set-timezone `"$tz`" 2>/dev/null || ln -sf /usr/share/zoneinfo/$tz /etc/localtime"
    & $L "ok `"Timezone: $tz`""
    & $L ""

    # Base packages
    & $L "step `"Pacotes base`""
    & $L "apt-get update -qq"
    & $L "apt-get install -y -qq curl wget git unzip zip tar ca-certificates gnupg lsb-release apt-transport-https software-properties-common build-essential sudo vim nano less openssl"
    & $L "ok `"Pacotes base`""
    & $L ""

    # Shell
    if ($shell -eq 'zsh' -or $tools -contains 'ohmyzsh') {
        & $L "step `"Instalando zsh`""
        & $L "apt-get install -y -qq zsh"
        & $L "ok `"zsh instalado`""
        & $L ""
    }

    # Create user
    & $L "step `"Criando usuário: `$USERNAME`""
    & $L "if id `"`$USERNAME`" &>/dev/null; then warn `"Usuário `$USERNAME já existe`""
    & $L "else"
    & $L "  useradd -m -s `"`$SHELL_BIN`" -c `"$user WSL Manager`" `"`$USERNAME`""
    & $L "  echo `"`$USERNAME:`$(openssl rand -base64 16)`" | chpasswd"
    & $L "  ok `"Usuário `$USERNAME criado`""
    & $L "fi"
    & $L ""

    if ($sudo) {
        & $L "step `"Sudo NOPASSWD`""
        & $L "usermod -aG sudo `"`$USERNAME`""
        & $L "echo `"`$USERNAME ALL=(ALL) NOPASSWD:ALL`" > /etc/sudoers.d/`$USERNAME"
        & $L "chmod 440 /etc/sudoers.d/`$USERNAME"
        & $L "ok `"Sudo configurado`""
        & $L ""
    }

    # Oh My Zsh
    if ($tools -contains 'ohmyzsh') {
        & $L "step `"Oh My Zsh`""
        & $L "su - `"`$USERNAME`" -c 'sh -c `"`$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)`" `"`" --unattended'"
        if ($theme -eq 'powerlevel10k') {
            & $L "su - `"`$USERNAME`" -c 'git clone --depth=1 https://github.com/romkatv/powerlevel10k.git `${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/themes/powerlevel10k'"
            & $L "su - `"`$USERNAME`" -c 'sed -i s/ZSH_THEME=.*/ZSH_THEME=`"powerlevel10k\/powerlevel10k`"/ ~/.zshrc'"
        } elseif ($theme -ne 'none') {
            & $L "su - `"`$USERNAME`" -c 'sed -i s/ZSH_THEME=.*/ZSH_THEME=`"$theme`"/ ~/.zshrc'"
        }
        & $L "ok `"Oh My Zsh (tema: $theme)`""
        & $L ""
    }

    if ($tools -contains 'zsh_plugins') {
        & $L "step `"Plugins zsh`""
        & $L "su - `"`$USERNAME`" -c 'git clone https://github.com/zsh-users/zsh-autosuggestions `${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions 2>/dev/null||true'"
        & $L "su - `"`$USERNAME`" -c 'git clone https://github.com/zsh-users/zsh-syntax-highlighting `${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting 2>/dev/null||true'"
        & $L "su - `"`$USERNAME`" -c 'sed -i s/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting kubectl docker)/ ~/.zshrc'"
        & $L "ok `"Plugins zsh`""
        & $L ""
    }

    if ($tools -contains 'kubectl') {
        & $L "step `"kubectl`""
        & $L "curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
        & $L "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' > /etc/apt/sources.list.d/kubernetes.list"
        & $L "apt-get update -qq && apt-get install -y -qq kubectl"
        & $L "ok `"kubectl`""
        & $L ""
    }

    if ($tools -contains 'oc') {
        & $L "step `"OpenShift CLI`""
        & $L "OC_VER=`$(curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/release.txt | grep 'Version:' | awk '{print `$2}')"
        & $L "curl -fsSL `"https://mirror.openshift.com/pub/openshift-v4/clients/ocp/`$OC_VER/openshift-client-linux.tar.gz`" | tar -xz -C /usr/local/bin oc"
        & $L "ok `"oc `$OC_VER`""
        & $L ""
    }

    if ($tools -contains 'helm') {
        & $L "step `"Helm v3`""
        & $L "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
        & $L "ok `"`$(helm version --short)`""
        & $L ""
    }

    if ($tools -contains 'k9s') {
        & $L "step `"k9s`""
        & $L "K9S_VER=`$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep tag_name | cut -d'`"' -f4)"
        & $L "curl -fsSL `"https://github.com/derailed/k9s/releases/download/`$K9S_VER/k9s_Linux_amd64.tar.gz`" | tar -xz -C /usr/local/bin k9s"
        & $L "ok `"k9s`""
        & $L ""
    }

    if ($tools -contains 'kubectx') {
        & $L "step `"kubectx + kubens`""
        & $L "KCTX=`$(curl -s https://api.github.com/repos/ahmetb/kubectx/releases/latest | grep tag_name | cut -d'`"' -f4)"
        & $L "curl -fsSL `"https://github.com/ahmetb/kubectx/releases/download/`$KCTX/kubectx_`${KCTX}_linux_x86_64.tar.gz`" | tar -xz -C /usr/local/bin kubectx"
        & $L "curl -fsSL `"https://github.com/ahmetb/kubectx/releases/download/`$KCTX/kubens_`${KCTX}_linux_x86_64.tar.gz`" | tar -xz -C /usr/local/bin kubens"
        & $L "ok `"kubectx + kubens`""
        & $L ""
    }

    if ($tools -contains 'stern') {
        & $L "step `"Stern`""
        & $L "STERN=`$(curl -s https://api.github.com/repos/stern/stern/releases/latest | grep tag_name | cut -d'`"' -f4)"
        & $L "curl -fsSL `"https://github.com/stern/stern/releases/download/`$STERN/stern_linux_amd64.tar.gz`" | tar -xz -C /usr/local/bin stern"
        & $L "ok `"stern`""
        & $L ""
    }

    if ($tools -contains 'argocd') {
        & $L "step `"ArgoCD CLI`""
        & $L "ARGO=`$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | grep tag_name | cut -d'`"' -f4)"
        & $L "curl -fsSL `"https://github.com/argoproj/argo-cd/releases/download/`$ARGO/argocd-linux-amd64`" -o /usr/local/bin/argocd && chmod +x /usr/local/bin/argocd"
        & $L "ok `"argocd`""
        & $L ""
    }

    if ($tools -contains 'terraform') {
        & $L "step `"Terraform`""
        & $L "wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg"
        & $L "echo `"deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com `$(lsb_release -cs) main`" > /etc/apt/sources.list.d/hashicorp.list"
        & $L "apt-get update -qq && apt-get install -y -qq terraform"
        & $L "ok `"`$(terraform version | head -1)`""
        & $L ""
    }

    if ($tools -contains 'ansible') {
        & $L "step `"Ansible`""
        & $L "apt-get install -y -qq ansible"
        & $L "ok `"`$(ansible --version | head -1)`""
        & $L ""
    }

    if ($tools -contains 'awscli') {
        & $L "step `"AWS CLI v2`""
        & $L "curl -fsSL 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o /tmp/awscliv2.zip"
        & $L "unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip"
        & $L "ok `"`$(aws --version)`""
        & $L ""
    }

    if ($tools -contains 'docker') {
        & $L "step `"Docker CLI`""
        & $L "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
        & $L "echo `"deb [arch=`$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu `$(lsb_release -cs) stable`" > /etc/apt/sources.list.d/docker.list"
        & $L "apt-get update -qq && apt-get install -y -qq docker-ce-cli docker-compose-plugin"
        & $L "usermod -aG docker `"`$USERNAME`""
        & $L "ok `"Docker CLI`""
        & $L ""
    }

    if ($tools -contains 'vector') {
        & $L "step `"Vector 0.39`""
        & $L "curl -fsSL https://apt.vector.dev/gpg.key | gpg --dearmor -o /usr/share/keyrings/vector.gpg"
        & $L "echo `"deb [arch=`$(dpkg --print-architecture) signed-by=/usr/share/keyrings/vector.gpg] https://apt.vector.dev stable vector-0`" > /etc/apt/sources.list.d/vector.list"
        & $L "apt-get update -qq && apt-get install -y -qq vector"
        & $L "ok `"`$(vector --version)`""
        & $L ""
    }

    if ($tools -contains 'sqlplus') {
        & $L "step `"Oracle Instant Client 21c + SQLPlus`""
        & $L "apt-get install -y -qq libaio1"
        & $L "IC='https://download.oracle.com/otn_software/linux/instantclient/2112000'"
        & $L "curl -fsSL `"`$IC/instantclient-basic-linux.x64-21.12.0.0.0dbru.zip`" -o /tmp/ic-basic.zip"
        & $L "curl -fsSL `"`$IC/instantclient-sqlplus-linux.x64-21.12.0.0.0dbru.zip`" -o /tmp/ic-sql.zip"
        & $L "mkdir -p /usr/lib/oracle/21/client64/{bin,lib}"
        & $L "unzip -q /tmp/ic-basic.zip -d /tmp/ic && mv /tmp/ic/instantclient_21_12/*.so* /usr/lib/oracle/21/client64/lib/"
        & $L "unzip -q /tmp/ic-sql.zip   -d /tmp/ic && mv /tmp/ic/instantclient_21_12/sqlplus /usr/lib/oracle/21/client64/bin/"
        & $L "rm -rf /tmp/ic /tmp/ic-*.zip"
        & $L "echo /usr/lib/oracle/21/client64/lib > /etc/ld.so.conf.d/oracle21.conf && ldconfig"
        & $L "ln -sf /usr/lib/oracle/21/client64/bin/sqlplus /usr/local/bin/sqlplus"
        & $L "cat >> /home/`$USERNAME/.zshrc << 'ORACLE'"
        & $L "export ORACLE_HOME=/usr/lib/oracle/21/client64"
        & $L "export LD_LIBRARY_PATH=`$ORACLE_HOME/lib:`$LD_LIBRARY_PATH"
        & $L "export PATH=`$ORACLE_HOME/bin:`$PATH"
        & $L "export NLS_LANG=AMERICAN_AMERICA.AL32UTF8"
        & $L "ORACLE"
        & $L "ok `"SQLPlus 21c`""
        & $L ""
    }

    if ($tools -contains 'vscode') {
        & $L "step `"VS Code (WSL alias)`""
        & $L "cat >> /home/`$USERNAME/.zshrc << 'VSCODE'"
        & $L "alias code='/mnt/c/Users/`$(cmd.exe /c `"echo %USERNAME%`" 2>/dev/null | tr -d `"\r`")/AppData/Local/Programs/Microsoft\\ VS\\ Code/bin/code'"
        & $L "VSCODE"
        & $L "ok `"Alias 'code' configurado`""
        & $L ""
    }

    if ($tools -contains 'python3') {
        & $L "step `"Python 3.11 + pip`""
        & $L "apt-get install -y -qq python3.11 python3.11-venv python3-pip python3-dev"
        & $L "update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1"
        & $L "ok `"`$(python3 --version)`""
        & $L ""
    }

    if ($tools -contains 'nodejs') {
        & $L "step `"Node.js 20 via nvm`""
        & $L "su - `"`$USERNAME`" -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'"
        & $L "su - `"`$USERNAME`" -c 'source ~/.nvm/nvm.sh && nvm install 20 && nvm alias default 20'"
        & $L "ok `"Node.js 20 LTS`""
        & $L ""
    }

    if ($tools -contains 'go') {
        & $L "step `"Go 1.22`""
        & $L "curl -fsSL https://go.dev/dl/go1.22.3.linux-amd64.tar.gz | tar -xz -C /usr/local"
        & $L "cat >> /home/`$USERNAME/.zshrc << 'GOENV'"
        & $L "export GOPATH=`$HOME/go"
        & $L "export PATH=`$PATH:/usr/local/go/bin:`$GOPATH/bin"
        & $L "GOENV"
        & $L "ok `"Go 1.22`""
        & $L ""
    }

    if ($tools -contains 'fzf') {
        & $L "step `"fzf`""
        & $L "su - `"`$USERNAME`" -c 'git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf && ~/.fzf/install --all'"
        & $L "ok `"fzf`""
        & $L ""
    }

    if ($tools -contains 'jq') {
        & $L "step `"jq + yq`""
        & $L "apt-get install -y -qq jq"
        & $L "YQ=`$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep tag_name | cut -d'`"' -f4)"
        & $L "curl -fsSL `"https://github.com/mikefarah/yq/releases/download/`$YQ/yq_linux_amd64`" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq"
        & $L "ok `"jq + yq`""
        & $L ""
    }

    if ($tools -contains 'tmux') {
        & $L "step `"tmux`""
        & $L "apt-get install -y -qq tmux"
        & $L "printf 'set -g mouse on\nset -g default-terminal screen-256color\nset -g history-limit 50000\n' > /home/`$USERNAME/.tmux.conf"
        & $L "chown `$USERNAME: /home/`$USERNAME/.tmux.conf"
        & $L "ok `"tmux`""
        & $L ""
    }

    if ($tools -contains 'bat') {
        & $L "step `"bat`""
        & $L "apt-get install -y -qq bat"
        & $L "su - `"`$USERNAME`" -c 'echo alias cat=batcat >> ~/.zshrc'"
        & $L "ok `"bat`""
        & $L ""
    }

    if ($tools -contains 'eza') {
        & $L "step `"eza`""
        & $L "apt-get install -y -qq eza 2>/dev/null || true"
        & $L "su - `"`$USERNAME`" -c 'printf `"alias ls=eza\nalias ll=\`"eza -la\`"\nalias lt=\`"eza --tree\`"\n`" >> ~/.zshrc'"
        & $L "ok `"eza`""
        & $L ""
    }

    if ($tools -contains 'htop') {
        & $L "step `"htop + btop`""
        & $L "apt-get install -y -qq htop btop"
        & $L "ok `"htop + btop`""
        & $L ""
    }

    if ($tools -contains 'jq' -or $tools -contains 'curl_jq') {
        & $L "step `"httpie`""
        & $L "apt-get install -y -qq httpie"
        & $L "ok `"httpie`""
        & $L ""
    }

    if ($tools -contains 'ripgrep') {
        & $L "step `"ripgrep + fd`""
        & $L "apt-get install -y -qq ripgrep fd-find"
        & $L "su - `"`$USERNAME`" -c 'echo alias fd=fdfind >> ~/.zshrc'"
        & $L "ok `"rg + fd`""
        & $L ""
    }

    if ($tools -contains 'mysql') {
        & $L "step `"MySQL Client`""
        & $L "apt-get install -y -qq mysql-client"
        & $L "ok `"mysql client`""
        & $L ""
    }

    if ($tools -contains 'psql') {
        & $L "step `"PostgreSQL Client`""
        & $L "apt-get install -y -qq postgresql-client"
        & $L "ok `"psql`""
        & $L ""
    }

    if ($tools -contains 'mongosh') {
        & $L "step `"mongosh`""
        & $L "curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb.gpg"
        & $L "echo `"deb [arch=amd64 signed-by=/usr/share/keyrings/mongodb.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse`" > /etc/apt/sources.list.d/mongodb.list"
        & $L "apt-get update -qq && apt-get install -y -qq mongodb-mongosh"
        & $L "ok `"mongosh`""
        & $L ""
    }

    # Git config
    if ($gname -or $gemail) {
        & $L "step `"Git config`""
        if ($gname)  { & $L "su - `"`$USERNAME`" -c 'git config --global user.name `"$gname`"'" }
        if ($gemail) { & $L "su - `"`$USERNAME`" -c 'git config --global user.email `"$gemail`"'" }
        & $L "su - `"`$USERNAME`" -c 'git config --global init.defaultBranch main && git config --global pull.rebase false && git config --global core.autocrlf false'"
        & $L "ok `"Git configurado`""
        & $L ""
    }

    # Aliases
    & $L "step `"Aliases DevOps`""
    & $L "cat >> /home/`$USERNAME/.zshrc << 'ALIASES'"
    & $L "# ── WSL Manager aliases ──────────────────────────────"
    if ($tools -contains 'kubectl' -or $tools -contains 'oc') {
        & $L "alias k='kubectl'"
        & $L "alias kgp='kubectl get pods -A'"
        & $L "alias kgs='kubectl get svc -A'"
        & $L "alias kgn='kubectl get nodes'"
        & $L "alias kaf='kubectl apply -f'"
        & $L "alias kl='kubectl logs -f'"
        & $L "alias kex='kubectl exec -it'"
        & $L "alias kns='kubectl config set-context --current --namespace'"
    }
    if ($tools -contains 'oc') {
        & $L "alias oc-login='oc login https://api.openshift.openlabs.local:6443'"
    }
    if ($tools -contains 'helm') {
        & $L "alias h='helm'"
        & $L "alias hls='helm list -A'"
    }
    if ($tools -contains 'docker') {
        & $L "alias d='docker'"
        & $L "alias dps='docker ps --format `"table {{.Names}}\t{{.Status}}\t{{.Ports}}`"'"
    }
    if ($tools -contains 'terraform') {
        & $L "alias tf='terraform'"
        & $L "alias tfp='terraform plan'"
        & $L "alias tfa='terraform apply'"
    }
    if ($tools -contains 'sqlplus') {
        & $L "alias sqldev='sqlplus /nolog'"
    }
    & $L "alias ll='ls -lahF'"
    & $L "alias ..='cd ..'"
    & $L "alias ...='cd ../..'"
    & $L "alias ports='ss -tulnp'"
    & $L "alias myip='curl -s ifconfig.me'"
    & $L "alias wsl-restart='wsl.exe --shutdown'"
    & $L "# ────────────────────────────────────────────────────"
    & $L "ALIASES"
    & $L "chown `$USERNAME: /home/`$USERNAME/.zshrc 2>/dev/null || true"
    & $L "ok `"Aliases configurados`""
    & $L ""

    # Instalar wsl_profile.sh
    & $L "step `"Instalando wsl_profile.sh`""
    & $L "if [[ -f /tmp/wsl_profile.sh ]]; then"
    & $L "  cp /tmp/wsl_profile.sh /usr/local/bin/wsl_profile.sh"
    & $L "  chmod +x /usr/local/bin/wsl_profile.sh"
    & $L "  ok `"wsl_profile.sh instalado em /usr/local/bin/`""
    & $L "fi"
    & $L ""

    & $L "step `"Provisionamento concluído!`""
    & $L "echo ''"
    & $L "echo -e `"  `${GREEN}Usuário:`${NC} `$USERNAME`""
    & $L "echo -e `"  `${GREEN}Shell:`${NC}   `$SHELL_BIN`""
    & $L "echo ''"
    & $L "echo -e `"  Acesse: `${CYAN}wsl -u `$USERNAME`${NC}`""
    & $L "echo -e `"  Export: `${CYAN}WSL_USER=`$USERNAME wsl_profile.sh export`${NC}`""
    & $L "echo -e `"  `${YELLOW}Reinicie o WSL para aplicar wsl.conf:`${NC} wsl --shutdown`""

    return $lines -join "`n"
}

# ── INJETAR E EXECUTAR provision.sh ─────────────────────────────────────────
function Invoke-Provision {
    param([string]$distro, [string]$script, $c)

    Write-Step "Injetando provision.sh no WSL"

    $wslTmp = "/tmp/provision_$($c.user.name).sh"

    if (-not $DryRun) {
        # Converte \r\n → \n e injeta via stdin
        $bytes  = [System.Text.Encoding]::UTF8.GetBytes($script)
        $b64    = [Convert]::ToBase64String($bytes)
        wsl -d $distro -- bash -c "echo '$b64' | base64 -d > $wslTmp && chmod +x $wslTmp"
        Write-Ok "provision.sh injetado em $wslTmp"

        # Injeta wsl_profile.sh se existir ao lado do Install-WSL.ps1
        $profileScript = "$PSScriptRoot\wsl_profile.sh"
        if (Test-Path $profileScript) {
            $pb  = [System.IO.File]::ReadAllBytes($profileScript)
            $pb64 = [Convert]::ToBase64String($pb)
            wsl -d $distro -- bash -c "echo '$pb64' | base64 -d > /tmp/wsl_profile.sh && chmod +x /tmp/wsl_profile.sh"
            Write-Ok "wsl_profile.sh injetado"
        }

        # Executa como root
        Write-Step "Executando provision.sh (isso pode demorar 5-15 min)..."
        Write-Info "Acompanhe o progresso abaixo:"
        Write-Host ""
        wsl -d $distro -- bash -c "sudo bash $wslTmp"
        Write-Host ""
    } else {
        Write-Info "[DRY RUN] wsl -d $distro -- sudo bash $wslTmp"
    }

    Write-Ok "Provisionamento concluído!"
}

# ── RESTART WSL ──────────────────────────────────────────────────────────────
function Restart-WSL {
    param([string]$distro)
    Write-Step "Reiniciando WSL para aplicar wsl.conf..."
    if (-not $DryRun) {
        wsl --terminate $distro 2>$null
        Start-Sleep -Seconds 3
        wsl -d $distro -- echo "WSL reiniciado" | Out-Null
    }
    Write-Ok "WSL reiniciado"
}

# ── RELATÓRIO FINAL ──────────────────────────────────────────────────────────
function Show-Summary {
    param($c, [string]$distro)
    $duration = (Get-Date) - $script:StartTime
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "  ║              Instalação Completa!             ║" -ForegroundColor Green
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Distro:    $distro" -ForegroundColor Cyan
    Write-Host "  Usuário:   $($c.user.name)" -ForegroundColor Cyan
    Write-Host "  Shell:     $($c.user.shell)" -ForegroundColor Cyan
    Write-Host "  Tempo:     $([int]$duration.TotalMinutes)m $($duration.Seconds)s" -ForegroundColor Cyan
    Write-Host "  Log:       $LogFile" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Como acessar:" -ForegroundColor Yellow
    Write-Host "    wsl -d $distro -u $($c.user.name)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Exportar perfil depois:" -ForegroundColor Yellow
    Write-Host "    WSL_USER=$($c.user.name) wsl_profile.sh export" -ForegroundColor White
    Write-Host ""
    Write-Host "  IMPORTANTE: Execute 'wsl --shutdown' e reabra o WSL" -ForegroundColor Yellow
    Write-Host "  para o wsl.conf (hostname/systemd) ter efeito." -ForegroundColor Yellow
    Write-Host ""
}

# ── MAIN ─────────────────────────────────────────────────────────────────────
$script:StartTime = Get-Date
Show-Banner
Assert-Admin
Assert-WSLAvailable

$c = Read-Config

Write-Host "  Configuração carregada:" -ForegroundColor Cyan
Write-Host "    Distro:   $($c.distro.name)" -ForegroundColor Gray
Write-Host "    Usuário:  $($c.user.name) ($($c.user.shell))" -ForegroundColor Gray
Write-Host "    RAM:      $($c.wsl.memoryGB)GB  CPUs: $($c.wsl.cpus)" -ForegroundColor Gray
Write-Host "    Tools:    $($c.tools.Count) selecionadas" -ForegroundColor Gray
Write-Host ""

if (-not $DryRun -and -not $Force) {
    $confirm = Read-Host "  Continuar? [S/n]"
    if ($confirm -match '^[Nn]') { Write-Warn "Cancelado."; exit 0 }
}

$distro = if ($SkipDistro) {
    $c.distro.wslName
} else {
    Install-Distro $c
}

Set-WslConfig $c
Wait-WSLReady $distro
Set-WslConf $c $distro

$script = New-ProvisionScript $c

# Salva provision.sh localmente também
$localScript = "$PSScriptRoot\provision_$($c.user.name).sh"
if (-not $DryRun) {
    Set-Content $localScript $script -Encoding UTF8
    Write-Ok "provision.sh salvo em $localScript"
}

Invoke-Provision $distro $script $c
Restart-WSL $distro
Show-Summary $c $distro
