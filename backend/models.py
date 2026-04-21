# =============================================================================
# WSL Manager v3 — Models Pydantic
# Autor: Diego Regis M. F. dos Santos
# Email: diego-f-santos@openlabs.com.br
# Time:  OpenLabs - DevOps | Infra
# Versão: 3.0.0
# =============================================================================

from typing import Any, Optional
from pydantic import BaseModel


class AdminLoginRequest(BaseModel):
    password: str


class PCRegisterRequest(BaseModel):
    name: str
    description: Optional[str] = ""


class DistroInfo(BaseModel):
    name: str
    running: bool = False
    users: list[str] = []


class PCMetrics(BaseModel):
    cpu_pct:      Optional[int]   = 0
    ram_used_mb:  Optional[int]   = 0
    ram_total_mb: Optional[int]   = 0
    ram_pct:      Optional[int]   = 0
    disk_used_gb: Optional[float] = 0.0
    disk_total_gb:Optional[float] = 0.0
    disk_pct:     Optional[int]   = 0


class PCHeartbeatRequest(BaseModel):
    distros:         list[DistroInfo] = []
    metrics:         PCMetrics        = PCMetrics()
    hostname:        Optional[str]    = ""
    windows_version: Optional[str]    = ""


class CommandRequest(BaseModel):
    type:   str
    config: Optional[dict] = None


class CommandResultRequest(BaseModel):
    command_id: str
    result:     dict[str, Any]


class ProvisionRequest(BaseModel):
    config: dict[str, Any]
