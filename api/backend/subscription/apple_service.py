"""Apple StoreKit / App Store Server integration (iOS).

StoreKit 2 verifies transactions cryptographically ON DEVICE and hands the app a
signed JWS. The app forwards that JWS here; we decode its payload to read the
product, original transaction id, and expiry, then record the subscription.

NOTE: this decodes the JWS payload but does not yet verify Apple's signature
chain. StoreKit's on-device verification already gates what the app sends, which
is acceptable for a first release; full server-side JWS signature verification
(Apple root certs) and App Store Server Notifications signature checks are the
recommended hardening step.
"""

import base64
import json
import logging

logger = logging.getLogger(__name__)

# App Store Connect product id → member_count. Must match the products created
# in App Store Connect and StoreKitManager on iOS. One fixed-price product per
# member count (1-8), since StoreKit can't compute an arbitrary price.
APPLE_PRODUCTS: dict[str, int] = {
    "com.fellowscript.app.group1": 1,
    "com.fellowscript.app.group2": 2,
    "com.fellowscript.app.group3": 3,
    "com.fellowscript.app.group4": 4,
    "com.fellowscript.app.group5": 5,
    "com.fellowscript.app.group6": 6,
    "com.fellowscript.app.group7": 7,
    "com.fellowscript.app.group8": 8,
}


def member_count_for(product_id: str) -> int | None:
    return APPLE_PRODUCTS.get(product_id or "")


def _b64url_decode(segment: str) -> bytes:
    segment += "=" * (-len(segment) % 4)   # restore padding
    return base64.urlsafe_b64decode(segment)


def decode_jws(jws: str) -> dict:
    """Return the decoded payload of a JWS (``header.payload.signature``).

    Raises ValueError if the token is malformed.
    """
    parts = (jws or "").split(".")
    if len(parts) < 2:
        raise ValueError("Malformed JWS")
    return json.loads(_b64url_decode(parts[1]))
