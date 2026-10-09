"""DB-backed feature flags (off / canary / on) with a fail-closed reader.

Flags live in the ``feature_flags`` table (DDL module ``flags``), not in a
JSON file, so a flip needs no deploy: ``PUT /admin/flags/{name}`` or
``python -m backend.admin_flags``. Claude/the pipeline never flips a flag.

Reader rules:
- One query reads every row; the snapshot is cached per process for
  ``CACHE_TTL_SECONDS`` (the API runs a single uvicorn process).
- Fail CLOSED: any DB error answers "off" for every flag (never a stale "on")
  and logs one WARNING per minute.
- Unknown flag name: off.
- ``canary``: on only for user ids in the flag's canary list; a flag
  registered ``no_canary`` treats a stored ``canary`` state as off.
- ``invalidate()`` drops the cache (the writers call it).

Registry: ``register()`` declares a flag's attributes. ``no_canary`` flags
accept only off/on; ``exposed_in_capabilities`` flags appear in
``GET /app/capabilities`` ``features``. Later tasks add a flag with one
``register()`` call (the DDL seed list is only a convenience, the writer
upserts).

Log wording: the CloudWatch watchdog treats the bare word ERROR as a
detection, so non-error lines here say "failed".
"""
from __future__ import annotations

import logging
import threading
import time
import uuid
from dataclasses import dataclass

from db import DBManager

logger = logging.getLogger(__name__)
audit_logger = logging.getLogger("admin_audit")

STATES = ("off", "canary", "on")
CACHE_TTL_SECONDS = 10.0
WARN_INTERVAL_SECONDS = 60.0
MAX_CANARY_IDS = 500


class FlagError(Exception):
    """Base class for writer validation failures."""


class UnknownFlagError(FlagError):
    pass


class InvalidFlagStateError(FlagError):
    pass


class InvalidCanaryError(FlagError):
    pass


@dataclass(frozen=True)
class FlagSpec:
    name: str
    no_canary: bool = False
    exposed_in_capabilities: bool = True


_REGISTRY: dict[str, FlagSpec] = {}


def register(name: str, *, no_canary: bool = False, exposed_in_capabilities: bool = True) -> FlagSpec:
    spec = FlagSpec(name=name, no_canary=no_canary, exposed_in_capabilities=exposed_in_capabilities)
    _REGISTRY[name] = spec
    invalidate()
    return spec


def registry() -> dict[str, FlagSpec]:
    """A copy of the registry (insertion order = registration order)."""
    return dict(_REGISTRY)


# -- cache --------------------------------------------------------------------

_lock = threading.Lock()
_snapshot: dict[str, tuple[str, frozenset[str]]] | None = None
_snapshot_at = 0.0
_last_warn = 0.0


def invalidate() -> None:
    global _snapshot, _snapshot_at
    with _lock:
        _snapshot = None
        _snapshot_at = 0.0


register("chat_pagination")
register("chat_pagination_dm")
register("threads")
register("message_delete")
register("explorer_publish")
register("explorer_browse", no_canary=True)
register("join_requests")
register("join_request_push")
# Creator Affiliates page (task 20261007-affiliates-page): off/on only, exposed via no capability.
register("affiliates", no_canary=True, exposed_in_capabilities=False)
# Affiliate payout details (task 20261008-affiliate-payout-details): nested inside
# ``affiliates``; off/on only, server-side only. Ships OFF.
register("affiliate_payouts", no_canary=True, exposed_in_capabilities=False)
# Content encryption at rest (task 20261008-content-encryption-at-rest): gates WRITE
# encryption only; reads always handle plaintext and ciphertext. Off/on only,
# server-side only, ships OFF.
register("content_encryption_write", no_canary=True, exposed_in_capabilities=False)
register("agent_chats")
# Per-chat memory for agent chats (windowed history + rolling summary). Needs
# agent_chats on too; server-side only, so not exposed in capabilities.
register("agent_chat_memory", exposed_in_capabilities=False)


def _load_snapshot() -> dict[str, tuple[str, frozenset[str]]]:
    db = DBManager()
    try:
        db.cur.execute("SELECT name, state, canary_user_ids::text[] FROM feature_flags")
        return {
            name: (state, frozenset(str(u).lower() for u in (canary or [])))
            for name, state, canary in db.cur.fetchall()
        }
    finally:
        db.close()


def _warn_once_per_minute() -> None:
    global _last_warn
    now = time.monotonic()
    if now - _last_warn >= WARN_INTERVAL_SECONDS or _last_warn == 0.0:
        _last_warn = now
        logger.warning("feature flag lookup failed; treating every flag as off")


