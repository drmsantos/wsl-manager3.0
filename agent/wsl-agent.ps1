#Requires -Version 5.1
# =============================================================================
# WSL Manager v3 — Agente Windows (cliente polling)
# Autor: Diego Regis M. F. dos Santos
# Email: diego-f-santos@openlabs.com.br
# Time:  OpenLabs - DevOps | Infra
# Versão: 3.0.0
#
# CONFIGURAÇÃO:
#   1. Defina $AgentToken com o token JWT gerado no dashboard
#   2. Defina $BackendURL com a URL do backend no Rancher
#   3. Execute: .\wsl-agent.ps1
#   Para instalar como tarefa agendada: .\wsl-agent.ps1 -Install
# =============================================================================
param(
    [string] $BackendURL  = "http://wsl-manager.drmsantos.local/api",
    [string] $AgentToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJwY19pZCI6IjFhYzU1ODQyLTg4YTctNGJhYi05NWE0LWMxMTljMzExYTc4MSIsInBjX25hbWUiOiJERVNLVE9QLU5EM0lVMTEiLCJpc19hZG1pbiI6ZmFsc2UsImV4cCI6MjA5MjE3MzI3MX0.AtOumWtHy8Lubd2DhjAh6Ly2vjLnX1ROvmb7te3RDi8",           # Cole aqui o token JWT do dashboard
    [int]    $HeartbeatSec = 5,
    [int]    $PollSec      = 3,
    [switch] $Install,
    [switch] $Uninstall,
    [switch] $Silent
)

$ErrorActionPreference = "SilentlyContinue"
$AgentVersion = "3.0.0"
$TaskName     = "WSLManagerAgent"
$LogFile      = "$env:TEMP\wsl-agent-v3.log"

# ── Validação inicial ─────────────────────────────────────────────────────────
if (-not $AgentToken -and -not $Install -and -not $Uninstall) {
    Write-Host ""
    Write-Host "  WSL Manager Agent v$AgentVersion" -ForegroundColor Cyan
    Write-Host "  ERRO: AgentToken não configurado." -ForegroundColor Red
    Write-Host ""
    Write-Host "  1. Aceda ao dashboard: $BackendURL/../" -ForegroundColor Yellow
    Write-Host "  2. Vá em Tokens / PCs → Registrar PC" -ForegroundColor Yellow
    Write-Host "  3. Copie o token JWT e edite este script:" -ForegroundColor Yellow
    Write-Host '     $AgentToken = "eyJ..."' -ForegroundColor Gray
    Write-Host ""
    exit 1
}

# ── Install / Uninstall ───────────────────────────────────────────────────────
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "WSL Manager Agent removido." -ForegroundColor Green
    exit 0
}

