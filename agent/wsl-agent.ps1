#Requires -Version 5.1
# =============================================================================
# WSL Manager v3 — Agente Windows (cliente polling)
# Autor: Diego Regis M. F. dos Santos
# Email: diego-f-santos@openlabs.com.br
# Time:  OpenLabs - DevOps | Infra
# Versão: 3.1.0
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
$AgentVersion = "3.1.0"
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
    $result = @()
    $raw | Select-Object -Skip 1 | ForEach-Object {
        $line = ($_ -replace '\x00','').Trim()
        if ($line -eq '' -or $line -match '^NAME') { return }
        $line = $line -replace '^\*\s*', ''
        $parts = $line -split '\s+' | Where-Object { $_ -ne '' }
        if ($parts.Count -ge 2) {
            $n = $parts[0]
            $state = $parts[1]
            $result += @{ name = $n; running = ($state -eq 'Running') }
        }
    }
    return $result
}

# ── Coleta métricas Windows ───────────────────────────────────────────────────
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
    try { return (Get-CimInstance Win32_OperatingSystem).Caption -replace "Microsoft ","" }
    catch { return "Windows" }
}

# ── SSE helper ────────────────────────────────────────────────────────────────
function Post-Result {
    param([string]$cmdId, [string]$type, [string]$msg, [int]$pct=-1, [string]$level='info')
    $body = @{
        command_id = $cmdId
        result = @{ type=$type; msg=$msg; pct=$pct; level=$level; ts=(Get-Date -f 'HH:mm:ss') }
    }
    try { Api-Post "/agent/result" $body | Out-Null } catch {}
}

