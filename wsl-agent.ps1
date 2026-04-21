#Requires -Version 5.1
param(
    [int]    $Port      = 7745,
    [switch] $Install,
    [switch] $Uninstall,
    [switch] $Silent
)
$ErrorActionPreference = "Stop"
$AgentVersion = "1.1.0"
$TaskName     = "WSLManagerAgent"
$LogFile      = "$env:TEMP\wsl-agent.log"

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "WSL Agent removed." -ForegroundColor Green
    exit
}

if ($Install) {
    $scriptPath = $MyInvocation.MyCommand.Path
    Unblock-File -Path $scriptPath -ErrorAction SilentlyContinue
    $action   = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"" + $scriptPath + "`" -Silent")
    $trigger  = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
    $principal= New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "WSL Agent installed! Will start automatically on next login." -ForegroundColor Green
    Start-Process powershell -ArgumentList ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"" + $scriptPath + "`" -Silent") -WindowStyle Hidden
    exit
}

function Log { param($m) Add-Content $LogFile ("[" + (Get-Date -f 'HH:mm:ss') + "] " + $m) -ErrorAction SilentlyContinue }

function Send-CorsResponse {
    param($ctx, [int]$code=200, [string]$body='', [string]$ct='application/json')
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = $ct
    $ctx.Response.Headers.Add("Access-Control-Allow-Origin",  "*")
    $ctx.Response.Headers.Add("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
    $ctx.Response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
    if ($body) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    $ctx.Response.OutputStream.Close()
}

function Get-InstalledDistros {
    $raw = wsl --list --quiet 2>$null
    if (-not $raw) { return @() }
    return $raw | ForEach-Object { ($_ -replace '\x00','').Trim() } | Where-Object { $_ -ne '' }
}

function Get-AgentStatus {
    $distros = Get-InstalledDistros
    $obj = @{
        version  = $AgentVersion
        port     = $Port
        distros  = $distros
        pc       = $env:COMPUTERNAME
        user     = $env:USERNAME
        wslReady = ($distros.Count -gt 0)
    }
    return $obj | ConvertTo-Json -Compress
}

function Send-SSE {
    param($stream, [string]$type, [string]$msg, [int]$pct=-1, [string]$level='info')
    $obj = '{"type":"' + $type + '","msg":' + ($msg | ConvertTo-Json) + ',"pct":' + $pct + ',"level":"' + $level + '","ts":"' + (Get-Date -f 'HH:mm:ss') + '"}'
    $line = "data: " + $obj + "`n`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } catch {}
}

function Send-SSEDone {
    param($stream, [bool]$ok, [string]$msg)
    $obj = '{"type":"done","ok":' + ($ok.ToString().ToLower()) + ',"msg":' + ($msg | ConvertTo-Json) + ',"ts":"' + (Get-Date -f 'HH:mm:ss') + '"}'
    $line = "data: " + $obj + "`n`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } catch {}
    try { $stream.Close() } catch {}
}

function Build-ProvisionScript {
    param($cfg)
    $u      = $cfg.user.name
    $shell  = $cfg.user.shell
    $sbin   = if ($shell -eq 'zsh') { '/usr/bin/zsh' } else { '/bin/bash' }
    $theme  = $cfg.user.zshTheme
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
    & $a "# WSL Manager Agent - $(Get-Date -f 'yyyy-MM-dd HH:mm')"
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

    # Timezone
    & $a ("step 'Timezone: " + $tz + "'")
    & $a ("timedatectl set-timezone '" + $tz + "' 2>/dev/null || ln -sf /usr/share/zoneinfo/" + $tz + " /etc/localtime")
    & $a "ok 'Timezone'"
    & $a ""

    # Base packages -- works on Ubuntu and Debian
    & $a "step 'Base packages'"
    & $a "apt-get update -qq"
    & $a "export DEBIAN_FRONTEND=noninteractive"
    & $a "apt-get install -y -qq curl wget git unzip zip tar ca-certificates gnupg lsb-release apt-transport-https build-essential sudo vim nano openssl"
    & $a 'DISTRO_ID=$(. /etc/os-release && echo $ID)'
    & $a 'if [[ "$DISTRO_ID" == "ubuntu" ]]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq software-properties-common 2>/dev/null||true; fi'
    & $a "ok 'Base packages'"
    & $a ""

    if ($shell -eq 'zsh' -or $tools -contains 'ohmyzsh') { & $a "apt-get install -y -qq zsh" }

    # Create user
    & $a ('step "User: $U"')
    & $a ('id "$U" &>/dev/null && warn "Already exists" || { useradd -m -s "' + $sbin + '" "$U"; echo "$U:$(openssl rand -base64 16)" | chpasswd; ok "Created"; }')
    & $a ""

    if ($sudo) {
        & $a ('usermod -aG sudo "$U"')
        & $a ('echo "$U ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$U && chmod 440 /etc/sudoers.d/$U')
        & $a "ok 'Sudo NOPASSWD'"
        & $a ""
    }

    $CMDS = @{
        ohmyzsh     = 'rm -rf ~/.oh-my-zsh 2>/dev/null; su - "$U" -c ''sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'''
        zsh_plugins = 'su - "$U" -c ''rm -rf ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions; git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions 2>/dev/null||true''' + "`n" + 'su - "$U" -c ''rm -rf ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting; git clone https://github.com/zsh-users/zsh-syntax-highlighting ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting 2>/dev/null||true''' + "`n" + 'su - "$U" -c ''sed -i "s/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting kubectl docker)/" ~/.zshrc'''
        kubectl     = 'rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg /etc/apt/sources.list.d/kubernetes.list; curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg' + "`n" + "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' > /etc/apt/sources.list.d/kubernetes.list" + "`n" + 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq kubectl'
        oc          = 'OC=$(curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/release.txt | grep ''Version:'' | awk ''{print $2}'')' + "`n" + 'curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OC/openshift-client-linux.tar.gz" | tar -xz -C /usr/local/bin oc'
        helm        = 'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash'
        k9s         = 'K=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" + 'curl -fsSL "https://github.com/derailed/k9s/releases/download/$K/k9s_Linux_amd64.tar.gz" | tar -xz -C /usr/local/bin k9s'
        kubectx     = 'K=$(curl -s https://api.github.com/repos/ahmetb/kubectx/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" + 'curl -fsSL "https://github.com/ahmetb/kubectx/releases/download/$K/kubectx_${K}_linux_x86_64.tar.gz" | tar -xz -C /usr/local/bin kubectx' + "`n" + 'curl -fsSL "https://github.com/ahmetb/kubectx/releases/download/$K/kubens_${K}_linux_x86_64.tar.gz" | tar -xz -C /usr/local/bin kubens'
        stern       = 'K=$(curl -s https://api.github.com/repos/stern/stern/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" + 'curl -fsSL "https://github.com/stern/stern/releases/download/$K/stern_linux_amd64.tar.gz" | tar -xz -C /usr/local/bin stern'
        argocd      = 'K=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" + 'curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/$K/argocd-linux-amd64" -o /usr/local/bin/argocd && chmod +x /usr/local/bin/argocd'
        terraform   = 'wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor --yes -o /usr/share/keyrings/hashicorp.gpg' + "`n" + 'echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list' + "`n" + 'apt-get update -qq && apt-get install -y -qq terraform'
        ansible     = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ansible'
        awscli      = "curl -fsSL 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o /tmp/awscliv2.zip" + "`n" + 'unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip'
        docker      = 'DISTRO_ID=$(. /etc/os-release && echo $ID)' + "`n" + 'rm -f /etc/apt/keyrings/docker.gpg; curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg' + "`n" + 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list' + "`n" + 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq docker-ce-cli docker-compose-plugin' + "`n" + 'getent group docker >/dev/null 2>&1 || groupadd docker' + "`n" + 'usermod -aG docker "$U"'
        vector      = 'curl -fsSL https://setup.vector.dev | bash -s -- -y 2>/dev/null || echo "[WARN] Vector skipped"'
        python3     = 'apt-get install -y -qq python3 python3-venv python3-pip python3-dev' + "`n" + 'PY=$(readlink -f /usr/bin/python3)' + "`n" + 'update-alternatives --install /usr/bin/python3 python3 $PY 1 2>/dev/null||true'
        nodejs      = 'su - "$U" -c ''curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash''' + "`n" + 'su - "$U" -c ''source ~/.nvm/nvm.sh && nvm install 20 && nvm alias default 20'''
        go          = 'curl -fsSL https://go.dev/dl/go1.22.3.linux-amd64.tar.gz | tar -xz -C /usr/local' + "`n" + ('printf ''export GOPATH=$HOME/go\nexport PATH=$PATH:/usr/local/go/bin:$GOPATH/bin\n'' >> /home/$U/.' + $shell + 'rc')
        fzf         = 'su - "$U" -c ''git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf && ~/.fzf/install --all'''
        jq          = 'apt-get install -y -qq jq' + "`n" + 'YQ=$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" + 'curl -fsSL "https://github.com/mikefarah/yq/releases/download/$YQ/yq_linux_amd64" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq'
        tmux        = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux' + "`n" + ('printf ''set -g mouse on\nset -g default-terminal screen-256color\n'' > /home/$U/.tmux.conf && chown $U: /home/$U/.tmux.conf')
        bat         = ('DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bat && su - "$U" -c ''echo "alias cat=batcat" >> ~/.' + $shell + 'rc''')
        htop        = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq htop btop'
        ripgrep     = ('DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ripgrep fd-find && su - "$U" -c ''echo "alias fd=fdfind" >> ~/.' + $shell + 'rc''')
        curl_jq     = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq httpie'
        mysql       = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-client'
        psql        = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql-client'
        mongosh     = 'curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor --yes -o /usr/share/keyrings/mongodb.gpg' + "`n" + 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/mongodb.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" > /etc/apt/sources.list.d/mongodb.list' + "`n" + 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mongodb-mongosh'
        sqlplus     = "apt-get install -y -qq libaio1t64 2>/dev/null || apt-get install -y -qq libaio1 2>/dev/null; ln -sf /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /usr/lib/x86_64-linux-gnu/libaio.so.1 2>/dev/null||true`nIC='https://download.oracle.com/otn_software/linux/instantclient/2112000'`ncurl -fsSL `"`$IC/instantclient-basic-linux.x64-21.12.0.0.0dbru.zip`" -o /tmp/ic-basic.zip`ncurl -fsSL `"`$IC/instantclient-sqlplus-linux.x64-21.12.0.0.0dbru.zip`" -o /tmp/ic-sql.zip`nmkdir -p /usr/lib/oracle/21/client64/{bin,lib}`nunzip -q /tmp/ic-basic.zip -d /tmp/ic && mv /tmp/ic/instantclient_21_12/*.so* /usr/lib/oracle/21/client64/lib/`nunzip -q /tmp/ic-sql.zip -d /tmp/ic && mv /tmp/ic/instantclient_21_12/sqlplus /usr/lib/oracle/21/client64/bin/`nrm -rf /tmp/ic /tmp/ic-*.zip`necho /usr/lib/oracle/21/client64/lib > /etc/ld.so.conf.d/oracle21.conf && ldconfig`nln -sf /usr/lib/oracle/21/client64/bin/sqlplus /usr/local/bin/sqlplus`nprintf 'export ORACLE_HOME=/usr/lib/oracle/21/client64\nexport LD_LIBRARY_PATH=`$ORACLE_HOME/lib:`$LD_LIBRARY_PATH\nexport PATH=`$ORACLE_HOME/bin:`$PATH\nexport NLS_LANG=AMERICAN_AMERICA.AL32UTF8\n' >> /home/`$U/.$($shell)rc"
        azcli       = 'curl -sL https://aka.ms/InstallAzureCLIDeb | bash'
        ocicli      = 'curl -fsSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o /tmp/oci_install.sh && bash /tmp/oci_install.sh --accept-all-defaults 2>/dev/null || pip3 install oci-cli --quiet 2>/dev/null||true'
        gcloud      = 'curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg' + "`n" + 'echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" > /etc/apt/sources.list.d/google-cloud-sdk.list' + "`n" + 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq google-cloud-cli'
        pulumi      = 'curl -fsSL https://get.pulumi.com | sh -s -- --non-interactive 2>/dev/null||true'
        tekton      = 'TKN=$(curl -s https://api.github.com/repos/tektoncd/cli/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" + 'curl -fsSL "https://github.com/tektoncd/cli/releases/download/$TKN/tkn_$(echo $TKN | tr -d v)_Linux_x86_64.tar.gz" | tar -xz -C /usr/local/bin tkn 2>/dev/null||true'
        kustomize   = 'curl -fsSL https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh | bash -s -- /usr/local/bin 2>/dev/null||true'
        logcli      = 'LC=$(curl -s https://api.github.com/repos/grafana/loki/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" + 'curl -fsSL "https://github.com/grafana/loki/releases/download/$LC/logcli-linux-amd64.zip" -o /tmp/logcli.zip && unzip -q /tmp/logcli.zip -d /tmp && mv /tmp/logcli-linux-amd64 /usr/local/bin/logcli && chmod +x /usr/local/bin/logcli && rm /tmp/logcli.zip 2>/dev/null||true'
        opensearch_cli = 'pip3 install opensearch-py --quiet 2>/dev/null||true; curl -fsSL https://github.com/opensearch-project/opensearch-cli/releases/latest/download/opensearch-cli-linux-amd64.tar.gz 2>/dev/null | tar -xz -C /usr/local/bin 2>/dev/null||true'
        promtool    = 'PVER=$(curl -s https://api.github.com/repos/prometheus/prometheus/releases/latest | grep tag_name | cut -d''"'' -f4 | tr -d v)' + "`n" + 'curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v$PVER/prometheus-$PVER.linux-amd64.tar.gz" | tar -xz --strip-components=1 -C /usr/local/bin "prometheus-$PVER.linux-amd64/promtool" 2>/dev/null||true'
        podman      = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman 2>/dev/null||true'
        skopeo      = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq skopeo 2>/dev/null||true'
        buildah     = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq buildah 2>/dev/null||true'
        redis_cli   = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq redis-tools'
        java        = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openjdk-21-jdk maven' + "`n" + ('printf ''export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
export PATH=$PATH:$JAVA_HOME/bin
'' >> /home/$U/.' + $shell + 'rc')
        rust        = 'su - "$U" -c ''curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'''
        zoxide      = 'curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash 2>/dev/null||true' + "`n" + ('su - "$U" -c ''echo eval \"\$(zoxide init ' + $shell + ')\" >> ~/.' + $shell + 'rc'' 2>/dev/null||true')
        starship    = 'curl -sS https://starship.rs/install.sh | sh -s -- -y 2>/dev/null||true' + "`n" + ('su - "$U" -c ''echo eval \"\$(starship init ' + $shell + ')\" >> ~/.' + $shell + 'rc'' 2>/dev/null||true')
        openssl     = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssl' + "`n" + 'curl -fsSL https://github.com/cloudflare/cfssl/releases/latest/download/cfssl_linux-amd64 -o /usr/local/bin/cfssl && chmod +x /usr/local/bin/cfssl 2>/dev/null||true' + "`n" + 'curl -fsSL https://github.com/cloudflare/cfssl/releases/latest/download/cfssljson_linux-amd64 -o /usr/local/bin/cfssljson && chmod +x /usr/local/bin/cfssljson 2>/dev/null||true'
        sshpass     = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass'
        wireshark_cli = 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tshark'
        eza         = 'EZA=$(curl -s https://api.github.com/repos/eza-community/eza/releases/latest | grep tag_name | cut -d''"'' -f4)' + "`n" + 'curl -fsSL "https://github.com/eza-community/eza/releases/download/$EZA/eza_x86_64-unknown-linux-gnu.tar.gz" | tar -xz -C /usr/local/bin eza 2>/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq eza 2>/dev/null||true' + "`n" + ('su - "$U" -c ''printf "alias ls=eza
alias ll=\"eza -la\"
" >> ~/.' + $shell + 'rc''')
        vscode      = ('printf "alias code=''/mnt/c/Users/$(cmd.exe /c \"echo %USERNAME%\" 2>/dev/null | tr -d \"\r\")/AppData/Local/Programs/Microsoft\\ VS\\ Code/bin/code''\n" >> /home/$U/.' + $shell + 'rc')
    }
    $NAMES = @{ohmyzsh='Oh My Zsh';zsh_plugins='zsh plugins';kubectl='kubectl';oc='OpenShift CLI';helm='Helm v3';k9s='k9s';kubectx='kubectx+kubens';stern='Stern';argocd='ArgoCD';tekton='tkn (Tekton)';kustomize='kustomize';terraform='Terraform';ansible='Ansible';awscli='AWS CLI';azcli='Azure CLI';gcloud='gcloud CLI';ocicli='OCI CLI';pulumi='Pulumi';docker='Docker';podman='Podman';skopeo='Skopeo';buildah='Buildah';vector='Vector';promtool='promtool';logcli='logcli';opensearch_cli='opensearch-cli';python3='Python 3';nodejs='Node.js 20';go='Go 1.22';java='Java 21 JDK';rust='Rust+cargo';fzf='fzf';jq='jq+yq';tmux='tmux';bat='bat';eza='eza';htop='htop+btop';ripgrep='ripgrep+fd';zoxide='zoxide';starship='Starship';curl_jq='httpie';nmap='nmap';openssl='openssl+cfssl';sshpass='sshpass';wireshark_cli='tshark';mysql='MySQL Client';psql='psql';mongosh='mongosh';redis_cli='redis-cli';sqlplus='SQLPlus 21c';vscode='VS Code'}

    if ($tools -contains 'ohmyzsh') {
        & $a "step 'Oh My Zsh'"
        $cleanOmz = 'rm -rf ~/.oh-my-zsh 2>/dev/null; true'
        & $a $cleanOmz
        & $a $CMDS['ohmyzsh']
        if ($theme -eq 'powerlevel10k') {
            & $a 'su - "$U" -c ''rm -rf ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/themes/powerlevel10k 2>/dev/null; git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/themes/powerlevel10k'''
            & $a 'su - "$U" -c ''sed -i "s/ZSH_THEME=.*/ZSH_THEME=\"powerlevel10k\/powerlevel10k\"/" ~/.zshrc'''
        } elseif ($theme -and $theme -ne 'none') {
            & $a ('su - "$U" -c ''sed -i "s/ZSH_THEME=.*/ZSH_THEME=\"' + $theme + '\"/" ~/.zshrc''')
        }
        & $a "ok 'Oh My Zsh'"
        & $a ""
    }

    foreach ($tool in $tools) {
        if ($tool -eq 'ohmyzsh') { continue }
        if (-not $CMDS.ContainsKey($tool)) { continue }
        $n = if ($NAMES.ContainsKey($tool)) { $NAMES[$tool] } else { $tool }
        & $a ("step '" + $n + "'")
        foreach ($line in ($CMDS[$tool] -split "`n")) { & $a $line }
        & $a ("ok '" + $n + "'")
        & $a ""
    }

    if ($gname -or $gemail) {
        & $a "step 'Git config'"
        if ($gname)  { & $a ('su - "$U" -c ''git config --global user.name "' + $gname + '"''') }
        if ($gemail) { & $a ('su - "$U" -c ''git config --global user.email "' + $gemail + '"''') }
        & $a 'su - "$U" -c ''git config --global init.defaultBranch main && git config --global pull.rebase false && git config --global core.autocrlf false'''
        & $a "ok 'Git'"
        & $a ""
    }

    $rc = '/home/$U/.' + $shell + 'rc'
    & $a "step 'Aliases'"
    & $a ("cat >> " + $rc + " << 'ALIASES'")
    & $a "# -- WSL Manager aliases -----------------------------------------"
    if ($tools -contains 'kubectl' -or $tools -contains 'oc') {
        & $a "alias k='kubectl'"
        & $a "alias kgp='kubectl get pods -A'"
        & $a "alias kgs='kubectl get svc -A'"
        & $a "alias kaf='kubectl apply -f'"
        & $a "alias kl='kubectl logs -f'"
        & $a "alias kex='kubectl exec -it'"
        & $a "alias kns='kubectl config set-context --current --namespace'"
    }
    if ($tools -contains 'oc')          { & $a "alias oc-login='oc login https://api.openshift.openlabs.local:6443'" }
    if ($tools -contains 'helm')        { & $a "alias h='helm'"; & $a "alias hls='helm list -A'" }
    if ($tools -contains 'docker')      { & $a "alias d='docker'" }
    if ($tools -contains 'terraform')   { & $a "alias tf='terraform'"; & $a "alias tfp='terraform plan'"; & $a "alias tfa='terraform apply'" }
    if ($tools -contains 'sqlplus')     { & $a "alias sqldev='sqlplus /nolog'" }
    & $a "alias ll='ls -lahF'"
    & $a "alias ..='cd ..'"
    & $a "alias ports='ss -tulnp'"
    & $a "alias myip='curl -s ifconfig.me'"
    & $a "alias wsl-restart='wsl.exe --shutdown'"
    & $a "# -----------------------------------------------------------------"
    & $a "ALIASES"
    & $a ('chown "$U": /home/"$U"/.' + $shell + 'rc 2>/dev/null||true')
    & $a "ok 'Aliases'"
    & $a ""
    & $a 'if [[ -f /tmp/wsl_profile.sh ]]; then'
    & $a '  cp /tmp/wsl_profile.sh /usr/local/bin/wsl_profile.sh && chmod +x /usr/local/bin/wsl_profile.sh'
    & $a "  ok 'wsl_profile.sh installed'"
    & $a 'fi'
    & $a ""
    & $a 'echo -e "\n\033[0;32m[DONE] Provisioning complete!\033[0m"'
    & $a ('echo -e "  Access: wsl -d ' + $cfg.distro.wslName + ' -u $U"')

    return ($L -join "`n")
}

