#!/usr/bin/env bash
# Auto-gerado por WSL Manager — 21/03/2026, 10:36:20
# Usuário: operador | Distro: Debian 12
set -euo pipefail
RED='\033[0;31m';GREEN='\033[0;32m';YELLOW='\033[1;33m';CYAN='\033[0;36m';BOLD='\033[1m';NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step() { echo -e "\n${BOLD}▸ $*${NC}"; }
[[ $EUID -ne 0 ]] && { echo -e "${RED}root necessário${NC}"; exit 1; }
USERNAME="operador"

step "Timezone: America/Sao_Paulo"
timedatectl set-timezone "America/Sao_Paulo" 2>/dev/null || ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
ok "Timezone"

step "Pacotes base"
apt-get update -qq
apt-get install -y -qq curl wget git unzip zip tar ca-certificates gnupg lsb-release apt-transport-https software-properties-common build-essential sudo vim nano openssl
ok "Pacotes base"

apt-get install -y -qq zsh
step "Criando usuário: $USERNAME"
if id "$USERNAME" &>/dev/null; then warn "Já existe"; else
  useradd -m -s "/usr/bin/zsh" "$USERNAME"
  echo "$USERNAME:$(openssl rand -base64 16)" | chpasswd
  ok "Usuário criado"
fi

usermod -aG sudo "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME
chmod 440 /etc/sudoers.d/$USERNAME
ok "Sudo NOPASSWD"

step "wsl.conf"
cat > /etc/wsl.conf << 'WSLEOF'
[boot]
systemd=true
[automount]
enabled=true
root=/mnt/
options=metadata,umask=22,fmask=11
[network]
hostname=wsl-devbox
generateHosts=true
generateResolvConf=true
[interop]
enabled=true
appendWindowsPath=false
WSLEOF
ok "wsl.conf"

step "Oh My Zsh"
su - "$USERNAME" -c 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
su - "$USERNAME" -c 'git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/themes/powerlevel10k'
su - "$USERNAME" -c 'sed -i "s/ZSH_THEME=\"robbyrussell\"/ZSH_THEME=\"powerlevel10k\/powerlevel10k\"/" ~/.zshrc'
ok "Oh My Zsh"

step "Plugins zsh"
su - "$USERNAME" -c 'git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions 2>/dev/null||true'
su - "$USERNAME" -c 'git clone https://github.com/zsh-users/zsh-syntax-highlighting ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting 2>/dev/null||true'
su - "$USERNAME" -c 'sed -i "s/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting kubectl docker)/" ~/.zshrc'
ok "Plugins zsh"

step "kubectl"
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq && apt-get install -y -qq kubectl
ok "kubectl"

step "OpenShift CLI"
OC_VER=$(curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/release.txt | grep 'Version:' | awk '{print $2}')
curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OC_VER/openshift-client-linux.tar.gz" | tar -xz -C /usr/local/bin oc
ok "OpenShift CLI"

step "Helm v3"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
ok "Helm v3"

step "k9s"
K9S=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep tag_name | cut -d'"' -f4)
curl -fsSL "https://github.com/derailed/k9s/releases/download/$K9S/k9s_Linux_amd64.tar.gz" | tar -xz -C /usr/local/bin k9s
ok "k9s"

step "Ansible"
apt-get install -y -qq ansible
ok "Ansible"

step "AWS CLI v2"
curl -fsSL 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip
ok "AWS CLI v2"

step "Docker CLI"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq && apt-get install -y -qq docker-ce-cli docker-compose-plugin
usermod -aG docker "$USERNAME"
ok "Docker CLI"

step "Python 3.11"
apt-get install -y -qq python3.11 python3.11-venv python3-pip python3-dev
update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
ok "Python 3.11"

step "fzf"
su - "$USERNAME" -c 'git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf && ~/.fzf/install --all'
ok "fzf"

step "jq+yq"
apt-get install -y -qq jq
YQ=$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep tag_name | cut -d'"' -f4)
curl -fsSL "https://github.com/mikefarah/yq/releases/download/$YQ/yq_linux_amd64" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
ok "jq+yq"

