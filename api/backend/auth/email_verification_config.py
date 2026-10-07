"""Validated tunables for email-ownership verification
(``api/config/email_verification.json``, section ``email_verification``;
task 20261007-email-verification).

Loaded through the shared ``config_loader`` (every key required, unknown keys
and wrong types rejected, no implicit defaults), cached after first load.
``validate_email_verification_config()`` runs from ``startup_checks``.

``enabled`` ships ``false``. While false: no verification mail is sent, the
verify/resend endpoints answer a uniform 404, and no gate (Affiliates, promo
rewards) consults verification, so behavior is identical to before this
feature. Enabling it is a deliberate per-environment decision (it narrows who
can reach email-linked privileges) and needs Jacey's sign-off.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from backend.config_loader import ConfigSectionError, load_section

CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "email_verification.json"
SECTION = "email_verification"


@dataclass(frozen=True)
class EmailVerificationConfig:
    enabled: bool
    token_ttl_minutes: int
    resend_cooldown_seconds: int
    max_sends_per_day: int
    public_base_url: str
    verify_link_format: str
    rate_limit_verify: str
    rate_limit_resend: str
    rate_limit_status: str

    def verify_link(self, token: str) -> str:
        return (self.verify_link_format
                .replace("{base}", self.public_base_url.rstrip("/"))
                .replace("{token}", token))


_cfg: EmailVerificationConfig | None = None


def _err(msg: str) -> ConfigSectionError:
    return ConfigSectionError(f"email_verification.json[{SECTION}]: {msg}")


def _int(v, name: str, low: int, high: int) -> int:
    if isinstance(v, bool) or not isinstance(v, int) or v < low or v > high:
        raise _err(f"{name} must be an integer between {low} and {high}")
    return v


def _load() -> EmailVerificationConfig:
    raw = load_section(
        CONFIG_PATH, SECTION,
        required_keys=("enabled", "token_ttl_minutes", "resend_cooldown_seconds", "max_sends_per_day",
                       "public_base_url", "verify_link_format",
                       "rate_limit_verify", "rate_limit_resend", "rate_limit_status"),
        types={"enabled": bool, "token_ttl_minutes": int, "resend_cooldown_seconds": int,
               "max_sends_per_day": int, "public_base_url": str, "verify_link_format": str,
               "rate_limit_verify": str, "rate_limit_resend": str, "rate_limit_status": str},
        rate_keys=("rate_limit_verify", "rate_limit_resend", "rate_limit_status"),
    )
    base = raw["public_base_url"]
    if not re.fullmatch(r"https://[A-Za-z0-9.-]+(:\d+)?/?", base):
        raise _err("public_base_url must be an https origin")
    fmt = raw["verify_link_format"]
    if "{base}" not in fmt or "{token}" not in fmt:
        raise _err("verify_link_format must contain {base} and {token}")
    return EmailVerificationConfig(
        enabled=raw["enabled"],
        token_ttl_minutes=_int(raw["token_ttl_minutes"], "token_ttl_minutes", 5, 1440),
        resend_cooldown_seconds=_int(raw["resend_cooldown_seconds"], "resend_cooldown_seconds", 10, 3600),
        max_sends_per_day=_int(raw["max_sends_per_day"], "max_sends_per_day", 1, 50),
        public_base_url=base,
        verify_link_format=fmt,
        rate_limit_verify=raw["rate_limit_verify"],
        rate_limit_resend=raw["rate_limit_resend"],
        rate_limit_status=raw["rate_limit_status"],
    )


def get_email_verification_config() -> EmailVerificationConfig:
    global _cfg
    if _cfg is None:
        _cfg = _load()
    return _cfg


def validate_email_verification_config() -> None:
    """Startup check: reload uncached so a file edited since import is re-read."""
    global _cfg
    _cfg = _load()


def reset_for_tests() -> None:
    global _cfg
    _cfg = None