if ($Install) {
    $scriptPath = $MyInvocation.MyCommand.Path
    Unblock-File -Path $scriptPath -ErrorAction SilentlyContinue
    $args = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -BackendURL `"$BackendURL`" -AgentToken `"$AgentToken`" -Silent"
    $action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $args
    $trigger  = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0 -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal= New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "WSL Manager Agent instalado! Iniciará automaticamente no próximo login." -ForegroundColor Green
    Start-Process powershell -ArgumentList $args -WindowStyle Hidden
    exit 0
}

# ── Helpers ───────────────────────────────────────────────────────────────────
function Log { param($m) Add-Content $LogFile ("[$(Get-Date -f 'HH:mm:ss')] $m") -ErrorAction SilentlyContinue }

function Api-Post {
    param([string]$path, $body)
    $json = $body | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $req = [System.Net.HttpWebRequest]::Create($BackendURL + $path)
    $req.Method = "POST"
    $req.ContentType = "application/json"
    $req.ContentLength = $bytes.Length
    $req.Headers.Add("Authorization", "Bearer $AgentToken")
    $req.Timeout = 8000
    $stream = $req.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    $resp = $req.GetResponse()
    $reader = [System.IO.StreamReader]::new($resp.GetResponseStream())
    $result = $reader.ReadToEnd()
    $reader.Close(); $resp.Close()
    return $result | ConvertFrom-Json
}

function Api-Get {
    param([string]$path)
    $req = [System.Net.HttpWebRequest]::Create($BackendURL + $path)
    $req.Method = "GET"
    $req.Headers.Add("Authorization", "Bearer $AgentToken")
    $req.Timeout = 8000
    $resp = $req.GetResponse()
    $reader = [System.IO.StreamReader]::new($resp.GetResponseStream())
    $result = $reader.ReadToEnd()
    $reader.Close(); $resp.Close()
    return $result | ConvertFrom-Json
}

# ── Coleta distros ────────────────────────────────────────────────────────────
function Get-DistroList {
    $raw = wsl --list --verbose 2>$null
    if (-not $raw) { return @() }
    $names = $raw | Select-Object -Skip 1 | ForEach-Object {
        ($_ -replace '\x00','').Trim() -replace '^[*\s]+','' -replace '\s+.*$',''
    } | Where-Object { $_ -ne '' -and $_ -ne 'NAME' }

    $runningRaw = wsl --list --running --quiet 2>$null
    $running = @()
    if ($runningRaw) {
        $running = $runningRaw | ForEach-Object { ($_ -replace '\x00','').Trim() } | Where-Object { $_ -ne '' }
    }

    return $names | ForEach-Object {
        $n = $_
        @{ name = $n; running = ($running -contains $n) }
    }
}

# ── Coleta métricas Windows (CPU, RAM) ───────────────────────────────────────
function Get-WinMetrics {
    try {
        $cpu = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 0)
    } catch { $cpu = 0 }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $ramTotal = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
        $ramFree  = [math]::Round($os.FreePhysicalMemory     / 1024, 0)
        $ramUsed  = $ramTotal - $ramFree
        $ramPct   = if ($ramTotal -gt 0) { [math]::Round($ramUsed * 100 / $ramTotal, 0) } else { 0 }
    } catch { $ramTotal = 0; $ramUsed = 0; $ramPct = 0 }

    try {
        $disk = Get-PSDrive C
        $diskTotal = [math]::Round(($disk.Used + $disk.Free) / 1GB, 1)
        $diskUsed  = [math]::Round($disk.Used / 1GB, 1)
        $diskPct   = if ($diskTotal -gt 0) { [math]::Round($diskUsed * 100 / $diskTotal, 0) } else { 0 }
    } catch { $diskTotal = 0; $diskUsed = 0; $diskPct = 0 }

    return @{
        cpu_pct       = [int]$cpu
        ram_used_mb   = [int]$ramUsed
        ram_total_mb  = [int]$ramTotal
        ram_pct       = [int]$ramPct
        disk_used_gb  = $diskUsed
        disk_total_gb = $diskTotal
        disk_pct      = [int]$diskPct
    }
}

function Get-WinVersion {
    try {
        $v = (Get-CimInstance Win32_OperatingSystem).Caption
        return $v -replace "Microsoft ",""
    } catch { return "Windows" }
}

# ── SSE helper: posta evento de progresso ao backend ─────────────────────────
function Post-Result {
    param([string]$cmdId, [string]$type, [string]$msg, [int]$pct=-1, [string]$level='info')
    $body = @{
        command_id = $cmdId
        result = @{
            type  = $type
            msg   = $msg
            pct   = $pct
            level = $level
            ts    = (Get-Date -f 'HH:mm:ss')
        }
    }
    try { Api-Post "/agent/result" $body | Out-Null } catch {}
}

# ── Executores de comandos ────────────────────────────────────────────────────

function Run-Provision {
    param($cmd)
    $cmdId  = $cmd.command_id
    $cfg    = $cmd.config
    $distro = $cfg.distro.wslName
    $user   = $cfg.user.name

    Log "Provision start: $distro / $user"
    Post-Result $cmdId 'step' "Iniciando provisionamento: $distro / $user" 5

    try {
        # .wslconfig
        Post-Result $cmdId 'step' "Escrevendo .wslconfig..." 10
        $wslCfg = "[wsl2]`nmemory=$($cfg.wsl.memoryGB)GB`nprocessors=$($cfg.wsl.cpus)`nswap=$($cfg.wsl.swapGB)GB`nlocalhostForwarding=true"
        Set-Content "$env:USERPROFILE\.wslconfig" $wslCfg -Encoding UTF8
        Post-Result $cmdId 'ok' ".wslconfig escrito" 12

        # Verificar se distro já existe
        $installed = @(Get-DistroList | ForEach-Object { $_.name })
        if ($installed -contains $distro) {
            Post-Result $cmdId 'warn' "$distro já instalada — pulando instalação" 15
        } else {
            Post-Result $cmdId 'step' "Instalando $distro via wsl --install..." 15
            $proc = Start-Process "wsl.exe" -ArgumentList "--install -d $distro --no-launch" -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -ne 0) {
                Post-Result $cmdId 'warn' "wsl --install retornou $($proc.ExitCode)" 18
            }
            Start-Sleep -Seconds 5
            Post-Result $cmdId 'ok' "$distro instalada" 20
        }

        # Gerar provision.sh
        Post-Result $cmdId 'step' "Gerando provision.sh..." 22
        $provScript = Build-ProvisionScript $cfg
        $tmpWin = "$env:TEMP\provision_$user.sh"
        $scriptLF = $provScript -replace "`r`n","`n" -replace "`r","`n"
        [System.IO.File]::WriteAllText($tmpWin, $scriptLF, [System.Text.Encoding]::UTF8)
        $wslSrc  = (wsl -d $distro -- wslpath -u ($tmpWin -replace '\\','/')).Trim()
        $wslPath = "/tmp/provision_$user.sh"
        wsl -d $distro -- bash -c "cp '$wslSrc' $wslPath && chmod +x $wslPath"
        Remove-Item $tmpWin -ErrorAction SilentlyContinue
        Post-Result $cmdId 'ok' "provision.sh injetado" 25

        # Executar
        Post-Result $cmdId 'step' "Executando provision.sh (5-15 min)..." 28
        $psi = [System.Diagnostics.ProcessStartInfo]::new("wsl.exe")
        $psi.Arguments = "-d $distro -- bash -c `"sudo bash $wslPath`""
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $proc2 = [System.Diagnostics.Process]::Start($psi)

        $pctMap = @{
            'Timezone'=30;'Base packages'=35;'User'=38;'Sudo'=40;
            'wsl.conf'=42;'Oh My Zsh'=45;'zsh plugins'=48;'kubectl'=52;
            'OpenShift'=55;'Helm'=57;'k9s'=59;'Terraform'=62;
            'Docker'=65;'SQLPlus'=68;'Python'=72;'Node'=75;
            'fzf'=77;'jq'=78;'htop'=80;'Aliases'=88;'Git'=91
        }
        $curPct = 28

        while (-not $proc2.StandardOutput.EndOfStream) {
            $line = $proc2.StandardOutput.ReadLine()
            if (-not $line) { continue }
            foreach ($kv in $pctMap.GetEnumerator()) {
                if ($line -match $kv.Key) { $curPct = [Math]::Max($curPct, $kv.Value); break }
            }
            $lvl = 'info'
            if ($line -match '\[OK\]')   { $lvl = 'ok' }
            if ($line -match '\[WARN\]') { $lvl = 'warn' }
            if ($line -match '\[ERR\]')  { $lvl = 'error' }
            if ($line -match '^>')       { $lvl = 'step' }
            $clean = $line -replace '\x1b\[[0-9;]*m',''
            Post-Result $cmdId $lvl $clean $curPct
        }

        $proc2.WaitForExit()

        if ($proc2.ExitCode -ne 0) {
            $stderr = $proc2.StandardError.ReadToEnd() -replace '\x1b\[[0-9;]*m',''
            Post-Result $cmdId 'error' "Exit code $($proc2.ExitCode): $stderr" 98 'error'
            Post-Result $cmdId 'done'  "Provision failed" 98
            Post-Result $cmdId 'done'  'done' 98
            # Sinaliza done=false
            $body = @{ command_id=$cmdId; result=@{ type='done'; ok=$false; msg='Provision failed'; pct=98 } }
            Api-Post "/agent/result" $body | Out-Null
            return
        }

        # Restart WSL
        Post-Result $cmdId 'step' "Reiniciando WSL para aplicar wsl.conf..." 97
        wsl --terminate $distro 2>$null
        Start-Sleep -Seconds 2
        Post-Result $cmdId 'ok' "WSL reiniciado" 99

        # Done
        $doneBody = @{ command_id=$cmdId; result=@{ type='done'; ok=$true; msg="wsl -d $distro -u $user"; pct=100 } }
        Api-Post "/agent/result" $doneBody | Out-Null
        Log "Provision complete: $distro / $user"

    } catch {
        Log "Provision error: $_"
        $errBody = @{ command_id=$cmdId; result=@{ type='done'; ok=$false; msg="$_"; pct=0 } }
        try { Api-Post "/agent/result" $errBody | Out-Null } catch {}
    }
}

function Run-Launch {
    param($cmd)
    $distro = $cmd.distro
    try {
        Start-Process "cmd.exe" -ArgumentList "/k wsl.exe -d `"$distro`"" -WindowStyle Normal
        $body = @{ command_id=$cmd.command_id; result=@{ type='done'; ok=$true; msg="Terminal aberto: $distro" } }
        Api-Post "/agent/result" $body | Out-Null
    } catch {
        $body = @{ command_id=$cmd.command_id; result=@{ type='done'; ok=$false; msg="$_" } }
        Api-Post "/agent/result" $body | Out-Null
    }
}