# ── Run-Provision ─────────────────────────────────────────────────────────────
function Run-Provision {
    param($cmd)
    $cmdId  = $cmd.command_id
    $cfg    = $cmd.config
    $distro = $cfg.distro.wslName
    $user   = $cfg.user.name

    Log "Provision start: $distro / $user"
    Post-Result $cmdId 'step' "Iniciando provisionamento: $distro / $user" 5

    try {
        Post-Result $cmdId 'step' "Escrevendo .wslconfig..." 10
        $wslCfg = "[wsl2]`nmemory=$($cfg.wsl.memoryGB)GB`nprocessors=$($cfg.wsl.cpus)`nswap=$($cfg.wsl.swapGB)GB`nlocalhostForwarding=true"
        Set-Content "$env:USERPROFILE\.wslconfig" $wslCfg -Encoding UTF8
        Post-Result $cmdId 'ok' ".wslconfig escrito" 12

        $installed = @(Get-DistroList | ForEach-Object { $_.name })
        if ($installed -contains $distro) {
            Post-Result $cmdId 'warn' "$distro ja instalada - pulando instalacao" 15
        } else {
            Post-Result $cmdId 'step' "Instalando $distro via wsl --install..." 15
            $proc = Start-Process "wsl.exe" -ArgumentList "--install -d $distro --no-launch" -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -ne 0) {
                Post-Result $cmdId 'warn' "wsl --install retornou $($proc.ExitCode)" 18
            }
            Start-Sleep -Seconds 5
            Post-Result $cmdId 'ok' "$distro instalada" 20
        }

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

        Post-Result $cmdId 'step' "Executando provision.sh (5-15 min)..." 28
        $psi = [System.Diagnostics.ProcessStartInfo]::new("wsl.exe")
        $psi.Arguments = "-d $distro -- bash -c `"sudo bash $wslPath 2>&1`""
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $proc2 = [System.Diagnostics.Process]::Start($psi)

        $pctMap = @{
            'wsl.conf'=30;'Timezone'=33;'Base packages'=36;'zsh'=38;
            'User'=40;'Sudo'=42;'kubectl'=45;'oc'=47;'helm'=49;
            'k9s'=51;'kubectx'=52;'stern'=53;'argocd'=54;'tkn'=55;
            'kustomize'=56;'Terraform'=58;'Ansible'=60;'docker'=62;
            'podman'=63;'skopeo'=64;'buildah'=65;'awscli'=66;
            'azcli'=67;'gcloud'=68;'pulumi'=69;'vector'=70;
            'promtool'=71;'SQLPlus'=72;'mysql'=73;'psql'=74;
            'mongosh'=75;'redis'=76;'python3'=77;'nodejs'=78;
            'java'=79;'go'=80;'rust'=81;'ohmyzsh'=83;
            'zsh plugins'=84;'fzf'=85;'jq'=86;'bat'=87;
            'eza'=87;'ripgrep'=88;'tmux'=88;'htop'=89;
            'zoxide'=89;'starship'=90;'nmap'=90;'sshpass'=91;
            'Aliases'=93;'Git'=95
        }
        $curPct = 28

        $bufSize = 4096
        $buf = [char[]]::new($bufSize)
        $lastLine = ''
        $timeoutMs = 1800000  # 30 min
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        while (-not $proc2.HasExited -or -not $proc2.StandardOutput.EndOfStream) {
            if ($sw.ElapsedMilliseconds -gt $timeoutMs) { break }
            if ($proc2.HasExited -and $proc2.StandardOutput.Peek() -eq -1) { break }
            $n = $proc2.StandardOutput.Read($buf, 0, $bufSize)
            if ($n -le 0) {
                if ($proc2.HasExited) { break }
                Start-Sleep -Milliseconds 100
                continue
            }
            $chunk = [string]::new($buf, 0, $n)
            $combined = $lastLine + $chunk
            $lines = $combined -split "`n"
            $lastLine = $lines[-1]
            foreach ($line in ($lines | Select-Object -SkipLast 1)) {
                $line = ($line -replace '\x1B\[[0-9;]*[mK]','' -replace '\x1B\[\??[0-9;]*[hlc]','' -replace '[^\x20-\x7E]','').Trim()
                if (-not $line) { continue }
                foreach ($kv in $pctMap.GetEnumerator()) {
                    if ($line -match $kv.Key) { $curPct = [Math]::Max($curPct, $kv.Value); break }
                }
                $lvl = 'info'
                if ($line -match '\[OK\]')   { $lvl = 'ok' }
                if ($line -match '\[WARN\]') { $lvl = 'warn' }
                if ($line -match '\[ERR\]')  { $lvl = 'error' }
                if ($line -match '^>')       { $lvl = 'step' }
                Post-Result $cmdId $lvl $line $curPct
            }
        }
        $proc2.WaitForExit(60000) | Out-Null

        if ($proc2.ExitCode -ne 0) {
            $stderr = $proc2.StandardError.ReadToEnd() -replace '\x1b\[[0-9;]*m',''
            Post-Result $cmdId 'error' "Exit code $($proc2.ExitCode): $stderr" 98 'error'
            $body = @{ command_id=$cmdId; result=@{ type='done'; ok=$false; msg='Provision failed'; pct=98 } }
            Api-Post "/agent/result" $body | Out-Null
            return
        }

        Post-Result $cmdId 'step' "Reiniciando WSL para aplicar wsl.conf..." 97
        wsl --terminate $distro 2>$null
        Start-Sleep -Seconds 2
        Post-Result $cmdId 'ok' "WSL reiniciado" 99

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

