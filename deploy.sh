#!/usr/bin/env bash
# =============================================================================
# WSL Manager v3 — Deploy Script
# Autor: Diego Regis M. F. dos Santos
# Email: diego-f-santos@openlabs.com.br
# Time:  OpenLabs - DevOps | Infra
# Versão: 3.0.0
#
# Localização Windows: C:\APP\wsl-manager3.0
#
# Uso a partir do WSL:
#   cd /mnt/c/APP/wsl-manager3.0
#   chmod +x deploy.sh
#   ./deploy.sh
#
# Ou duplo-clique em Deploy-WSLManager.bat no Windows Explorer
#
# O script:
#   1. Detecta a StorageClass disponível no cluster
#   2. Faz login no ghcr.io
#   3. Build + push das imagens (backend e frontend)
#   4. Aplica os manifests K8s
#   5. Aguarda os pods ficarem prontos
# =============================================================================
set -euo pipefail

# ── Cores ─────────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok()   { echo -e "${G}[OK]${N}   $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
err()  { echo -e "${R}[ERR]${N}  $*"; exit 1; }
step() { echo -e "\n${B}${C}▸ $*${N}"; }

# ── Config ────────────────────────────────────────────────────────────────────
REGISTRY="ghcr.io/drmsantos"
BACKEND_IMAGE="${REGISTRY}/wsl-manager-backend"
FRONTEND_IMAGE="${REGISTRY}/wsl-manager-frontend"
VERSION="3.0.0"
NAMESPACE="wsl-manager"
CONTEXT="rancher.drmsantos.local"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${SCRIPT_DIR}/k8s/manifests.yaml"

echo -e "\n${B}${C}╔══════════════════════════════════════════╗${N}"
echo -e "${B}${C}║     WSL Manager v3 — Deploy Script       ║${N}"
echo -e "${B}${C}╚══════════════════════════════════════════╝${N}\n"

# ── 0. Pré-requisitos ─────────────────────────────────────────────────────────
step "Verificando pré-requisitos"

command -v docker  &>/dev/null || err "docker não encontrado"
command -v kubectl &>/dev/null || err "kubectl não encontrado"
ok "docker e kubectl disponíveis"

# Verifica contexto kubectl
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "")
if [[ "$CURRENT_CTX" != "$CONTEXT" ]]; then
    warn "Contexto atual: '${CURRENT_CTX}' — trocando para '${CONTEXT}'"
    kubectl config use-context "$CONTEXT" || err "Contexto '${CONTEXT}' não encontrado. Verifica com: kubectl config get-contexts"
fi
ok "Contexto: $(kubectl config current-context)"

# ── 1. Detectar StorageClass ──────────────────────────────────────────────────
step "Detectando StorageClass disponível"