function Run-RemoveDistro {
    param($cmd)
    $distro = $cmd.distro
    try {
        wsl --terminate $distro 2>$null
        Start-Sleep 1
        wsl --unregister $distro 2>$null
        $body = @{ command_id=$cmd.command_id; result=@{ type='done'; ok=$true; msg="$distro removida" } }
        Api-Post "/agent/result" $body | Out-Null
    } catch {
        $body = @{ command_id=$cmd.command_id; result=@{ type='done'; ok=$false; msg="$_" } }
        Api-Post "/agent/result" $body | Out-Null
    }
}

# ── Build-ProvisionScript (igual ao agente v2, adaptado) ─────────────────────
function Build-ProvisionScript {
    param($cfg)
    $u      = $cfg.user.name
    $shell  = $cfg.user.shell
    $sbin   = if ($shell -eq 'zsh') { '/usr/bin/zsh' } else { '/bin/bash' }
    $tools  = $cfg.tools
    $tz     = $cfg.wsl.timezone
    $hname  = $cfg.wsl.hostname
    $gname  = $cfg.user.gitName
    $gemail = $cfg.user.gitEmail
    $sudo   = $cfg.user.sudo
    $sysmd  = ($cfg.wsl.systemd).ToString().ToLower()
    $amnt   = ($cfg.wsl.automount).ToString().ToLower()
    $iop    = ($cfg.wsl.interop).ToString().ToLower()
    $resolv = ($cfg.wsl.generateResolvConf).ToString().ToLower()
    $hosts  = ($cfg.wsl.generateHosts).ToString().ToLower()

    $L = [System.Collections.Generic.List[string]]::new()
    $a = { param($s) $L.Add($s) }

    & $a "#!/usr/bin/env bash"
    & $a "# WSL Manager v3 Agent - $(Get-Date -f 'yyyy-MM-dd HH:mm')"
    & $a "set -uo pipefail"
    & $a 'R="\033[0;31m";G="\033[0;32m";Y="\033[1;33m";B="\033[1m";N="\033[0m"'
    & $a 'ok()   { echo -e "${G}[OK]${N} $*"; }'
    & $a 'warn() { echo -e "${Y}[WARN]${N} $*"; }'
    & $a 'step() { echo -e "\n${B}> $*${N}"; }'
    & $a 'err()  { echo -e "${R}[ERR]${N} $*"; }'
    & $a '[[ $EUID -ne 0 ]] && { err "root required"; exit 1; }'
    & $a ('U="' + $u + '"')
    & $a ""

    # wsl.conf
    & $a "step 'wsl.conf'"
    & $a "cat > /etc/wsl.conf << 'WSLEOF'"
    & $a ("[boot]`nsystemd=" + $sysmd)
    & $a ("[automount]`nenabled=" + $amnt + "`nroot=/mnt/`noptions=metadata,umask=22,fmask=11")
    & $a ("[network]`nhostname=" + $hname + "`ngenerateHosts=" + $hosts + "`ngenerateResolvConf=" + $resolv)
    & $a ("[interop]`nenabled=" + $iop + "`nappendWindowsPath=false")
    & $a "WSLEOF"
    & $a ("ok 'wsl.conf (hostname=" + $hname + ", systemd=" + $sysmd + ")'")
    & $a ""

    & $a ("step 'Timezone: " + $tz + "'")
    & $a ("timedatectl set-timezone '" + $tz + "' 2>/dev/null || ln -sf /usr/share/zoneinfo/" + $tz + " /etc/localtime")
    & $a "ok 'Timezone'"; & $a ""

    & $a "step 'Base packages'"
    & $a "apt-get update -qq && export DEBIAN_FRONTEND=noninteractive"
    & $a "apt-get install -y -qq curl wget git unzip zip tar ca-certificates gnupg lsb-release apt-transport-https build-essential sudo vim nano openssl"
    & $a 'DISTRO_ID=$(. /etc/os-release && echo $ID)'
    & $a "ok 'Base packages'"; & $a ""

    if ($shell -eq 'zsh' -or $tools -contains 'ohmyzsh') { & $a "apt-get install -y -qq zsh" }

    & $a ('step "User: $U"')
    & $a ('id "$U" &>/dev/null && warn "Already exists" || { useradd -m -s "' + $sbin + '" "$U"; echo "$U:$(openssl rand -base64 16)" | chpasswd; ok "Created"; }')
    & $a ""

    if ($sudo) {
        & $a ('usermod -aG sudo "$U"')
        & $a ('echo "$U ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$U && chmod 440 /etc/sudoers.d/$U')
        & $a "ok 'Sudo NOPASSWD'"; & $a ""
    }

    $CMDS = @{
        ohmyzsh     = 'rm -rf ~/.oh-my-zsh 2>/dev/null; su - "$U" -c ''sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended''' + "`n" + 'su - "$U" -c ''git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/themes/powerlevel10k 2>/dev/null||true''' + "`n" + 'su - "$U" -c ''sed -i "s/ZSH_THEME=\"robbyrussell\"/ZSH_THEME=\"powerlevel10k\/powerlevel10k\"/" ~/.zshrc'''
        zsh_plugins = 'su - "$U" -c ''git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions 2>/dev/null||true''' + "`n" + 'su - "$U" -c ''git clone https://github.com/zsh-users/zsh-syntax-highlighting ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting 2>/dev/null||true''' + "`n" + 'su - "$U" -c ''sed -i "s/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting kubectl docker)/" ~/.zshrc'''
        kubectl     = 'rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg; curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg' + "`n" + "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' > /etc/apt/sources.list.d/kubernetes.list" + "`n" + 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq kubectl'
        oc          = 'OC=$(curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/release.txt | grep ''Version:'' | awk ''{print $2}'')' + "`n" + 'curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OC/openshift-client-linux.tar.gz" | tar -xz -C /usr/local/bin oc'
        helm        = 'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash'
        k9s         = 'K=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" + 'curl -fsSL "https://github.com/derailed/k9s/releases/download/$K/k9s_Linux_amd64.tar.gz" | tar -xz -C /usr/local/bin k9s'
        kubectx     = 'K=$(curl -s https://api.github.com/repos/ahmetb/kubectx/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" + 'curl -fsSL "https://github.com/ahmetb/kubectx/releases/download/$K/kubectx_${K}_linux_x86_64.tar.gz" | tar -xz -C /usr/local/bin kubectx 2>/dev/null||true' + "`n" + 'curl -fsSL "https://github.com/ahmetb/kubectx/releases/download/$K/kubens_${K}_linux_x86_64.tar.gz" | tar -xz -C /usr/local/bin kubens 2>/dev/null||true'
        argocd      = 'K=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" + 'curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/$K/argocd-linux-amd64" -o /usr/local/bin/argocd && chmod +x /usr/local/bin/argocd'
        terraform   = 'wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --batch --yes --dearmor -o /usr/share/keyrings/hashicorp.gpg' + "`n" + 'echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list' + "`n" + 'apt-get update -qq && apt-get install -y -qq terraform'
        ansible     = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ansible'
        docker      = 'DISTRO_ID=$(. /etc/os-release && echo $ID)' + "`n" + 'rm -f /etc/apt/keyrings/docker.gpg; curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg' + "`n" + 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list' + "`n" + 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq docker-ce-cli docker-compose-plugin' + "`n" + 'getent group docker >/dev/null 2>&1 || groupadd docker' + "`n" + 'usermod -aG docker "$U"'
        awscli      = "curl -fsSL 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o /tmp/awscliv2.zip" + "`n" + 'unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip'
        azcli       = 'curl -sL https://aka.ms/InstallAzureCLIDeb | bash'
        python3     = 'apt-get install -y -qq python3 python3-venv python3-pip python3-dev'
        nodejs      = 'su - "$U" -c ''curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash''' + "`n" + 'su - "$U" -c ''source ~/.nvm/nvm.sh && nvm install 20 && nvm alias default 20'''
        go          = 'curl -fsSL https://go.dev/dl/go1.22.3.linux-amd64.tar.gz | tar -xz -C /usr/local' + "`n" + ('printf ''export GOPATH=$HOME/go\nexport PATH=$PATH:/usr/local/go/bin:$GOPATH/bin\n'' >> /home/$U/.' + $shell + 'rc')
        java        = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openjdk-21-jdk maven'
        fzf         = 'su - "$U" -c ''git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf && ~/.fzf/install --all'''
        jq          = 'apt-get install -y -qq jq' + "`n" + 'YQ=$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" + 'curl -fsSL "https://github.com/mikefarah/yq/releases/download/$YQ/yq_linux_amd64" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq'
        tmux        = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux'
        htop        = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq htop btop'
        psql        = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql-client'
        mysql       = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-client'
        sqlplus     = "apt-get install -y -qq libaio1t64 2>/dev/null || apt-get install -y -qq libaio1 2>/dev/null; ln -sf /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /usr/lib/x86_64-linux-gnu/libaio.so.1 2>/dev/null||true`nIC='https://download.oracle.com/otn_software/linux/instantclient/2112000'`ncurl -fsSL `"`$IC/instantclient-basic-linux.x64-21.12.0.0.0dbru.zip`" -o /tmp/ic-basic.zip`ncurl -fsSL `"`$IC/instantclient-sqlplus-linux.x64-21.12.0.0.0dbru.zip`" -o /tmp/ic-sql.zip`nmkdir -p /usr/lib/oracle/21/client64/{bin,lib}`nunzip -q /tmp/ic-basic.zip -d /tmp/ic && mv /tmp/ic/instantclient_21_12/*.so* /usr/lib/oracle/21/client64/lib/`nunzip -q /tmp/ic-sql.zip -d /tmp/ic && mv /tmp/ic/instantclient_21_12/sqlplus /usr/lib/oracle/21/client64/bin/`nrm -rf /tmp/ic /tmp/ic-*.zip`necho /usr/lib/oracle/21/client64/lib > /etc/ld.so.conf.d/oracle21.conf && ldconfig`nln -sf /usr/lib/oracle/21/client64/bin/sqlplus /usr/local/bin/sqlplus`nprintf 'export ORACLE_HOME=/usr/lib/oracle/21/client64\nexport LD_LIBRARY_PATH=`$ORACLE_HOME/lib:`$LD_LIBRARY_PATH\nexport PATH=`$ORACLE_HOME/bin:`$PATH\nexport NLS_LANG=AMERICAN_AMERICA.AL32UTF8\n' >> /home/`$U/.$($shell)rc"
        vscode      = ('printf "alias code=''/mnt/c/Users/$(cmd.exe /c \"echo %USERNAME%\" 2>/dev/null | tr -d \"\r\")/AppData/Local/Programs/Microsoft\\ VS\\ Code/bin/code''\n" >> /home/$U/.' + $shell + 'rc')
    }

    foreach ($tool in $tools) {
        if ($CMDS.ContainsKey($tool)) {
            $name = $tool -replace '_',' '
            & $a ("step '$name'")
            foreach ($line in ($CMDS[$tool] -split "`n")) { & $a $line }
            & $a ("ok '$name'"); & $a ""
        }
    }

    # Git config
    if ($gname -or $gemail) {
        & $a "step 'Git config'"
        if ($gname)  { & $a "su - `"`$U`" -c 'git config --global user.name `"$gname`"'" }
        if ($gemail) { & $a "su - `"`$U`" -c 'git config --global user.email `"$gemail`"'" }
        & $a "su - `"`$U`" -c 'git config --global init.defaultBranch main && git config --global pull.rebase false && git config --global core.autocrlf false'"
        & $a "ok 'Git configurado'"; & $a ""
    }

    # Aliases
    & $a "step 'Aliases'"
    & $a "cat >> /home/`$U/.$($shell)rc << 'ALIASES'"
    & $a "alias ll='ls -lahF'"
    & $a "alias ..='cd ..'"
    & $a "alias ...='cd ../..'"
    & $a "alias ports='ss -tulnp'"
    & $a "alias myip='curl -s ifconfig.me'"
    & $a "alias wsl-restart='wsl.exe --shutdown'"
    if ($tools -contains 'kubectl') {
        & $a "alias k='kubectl'"
        & $a "alias kgp='kubectl get pods -A'"
        & $a "alias kgs='kubectl get svc -A'"
        & $a "alias kgn='kubectl get nodes'"
        & $a "alias kaf='kubectl apply -f'"
        & $a "alias kl='kubectl logs -f'"
        & $a "alias kex='kubectl exec -it'"
    }
    if ($tools -contains 'helm')   { & $a "alias h='helm'"; & $a "alias hls='helm list -A'" }
    if ($tools -contains 'docker') { & $a "alias d='docker'"; & $a "alias dps='docker ps --format \`"table {{.Names}}\t{{.Status}}\t{{.Ports}}\`"'" }
    if ($tools -contains 'sqlplus'){ & $a "alias sqldev='sqlplus /nolog'" }
    & $a "ALIASES"
    & $a "chown `$U: /home/`$U/.$($shell)rc 2>/dev/null||true"
    & $a "ok 'Aliases'"; & $a ""

    & $a "echo -e \"\n\033[0;32m✓ Provisionamento concluído!\033[0m\""
    & $a "echo -e \"  Acesse: wsl -d $($cfg.distro.wslName) -u `$U\""

    return $L -join "`n"
}

# ── Loop principal ────────────────────────────────────────────────────────────
if (-not $Silent) {
    Write-Host ""
    Write-Host "  WSL Manager Agent v$AgentVersion" -ForegroundColor Cyan
    Write-Host "  Backend: $BackendURL"             -ForegroundColor Gray
    Write-Host "  PC: $env:COMPUTERNAME"            -ForegroundColor Gray
    Write-Host "  Ctrl+C para parar."               -ForegroundColor Gray
    Write-Host ""
}

Log "Agent v$AgentVersion started. Backend: $BackendURL"

$heartbeatTs = [DateTime]::MinValue
$pollTs      = [DateTime]::MinValue
$winVer      = Get-WinVersion

while ($true) {
    $now = [DateTime]::Now

    # ── Heartbeat ────────────────────────────────────────────────────────────
    if (($now - $heartbeatTs).TotalSeconds -ge $HeartbeatSec) {
        try {
            $distros = @(Get-DistroList)
            $metrics = Get-WinMetrics
            $body = @{
                distros         = $distros
                metrics         = $metrics
                hostname        = $env:COMPUTERNAME
                windows_version = $winVer
            }
            Api-Post "/agent/heartbeat" $body | Out-Null
            $heartbeatTs = $now
        } catch {
            Log "Heartbeat error: $_"
        }
    }

    # ── Poll commands ─────────────────────────────────────────────────────────
    if (($now - $pollTs).TotalSeconds -ge $PollSec) {
        try {
            $resp = Api-Get "/agent/commands"
            $pollTs = $now

            if ($resp.command) {
                $cmd = $resp.command.command
                Log "Command received: $($cmd.type) / $($resp.command.command_id)"

                switch ($cmd.type) {
                    'provision'    { Run-Provision    $cmd }
                    'launch'       { Run-Launch       $cmd }
                    'remove_distro'{ Run-RemoveDistro $cmd }
                    default        { Log "Unknown command type: $($cmd.type)" }
                }
            }
        } catch {
            Log "Poll error: $_"
        }
    }

    Start-Sleep -Milliseconds 500
}