# ── Build-ProvisionScript ─────────────────────────────────────────────────────
function Build-ProvisionScript {
    param($cfg)
    $u      = $cfg.user.name
    $shell  = $cfg.user.shell
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

    # Detecção do package manager
    & $a "step 'Base packages'"
    & $a 'DISTRO_ID=$(. /etc/os-release && echo $ID)'
    & $a 'PKG_MGR="apt-get"; command -v dnf &>/dev/null && PKG_MGR="dnf"'
    & $a 'if [[ "$PKG_MGR" == "apt-get" ]]; then apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl wget git unzip zip tar ca-certificates gnupg lsb-release apt-transport-https build-essential sudo vim nano openssl; fi'
    & $a 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y curl wget git unzip zip tar ca-certificates sudo vim nano openssl which findutils; fi'
    & $a "ok 'Base packages'"; & $a ""

    if ($shell -eq 'zsh' -or $tools -contains 'ohmyzsh') {
        & $a 'if [[ "$PKG_MGR" == "apt-get" ]]; then apt-get install -y -qq zsh; fi'
        & $a 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y zsh; fi'
        & $a 'ZSH_BIN=$(command -v zsh 2>/dev/null || echo /usr/bin/zsh)'
        & $a 'grep -qxF "$ZSH_BIN" /etc/shells 2>/dev/null || echo "$ZSH_BIN" >> /etc/shells'
    }

    $sbin = if ($shell -eq 'zsh') { '${ZSH_BIN:-/usr/bin/zsh}' } else { '/bin/bash' }

    & $a ('step "User: $U"')
    & $a ('id "$U" &>/dev/null && warn "Already exists" || { useradd -m -s "' + $sbin + '" "$U"; echo "$U:$(openssl rand -base64 16)" | chpasswd; ok "Created"; }')
    & $a ""

    if ($sudo) {
        & $a 'usermod -aG sudo "$U" 2>/dev/null; usermod -aG wheel "$U" 2>/dev/null'
        & $a ('echo "$U ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$U && chmod 440 /etc/sudoers.d/$U')
        & $a "ok 'Sudo NOPASSWD'"; & $a ""
    }

    $CMDS = @{
        # ── K8s ──────────────────────────────────────────────────────────────
        kubectl     = 'if [[ "$PKG_MGR" == "dnf" ]]; then' + "`n" +
                      '  cat > /etc/yum.repos.d/kubernetes.repo << EOF' + "`n" +
                      '[kubernetes]' + "`n" + 'name=Kubernetes' + "`n" +
                      'baseurl=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/' + "`n" +
                      'enabled=1' + "`n" + 'gpgcheck=1' + "`n" +
                      'gpgkey=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/repodata/repomd.xml.key' + "`n" +
                      'EOF' + "`n" + '  dnf install -y kubectl' + "`n" + 'else' + "`n" +
                      '  rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg' + "`n" +
                      "  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg" + "`n" +
                      "  echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' > /etc/apt/sources.list.d/kubernetes.list" + "`n" +
                      '  DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq kubectl' + "`n" + 'fi'

        oc          = 'OC=$(curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/release.txt | grep ''Version:'' | awk ''{print $2}'')' + "`n" +
                      'curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OC/openshift-client-linux.tar.gz" | tar -xz -C /usr/local/bin oc'

        helm        = 'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | VERIFY_CHECKSUM=false bash'

        k9s         = 'K=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" +
                      'curl -fsSL "https://github.com/derailed/k9s/releases/download/$K/k9s_Linux_amd64.tar.gz" | tar -xz -C /usr/local/bin k9s'

        kubectx     = 'K=$(curl -s https://api.github.com/repos/ahmetb/kubectx/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" +
                      'curl -fsSL "https://github.com/ahmetb/kubectx/releases/download/$K/kubectx_${K}_linux_x86_64.tar.gz" | tar -xz -C /usr/local/bin kubectx 2>/dev/null||true' + "`n" +
                      'curl -fsSL "https://github.com/ahmetb/kubectx/releases/download/$K/kubens_${K}_linux_x86_64.tar.gz" | tar -xz -C /usr/local/bin kubens 2>/dev/null||true'

        stern       = 'K=$(curl -s https://api.github.com/repos/stern/stern/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" +
                      'curl -fsSL "https://github.com/stern/stern/releases/download/$K/stern_${K#v}_linux_amd64.tar.gz" | tar -xz -C /usr/local/bin stern 2>/dev/null||' + "`n" +
                      'curl -fsSL "https://github.com/stern/stern/releases/download/$K/stern_linux_amd64" -o /usr/local/bin/stern && chmod +x /usr/local/bin/stern 2>/dev/null||true'

        argocd      = 'K=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" +
                      'curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/$K/argocd-linux-amd64" -o /usr/local/bin/argocd && chmod +x /usr/local/bin/argocd'

        tekton      = 'K=$(curl -s https://api.github.com/repos/tektoncd/cli/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" +
                      'curl -fsSL "https://github.com/tektoncd/cli/releases/download/$K/tkn_${K#v}_Linux_x86_64.tar.gz" | tar -xz -C /usr/local/bin tkn 2>/dev/null||true'

        kustomize   = 'K=$(curl -s https://api.github.com/repos/kubernetes-sigs/kustomize/releases/latest | grep tag_name | grep kustomize | cut -d''"'' -f4 | head -1)' + "`n" +
                      'VER=${K#kustomize/}' + "`n" +
                      'curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${VER}/kustomize_${VER}_linux_amd64.tar.gz" | tar -xz -C /usr/local/bin kustomize 2>/dev/null||true'

        # ── Cloud & IaC ───────────────────────────────────────────────────────
        terraform   = 'if [[ "$PKG_MGR" == "dnf" ]]; then' + "`n" +
                      '  dnf install -y dnf-plugins-core 2>/dev/null||true' + "`n" +
                      '  dnf config-manager addrepo --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo 2>/dev/null || dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo 2>/dev/null||true' + "`n" +
                      '  dnf install -y terraform' + "`n" + 'else' + "`n" +
                      '  wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --batch --yes --dearmor -o /usr/share/keyrings/hashicorp.gpg' + "`n" +
                      '  echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list' + "`n" +
                      '  apt-get update -qq && apt-get install -y -qq terraform' + "`n" + 'fi'

        ansible     = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y ansible; else DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ansible; fi'

        awscli      = "curl -fsSL 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o /tmp/awscliv2.zip" + "`n" +
                      'unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip'

        azcli       = 'if [[ "$PKG_MGR" == "dnf" ]]; then rpm --import https://packages.microsoft.com/keys/microsoft.asc; dnf install -y https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm 2>/dev/null||true; dnf install -y azure-cli; else curl -sL https://aka.ms/InstallAzureCLIDeb | bash; fi'

        gcloud      = 'curl -fsSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz | tar -xz -C /opt' + "`n" +
                      '/opt/google-cloud-sdk/install.sh --quiet --no-report-usage 2>/dev/null||true' + "`n" +
                      ('printf ''export PATH=$PATH:/opt/google-cloud-sdk/bin\n'' >> /home/$U/.' + $shell + 'rc')

        ocicli      = 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults 2>/dev/null||true'

        pulumi      = 'curl -fsSL https://get.pulumi.com | sh' + "`n" +
                      ('printf ''export PATH=$PATH:$HOME/.pulumi/bin\n'' >> /home/$U/.' + $shell + 'rc')

        # ── Observabilidade ────────────────────────────────────────────────────
        vector      = 'if [[ "$PKG_MGR" == "dnf" ]]; then' + "`n" +
                      '  cat > /etc/yum.repos.d/vector.repo << EOF' + "`n" +
                      '[vector]' + "`n" + 'name=Vector' + "`n" +
                      'baseurl=https://yum.vector.dev/stable/vector-0/x86_64/' + "`n" +
                      'enabled=1' + "`n" + 'gpgcheck=1' + "`n" +
                      'gpgkey=https://yum.vector.dev/stable/vector-0/x86_64/repodata/repomd.xml.key' + "`n" +
                      'EOF' + "`n" + '  dnf install -y vector' + "`n" + 'else' + "`n" +
                      '  curl -fsSL https://apt.vector.dev/gpg.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/vector.gpg' + "`n" +
                      '  echo "deb [signed-by=/usr/share/keyrings/vector.gpg] https://apt.vector.dev stable vector-0" > /etc/apt/sources.list.d/vector.list' + "`n" +
                      '  apt-get update -qq && apt-get install -y -qq vector' + "`n" + 'fi'

        promtool    = 'K=$(curl -s https://api.github.com/repos/prometheus/prometheus/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" +
                      'curl -fsSL "https://github.com/prometheus/prometheus/releases/download/$K/prometheus-${K#v}.linux-amd64.tar.gz" | tar -xz -C /tmp' + "`n" +
                      'mv /tmp/prometheus-*/promtool /usr/local/bin/ && rm -rf /tmp/prometheus-*'

        logcli      = 'K=$(curl -s https://api.github.com/repos/grafana/loki/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" +
                      'curl -fsSL "https://github.com/grafana/loki/releases/download/$K/logcli-linux-amd64.zip" -o /tmp/logcli.zip' + "`n" +
                      'unzip -q /tmp/logcli.zip -d /usr/local/bin && chmod +x /usr/local/bin/logcli-linux-amd64' + "`n" +
                      'mv /usr/local/bin/logcli-linux-amd64 /usr/local/bin/logcli 2>/dev/null||true && rm -f /tmp/logcli.zip'

        opensearch_cli = 'K=$(curl -s https://api.github.com/repos/opensearch-project/opensearch-cli/releases/latest | grep tag_name | cut -d''"'' -f4 | head -1)' + "`n" +
                         'curl -fsSL "https://github.com/opensearch-project/opensearch-cli/releases/download/$K/opensearch-cli-${K#v}-linux-x64.tar.gz" | tar -xz -C /tmp 2>/dev/null||true' + "`n" +
                         'find /tmp -name "opensearch-cli" -exec mv {} /usr/local/bin/opensearch-cli \; 2>/dev/null||true && chmod +x /usr/local/bin/opensearch-cli 2>/dev/null||true'

        # ── Containers & CI/CD ─────────────────────────────────────────────────
        docker      = 'if [[ "$PKG_MGR" == "dnf" ]]; then' + "`n" +
                      '  dnf install -y dnf-plugins-core 2>/dev/null||true' + "`n" +
                      '  dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null || dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null||true' + "`n" +
                      '  dnf install -y docker-ce-cli docker-compose-plugin' + "`n" + 'else' + "`n" +
                      '  DISTRO_ID=$(. /etc/os-release && echo $ID)' + "`n" +
                      '  rm -f /etc/apt/keyrings/docker.gpg' + "`n" +
                      '  curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg' + "`n" +
                      '  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list' + "`n" +
                      '  DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq docker-ce-cli docker-compose-plugin' + "`n" + 'fi' + "`n" +
                      'getent group docker >/dev/null 2>&1 || groupadd docker' + "`n" +
                      'usermod -aG docker "$U"'

        podman      = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y podman; else' + "`n" +
                      '  if command -v apt-get &>/dev/null; then' + "`n" +
                      '    apt-get install -y -qq podman 2>/dev/null || (. /etc/os-release && echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/ /" > /etc/apt/sources.list.d/podman.list && curl -fsSL "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/Release.key" | gpg --batch --yes --dearmor -o /etc/apt/trusted.gpg.d/podman.gpg && apt-get update -qq && apt-get install -y -qq podman)' + "`n" +
                      '  fi' + "`n" + 'fi'

        skopeo      = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y skopeo; else apt-get install -y -qq skopeo 2>/dev/null||true; fi'

        buildah     = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y buildah; else apt-get install -y -qq buildah 2>/dev/null||true; fi'

        # ── Banco de Dados ────────────────────────────────────────────────────
        sqlplus     = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y libaio 2>/dev/null||true; else apt-get install -y -qq libaio1t64 2>/dev/null || apt-get install -y -qq libaio1 2>/dev/null; ln -sf /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /usr/lib/x86_64-linux-gnu/libaio.so.1 2>/dev/null||true; fi' + "`n" +
                      "IC='https://download.oracle.com/otn_software/linux/instantclient/2112000'" + "`n" +
                      'curl -fsSL "$IC/instantclient-basic-linux.x64-21.12.0.0.0dbru.zip" -o /tmp/ic-basic.zip' + "`n" +
                      'curl -fsSL "$IC/instantclient-sqlplus-linux.x64-21.12.0.0.0dbru.zip" -o /tmp/ic-sql.zip' + "`n" +
                      'mkdir -p /usr/lib/oracle/21/client64/{bin,lib}' + "`n" +
                      'unzip -q /tmp/ic-basic.zip -d /tmp/ic && mv /tmp/ic/instantclient_21_12/*.so* /usr/lib/oracle/21/client64/lib/' + "`n" +
                      'unzip -q /tmp/ic-sql.zip -d /tmp/ic && mv /tmp/ic/instantclient_21_12/sqlplus /usr/lib/oracle/21/client64/bin/' + "`n" +
                      'rm -rf /tmp/ic /tmp/ic-*.zip' + "`n" +
                      'echo /usr/lib/oracle/21/client64/lib > /etc/ld.so.conf.d/oracle21.conf && ldconfig' + "`n" +
                      'ln -sf /usr/lib/oracle/21/client64/bin/sqlplus /usr/local/bin/sqlplus' + "`n" +
                      ('printf ''export ORACLE_HOME=/usr/lib/oracle/21/client64\nexport LD_LIBRARY_PATH=$ORACLE_HOME/lib:$LD_LIBRARY_PATH\nexport PATH=$ORACLE_HOME/bin:$PATH\nexport NLS_LANG=AMERICAN_AMERICA.AL32UTF8\n'' >> /home/$U/.' + $shell + 'rc')

        mysql       = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y mysql; else DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-client; fi'

        psql        = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y postgresql; else DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql-client; fi'

        mongosh     = 'K=$(curl -s https://api.github.com/repos/mongodb-js/mongosh/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" +
                      'curl -fsSL "https://github.com/mongodb-js/mongosh/releases/download/$K/mongosh-${K#v}-linux-x64.tgz" | tar -xz -C /tmp 2>/dev/null||true' + "`n" +
                      'find /tmp -name "mongosh" -type f -exec mv {} /usr/local/bin/mongosh \; 2>/dev/null||true && chmod +x /usr/local/bin/mongosh 2>/dev/null||true'

        redis_cli   = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y redis; else DEBIAN_FRONTEND=noninteractive apt-get install -y -qq redis-tools; fi'

        # ── Dev & Linguagens ──────────────────────────────────────────────────
        python3     = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y python3 python3-virtualenv python3-pip python3-devel; else apt-get install -y -qq python3 python3-venv python3-pip python3-dev; fi'

        nodejs      = 'su - "$U" -c ''curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash''' + "`n" +
                      'su - "$U" -c ''source ~/.nvm/nvm.sh && nvm install 20 && nvm alias default 20'''

        go          = 'curl -fsSL https://go.dev/dl/go1.22.3.linux-amd64.tar.gz | tar -xz -C /usr/local' + "`n" +
                      ('printf ''export GOPATH=$HOME/go\nexport PATH=$PATH:/usr/local/go/bin:$GOPATH/bin\n'' >> /home/$U/.' + $shell + 'rc')

        java        = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y java-21-openjdk-devel maven; else DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openjdk-21-jdk maven; fi'

        rust        = 'su - "$U" -c ''curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y''' + "`n" +
                      ('printf ''export PATH=$HOME/.cargo/bin:$PATH\n'' >> /home/$U/.' + $shell + 'rc')

        # ── Shell & Produtividade ──────────────────────────────────────────────
        ohmyzsh     = 'rm -rf ~/.oh-my-zsh 2>/dev/null; su - "$U" -c ''sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended''' + "`n" +
                      'su - "$U" -c ''git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/themes/powerlevel10k 2>/dev/null||true''' + "`n" +
                      'su - "$U" -c ''sed -i "s/ZSH_THEME=\"robbyrussell\"/ZSH_THEME=\"powerlevel10k\/powerlevel10k\"/" ~/.zshrc'''

        zsh_plugins = 'su - "$U" -c ''git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions 2>/dev/null||true''' + "`n" +
                      'su - "$U" -c ''git clone https://github.com/zsh-users/zsh-syntax-highlighting ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting 2>/dev/null||true''' + "`n" +
                      'su - "$U" -c ''sed -i "s/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting kubectl docker)/" ~/.zshrc'''

        fzf         = 'su - "$U" -c ''git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf && ~/.fzf/install --all'''

        jq          = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y jq; else apt-get install -y -qq jq; fi' + "`n" +
                      'YQ=$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" +
                      'curl -fsSL "https://github.com/mikefarah/yq/releases/download/$YQ/yq_linux_amd64" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq'

        bat         = 'K=$(curl -s https://api.github.com/repos/sharkdp/bat/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" +
                      'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y bat 2>/dev/null || curl -fsSL "https://github.com/sharkdp/bat/releases/download/$K/bat-${K}-x86_64-unknown-linux-gnu.tar.gz" | tar -xz -C /tmp && mv /tmp/bat-*/bat /usr/local/bin/ 2>/dev/null||true; else curl -fsSL "https://github.com/sharkdp/bat/releases/download/$K/bat_${K#v}_amd64.deb" -o /tmp/bat.deb && dpkg -i /tmp/bat.deb && rm /tmp/bat.deb 2>/dev/null||true; fi'

        eza         = 'K=$(curl -s https://api.github.com/repos/eza-community/eza/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" +
                      'curl -fsSL "https://github.com/eza-community/eza/releases/download/$K/eza_x86_64-unknown-linux-gnu.tar.gz" | tar -xz -C /usr/local/bin 2>/dev/null||true && chmod +x /usr/local/bin/eza 2>/dev/null||true'

        ripgrep     = 'K=$(curl -s https://api.github.com/repos/BurntSushi/ripgrep/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" +
                      'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y ripgrep 2>/dev/null || curl -fsSL "https://github.com/BurntSushi/ripgrep/releases/download/$K/ripgrep-${K}-x86_64-unknown-linux-musl.tar.gz" | tar -xz -C /tmp && mv /tmp/ripgrep-*/rg /usr/local/bin/ 2>/dev/null||true; else curl -fsSL "https://github.com/BurntSushi/ripgrep/releases/download/$K/ripgrep_${K}_amd64.deb" -o /tmp/rg.deb && dpkg -i /tmp/rg.deb && rm /tmp/rg.deb 2>/dev/null||true; fi' + "`n" +
                      'K2=$(curl -s https://api.github.com/repos/sharkdp/fd/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" +
                      'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y fd-find 2>/dev/null || curl -fsSL "https://github.com/sharkdp/fd/releases/download/$K2/fd-${K2}-x86_64-unknown-linux-gnu.tar.gz" | tar -xz -C /tmp && mv /tmp/fd-*/fd /usr/local/bin/ 2>/dev/null||true; else curl -fsSL "https://github.com/sharkdp/fd/releases/download/$K2/fd_${K2#v}_amd64.deb" -o /tmp/fd.deb && dpkg -i /tmp/fd.deb && rm /tmp/fd.deb 2>/dev/null||true; fi'

        tmux        = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y tmux; else DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux; fi'

        htop        = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y htop btop 2>/dev/null || dnf install -y htop; else DEBIAN_FRONTEND=noninteractive apt-get install -y -qq htop btop 2>/dev/null || apt-get install -y -qq htop; fi'

        zoxide      = 'curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh' + "`n" +
                      ('printf ''eval "$(zoxide init ' + $shell + ')"\n'' >> /home/$U/.' + $shell + 'rc')

        starship    = 'curl -fsSL https://starship.rs/install.sh | sh -s -- -y' + "`n" +
                      ('printf ''eval "$(starship init ' + $shell + ')"\n'' >> /home/$U/.' + $shell + 'rc')

        # ── Rede & Segurança ──────────────────────────────────────────────────
        curl_jq     = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y httpie 2>/dev/null||true; else apt-get install -y -qq httpie 2>/dev/null||true; fi'

        nmap        = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y nmap; else DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nmap; fi'

        openssl     = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y openssl; else DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssl cfssl 2>/dev/null||apt-get install -y -qq openssl; fi'

        sshpass     = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y sshpass; else DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass; fi'

        wireshark_cli = 'if [[ "$PKG_MGR" == "dnf" ]]; then dnf install -y wireshark-cli; else DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tshark; fi'

        # ── VS Code alias ──────────────────────────────────────────────────────
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
    if ($tools -contains 'helm')    { & $a "alias h='helm'"; & $a "alias hls='helm list -A'" }
    if ($tools -contains 'docker')  { & $a "alias d='docker'"; & $a "alias dps='docker ps --format \`\"table {{.Names}}\t{{.Status}}\t{{.Ports}}\`\"'" }
    if ($tools -contains 'sqlplus') { & $a "alias sqldev='sqlplus /nolog'" }
    if ($tools -contains 'eza')     { & $a "alias ls='eza --icons'"; & $a "alias ll='eza -lahF --icons --git'" }
    if ($tools -contains 'bat')     { & $a "alias cat='bat --style=plain'" }
    & $a "ALIASES"
    & $a "chown `$U: /home/`$U/.$($shell)rc 2>/dev/null||true"
    & $a "ok 'Aliases'"; & $a ""

    & $a 'echo -e "\n\033[0;32m✓ Provisionamento concluido!\033[0m"'
    & $a ("echo -e '  Acesse: wsl -d " + $cfg.distro.wslName + " -u $U'")

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