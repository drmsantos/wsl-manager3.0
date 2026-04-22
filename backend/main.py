# =============================================================================
# WSL Manager v3 — Backend FastAPI
# Autor: Diego Regis M. F. dos Santos
# Email: diego-f-santos@openlabs.com.br
# Time:  OpenLabs - DevOps | Infra
# Versão: 3.0.0
# =============================================================================

import asyncio
import json
import os
import uuid
from datetime import datetime, timezone
from typing import AsyncGenerator

from fastapi import FastAPI, Depends, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from auth import (
    create_pc_token, verify_token, verify_admin_token,
    get_admin_token_from_env
)
from database import db
from models import (
    PCRegisterRequest, PCHeartbeatRequest,
    CommandRequest, CommandResultRequest,
    ProvisionRequest, AdminLoginRequest
)

app = FastAPI(
    title="WSL Manager v3",
    version="3.0.0",
    docs_url="/api/docs",
    redoc_url=None
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── SSE queues: pc_id → asyncio.Queue ────────────────────────────────────────
_sse_queues: dict[str, asyncio.Queue] = {}

def get_or_create_queue(pc_id: str) -> asyncio.Queue:
    if pc_id not in _sse_queues:
        _sse_queues[pc_id] = asyncio.Queue(maxsize=200)
    return _sse_queues[pc_id]

async def push_sse(pc_id: str, event: dict):
    q = get_or_create_queue(pc_id)
    try:
        q.put_nowait(event)
    except asyncio.QueueFull:
        pass

# ── Startup / Shutdown ────────────────────────────────────────────────────────
@app.on_event("startup")
async def startup():
    await db.init()

@app.on_event("shutdown")
async def shutdown():
    await db.close()

# =============================================================================
# ADMIN AUTH
# =============================================================================

@app.post("/api/admin/login")
async def admin_login(req: AdminLoginRequest):
    """Valida senha de admin e retorna token de sessão."""
    admin_token = get_admin_token_from_env()
    if req.password != admin_token:
        raise HTTPException(status_code=401, detail="Senha incorreta")
    token = create_pc_token(pc_id="__admin__", pc_name="admin", is_admin=True)
    return {"token": token}

@app.get("/api/admin/verify")
async def admin_verify(payload=Depends(verify_admin_token)):
    return {"ok": True}

# =============================================================================
# PC MANAGEMENT (admin)
# =============================================================================

@app.get("/api/pcs")
async def list_pcs(_=Depends(verify_admin_token)):
    """Lista todos os PCs registrados com status online/offline."""
    pcs = await db.list_pcs()
    now = datetime.now(timezone.utc)
    result = []
    for pc in pcs:
        last_seen = pc.get("last_seen")
        online = False
        if last_seen:
            try:
                ls = datetime.fromisoformat(last_seen)
                if ls.tzinfo is None:
                    ls = ls.replace(tzinfo=timezone.utc)
                online = (now - ls).total_seconds() < 30
            except Exception:
                pass
        result.append({**pc, "online": online})
    return result

@app.post("/api/pcs")
async def create_pc(req: PCRegisterRequest, _=Depends(verify_admin_token)):
    """Cria um novo PC e retorna o token JWT para o agente."""
    pc_id = str(uuid.uuid4())
    token = create_pc_token(pc_id=pc_id, pc_name=req.name)
    await db.create_pc(pc_id=pc_id, name=req.name, description=req.description)
    return {"pc_id": pc_id, "name": req.name, "token": token}

@app.delete("/api/pcs/{pc_id}")
async def delete_pc(pc_id: str, _=Depends(verify_admin_token)):
    await db.delete_pc(pc_id)
    return {"ok": True}

@app.get("/api/pcs/{pc_id}")
async def get_pc(pc_id: str, _=Depends(verify_admin_token)):
    pc = await db.get_pc(pc_id)
    if not pc:
        raise HTTPException(404, "PC não encontrado")
    now = datetime.now(timezone.utc)
    last_seen = pc.get("last_seen")
    online = False
    if last_seen:
        try:
            ls = datetime.fromisoformat(last_seen)
            if ls.tzinfo is None:
                ls = ls.replace(tzinfo=timezone.utc)
            online = (now - ls).total_seconds() < 30
        except Exception:
            pass
    return {**pc, "online": online}

# =============================================================================
# AGENT ENDPOINTS (autenticados com token do PC)
# =============================================================================

@app.post("/api/agent/heartbeat")
async def agent_heartbeat(req: PCHeartbeatRequest, payload=Depends(verify_token)):
    """Agente envia métricas a cada 5s."""
    pc_id = payload["pc_id"]
    await db.update_pc_heartbeat(
        pc_id=pc_id,
        distros=[d.dict() for d in req.distros],
        metrics=req.metrics.dict() if req.metrics else {},
        hostname=req.hostname,
        windows_version=req.windows_version,
    )
    return {"ok": True}

@app.get("/api/agent/commands")
async def agent_poll_commands(payload=Depends(verify_token)):
    """Agente faz polling a cada 3s para buscar comandos pendentes."""
    pc_id = payload["pc_id"]
    cmd = await db.pop_pending_command(pc_id)
    if cmd:
        return {"command": cmd}
    return {"command": None}

@app.post("/api/agent/result")
async def agent_post_result(req: CommandResultRequest, payload=Depends(verify_token)):
    """Agente posta resultado/progresso de um comando em execução."""
    pc_id = payload["pc_id"]
    await db.save_command_result(req.command_id, req.result)

    # Encaminha para SSE do frontend
    await push_sse(pc_id, {
        "type":       req.result.get("type", "info"),
        "msg":        req.result.get("msg", ""),
        "pct":        req.result.get("pct", -1),
        "level":      req.result.get("level", "info"),
        "command_id": req.command_id,
        "ts":         datetime.now(timezone.utc).isoformat(),
    })
    return {"ok": True}

# =============================================================================
# COMMANDS (admin → agente)
# =============================================================================

@app.post("/api/pcs/{pc_id}/provision")
async def send_provision(pc_id: str, req: ProvisionRequest, _=Depends(verify_admin_token)):
    """Enfileira um comando de provisionamento para o agente do PC."""
    pc = await db.get_pc(pc_id)
    if not pc:
        raise HTTPException(404, "PC não encontrado")

    command_id = str(uuid.uuid4())
    await db.enqueue_command(pc_id=pc_id, command_id=command_id, command={
        "type":       "provision",
        "command_id": command_id,
        "config":     req.config,
    })
    return {"command_id": command_id}

@app.post("/api/pcs/{pc_id}/export")
async def send_export(pc_id: str, request: Request, _=Depends(verify_admin_token)):
    body = await request.json()
    command_id = str(uuid.uuid4())
    await db.enqueue_command(pc_id=pc_id, command_id=command_id, command={
        "type":       "export",
        "command_id": command_id,
        "distro":     body.get("distro"),
        "user":       body.get("user"),
    })
    return {"command_id": command_id}

@app.post("/api/pcs/{pc_id}/launch")
async def send_launch(pc_id: str, request: Request, _=Depends(verify_admin_token)):
    body = await request.json()
    command_id = str(uuid.uuid4())
    await db.enqueue_command(pc_id=pc_id, command_id=command_id, command={
        "type":       "launch",
        "command_id": command_id,
        "distro":     body.get("distro"),
    })
    return {"command_id": command_id}

@app.post("/api/pcs/{pc_id}/remove-distro")
async def send_remove_distro(pc_id: str, request: Request, _=Depends(verify_admin_token)):
    body = await request.json()
    command_id = str(uuid.uuid4())
    await db.enqueue_command(pc_id=pc_id, command_id=command_id, command={
        "type":       "remove_distro",
        "command_id": command_id,
        "distro":     body.get("distro"),
    })
    return {"command_id": command_id}

# =============================================================================
# SSE STREAM (frontend escuta logs em tempo real)
# =============================================================================

@app.get("/api/pcs/{pc_id}/stream")
async def sse_stream(pc_id: str, request: Request, token: str = None):
    """SSE: frontend escuta eventos de um PC específico em tempo real.
    Aceita token via query string (necessário para EventSource do browser).
    """
    from auth import _decode_token
    auth_header = request.headers.get("authorization", "")
    raw_token = token or (auth_header.replace("Bearer ", "") if auth_header else None)
    if not raw_token:
        raise HTTPException(401, "Token não fornecido")
    payload = _decode_token(raw_token)
    if not payload.get("is_admin"):
        raise HTTPException(403, "Acesso negado")
    """SSE: frontend escuta eventos de um PC específico em tempo real."""
    queue = get_or_create_queue(pc_id)

    async def event_generator() -> AsyncGenerator[str, None]:
        # Heartbeat inicial para manter conexão
        yield "data: {\"type\":\"connected\"}\n\n"
        while True:
            try:
                event = await asyncio.wait_for(queue.get(), timeout=20.0)
                yield f"data: {json.dumps(event)}\n\n"
            except asyncio.TimeoutError:
                # Keep-alive ping a cada 20s
                yield "data: {\"type\":\"ping\"}\n\n"

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control":     "no-cache",
            "X-Accel-Buffering": "no",
        }
    )

# =============================================================================
# HISTÓRICO
# =============================================================================

@app.get("/api/pcs/{pc_id}/history")
async def get_history(pc_id: str, limit: int = 20, _=Depends(verify_admin_token)):
    rows = await db.get_command_history(pc_id, limit)
    return rows

# =============================================================================
# HEALTH
# =============================================================================

@app.get("/health")
async def health():
    return {"ok": True, "version": "3.0.0"}

@app.get("/api/ping")
async def ping():
    return {"ok": True}
