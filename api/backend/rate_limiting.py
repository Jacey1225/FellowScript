"""Shared slowapi `Limiter` instance + client-IP resolution.

Extracted from `main.py` (security step 4 of the error-debug-agent-admin-page
workflow) so route modules other than `main.py` -- e.g. `routes/monitoring.py`
-- can apply `@limiter.limit(...)` to a specific endpoint without a circular
import back through `main`. `main.py` imports `get_client_ip`/`limiter` from
here (re-exporting `get_client_ip` under its own name, so the existing
`from main import get_client_ip` import in `tests/test_security_hardening.py`
keeps working unchanged) and still owns wiring the exception handler +
`SlowAPIMiddleware` onto `app`.
"""
import ipaddress

from fastapi import Request
from slowapi import Limiter
from slowapi.util import get_remote_address


# Peers allowed to tell us the visitor IP via CF-Connecting-IP: nginx on the
# same host (loopback) and Starlette's TestClient pseudo-peer. "testclient" is
# not an IP literal, so it can never be a real TCP peer in production. Module
# constant on purpose, not configuration.
_TRUSTED_PEERS = frozenset({"127.0.0.1", "::1", "testclient"})


def get_client_ip(request: Request) -> str:
    """Resolve the visitor IP used as the rate-limit key.

    Production sits behind Cloudflare and nginx, and uvicorn runs with
    ``--no-proxy-headers`` (see the Dockerfile), so ``request.client.host`` is
    the real TCP peer. ``CF-Connecting-IP`` is honoured only when that peer is
    a trusted one (nginx on loopback, or the test client) AND the value parses
    as an IP address; otherwise the peer itself is the key, so a client that
    reaches the app directly can never choose its own bucket. ``X-Real-IP`` is
    never read. A missing ``request.client`` does not raise.
    """
    peer = request.client.host if request.client else ""
    if peer in _TRUSTED_PEERS:
        raw = request.headers.get("cf-connecting-ip", "").strip()
        if raw:
            try:
                return str(ipaddress.ip_address(raw))
            except ValueError:
                pass  # malformed header: fall through to the peer
    return peer or get_remote_address(request)


limiter = Limiter(key_func=get_client_ip)
