<div align="center">

<img src="https://img.shields.io/badge/version-2.0.0-blue?style=for-the-badge" />
<img src="https://img.shields.io/badge/platform-Windows-0078D4?style=for-the-badge&logo=windows" />
<img src="https://img.shields.io/badge/WSL-2-orange?style=for-the-badge&logo=linux" />
<img src="https://img.shields.io/badge/PowerShell-5.1+-5391FE?style=for-the-badge&logo=powershell" />

# 🖥️ WSL Manager

**Provisionamento, gestão e sincronização de perfis WSL entre múltiplos PCs Windows**

[Funcionalidades](#-funcionalidades) • [Instalação](#-instalação) • [Como usar](#-como-usar) • [Ferramentas](#-ferramentas-suportadas) • [Autor](#-autor)

</div>

---

## ✨ Funcionalidades

| Módulo | Descrição |
|--------|-----------|
| 🚀 **Provisionamento** | Instala e configura distros WSL com utilizadores, shell e ferramentas DevOps |
| 📤 **Exportar perfil** | Exporta dotfiles de um ou todos os utilizadores da distro |
| 📥 **Importar perfil** | Restaura dotfiles noutro PC, criando utilizadores automaticamente |
| 🖥️ **Gestão de PCs** | Regista e monitoriza múltiplos PCs e distros WSL |
| 🔄 **Sync automático** | Sincroniza perfis entre máquinas com um clique |

---

## 📦 Instalação

### Requisitos
- Windows 10/11 com WSL2 activado
- PowerShell 5.1+
- Browser moderno (Chrome, Edge, Firefox)

### Setup

```powershell
# 1. Clona o repositório
git clone https://github.com/drmsantos/wsl-manager.git C:\wsl-manager

# 2. Inicia o agente
cd C:\wsl-manager
.\Iniciar-WSLManager.bat

# 3. Abre no browser
# http://localhost:7745/app
```

### Iniciar automaticamente com o Windows

```powershell
$startup = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut("$startup\WSLManager.lnk")
$shortcut.TargetPath = "C:\wsl-manager\Iniciar-WSLManager.bat"
$shortcut.WorkingDirectory = "C:\wsl-manager"
$shortcut.WindowStyle = 7
$shortcut.Save()
Write-Host "Atalho criado!" -ForegroundColor Green
```

---

## 🚀 Como usar

### 1️⃣ Provisionar uma nova distro WSL

1. Abre `http://localhost:7745/app`
2. Vai a **Distro WSL** → escolhe Ubuntu, Debian, Fedora, etc.
3. Configura RAM, CPUs e hostname
4. Cria o utilizador e selecciona as ferramentas
5. Clica **Instalar Agora** — o progresso aparece em tempo real

### 2️⃣ Exportar perfil

```
Exportar → Selecciona distro → Clica "Exportar utilizador" ou "Exportar TODOS"
→ Download automático do .tar.gz
```

### 3️⃣ Importar perfil noutro PC

```
Importar → Selecciona distro destino → Arrasta o .tar.gz
→ "Importar TODOS" cria utilizadores automaticamente e restaura os dotfiles
```

---

## 🛠️ Ferramentas suportadas

<details>
<summary><b>☸️ Kubernetes & OpenShift</b></summary>

`kubectl` `oc` `helm` `k9s` `kubectx` `kubens` `stern` `argocd` `tekton` `kustomize`

</details>

<details>
<summary><b>☁️ Cloud & IaC</b></summary>

`terraform` `ansible` `aws-cli` `azure-cli` `gcloud` `oci-cli` `pulumi`

</details>

<details>
<summary><b>🗄️ Bases de dados</b></summary>

`sqlplus` `mysql-client` `psql` `mongosh` `redis-cli`

</details>

<details>
<summary><b>🐳 Containers & CI/CD</b></summary>

`docker` `podman` `skopeo` `buildah`

</details>

<details>
<summary><b>💻 Dev & Linguagens</b></summary>

`python3` `node.js` `go` `java` `rust` `vs-code`

</details>

<details>
<summary><b>🐚 Shell & Produtividade</b></summary>

`oh-my-zsh` `fzf` `jq` `yq` `tmux` `bat` `eza` `htop` `ripgrep` `zoxide` `starship`

</details>

---

## 📁 Estrutura

```
C:\wsl-manager\
├── 📄 wsl-agent.ps1           # Agente HTTP local (porta 7745)
├── 🌐 wsl_manager.html        # Interface web completa
├── ▶️  Iniciar-WSLManager.bat  # Script de arranque
└── 📋 Install-WSL.ps1         # Instalador alternativo
```

---

## 🔧 API do Agente

O agente expõe uma API REST em `http://localhost:7745`:

| Endpoint | Método | Descrição |
|----------|--------|-----------|
| `/ping` | GET | Verifica se o agente está online |
| `/status` | GET | Estado do agente e distros instaladas |
| `/distros` | GET | Lista distros WSL instaladas |
| `/run` | POST | Inicia provisionamento (SSE streaming) |
| `/export` | POST | Exporta perfil de um utilizador |
| `/export-all` | POST | Exporta todos os perfis |
| `/import` | POST | Importa perfil para um utilizador |
| `/import-all` | POST | Importa todos os perfis do backup |
| `/remove` | POST | Remove uma distro WSL |
| `/app` | GET | Serve a interface web |

---

## 👤 Autor

<div align="center">

**Diego Regis M. F. dos Santos**
Analista de Sistemas Pleno — DevOps & Infrastructure

[![LinkedIn](https://img.shields.io/badge/LinkedIn-0077B5?style=for-the-badge&logo=linkedin&logoColor=white)](https://linkedin.com/in/diego-regis-361a0a20)
[![GitHub](https://img.shields.io/badge/GitHub-100000?style=for-the-badge&logo=github&logoColor=white)](https://github.com/drmsantos)

</div>

---

<div align="center">
<sub>Feito com ☕ e muito PowerShell</sub>
</div>