step "htop+btop"
apt-get install -y -qq htop btop
ok "htop+btop"

step "httpie"
apt-get install -y -qq httpie
ok "httpie"

step "SQLPlus 21c"
apt-get install -y -qq libaio1
IC='https://download.oracle.com/otn_software/linux/instantclient/2112000'
curl -fsSL "$IC/instantclient-basic-linux.x64-21.12.0.0.0dbru.zip" -o /tmp/ic-basic.zip
curl -fsSL "$IC/instantclient-sqlplus-linux.x64-21.12.0.0.0dbru.zip" -o /tmp/ic-sql.zip
mkdir -p /usr/lib/oracle/21/client64/{bin,lib}
unzip -q /tmp/ic-basic.zip -d /tmp/ic && mv /tmp/ic/instantclient_21_12/*.so* /usr/lib/oracle/21/client64/lib/
unzip -q /tmp/ic-sql.zip   -d /tmp/ic && mv /tmp/ic/instantclient_21_12/sqlplus /usr/lib/oracle/21/client64/bin/
rm -rf /tmp/ic /tmp/ic-*.zip
echo /usr/lib/oracle/21/client64/lib > /etc/ld.so.conf.d/oracle21.conf && ldconfig
ln -sf /usr/lib/oracle/21/client64/bin/sqlplus /usr/local/bin/sqlplus
printf 'export ORACLE_HOME=/usr/lib/oracle/21/client64\nexport LD_LIBRARY_PATH=$ORACLE_HOME/lib:$LD_LIBRARY_PATH\nexport PATH=$ORACLE_HOME/bin:$PATH\nexport NLS_LANG=AMERICAN_AMERICA.AL32UTF8\n' >> /home/$USERNAME/.zshrc
ok "SQLPlus 21c"

step "VS Code"
printf "alias code='/mnt/c/Users/\$(cmd.exe /c \"echo %USERNAME%\" 2>/dev/null | tr -d \"\\r\")/AppData/Local/Programs/Microsoft\\ VS\\ Code/bin/code'\n" >> /home/$USERNAME/.zshrc
ok "VS Code"

step "Git config"
su - "$USERNAME" -c 'git config --global user.name "drmsantos"'
su - "$USERNAME" -c 'git config --global user.email "diegoregis423@gmail.com"'
su - "$USERNAME" -c 'git config --global init.defaultBranch main && git config --global pull.rebase false && git config --global core.autocrlf false'
ok "Git"

step "Aliases"
cat >> /home/$USERNAME/.zshrc << 'ALIASES'
# ── WSL Manager aliases ─────────────────────────────
alias k='kubectl'
alias kgp='kubectl get pods -A'
alias kgs='kubectl get svc -A'
alias kgn='kubectl get nodes'
alias kaf='kubectl apply -f'
alias kl='kubectl logs -f'
alias kex='kubectl exec -it'
alias kns='kubectl config set-context --current --namespace'
alias oc-login='oc login https://api.openshift.openlabs.local:6443'
alias h='helm'
alias hls='helm list -A'
alias d='docker'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias sqldev='sqlplus /nolog'
alias ll='ls -lahF'
alias ..='cd ..'
alias ...='cd ../..'
alias ports='ss -tulnp'
alias myip='curl -s ifconfig.me'
alias wsl-restart='wsl.exe --shutdown'
# ────────────────────────────────────────────────────
ALIASES
chown "$USERNAME": /home/"$USERNAME"/.zshrc 2>/dev/null||true
ok "Aliases"

if [[ -f /tmp/wsl_profile.sh ]]; then
  cp /tmp/wsl_profile.sh /usr/local/bin/wsl_profile.sh && chmod +x /usr/local/bin/wsl_profile.sh
  ok "wsl_profile.sh instalado"
fi

echo -e "\n\033[0;32m✓ Provisionamento concluído!\033[0m"
echo -e "  Acesse: wsl -u $USERNAME"
echo -e "  \033[1;33mReinicie o WSL: wsl --shutdown\033[0m"