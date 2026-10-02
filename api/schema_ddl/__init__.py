"""Ordered, idempotent DDL modules applied at the end of ``db.create_tables``.

Each module is a file in this package exposing ``apply(cur)``. Which modules
run, and in what order, is the ``DDL_MODULES`` tuple in ``db.py`` (one name
per line so later tasks add a one-line edit). A name that is not a valid
module name, has no file, or has no ``apply`` raises: a typo must stop the
boot, never silently skip a schema change.

Rules for module bodies: only ``CREATE ... IF NOT EXISTS`` / ``ALTER ... ADD
COLUMN IF NOT EXISTS`` / ``ON CONFLICT DO NOTHING`` seeds, so every boot is a
safe no-op against a current schema. Statements run in the same transaction
as ``create_tables`` (the boot transaction in ``main.py`` lifespan).
"""
from __future__ import annotations

import importlib
import logging
import re
from typing import Iterable

logger = logging.getLogger(__name__)

# Boot-time lock wait cap (seconds as a Postgres interval string). A boot that
# is blocked behind another session fails loudly instead of hanging silently
# under ``restart: unless-stopped``.
BOOT_LOCK_TIMEOUT = "30s"

_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")


class DDLModuleError(RuntimeError):
    """A name in DDL_MODULES is invalid, missing, or has no ``apply``."""


def _load(name: str):
    if not isinstance(name, str) or not _NAME_RE.fullmatch(name):
        raise DDLModuleError(f"invalid DDL module name: {name!r}")
    try:
        module = importlib.import_module(f"{__name__}.{name}")
    except ModuleNotFoundError as e:
        if e.name == f"{__name__}.{name}":
            raise DDLModuleError(f"unknown DDL module: {name!r}") from e
        raise
    apply = getattr(module, "apply", None)
    if not callable(apply):
        raise DDLModuleError(f"DDL module {name!r} has no apply(cur)")
    return apply


def apply_modules(cur, names: Iterable[str]) -> None:
    """Apply each named module in order.

    Every name is resolved BEFORE anything runs, so an unknown module raises
    without having applied part of the list. ``lock_timeout`` is set once,
    transaction-locally, before the first module (a no-op under autocommit).
    """
    names = tuple(names)
    resolved = [(n, _load(n)) for n in names]
    if not resolved:
        return
    cur.execute("SELECT set_config('lock_timeout', %s, true)", (BOOT_LOCK_TIMEOUT,))
    for name, apply in resolved:
        apply(cur)
        logger.info("DDL module applied: %s", name)