function Start-Provision {
    param($ctx, $cfg)
    $distroName = $cfg.distro.wslName
    $userName   = $cfg.user.name
    $resp       = $ctx.Response
    $resp.StatusCode  = 200
    $resp.ContentType = "text/event-stream; charset=utf-8"
    $resp.Headers.Add("Access-Control-Allow-Origin", "*")
    $resp.Headers.Add("Cache-Control", "no-cache")
    $resp.Headers.Add("Connection", "keep-alive")
    $resp.SendChunked = $true
    $out = $resp.OutputStream

    try {
        Log ("Provision start: " + $distroName + " / " + $userName)
        Send-SSE $out 'start' "Starting provision of $distroName..." 0

        # 1. WSL feature
        Send-SSE $out 'step' "Checking WSL..." 5
        $feat = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
        if ($feat.State -ne 'Enabled') {
            Send-SSE $out 'step' "Enabling WSL..." 8 'warn'
            dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart 2>$null | Out-Null
            dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart 2>$null | Out-Null
        }
        wsl --set-default-version 2 2>$null | Out-Null
        Send-SSE $out 'ok' "WSL2 ready" 10

        # 2. Install distro
        $installed = Get-InstalledDistros
        if ($installed -contains $distroName) {
            Send-SSE $out 'warn' ($distroName + " already installed") 20
        } else {
            Send-SSE $out 'step' ("Installing " + $distroName + "...") 15
            Start-Process "wsl.exe" -ArgumentList ("--install -d " + $distroName + " --no-launch") -Wait -WindowStyle Hidden
            Send-SSE $out 'step' "Waiting for distro..." 22
            $tries = 0
            while ($tries -lt 25) {
                try { $o = wsl -d $distroName -- echo "ready" 2>$null; if ($o -match "ready") { break } } catch {}
                $tries++; Start-Sleep -Seconds 5
                Send-SSE $out 'step' ("Waiting... (" + $tries + "/25)") (22 + $tries) 'info'
            }
            Send-SSE $out 'ok' ($distroName + " ready") 30
        }

        # 3. .wslconfig
        $memVal  = [string]$cfg.wsl.memoryGB + "GB"
        $cpuVal  = [string]$cfg.wsl.cpus
        $swapVal = [string]$cfg.wsl.swapGB + "GB"
        Send-SSE $out 'step' ("Configuring .wslconfig (" + $memVal + " RAM, " + $cpuVal + " vCPUs)...") 35
        $wslCfg = "[wsl2]`nmemory=" + $memVal + "`nprocessors=" + $cpuVal + "`nswap=" + $swapVal + "`nlocalhostForwarding=true"
        Set-Content -Path ($env:USERPROFILE + "\.wslconfig") -Value $wslCfg -Encoding UTF8
        Send-SSE $out 'ok' ".wslconfig written" 38

        # 4. Build provision.sh
        Send-SSE $out 'step' "Building provision script..." 40
        $provScript = Build-ProvisionScript $cfg
        $lc = @($provScript -split "`n").Count
        Send-SSE $out 'ok' ("Script built: " + $lc + " lines") 42

        # 5. Inject
        Send-SSE $out 'step' "Injecting provision.sh into WSL..." 45
        $b64     = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($provScript))
        $wslPath = "/tmp/provision_" + $userName + ".sh"
        wsl -d $distroName -- bash -c ("echo '" + $b64 + "' | base64 -d > " + $wslPath + " && chmod +x " + $wslPath)
        Send-SSE $out 'ok' ("Injected: " + $wslPath) 48

        $profileSh = Join-Path (Split-Path $MyInvocation.ScriptName) "wsl_profile.sh"
        if (Test-Path $profileSh) {
            $pb64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($profileSh))
            wsl -d $distroName -- bash -c ("echo '" + $pb64 + "' | base64 -d > /tmp/wsl_profile.sh && chmod +x /tmp/wsl_profile.sh")
            Send-SSE $out 'ok' "wsl_profile.sh injected" 49
        }

        # 6. Execute and stream output
        Send-SSE $out 'step' "Running provision (5-15 min)..." 50 'info'
        $psi = [System.Diagnostics.ProcessStartInfo]::new("wsl.exe")
        $psi.Arguments = ("-d " + $distroName + " -- bash -c `"sudo bash " + $wslPath + "`"")
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.Environment["DEBIAN_FRONTEND"] = "noninteractive"
        $proc = [System.Diagnostics.Process]::Start($psi)

        $pctMap = @{
            'Timezone'=52;'Base packages'=55;'User'=58;'Sudo'=60;
            'wsl.conf'=62;'Oh My Zsh'=64;'zsh plugins'=66;'kubectl'=68;
            'OpenShift'=70;'Helm'=71;'k9s'=72;'Terraform'=74;
            'Docker'=76;'SQLPlus'=78;'Python'=80;'Node'=82;
            'fzf'=83;'jq'=84;'htop'=85;'Vector'=86;'Aliases'=90;'Git'=92
        }
        $curPct = 50

        $lastHeartbeat = [DateTime]::Now
        while (-not $proc.StandardOutput.EndOfStream) {
            $line = $proc.StandardOutput.ReadLine()
            # Send heartbeat every 15s to keep connection alive
            if (([DateTime]::Now - $lastHeartbeat).TotalSeconds -gt 15) {
                Send-SSE $out 'info' "... still running ..." $curPct 'info'
                $lastHeartbeat = [DateTime]::Now
            }
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
            Send-SSE $out $lvl $clean $curPct
        }
        $proc.WaitForExit()

        if ($proc.ExitCode -ne 0) {
            $stderr = $proc.StandardError.ReadToEnd() -replace '\x1b\[[0-9;]*m',''
            Send-SSE $out 'error' ("Exit code: " + $proc.ExitCode + " " + $stderr) 98 'error'
            Send-SSEDone $out $false "Provision failed"
            return
        }

        # 7. Restart
        Send-SSE $out 'step' "Restarting WSL to apply wsl.conf..." 97
        wsl --terminate $distroName 2>$null
        Start-Sleep -Seconds 2
        Send-SSE $out 'ok' "WSL restarted" 99
        Send-SSE $out 'ok' "Done!" 100 'ok'
        Send-SSEDone $out $true ("wsl -d " + $distroName + " -u " + $userName)
        Log ("Provision complete: " + $distroName + " / " + $userName)

    } catch {
        Log ("ERROR: " + $_)
        try { Send-SSE $out 'error' ("Unexpected error: " + $_) 0 'error' } catch {}
        try { Send-SSEDone $out $false "$_" } catch {}
    }
}

# HTTP Server
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:" + $Port + "/")
$listener.Prefixes.Add("http://127.0.0.1:" + $Port + "/")
try { $listener.Start() }
catch {
    Write-Host ("Port " + $Port + " in use or no permission.") -ForegroundColor Red
    exit 1
}

if (-not $Silent) {
    Write-Host ""
    Write-Host ("  WSL Manager Agent v" + $AgentVersion) -ForegroundColor Cyan
    Write-Host ("  Running on http://localhost:" + $Port) -ForegroundColor Green
    Write-Host "  Open wsl_manager.html in your browser." -ForegroundColor Gray
    Write-Host "  Ctrl+C to stop." -ForegroundColor Gray
    Write-Host ""
}
Log ("Agent started on port " + $Port)

while ($listener.IsListening) {
    try {
        $ctx    = $listener.GetContext()
        $method = $ctx.Request.HttpMethod
        $path   = $ctx.Request.Url.AbsolutePath
        Log ($method + " " + $path)

        if ($method -eq 'OPTIONS') { Send-CorsResponse $ctx 204; continue }

        switch ($path) {
            '/status'  { Send-CorsResponse $ctx 200 (Get-AgentStatus) }
            '/distros' { Send-CorsResponse $ctx 200 ((Get-InstalledDistros) | ConvertTo-Json -Compress) }
            '/ping'    { Send-CorsResponse $ctx 200 '{"ok":true}' }
            '/remove' {
                if ($method -ne 'POST') { Send-CorsResponse $ctx 405 '{"error":"POST only"}'; continue }
                $body = [System.IO.StreamReader]::new($ctx.Request.InputStream).ReadToEnd()
                $req2 = $body | ConvertFrom-Json
                $distro = $req2.distro
                if (-not $distro) { Send-CorsResponse $ctx 400 '{"error":"distro required"}'; continue }
                try {
                    $installed = Get-InstalledDistros
                    if ($installed -notcontains $distro) {
                        Send-CorsResponse $ctx 200 ('{"ok":false,"msg":"Distro not found: ' + $distro + '"}')
                        continue
                    }
                    wsl --terminate $distro 2>$null
                    Start-Sleep -Seconds 1
                    $result = wsl --unregister $distro 2>&1
                    Log ("Removed distro: " + $distro)
                    Send-CorsResponse $ctx 200 ('{"ok":true,"msg":"' + $distro + ' removed successfully"}')
                } catch {
                    Send-CorsResponse $ctx 500 ('{"ok":false,"msg":"' + (($_ -replace '[\r\n\t]',' ') -replace '"','') + '"}')
                }
            }
            '/run' {
                if ($method -ne 'POST') { Send-CorsResponse $ctx 405 '{"error":"POST only"}'; continue }
                $body = [System.IO.StreamReader]::new($ctx.Request.InputStream).ReadToEnd()
                $cfg  = $body | ConvertFrom-Json
                Start-Provision $ctx $cfg
            }
            '/export' {
                if ($method -ne 'POST') { Send-CorsResponse $ctx 405 '{"error":"POST only"}'; continue }
                $body = [System.IO.StreamReader]::new($ctx.Request.InputStream).ReadToEnd()
                $req3 = $body | ConvertFrom-Json
                $distro = $req3.distro
                $user = $req3.user
                if (-not $distro -or -not $user) { Send-CorsResponse $ctx 400 '{"error":"distro and user required"}'; continue }
                try {
                    # Create export script inside WSL
                    $exportScript = @'
#!/bin/sh
set -e
U="$1"
TS=$(date +%Y%m%d_%H%M%S)
PC=$(hostname)
OUT="/tmp/profile_${U}_${PC}_${TS}.tar.gz"
HOME_DIR=$(getent passwd "$U" | cut -d: -f6)
if [ -z "$HOME_DIR" ] || [ ! -d "$HOME_DIR" ]; then
  echo "ERROR: user $U not found" >&2; exit 1
fi
FILES=""
for f in .zshrc .bashrc .gitconfig .profile .aliases .exports .functions; do
  [ -f "$HOME_DIR/$f" ] && FILES="$FILES $f"
done
DIRS=""
for d in .oh-my-zsh/custom .config/starship .ssh; do
  [ -d "$HOME_DIR/$d" ] && DIRS="$DIRS $d"
done
cd "$HOME_DIR"
tar czf "$OUT" --exclude='.ssh/id_*' --exclude='.ssh/*.pem' $FILES $DIRS 2>/dev/null || true
echo "$OUT"
'@
                    $tmpScript = "/tmp/wslm_export_$user.sh"
                    $exportScript | wsl -d $distro -u root -- sh -c "cat > $tmpScript && chmod +x $tmpScript"
                    $outPath = wsl -d $distro -u root -- sh $tmpScript $user 2>&1 | Select-Object -Last 1
                    $outPath = $outPath.Trim()
                    if (-not $outPath -or $outPath -like "ERROR*") {
                        Send-CorsResponse $ctx 500 ('{"ok":false,"msg":"' + $outPath + '"}')
                        continue
                    }
                    # Read the tar.gz from WSL via base64 (PS5 compatible)
                    $tmpWin = [System.IO.Path]::GetTempFileName() + ".tar.gz"
                    $b64 = wsl -d $distro -u root -- sh -c "base64 -w 0 '$outPath'"
                    $b64str = ($b64 | Out-String).Trim()
                    $fileBytes = [System.Convert]::FromBase64String($b64str)
                    [System.IO.File]::WriteAllBytes($tmpWin, $fileBytes)
                    $fname = [System.IO.Path]::GetFileName($outPath)
                    $ctx.Response.StatusCode = 200
                    $ctx.Response.ContentType = 'application/gzip'
                    $ctx.Response.Headers.Add('Content-Disposition', "attachment; filename=`"$fname`"")
                    $ctx.Response.Headers.Add('Access-Control-Allow-Origin', '*')
                    $ctx.Response.Headers.Add('Access-Control-Expose-Headers', 'Content-Disposition')
                    $ctx.Response.ContentLength64 = $fileBytes.Length
                    $ctx.Response.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                    $ctx.Response.OutputStream.Close()
                    Remove-Item $tmpWin -ErrorAction SilentlyContinue
                    wsl -d $distro -u root -- sh -c "rm -f '$outPath' '$tmpScript'"
                } catch {
                    Send-CorsResponse $ctx 500 ('{"ok":false,"msg":"' + (($_ -replace '[\r\n\t]',' ') -replace '"','') + '"}')
                }
            }
                        '/import' {
                if ($method -ne 'POST') { Send-CorsResponse $ctx 405 '{"error":"POST only"}'; continue }
                try {
                    $ms1 = New-Object System.IO.MemoryStream
                    $ctx.Request.InputStream.CopyTo($ms1)
                    $body = [System.Text.Encoding]::UTF8.GetString($ms1.ToArray())
                    $ms1.Dispose()
                    $req = $body | ConvertFrom-Json
                    $distro = $req.distro
                    $user = $req.user
                    $b64 = $req.file
                    if (-not $distro -or -not $user -or -not $b64) {
                        Send-CorsResponse $ctx 400 '{"ok":false,"msg":"distro, user e file obrigatorios"}'
                        continue
                    }
                    $fileBytes = [System.Convert]::FromBase64String($b64)
                    $tmpTar = [System.IO.Path]::Combine($env:TEMP, "wslm_imp_$user.tar.gz")
                    [System.IO.File]::WriteAllBytes($tmpTar, $fileBytes)
                    $drive1 = $tmpTar.Substring(0,1).ToLower()
                    $rest1 = $tmpTar.Substring(2) -replace '\\','/'
                    $wslTar = "/mnt/$drive1$rest1" 
                    $script = "id '$user' 2>/dev/null || useradd -m -s /bin/bash '$user'; HD=`$(getent passwd '$user' | cut -d: -f6); mkdir -p `$HD; cd `$HD && tar xzf '$wslTar' --no-same-owner 2>/dev/null; chown -R '$user':'$user' `$HD 2>/dev/null; rm -f '$wslTar'; echo OK_DONE"
                    $out = wsl -d $distro -u root -- sh -c $script 2>&1
                    $outClean = (($out | Out-String) -replace '[^ -~]','').Trim()
                    Remove-Item $tmpTar -ErrorAction SilentlyContinue
                    if ($outClean -match 'OK_DONE') {
                        Send-CorsResponse $ctx 200 '{"ok":true,"msg":"Perfil importado com sucesso"}'
                    } else {
                        Send-CorsResponse $ctx 500 ('{"ok":false,"msg":"' + ($outClean -replace '"','') + '"}')
                    }
                } catch {
                    $em = (($_ | Out-String) -replace '[^ -~]','').Trim() -replace '"',''
                    Send-CorsResponse $ctx 500 ('{"ok":false,"msg":"' + $em + '"}')
                }
            }
            '/import-all' {
                if ($method -ne 'POST') { Send-CorsResponse $ctx 405 '{"error":"POST only"}'; continue }
                try {
                    $ms2b = New-Object System.IO.MemoryStream
                    $ctx.Request.InputStream.CopyTo($ms2b)
                    $body2 = [System.Text.Encoding]::UTF8.GetString($ms2b.ToArray())
                    $ms2b.Dispose()
                    $req2 = $body2 | ConvertFrom-Json
                    $distro2 = $req2.distro
                    $b642 = $req2.file
                    if (-not $distro2 -or -not $b642) {
                        Send-CorsResponse $ctx 400 '{"ok":false,"msg":"distro e file obrigatorios"}'
                        continue
                    }
                    $fileBytes2 = [System.Convert]::FromBase64String($b642)
                    $tmpTar2 = [System.IO.Path]::Combine($env:TEMP, "wslm_impall.tar.gz")
                    [System.IO.File]::WriteAllBytes($tmpTar2, $fileBytes2)
                    # Convert C:\path\file.tar.gz to /mnt/c/path/file.tar.gz
                    $drive2 = $tmpTar2.Substring(0,1).ToLower()
                    $rest2 = $tmpTar2.Substring(2) -replace '\\','/'
                    $wslTar2 = "/mnt/$drive2$rest2" 
                    $scriptAll = @'
#!/bin/sh
TAR="$1"
TMPD="/tmp/wslm_ia_$$"
mkdir -p "$TMPD"
tar xzf "$TAR" -C "$TMPD" 2>&1 || echo "TAR_FAILED"
RESULTS="DONE"
FOUND=0
for UD in "$TMPD"/*/; do
  [ -d "$UD" ] || continue
  U=$(basename "$UD")
  [ "$U" = "MANIFEST.txt" ] && continue
  echo "$U" | grep -qE '^[a-z][a-z0-9_-]+$' || continue
  FOUND=$((FOUND+1))
  HD=$(getent passwd "$U" 2>/dev/null | cut -d: -f6)
  if [ -z "$HD" ]; then
    useradd -m -s /bin/bash "$U" 2>/dev/null
    echo "$U ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$U" 2>/dev/null
    HD=$(getent passwd "$U" 2>/dev/null | cut -d: -f6)
    if [ -z "$HD" ]; then
      RESULTS="$RESULTS ERR_CREATE:$U"
      continue
    fi
    RESULTS="$RESULTS CREATED:$U"
  fi
  cp -a "$UD/." "$HD/" 2>/dev/null || cp -r "$UD/." "$HD/" 2>/dev/null || true
  chown -R "$U":"$U" "$HD" 2>/dev/null || true
  RESULTS="$RESULTS OK:$U"
done
[ $FOUND -eq 0 ] && RESULTS="$RESULTS NO_USERS_FOUND"
rm -rf "$TMPD" "$TAR"
echo "$RESULTS"
'@
                    $sc2 = "/tmp/wslm_ia.sh"
                    $scriptAll | wsl -d $distro2 -u root -- sh -c "cat > $sc2 && chmod +x $sc2"
                    $out2 = wsl -d $distro2 -u root -- sh $sc2 $wslTar2 2>&1
                    $out2Clean = (($out2 | Out-String) -replace '[^ -~]','').Trim()
                    wsl -d $distro2 -u root -- sh -c "rm -f $sc2" 2>$null
                    Remove-Item $tmpTar2 -ErrorAction SilentlyContinue
                    if ($out2Clean -match 'DONE') {
                        Send-CorsResponse $ctx 200 ('{"ok":true,"msg":"' + ($out2Clean -replace '"','') + '"}')
                    } else {
                        Send-CorsResponse $ctx 500 ('{"ok":false,"msg":"' + ($out2Clean -replace '"','') + '"}')
                    }
                } catch {
                    $em2 = (($_ | Out-String) -replace '[^ -~]','').Trim() -replace '"',''
                    Send-CorsResponse $ctx 500 ('{"ok":false,"msg":"' + $em2 + '"}')
                }
            }
                        '/app'  {
                $htmlPath = 'C:\wsl-manager\wsl_manager.html'
                if (-not (Test-Path $htmlPath)) { Send-CorsResponse $ctx 404 ('{"error":"not found: ' + $htmlPath + '"}'); continue }
                $html = [System.IO.File]::ReadAllBytes($htmlPath)
                $ctx.Response.StatusCode = 200
                $ctx.Response.ContentType = 'text/html; charset=utf-8'
                $ctx.Response.Headers.Add('Access-Control-Allow-Origin', '*')
                $ctx.Response.Headers.Add('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
                $ctx.Response.Headers.Add('Pragma', 'no-cache')
                $ctx.Response.Headers.Add('Expires', '0')
                $ctx.Response.ContentLength64 = $html.Length
                $ctx.Response.OutputStream.Write($html, 0, $html.Length)
                $ctx.Response.OutputStream.Close()
            }
            '/' {
                $ctx.Response.StatusCode = 302
                $ctx.Response.Headers.Add('Location', '/app')
                $ctx.Response.Headers.Add('Access-Control-Allow-Origin', '*')
                $ctx.Response.ContentLength64 = 0
                $ctx.Response.OutputStream.Close()
            }
            '/export-all' {
                if ($method -ne 'POST') { Send-CorsResponse $ctx 405 '{"error":"POST only"}'; continue }
                $body = [System.IO.StreamReader]::new($ctx.Request.InputStream).ReadToEnd()
                $req4 = $body | ConvertFrom-Json
                $distro = $req4.distro
                if (-not $distro) { Send-CorsResponse $ctx 400 '{"error":"distro required"}'; continue }
                try {
                    $exportAllScript = @'
#!/bin/sh
set -e
TS=$(date +%Y%m%d_%H%M%S)
PC=$(hostname)
OUT="/tmp/backup_todos_${PC}_${TS}.tar.gz"
TMPDIR="/tmp/wslm_backup_$$"
mkdir -p "$TMPDIR"

# Get all non-system users (uid >= 1000)
USERS=$(getent passwd | awk -F: '$3 >= 1000 {print $1}')
# Fallback: check /home directories
if [ -z "$USERS" ]; then
  USERS=$(ls /home 2>/dev/null)
fi

for U in $USERS; do
  HOME_DIR=$(getent passwd "$U" | cut -d: -f6)
  [ -z "$HOME_DIR" ] || [ ! -d "$HOME_DIR" ] && continue
  mkdir -p "$TMPDIR/$U"
  for f in .zshrc .bashrc .gitconfig .profile .aliases .exports .functions; do
    [ -f "$HOME_DIR/$f" ] && cp "$HOME_DIR/$f" "$TMPDIR/$U/" 2>/dev/null || true
  done
  for d in .oh-my-zsh/custom .config/starship .ssh; do
    [ -d "$HOME_DIR/$d" ] && cp -r "$HOME_DIR/$d" "$TMPDIR/$U/" 2>/dev/null || true
  done
  # Remove private keys
  rm -f "$TMPDIR/$U/.ssh/id_"* "$TMPDIR/$U/.ssh/"*.pem 2>/dev/null || true
  echo "  exported: $U"
done

# Create manifest
echo "WSL Manager Backup" > "$TMPDIR/MANIFEST.txt"
echo "Date: $(date)" >> "$TMPDIR/MANIFEST.txt"
echo "Distro: $PC" >> "$TMPDIR/MANIFEST.txt"
echo "Users: $USERS" >> "$TMPDIR/MANIFEST.txt"

tar czf "$OUT" -C "$TMPDIR" . 2>/dev/null
rm -rf "$TMPDIR"
echo "$OUT"
'@
                    $tmpScript = "/tmp/wslm_exportall.sh"
                    $exportAllScript | wsl -d $distro -u root -- sh -c "cat > $tmpScript && chmod +x $tmpScript"
                    $outPath = wsl -d $distro -u root -- sh $tmpScript 2>&1 | Select-Object -Last 1
                    $outPath = $outPath.Trim()
                    if (-not $outPath -or $outPath -like "ERROR*") {
                        Send-CorsResponse $ctx 500 ('{"ok":false,"msg":"' + $outPath + '"}')
                        continue
                    }
                    # Transfer via base64 (PS5 compatible)
                    $tmpWin = [System.IO.Path]::GetTempFileName() + ".tar.gz"
                    $b64 = wsl -d $distro -u root -- sh -c "base64 -w 0 '$outPath'"
                    $b64str = ($b64 | Out-String).Trim()
                    $fileBytes = [System.Convert]::FromBase64String($b64str)
                    [System.IO.File]::WriteAllBytes($tmpWin, $fileBytes)
                    $fname = [System.IO.Path]::GetFileName($outPath)
                    $ctx.Response.StatusCode = 200
                    $ctx.Response.ContentType = 'application/gzip'
                    $ctx.Response.Headers.Add('Content-Disposition', "attachment; filename=`"$fname`"")
                    $ctx.Response.Headers.Add('Access-Control-Allow-Origin', '*')
                    $ctx.Response.Headers.Add('Access-Control-Expose-Headers', 'Content-Disposition')
                    $ctx.Response.ContentLength64 = $fileBytes.Length
                    $ctx.Response.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                    $ctx.Response.OutputStream.Close()
                    Remove-Item $tmpWin -ErrorAction SilentlyContinue
                    wsl -d $distro -u root -- sh -c "rm -f '$outPath' '$tmpScript'"
                } catch {
                    Send-CorsResponse $ctx 500 ('{"ok":false,"msg":"' + (($_ -replace '[\r\n\t]',' ') -replace '"','') + '"}')
                }
            }
                        '/import-all' {
                if ($method -ne 'POST') { Send-CorsResponse $ctx 405 '{"error":"POST only"}'; continue }
                try {
                    $contentType = $ctx.Request.ContentType
                    if (-not $contentType -or $contentType -notmatch 'boundary=') {
                        Send-CorsResponse $ctx 400 '{"ok":false,"msg":"multipart boundary missing"}'
                        continue
                    }
                    $boundary = ($contentType -split 'boundary=')[1].Split(';')[0].Trim()
                    $stream = $ctx.Request.InputStream
                    $memStream = New-Object System.IO.MemoryStream
                    $stream.CopyTo($memStream)
                    $rawBytes = $memStream.ToArray()
                    $memStream.Dispose()

                    $rawStr = [System.Text.Encoding]::UTF8.GetString($rawBytes)
                    $distro = ''
                    if ($rawStr -match 'name="distro"[
]+([^
-]+)') { $distro = $matches[1].Trim() }

                    # Find file bytes
                    $enc = [System.Text.Encoding]::UTF8
                    $headerEnd = $enc.GetBytes("`r`n`r`n")
                    $fileStart = -1
                    for ($i = 0; $i -lt $rawBytes.Length - 4; $i++) {
                        if ($rawBytes[$i] -eq $headerEnd[0] -and $rawBytes[$i+1] -eq $headerEnd[1] -and
                            $rawBytes[$i+2] -eq $headerEnd[2] -and $rawBytes[$i+3] -eq $headerEnd[3]) {
                            $before = $enc.GetString($rawBytes[([Math]::Max(0,$i-200))..$i])
                            if ($before -match 'filename=') { $fileStart = $i + 4; break }
                        }
                    }

                    if ($fileStart -lt 0 -or -not $distro) {
                        Send-CorsResponse $ctx 400 '{"ok":false,"msg":"distro e ficheiro obrigatorios"}'
                        continue
                    }

                    # Find file end
                    $boundaryBytes = $enc.GetBytes("--$boundary")
                    $fileEnd = $rawBytes.Length
                    for ($i = $rawBytes.Length - $boundaryBytes.Length; $i -gt $fileStart; $i--) {
                        $match = $true
                        for ($j = 0; $j -lt $boundaryBytes.Length; $j++) {
                            if ($rawBytes[$i+$j] -ne $boundaryBytes[$j]) { $match = $false; break }
                        }
                        if ($match) { $fileEnd = $i - 2; break }
                    }

                    $fileBytes = $rawBytes[$fileStart..($fileEnd-1)]
                    $tmpTar = "$env:TEMP\wslm_importall.tar.gz"
                    [System.IO.File]::WriteAllBytes($tmpTar, $fileBytes)
                    $wslTmp = (wsl -d $distro -- wslpath -u ($tmpTar -replace "\\\\","/")).Trim()

                    $importAllScript = @'
#!/bin/sh
set -e
TAR="$1"
TMPDIR="/tmp/wslm_importall_$$"
mkdir -p "$TMPDIR"
tar xzf "$TAR" -C "$TMPDIR" 2>/dev/null || true

RESULTS=""
for USER_DIR in "$TMPDIR"/*/; do
  U=$(basename "$USER_DIR")
  [ "$U" = "MANIFEST.txt" ] && continue
  [ -z "$U" ] || [ "$U" = "." ] && continue

  HOME_DIR=$(getent passwd "$U" 2>/dev/null | cut -d: -f6)
  if [ -z "$HOME_DIR" ]; then
    RESULTS="$RESULTS
SKIPPED: $U (utilizador nao existe)"
    continue
  fi

  cp -r "$USER_DIR"* "$HOME_DIR/" 2>/dev/null || true
  chown -R "$U":"$U" "$HOME_DIR/.zshrc" "$HOME_DIR/.bashrc" "$HOME_DIR/.gitconfig" "$HOME_DIR/.oh-my-zsh" "$HOME_DIR/.ssh" 2>/dev/null || true
  RESULTS="$RESULTS
OK: $U"
done

rm -rf "$TMPDIR" "$TAR"
echo "DONE$RESULTS"
'@
                    $tmpScript = "/tmp/wslm_importall.sh"
                    $importAllScript | wsl -d $distro -u root -- sh -c "cat > $tmpScript && chmod +x $tmpScript"
                    $result = wsl -d $distro -u root -- sh $tmpScript $wslTmp 2>&1
                    Remove-Item $tmpTar -ErrorAction SilentlyContinue
                    wsl -d $distro -u root -- sh -c "rm -f $tmpScript" 2>$null

                    $resultLines = @($result)
                    $isOk = ($resultLines | Where-Object { $_ -match 'DONE' }).Count -gt 0
                    $okLines = $resultLines | Where-Object { $_ -match 'OK:|SKIPPED:|DONE' } | ForEach-Object { $_ -replace '[^ -~]','' }
                    $summary = ($okLines -join ' | ').Trim()
                    if (-not $summary) { $summary = if ($isOk) { 'Importado com sucesso' } else { 'Sem utilizadores encontrados' } }
                    if ($isOk) {
                        Send-CorsResponse $ctx 200 ('{"ok":true,"msg":"' + ($summary -replace '"','') + '"}')
                    } else {
                        Send-CorsResponse $ctx 500 ('{"ok":false,"msg":"' + ($summary -replace '"','') + '"}')
                    }
                } catch {
                    Send-CorsResponse $ctx 500 ('{"ok":false,"msg":"' + (($_ -replace '[\r\n\t]',' ') -replace '"','') + '"}')
                }
            }
                        default { Send-CorsResponse $ctx 404 '{"error":"not found"}' }
        }
    } catch [System.Net.HttpListenerException] {
        if ($_.Exception.ErrorCode -ne 995) { Log ("HttpListener: " + $_) }
        break
    } catch {
        Log ("Error: " + $_)
        try { Send-CorsResponse $ctx 500 ('{"error":"' + (($_ -replace '[\r\n\t]',' ') -replace '"','') + '"}') } catch {}
    }
}
$listener.Stop()
Log "Agent stopped"



