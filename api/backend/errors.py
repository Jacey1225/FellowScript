"""Shared "couldn't be saved" signal for a failed DB write.

``DBManager.insertion``/``.update``/``.delete`` (db.py) return an explicit
bool instead of a fake-success ``None`` (db-write-failure-signaling
workflow, step 1). Every call site invoking them -- across
``backend/interactions``, ``backend/auth``, ``backend/subscription``,
``backend/monitoring``, ``backend/backup``, and ``routes`` (~30+ sites,
workflow step 2) -- must check that bool and stop proceeding as if the
write happened. This module is the one shared place those sites raise
from, so they all report the same message instead of each inventing its
own wording.
"""


class SaveFailedError(Exception):
    """Raise wherever a DBManager.insertion/.update/.delete call returns
    False and the write cannot be treated as an expected no-op, instead of
    continuing on as if it had succeeded.

    A plain ``Exception`` rather than an ``HTTPException`` subclass, so the
    same class works whether it's raised directly in a route handler or
    several calls down inside a ``*Manager`` method -- mirrors this
    codebase's existing ``ContentRejected`` convention
    (backend/moderation/content_filter.py). Most routes simply let it
    propagate uncaught: main.py registers an app-wide handler (mirroring
    how slowapi's ``RateLimitExceeded`` is wired up there) that turns it
    into a 503 "couldn't be saved" response. A route that already wraps its
    own DB calls in a broader ``except Exception`` (e.g. the Stripe/Apple
    webhook handlers in routes/subscription.py) picks it up there instead,
    exactly as it already does for any other write failure on those paths.

    The few non-HTTP call sites (``ConnectionManager.save_message`` over a
    WebSocket, and the ``WatchdogManager``/``DebugAgentManager``/
    ``BackupManager`` background jobs) catch it themselves, since there is
    no HTTP response to send in those contexts -- see each call site's own
    comment for how it's handled there.

    Not every ``False`` return is raised on: ``DBManager.update``/``.delete``
    also return ``False`` for a real no-op (zero rows matched, no
    exception) -- see their docstrings in db.py. A call site whose write
    targets a row it just confirmed exists treats ``False`` as a genuine
    failure and raises; a call site doing best-effort/idempotent cleanup
    (e.g. severing a friendship that may only exist in one direction, or
    unblocking a user who may already be unblocked) treats ``False`` as an
    acceptable no-op and does not raise -- a real DB error on that path is
    still visible via db.py's own ``DB_WRITE_FAILURE`` log line either way.
    """

    def __init__(self, message: str = "Couldn't be saved. Please try again.") -> None:
        super().__init__(message)
        self.message = message
