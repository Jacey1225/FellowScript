import os
import time
import logging
import jwt
import httpx
from dotenv import load_dotenv

load_dotenv()

logger = logging.getLogger(__name__)

KEY_ID    = os.getenv("APPLE_KEY_ID", "")
TEAM_ID   = os.getenv("APPLE_TEAM_ID", "")
BUNDLE_ID = os.getenv("APPLE_BUNDLE_ID", "")
KEY_PATH  = os.getenv("APPLE_KEY_PATH", "")

# A device token belongs to exactly one APNs environment: sandbox for
# development/Xcode builds, production for App Store/TestFlight builds. We can't
# tell which from the token alone, so we try one host and fall back to the other
# on an environment-mismatch error. APNS_ENV pins which is tried first.
APNS_HOSTS = {
    "production": "https://api.push.apple.com",
    "sandbox":    "https://api.sandbox.push.apple.com",
}
_ENV_MISMATCH_REASONS = {"BadDeviceToken", "BadEnvironmentKeyInToken"}

_jwt_cache: tuple[str, float] | None = None


class APNsConfigError(RuntimeError):
    """APNs is unconfigured, or its ``.p8`` credential file can't be read.

    Deliberately never swallowed inside this module -- per this project's
    fail-fast Configuration Philosophy (see task
    20260903-push-notifications-not-delivering), a missing/unreadable APNs
    credential must surface loudly instead of degrading every push
    silently and indefinitely. That's exactly what the pattern this
    replaces (``if not all([...]): return False`` plus a broad
    ``except Exception`` around opening ``KEY_PATH``) let happen: a
    file-ownership mismatch on the live host's ``AuthKey_*.p8`` recurred in
    production logs roughly every 15 minutes for 48+ hours with no signal
    beyond a buried per-push warning.

    ``validate_apns_config()`` is called once, eagerly, from ``main.py``'s
    ``lifespan`` at process startup (alongside ``start_heartbeat()``/
    ``start_scheduler()``), so a misconfigured deployment fails at boot
    rather than after however many silent pushes. ``_apns_jwt()`` also
    re-validates on every cache-refresh, so if config drifts invalid while
    already running (e.g. permissions revoked on the mounted key, the
    actual failure mode found live here) it fails this same loud, specific
    way rather than reverting to silence. Every ``send_push`` call site
    already isolates its own per-send/per-job failures in its own
    try/except (see ``websockets.py``'s ``send_msg``, ``scheduler.py``'s
    reminder jobs) -- so letting this propagate can't crash the whole
    process, it just always shows up as a specific, named error in that
    caller's log instead of a generic one.
    """


def _missing_config_vars() -> list[str]:
    return [
        name for name, value in (
            ("APPLE_KEY_ID", KEY_ID),
            ("APPLE_TEAM_ID", TEAM_ID),
            ("APPLE_BUNDLE_ID", BUNDLE_ID),
            ("APPLE_KEY_PATH", KEY_PATH),
        )
        if not value
    ]


def validate_apns_config() -> None:
    """Eagerly validate every APNs env var is set and ``APPLE_KEY_PATH``
    resolves to a file this process can actually read.

    Raises ``APNsConfigError`` naming exactly which environment variable is
    missing, or exactly why the ``.p8`` file couldn't be read -- never the
    key material itself, per this project's log-redaction posture.
    """
    missing = _missing_config_vars()
    if missing:
        raise APNsConfigError(
            "APNs is not configured: missing required environment "
            f"variable(s) {', '.join(missing)}. There is no implicit "
            "default for push credentials -- set them explicitly."
        )
    if not os.path.isfile(KEY_PATH):
        raise APNsConfigError(f"APPLE_KEY_PATH ({KEY_PATH}) does not exist.")
    try:
        with open(KEY_PATH, "r") as f:
            f.read(1)
    except OSError as e:
        raise APNsConfigError(
            f"APPLE_KEY_PATH ({KEY_PATH}) exists but could not be read: "
            f"{e.strerror or e.__class__.__name__}. Check the file's "
            "ownership/permissions match the runtime process's user."
        ) from e


def _host_order() -> list[str]:
    primary = os.getenv("APNS_ENV", "production").lower()
    if primary not in APNS_HOSTS:
        primary = "production"
    other = "sandbox" if primary == "production" else "production"
    return [primary, other]


def _apns_jwt() -> str:
    global _jwt_cache
    now = time.time()
    if _jwt_cache and now < _jwt_cache[1]:
        return _jwt_cache[0]
    validate_apns_config()
    with open(KEY_PATH, "r") as f:
        private_key = f.read()
    token = jwt.encode(
        {"iss": TEAM_ID, "iat": int(now)},
        private_key,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )
    _jwt_cache = (token, now + 3000)  # refresh before Apple's 60-min expiry
    return token


async def send_push(
    device_token: str, title: str, body: str, data: dict | None = None
) -> bool:
    """Send an APNs alert push. ``data`` (optional) is merged into the
    payload alongside (not inside) ``aps`` -- standard APNs practice for
    passing identifiers a client needs to resolve the alert to specific
    local state (e.g. which heartbeat/agent fired) without putting anything
    sensitive in the alert title/body itself, which transits Apple's
    infrastructure and (unlike a client-scheduled local notification) is
    composed directly by this backend.

    Raises:
        APNsConfigError: If APNs is unconfigured or its credential file
            can't be read -- see that class's docstring for why this is
            allowed to propagate rather than being swallowed here.
    """
    token = _apns_jwt()

    headers = {
        "authorization": f"bearer {token}",
        "apns-push-type": "alert",
        "apns-topic": BUNDLE_ID,
    }
    payload = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
        }
    }
    if data:
        payload.update(data)

    for env in _host_order():
        url = f"{APNS_HOSTS[env]}/3/device/{device_token}"
        try:
            async with httpx.AsyncClient(http2=True) as client:
                resp = await client.post(url, json=payload, headers=headers, timeout=10)
        except Exception as e:
            logger.error("APNs send failed (%s): %s", env, e)
            continue
        if resp.status_code == 200:
            return True
        reason = ""
        try:
            reason = resp.json().get("reason", "")
        except Exception:
            pass
        logger.warning("APNs %d (%s): %s", resp.status_code, env, reason)
        # Only worth retrying the other environment on an env-mismatch error.
        if reason not in _ENV_MISMATCH_REASONS:
            break
    return False