def get_snapshot() -> dict[str, tuple[str, frozenset[str]]]:
    """Current ``{name: (state, canary_ids)}``; empty (all off) when the read fails."""
    global _snapshot, _snapshot_at
    now = time.monotonic()
    with _lock:
        if _snapshot is not None and now - _snapshot_at < CACHE_TTL_SECONDS:
            return _snapshot
    try:
        snap = _load_snapshot()
    except Exception:  # noqa: BLE001 - fail closed on anything
        with _lock:
            _warn_once_per_minute()
            _snapshot = None
        return {}
    with _lock:
        _snapshot = snap
        _snapshot_at = time.monotonic()
    return snap


def _evaluate(snap, name: str, user_id: str | None) -> bool:
    spec = _REGISTRY.get(name)
    row = snap.get(name)
    if spec is None or row is None:
        return False
    state, canary = row
    if state == "on":
        return True
    if state == "canary":
        if spec.no_canary or not user_id:
            return False
        return str(user_id).lower() in canary
    return False


def is_enabled(name: str, user_id: str | None = None) -> bool:
    return _evaluate(get_snapshot(), name, user_id)


def evaluate_all(user_id: str | None = None, *, exposed_only: bool = False) -> dict[str, bool]:
    """One snapshot read, every registered flag evaluated for ``user_id``."""
    snap = get_snapshot()
    return {
        name: _evaluate(snap, name, user_id)
        for name, spec in _REGISTRY.items()
        if spec.exposed_in_capabilities or not exposed_only
    }


# -- writer -------------------------------------------------------------------

def _clean_canary_ids(cur, ids) -> list[str]:
    if not isinstance(ids, (list, tuple)) or len(ids) > MAX_CANARY_IDS:
        raise InvalidCanaryError("invalid canary list")
    out: list[str] = []
    for raw in ids:
        try:
            if not isinstance(raw, str):
                raise ValueError
            out.append(str(uuid.UUID(raw)))
        except ValueError:
            raise InvalidCanaryError("invalid canary list") from None
    out = list(dict.fromkeys(out))
    if out:
        cur.execute("SELECT _id::text FROM users WHERE _id = ANY(%s::uuid[])", (out,))
        found = {r[0] for r in cur.fetchall()}
        if any(i not in found for i in out):
            raise InvalidCanaryError("invalid canary list")
    return out


def set_flag(name: str, state: str, canary_user_ids=None, *, actor: str) -> dict:
    """Validate and persist a flag change; the single writer for API and CLI.

    ``canary_user_ids`` None keeps the stored list. Raises FlagError subclasses
    (route -> 404/422). Logs one INFO audit line (ids and counts only).
    """
    spec = _REGISTRY.get(name)
    if spec is None:
        raise UnknownFlagError("unknown flag")
    if state not in STATES:
        raise InvalidFlagStateError("invalid state")
    if spec.no_canary and (state == "canary" or canary_user_ids):
        raise InvalidFlagStateError("flag does not support canary")
    db = DBManager()
    try:
        cur = db.cur
        ids = None if canary_user_ids is None else _clean_canary_ids(cur, canary_user_ids)
        if ids is None:
            cur.execute(
                "INSERT INTO feature_flags (name, state, updated_at, updated_by) "
                "VALUES (%s, %s, NOW(), %s) "
                "ON CONFLICT (name) DO UPDATE SET state = EXCLUDED.state, "
                "updated_at = NOW(), updated_by = EXCLUDED.updated_by "
                "RETURNING canary_user_ids::text[]",
                (name, state, actor),
            )
        else:
            cur.execute(
                "INSERT INTO feature_flags (name, state, canary_user_ids, updated_at, updated_by) "
                "VALUES (%s, %s, %s::uuid[], NOW(), %s) "
                "ON CONFLICT (name) DO UPDATE SET state = EXCLUDED.state, "
                "canary_user_ids = EXCLUDED.canary_user_ids, "
                "updated_at = NOW(), updated_by = EXCLUDED.updated_by "
                "RETURNING canary_user_ids::text[]",
                (name, state, ids, actor),
            )
        canary_count = len(cur.fetchone()[0] or [])
        db.conn.commit()
    except Exception:
        db.conn.rollback()
        raise
    finally:
        db.close()
    invalidate()
    audit_logger.info("FLAG_CHANGE name=%s state=%s actor=%s canary_count=%d",
                      name, state, actor, canary_count)
    return {"name": name, "state": state, "canary_count": canary_count}


def list_flags() -> list[dict]:
    """Registered flags with their stored state (DB read, not cached)."""
    snap = _load_snapshot()
    rows = []
    for name, spec in _REGISTRY.items():
        state, canary = snap.get(name, ("off", frozenset()))
        rows.append({"name": name, "state": state, "canary_count": len(canary),
                     "no_canary": spec.no_canary,
                     "exposed_in_capabilities": spec.exposed_in_capabilities})
    return rows
