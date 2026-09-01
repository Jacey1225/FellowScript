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
    """
    if not all([KEY_ID, TEAM_ID, BUNDLE_ID, KEY_PATH]):
        logger.warning("APNs not fully configured — skipping push")
        return False
    try:
        token = _apns_jwt()
    except Exception as e:
        logger.error("Failed to generate APNs JWT: %s", e)
        return False

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
