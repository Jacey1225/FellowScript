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
from fastapi import Request
from slowapi import Limiter
from slowapi.util import get_remote_address


def get_client_ip(request: Request) -> str:
    """Resolve the true visitor IP behind Cloudflare + nginx.

    Production sits behind Cloudflare, which terminates the client's real
    connection and reconnects to our nginx box from one of its own rotating
    edge IPs. uvicorn only trusts the single nginx hop (127.0.0.1), so
    ``request.client.host`` / slowapi's default ``get_remote_address``
    resolves to that rotating Cloudflare edge IP, not the actual visitor —
    which defeats per-IP rate limiting entirely (every request looks like a
    different client). Cloudflare's own ``CF-Connecting-IP`` header carries
    the real visitor IP directly, so prefer it; fall back to the standard
    resolution for local/non-Cloudflare requests (tests, direct access).
    """
    return request.headers.get("cf-connecting-ip") or get_remote_address(request)


limiter = Limiter(key_func=get_client_ip)
