# =============================================================================
# WSL Manager v3 — Auth JWT
# Autor: Diego Regis M. F. dos Santos
# Email: diego-f-santos@openlabs.com.br
# Time:  OpenLabs - DevOps | Infra
# Versão: 3.0.0
# =============================================================================

import os
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

SECRET_KEY  = os.environ.get("JWT_SECRET", "change-me-in-production-please")
ALGORITHM   = "HS256"
# Tokens de PC não expiram (agentes ficam anos rodando)
PC_TOKEN_EXPIRE_DAYS = 365 * 10

bearer_scheme = HTTPBearer(auto_error=False)


def get_admin_token_from_env() -> str:
    token = os.environ.get("ADMIN_PASSWORD", "admin123")
    return token


def create_pc_token(pc_id: str, pc_name: str, is_admin: bool = False) -> str:
    expire = datetime.now(timezone.utc) + timedelta(days=PC_TOKEN_EXPIRE_DAYS)
    payload = {
        "pc_id":    pc_id,
        "pc_name":  pc_name,
        "is_admin": is_admin,
        "exp":      expire,
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


def _decode_token(token: str) -> dict:
    try:
        return jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expirado")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Token inválido")


async def verify_token(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme)
) -> dict:
    if not credentials:
        raise HTTPException(status_code=401, detail="Token não fornecido")
    return _decode_token(credentials.credentials)


async def verify_admin_token(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme)
) -> dict:
    if not credentials:
        raise HTTPException(status_code=401, detail="Token não fornecido")
    payload = _decode_token(credentials.credentials)
    if not payload.get("is_admin"):
        raise HTTPException(status_code=403, detail="Acesso negado — token de admin necessário")
    return payload
