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

# ── VoIP push config (task 20260916-callkit-voip-ring) ──────────────────────
#
# Apple mandates the VoIP topic be exactly "<bundle-id>.voip" -- it isn't a
# free-form value the way BUNDLE_ID itself is. It's still read as explicit,
# required config (not derived from BUNDLE_ID + ".voip" in code) per this
# project's Configuration Philosophy (Q1/Q4/Q8: explicit config, fail fast at
# boot if unset) -- and validate_voip_config() below cross-checks it actually
# matches BUNDLE_ID's expected derivation, so a copy/paste drift between the
# two env vars is caught at boot rather than surfacing as every VoIP push
# silently getting dropped by Apple for using the wrong topic.
VOIP_APNS_TOPIC = os.getenv("VOIP_APNS_TOPIC", "")


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


def validate_voip_config() -> None:
    """Eagerly validate ``VOIP_APNS_TOPIC`` is set and well-formed.

    Call once, at process startup (``main.py``'s ``lifespan``), same
    placement as ``validate_apns_config()`` -- required regardless of
    whether ``RING_VOIP_ENABLED``/``RING_FEATURE_ENABLED`` currently gate
    the feature on, per this project's established "no implicit default,
    fail fast at boot" posture (mirrors ``validate_ring_config()``'s own
    reasoning for why a *disabled* feature's config still can't be left
    unset).

    Deliberately does NOT validate a separate VoIP credential/certificate
    path: ``send_voip_push()`` reuses the same token-based JWT
    (``_apns_jwt()``) that ``validate_apns_config()`` already validates --
    Apple's token-based provider authentication is not push-type-scoped, so
    there is no second ``.p8``/cert file for this project to configure or
    validate here. Whether the Apple Developer account nonetheless needs a
    *capability* enabled (distinct from a signing credential) for VoIP is
    this task's App Store Connect / App Review disclosure, owned by the
    security step -- not something to speculatively configure here.

    Raises:
        APNsConfigError: If ``VOIP_APNS_TOPIC`` is unset, or set to
            anything other than ``f"{BUNDLE_ID}.voip"`` (Apple's mandated
            exact format for a VoIP push topic).
    """
    if not VOIP_APNS_TOPIC:
        raise APNsConfigError(
            "VOIP_APNS_TOPIC is not configured. There is no implicit "
            "default -- set it explicitly (Apple requires exactly "
            f"\"{BUNDLE_ID or '<bundle-id>'}.voip\") before this process "
            "can start."
        )
    expected = f"{BUNDLE_ID}.voip"
    if VOIP_APNS_TOPIC != expected:
        raise APNsConfigError(
            f"VOIP_APNS_TOPIC ({VOIP_APNS_TOPIC!r}) does not match the "
            f"format Apple requires for a VoIP push topic ({expected!r})."
        )


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


async def _post_to_apns(device_token: str, headers: dict, payload: dict) -> bool:
    """Shared host-fallback POST loop behind both ``send_push`` and
    ``send_voip_push`` (task 20260916-callkit-voip-ring extracted this out
    of what used to be ``send_push``'s own tail -- behavior is unchanged for
    ``send_push``, just no longer duplicated for the new VoIP push path).
    Tries ``APNS_ENV``'s primary environment first, falling back to the
    other only on an environment-mismatch reason (``_ENV_MISMATCH_REASONS``)
    -- a VoIP-type push is subject to the exact same sandbox/production
    token split as an alert push, Apple doesn't distinguish push type for
    that purpose.
    """
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

    return await _post_to_apns(device_token, headers, payload)


async def send_voip_push(device_token: str, data: dict) -> bool:
    """Send a PushKit VoIP push -- wakes the app (even from a killed state)
    to report an incoming ring to CallKit (task 20260916-callkit-voip-ring).
    ``data`` is merged directly into the payload (no ``title``/``body``: a
    VoIP push carries no ``aps.alert`` at all, see below).

    Differs from ``send_push`` in the three ways Apple's VoIP push contract
    requires:
      - ``apns-push-type: voip`` (not ``alert``) and ``apns-topic`` is the
        dedicated ``VOIP_APNS_TOPIC`` (``<bundle-id>.voip``), never the
        plain ``BUNDLE_ID`` -- Apple silently drops a VoIP push sent to the
        wrong topic.
      - ``apns-priority: 10`` (immediate) -- Apple requires every VoIP push
        use immediate priority; there is no "normal priority" option for
        this push type.
      - No ``aps.alert``/``aps.sound`` -- a VoIP push is never shown by the
        system as a notification. Receiving one is this app's contract to
        *immediately* report an incoming call to CallKit (an Apple App
        Review requirement with real enforcement behind it, not just a
        style preference) -- the ring UI itself comes from ``CXProvider``
        on the client, never from an ``aps.alert``.

    Reuses the same token-based JWT (``_apns_jwt()``) ``send_push`` uses
    rather than a second, VoIP-specific credential -- see
    ``validate_voip_config()``'s docstring for why that's correct rather
    than an oversight.

    Raises:
        APNsConfigError: If APNs is unconfigured, its credential file can't
            be read, or ``VOIP_APNS_TOPIC`` itself is unconfigured/malformed
            -- propagates rather than being swallowed, matching
            ``send_push``'s fail-fast posture (Security Posture Q14).
    """
    if not VOIP_APNS_TOPIC:
        # _apns_jwt()/validate_apns_config() already guard the shared JWT
        # credential; this guards the VoIP-specific topic the same way in
        # case validate_voip_config() was somehow never called at boot (e.g.
        # a test harness constructing this module directly) -- fails the
        # same loud way rather than sending a push Apple would just drop.
        raise APNsConfigError(
            "VOIP_APNS_TOPIC is not configured -- see validate_voip_config()."
        )
    token = _apns_jwt()

    headers = {
        "authorization": f"bearer {token}",
        "apns-push-type": "voip",
        "apns-topic": VOIP_APNS_TOPIC,
        "apns-priority": "10",
    }
    payload = {"aps": {}}
    payload.update(data)

    return await _post_to_apns(device_token, headers, payload)
