# =============================================================================
# WSL Manager v3 — Database (SQLite async via aiosqlite)
# Autor: Diego Regis M. F. dos Santos
# Email: diego-f-santos@openlabs.com.br
# Time:  OpenLabs - DevOps | Infra
# Versão: 3.0.0
# =============================================================================

import json
import os
from datetime import datetime, timezone
from typing import Optional

import aiosqlite

DB_PATH = os.environ.get("DB_PATH", "/data/wsl-manager.db")


class Database:
    def __init__(self):
        self._conn: Optional[aiosqlite.Connection] = None

    async def init(self):
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
        self._conn = await aiosqlite.connect(DB_PATH)
        self._conn.row_factory = aiosqlite.Row
        await self._conn.execute("PRAGMA journal_mode=WAL")
        await self._create_tables()

    async def close(self):
        if self._conn:
            await self._conn.close()

    async def _create_tables(self):
        await self._conn.executescript("""
            CREATE TABLE IF NOT EXISTS pcs (
                pc_id           TEXT PRIMARY KEY,
                name            TEXT NOT NULL,
                description     TEXT,
                hostname        TEXT,
                windows_version TEXT,
                distros         TEXT DEFAULT '[]',
                metrics         TEXT DEFAULT '{}',
                last_seen       TEXT,
                created_at      TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS commands (
                command_id  TEXT PRIMARY KEY,
                pc_id       TEXT NOT NULL,
                command     TEXT NOT NULL,
                status      TEXT DEFAULT 'pending',
                result      TEXT,
                created_at  TEXT NOT NULL,
                updated_at  TEXT,
                FOREIGN KEY (pc_id) REFERENCES pcs(pc_id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_commands_pc_status
                ON commands(pc_id, status);
        """)
        await self._conn.commit()

    # ── PCs ──────────────────────────────────────────────────────────────────

    async def create_pc(self, pc_id: str, name: str, description: str = ""):
        now = datetime.now(timezone.utc).isoformat()
        await self._conn.execute(
            """INSERT INTO pcs (pc_id, name, description, created_at)
               VALUES (?, ?, ?, ?)""",
            (pc_id, name, description or "", now)
        )
        await self._conn.commit()

    async def list_pcs(self) -> list[dict]:
        async with self._conn.execute(
            "SELECT * FROM pcs ORDER BY name"
        ) as cur:
            rows = await cur.fetchall()
        return [dict(r) for r in rows]

    async def get_pc(self, pc_id: str) -> Optional[dict]:
        async with self._conn.execute(
            "SELECT * FROM pcs WHERE pc_id = ?", (pc_id,)
        ) as cur:
            row = await cur.fetchone()
        return dict(row) if row else None

    async def delete_pc(self, pc_id: str):
        await self._conn.execute("DELETE FROM pcs WHERE pc_id = ?", (pc_id,))
        await self._conn.commit()

    async def update_pc_heartbeat(
        self, pc_id: str, distros: list, metrics: dict,
        hostname: str = "", windows_version: str = ""
    ):
        now = datetime.now(timezone.utc).isoformat()
        await self._conn.execute(
            """UPDATE pcs SET
                distros         = ?,
                metrics         = ?,
                hostname        = ?,
                windows_version = ?,
                last_seen       = ?
               WHERE pc_id = ?""",
            (
                json.dumps(distros),
                json.dumps(metrics),
                hostname or "",
                windows_version or "",
                now,
                pc_id,
            )
        )
        await self._conn.commit()

    # ── Commands ─────────────────────────────────────────────────────────────

    async def enqueue_command(self, pc_id: str, command_id: str, command: dict):
        now = datetime.now(timezone.utc).isoformat()
        await self._conn.execute(
            """INSERT INTO commands (command_id, pc_id, command, status, created_at)
               VALUES (?, ?, ?, 'pending', ?)""",
            (command_id, pc_id, json.dumps(command), now)
        )
        await self._conn.commit()

    async def pop_pending_command(self, pc_id: str) -> Optional[dict]:
        """Retorna e marca como 'running' o próximo comando pendente do PC."""
        async with self._conn.execute(
            """SELECT * FROM commands
               WHERE pc_id = ? AND status = 'pending'
               ORDER BY created_at ASC LIMIT 1""",
            (pc_id,)
        ) as cur:
            row = await cur.fetchone()
        if not row:
            return None
        now = datetime.now(timezone.utc).isoformat()
        await self._conn.execute(
            "UPDATE commands SET status = 'running', updated_at = ? WHERE command_id = ?",
            (now, row["command_id"])
        )
        await self._conn.commit()
        cmd = dict(row)
        cmd["command"] = json.loads(cmd["command"])
        return cmd

    async def save_command_result(self, command_id: str, result: dict):
        now  = datetime.now(timezone.utc).isoformat()
        done = result.get("type") == "done"
        status = "done" if done else "running"
        await self._conn.execute(
            """UPDATE commands SET status = ?, result = ?, updated_at = ?
               WHERE command_id = ?""",
            (status, json.dumps(result), now, command_id)
        )
        await self._conn.commit()

    async def get_command_history(self, pc_id: str, limit: int = 20) -> list[dict]:
        async with self._conn.execute(
            """SELECT command_id, pc_id, command, status, result, created_at, updated_at
               FROM commands WHERE pc_id = ?
               ORDER BY created_at DESC LIMIT ?""",
            (pc_id, limit)
        ) as cur:
            rows = await cur.fetchall()
        result = []
        for r in rows:
            d = dict(r)
            try:
                d["command"] = json.loads(d["command"])
            except Exception:
                pass
            try:
                d["result"] = json.loads(d["result"]) if d["result"] else None
            except Exception:
                pass
            result.append(d)
        return result


db = Database()
