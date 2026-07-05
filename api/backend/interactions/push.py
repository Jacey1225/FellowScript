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

APNS_HOST = "https://api.push.apple.com"

_jwt_cache: tuple[str, float] | None = None


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


async def send_push(device_token: str, title: str, body: str) -> bool:
    if not all([KEY_ID, TEAM_ID, BUNDLE_ID, KEY_PATH]):
        logger.warning("APNs not fully configured — skipping push")
        return False
    try:
        token = _apns_jwt()
    except Exception as e:
        logger.error("Failed to generate APNs JWT: %s", e)
        return False

    url = f"{APNS_HOST}/3/device/{device_token}"
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
    try:
        async with httpx.AsyncClient(http2=True) as client:
            resp = await client.post(url, json=payload, headers=headers, timeout=10)
        if resp.status_code != 200:
            logger.error("APNs %d: %s", resp.status_code, resp.text[:200])
        return resp.status_code == 200
    except Exception as e:
        logger.error("APNs send failed: %s", e)
        return False
