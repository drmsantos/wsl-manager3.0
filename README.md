# WSL Manager v3

![version](https://img.shields.io/badge/version-3.0.0-blue?style=for-the-badge)
![platform](https://img.shields.io/badge/platform-Kubernetes-326CE5?style=for-the-badge&logo=kubernetes)
![backend](https://img.shields.io/badge/backend-FastAPI-009688?style=for-the-badge&logo=fastapi)
![agent](https://img.shields.io/badge/agent-PowerShell-5391FE?style=for-the-badge&logo=powershell)

**Gestão centralizada de ambientes WSL via Kubernetes — sem nada rodando na porta local.**

---

## Arquitectura

```
Rancher RKE2 (rkeopl)
└── namespace: wsl-manager
    ├── wsl-manager-backend   (FastAPI + SQLite)
    ├── wsl-manager-frontend  (nginx + HTML)
    └── Ingress: wsl-manager.drmsantos.local

Windows PCs (cada máquina)
└── wsl-agent.ps1  →  polling a cada 3s para buscar comandos
                   →  heartbeat a cada 5s com métricas + distros
```

---

## Deploy no Rancher

### 1. Editar o Secret

```yaml
# k8s/manifests.yaml — alterar antes de aplicar
stringData:
  JWT_SECRET:     "chave-aleatória-forte-32-chars-min"
  ADMIN_PASSWORD: "SuaSenhaSegura2026!"
```

### 2. Aplicar manifests

```bash
kubectl apply -f k8s/manifests.yaml
```

### 3. Verificar

```bash
kubectl get pods -n wsl-manager
kubectl logs -n wsl-manager deploy/wsl-manager-backend
```

### 4. Aceder

```
http://wsl-manager.drmsantos.local
```

---

## Configurar o Agente Windows

### 1. Registrar o PC no dashboard

1. Acede a `http://wsl-manager.drmsantos.local`
2. Faz login com `ADMIN_PASSWORD`
3. Vai a **Tokens / PCs** → **Registrar PC**
4. Copia o **token JWT** gerado

### 2. Configurar o agente

Edita `agent/wsl-agent.ps1` e define as variáveis no topo:

```powershell
$BackendURL = "http://wsl-manager.drmsantos.local/api"
$AgentToken = "eyJ..."   # token JWT do dashboard
```

### 3. Instalar como tarefa agendada

```powershell
# Executa uma vez para instalar
.\wsl-agent.ps1 -Install
```

O agente inicia automaticamente no próximo login do Windows.

---

## Teste local (Docker Compose)

```bash
docker compose up --build
# Acesse: http://localhost:8080
```

---

## Estrutura do projecto

```
wsl-manager-v3/
├── backend/
│   ├── main.py           # FastAPI app
│   ├── auth.py           # JWT
│   ├── database.py       # SQLite async
│   ├── models.py         # Pydantic models
│   └── requirements.txt
├── frontend/
│   ├── wsl_manager.html  # UI completa
│   └── nginx.conf        # Proxy /api → backend
├── agent/
│   └── wsl-agent.ps1     # Agente Windows (cliente polling)
├── k8s/
│   └── manifests.yaml    # Namespace, PVC, Deployments, Ingress
├── .github/workflows/
│   └── build.yml         # CI/CD GHCR
├── Dockerfile.backend
├── Dockerfile.frontend
└── docker-compose.yml
```

---

## API

| Endpoint | Método | Descrição |
|---|---|---|
| `POST /api/admin/login` | POST | Login admin |
| `GET /api/pcs` | GET | Lista PCs |
| `POST /api/pcs` | POST | Registrar PC + gerar token |
| `DELETE /api/pcs/{id}` | DELETE | Remover PC |
| `POST /api/agent/heartbeat` | POST | Agente envia métricas |
| `GET /api/agent/commands` | GET | Agente busca comandos |
| `POST /api/agent/result` | POST | Agente posta progresso |
| `POST /api/pcs/{id}/provision` | POST | Enfileirar provisionamento |
| `GET /api/pcs/{id}/stream` | GET | SSE — log em tempo real |
| `GET /api/pcs/{id}/history` | GET | Histórico de comandos |

---

## Autor

**Diego Regis M. F. dos Santos**  
DevOps & Infrastructure — OpenLabs
