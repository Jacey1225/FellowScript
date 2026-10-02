"""One place that imports every module registering lifecycle hooks, report
resolvers or report removers.

``main.py`` (lifespan), ``backend.moderation.admin_actions`` and
``backend.admin_listings`` all call ``load_all()``: the ``python -m`` CLIs run
as separate processes that import only ``db`` and ``SessionManager``, so a
registration made at an unrelated module's import time would not exist there.

Each later task (LST, THR, JRQ, LSM) adds exactly ONE import line below, in its
own step. ``load_all`` is idempotent.
"""
from __future__ import annotations


def load_all() -> None:
    from backend import lifecycle_wiring  # noqa: F401  SF: group photo / banner collectors, user_delete
    from backend.interactions import reports  # noqa: F401  SF: CONTENT_RESOLVERS for the five existing types
    from backend.moderation import removers  # noqa: F401  SF: CONTENT_REMOVERS for the five existing types
    from backend import listings_wiring  # noqa: F401  LST: member_leave / user_delete hooks for listings
    from backend import threads_wiring  # noqa: F401  THR: thread_message resolver/remover, group_delete key collector