# Tenta obter a StorageClass padrão primeiro
DEFAULT_SC=$(kubectl get storageclass -o json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    annotations = item.get('metadata', {}).get('annotations', {})
    if annotations.get('storageclass.kubernetes.io/is-default-class') == 'true':
        print(item['metadata']['name'])
        break
" 2>/dev/null || echo "")

# Se não encontrou padrão, lista as disponíveis e escolhe
if [[ -z "$DEFAULT_SC" ]]; then
    ALL_SC=$(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    echo "  StorageClasses disponíveis: ${ALL_SC}"

    # Preferência: longhorn > longhorn-1r > local-path > primeira disponível
    for preferred in "longhorn" "longhorn-1r" "local-path"; do
        if echo "$ALL_SC" | grep -qw "$preferred"; then
            DEFAULT_SC="$preferred"
            break
        fi
    done

    # Se ainda não encontrou, pega a primeira
    if [[ -z "$DEFAULT_SC" ]]; then
        DEFAULT_SC=$(echo "$ALL_SC" | awk '{print $1}')
    fi
fi

if [[ -z "$DEFAULT_SC" ]]; then
    err "Nenhuma StorageClass encontrada no cluster"
fi

ok "StorageClass selecionada: ${DEFAULT_SC}"

# ── 2. Login ghcr.io ──────────────────────────────────────────────────────────
step "Login no ghcr.io"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo -e "  ${Y}Precisas de um GitHub Personal Access Token com permissão 'write:packages'${N}"
    echo -e "  Cria em: https://github.com/settings/tokens/new?scopes=write:packages\n"
    read -rsp "  Cole o token (ficará oculto): " GITHUB_TOKEN
    echo ""
fi

echo "$GITHUB_TOKEN" | docker login ghcr.io -u drmsantos --password-stdin \
    || err "Falha no login do ghcr.io"
ok "Login ghcr.io OK"

# ── 3. Build imagens ──────────────────────────────────────────────────────────
step "Build — Backend (FastAPI)"
docker build \
    -f "${SCRIPT_DIR}/Dockerfile.backend" \
    -t "${BACKEND_IMAGE}:${VERSION}" \
    -t "${BACKEND_IMAGE}:latest" \
    "${SCRIPT_DIR}"
ok "Backend built: ${BACKEND_IMAGE}:${VERSION}"

step "Build — Frontend (nginx)"
docker build \
    -f "${SCRIPT_DIR}/Dockerfile.frontend" \
    -t "${FRONTEND_IMAGE}:${VERSION}" \
    -t "${FRONTEND_IMAGE}:latest" \
    "${SCRIPT_DIR}"
ok "Frontend built: ${FRONTEND_IMAGE}:${VERSION}"

# ── 4. Push imagens ───────────────────────────────────────────────────────────
step "Push para ghcr.io"
docker push "${BACKEND_IMAGE}:${VERSION}"
docker push "${BACKEND_IMAGE}:latest"
docker push "${FRONTEND_IMAGE}:${VERSION}"
docker push "${FRONTEND_IMAGE}:latest"
ok "Imagens publicadas em ghcr.io/drmsantos"

# ── 5. Preparar manifests ─────────────────────────────────────────────────────
step "Preparando manifests"

# Cria cópia temporária com StorageClass correta
TMP_MANIFEST="/tmp/wsl-manager-manifests-$$.yaml"
sed "s|storageClassName: longhorn$|storageClassName: ${DEFAULT_SC}|g" \
    "$MANIFESTS" > "$TMP_MANIFEST"
ok "StorageClass '${DEFAULT_SC}' aplicada no manifests"

# ── 6. Verificar/criar credenciais do Secret ──────────────────────────────────
step "Configurando Secret"

# Verifica se já existe o secret com valores customizados
if kubectl get secret wsl-manager-secret -n "$NAMESPACE" &>/dev/null 2>&1; then
    warn "Secret 'wsl-manager-secret' já existe — mantendo valores atuais"
else
    echo -e "\n  ${Y}Configure as credenciais do WSL Manager:${N}"
    read -rp "  JWT_SECRET (Enter para gerar automaticamente): " JWT_SECRET
    if [[ -z "$JWT_SECRET" ]]; then
        JWT_SECRET=$(openssl rand -base64 32 | tr -d '/+=')
        echo "  JWT_SECRET gerado automaticamente"
    fi
    read -rsp "  ADMIN_PASSWORD: " ADMIN_PASSWORD
    echo ""
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        err "ADMIN_PASSWORD não pode ser vazio"
    fi

    # Substitui no manifests temporário
    sed -i "s|TROQUE-POR-UMA-CHAVE-FORTE-E-ALEATORIA-32CHARS|${JWT_SECRET}|g" "$TMP_MANIFEST"
    sed -i "s|SuaSenhaDeAdmin2026!|${ADMIN_PASSWORD}|g" "$TMP_MANIFEST"
    ok "Credenciais configuradas"
fi

# ── 7. Aplicar manifests ──────────────────────────────────────────────────────
step "Aplicando manifests no cluster"
kubectl apply -f "$TMP_MANIFEST"
rm -f "$TMP_MANIFEST"
ok "Manifests aplicados"

# ── 8. Aguardar pods ──────────────────────────────────────────────────────────
step "Aguardando pods ficarem prontos"

echo "  Aguardando backend..."
kubectl rollout status deployment/wsl-manager-backend \
    -n "$NAMESPACE" --timeout=120s \
    || warn "Backend demorou — verifica: kubectl logs -n ${NAMESPACE} deploy/wsl-manager-backend"

echo "  Aguardando frontend..."
kubectl rollout status deployment/wsl-manager-frontend \
    -n "$NAMESPACE" --timeout=60s \
    || warn "Frontend demorou — verifica: kubectl logs -n ${NAMESPACE} deploy/wsl-manager-frontend"

# ── 9. Resumo final ───────────────────────────────────────────────────────────
echo ""
echo -e "${G}╔══════════════════════════════════════════════╗${N}"
echo -e "${G}║           Deploy concluído!                  ║${N}"
echo -e "${G}╚══════════════════════════════════════════════╝${N}"
echo ""
echo -e "  ${B}URL:${N}       http://wsl-manager.drmsantos.local"
echo -e "  ${B}Namespace:${N} ${NAMESPACE}"
echo -e "  ${B}Backend:${N}   ${BACKEND_IMAGE}:${VERSION}"
echo -e "  ${B}Frontend:${N}  ${FRONTEND_IMAGE}:${VERSION}"
echo ""
echo -e "  ${B}Pods:${N}"
kubectl get pods -n "$NAMESPACE"
echo ""
echo -e "  ${Y}Próximo passo:${N} Acede ao dashboard e regista o teu PC"
echo -e "  → Tokens / PCs → Registrar PC → copia o token JWT"
echo -e "  → Configura o token no wsl-agent.ps1 e executa -Install"
echo ""
