"""Regression tests for the APPLE_ALLOW_SANDBOX fail-fast config fix
(20260830-subscription-status-sandbox-investigation, backend step 1).

Background: this investigation started from a user report that their sandbox
StoreKit purchase reverted to "inactive" after refreshing the app. The final
diagnosis (see security.json / testing.json for this task) is that this is
EXPECTED Apple sandbox behavior (time-compressed renewal periods + a capped
renewal count causing AccountViewModel's legitimate stale-plan reconcile-and-
cancel to fire) -- not a persistence bug. No behavior bug was found or fixed.

Along the way, backend found one real (if unrelated) deviation from this
project's "no implicit defaults" configuration philosophy:
api/backend/subscription/apple_service.py's `_ALLOW_SANDBOX` used to read
`os.getenv("APPLE_ALLOW_SANDBOX", "true")`, i.e. silently default to the
*permissive* value (accept Sandbox transactions) if the operator ever forgot
to set the var. That was fixed to raise RuntimeError at import time instead,
forcing an explicit "true" or "false" choice.

This file proves:
  1. APPLE_ALLOW_SANDBOX unset -> importing apple_service raises RuntimeError
     (fail-fast/fail-closed: the process refuses to start rather than silently
     granting the permissive path).
  2. APPLE_ALLOW_SANDBOX="true" -> imports cleanly, sandbox transactions are
     accepted (today's intended/documented behavior preserved).
  3. APPLE_ALLOW_SANDBOX="false" -> imports cleanly, sandbox transactions are
     rejected (the flag actually still gates something, both ways).
  4. Regression: none of the above changes weaken the deny-by-default posture
     of is_accepted_environment() for "Production" (always allowed),
     "Xcode" (always denied -- this is the anti-fraud guard the whole
     investigation was scoped to never weaken), and absent/unknown/garbage
     environments (always denied), independent of APPLE_ALLOW_SANDBOX's value.

Run with: cd api && ../.venv/bin/python tests/test_apple_allow_sandbox_config.py
"""
import _pathfix  # noqa: F401

import importlib
import os

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def main():
    # First import needs a value present so the module loads at all -- this
    # mirrors how db.py's load_dotenv() already populates this var for every
    # real process boot (see .env in the repo root).
    original_value = os.environ.get("APPLE_ALLOW_SANDBOX")
    os.environ.setdefault("APPLE_ALLOW_SANDBOX", "true")

    from backend.subscription import apple_service

    try:
        print("=== 1. APPLE_ALLOW_SANDBOX unset -> import raises RuntimeError (fail-fast) ===")
        os.environ.pop("APPLE_ALLOW_SANDBOX", None)
        try:
            importlib.reload(apple_service)
            check("unset APPLE_ALLOW_SANDBOX raises RuntimeError on import", False,
                  "reload() succeeded instead of raising")
        except RuntimeError as e:
            check("unset APPLE_ALLOW_SANDBOX raises RuntimeError on import", True)
            check("error message names the var and gives no implicit default",
                  "APPLE_ALLOW_SANDBOX" in str(e) and "explicit" in str(e).lower(), str(e))

        print("\n=== 2. APPLE_ALLOW_SANDBOX=\"true\" -> imports cleanly, sandbox accepted ===")
        os.environ["APPLE_ALLOW_SANDBOX"] = "true"
        importlib.reload(apple_service)
        check("module reloads without error when explicitly \"true\"", True)
        check("is_accepted_environment(\"Sandbox\") is True when explicitly \"true\"",
              apple_service.is_accepted_environment("Sandbox") is True)
        check("is_accepted_environment(\"sandbox\") is case-insensitive",
              apple_service.is_accepted_environment("sandbox") is True)

        print("\n=== 3. APPLE_ALLOW_SANDBOX=\"false\" -> imports cleanly, sandbox rejected ===")
        os.environ["APPLE_ALLOW_SANDBOX"] = "false"
        importlib.reload(apple_service)
        check("module reloads without error when explicitly \"false\"", True)
        check("is_accepted_environment(\"Sandbox\") is False when explicitly \"false\"",
              apple_service.is_accepted_environment("Sandbox") is False)

        print("\n=== 4. Regression: deny-by-default posture unchanged regardless of the flag ===")
        for allow_value in ("true", "false"):
            os.environ["APPLE_ALLOW_SANDBOX"] = allow_value
            importlib.reload(apple_service)
            check(f"Production always accepted (APPLE_ALLOW_SANDBOX={allow_value})",
                  apple_service.is_accepted_environment("Production") is True)
            check(f"Xcode always rejected -- anti-fraud guard (APPLE_ALLOW_SANDBOX={allow_value})",
                  apple_service.is_accepted_environment("Xcode") is False)
            check(f"absent environment rejected (APPLE_ALLOW_SANDBOX={allow_value})",
                  apple_service.is_accepted_environment(None) is False)
            check(f"unknown/garbage environment rejected (APPLE_ALLOW_SANDBOX={allow_value})",
                  apple_service.is_accepted_environment("something-else") is False)
    finally:
        # Restore the real environment and leave the module in a good state
        # for any other test that might import it later in the same process.
        if original_value is None:
            os.environ.pop("APPLE_ALLOW_SANDBOX", None)
            os.environ["APPLE_ALLOW_SANDBOX"] = "true"  # keep module importable; matches repo .env
        else:
            os.environ["APPLE_ALLOW_SANDBOX"] = original_value
        importlib.reload(apple_service)

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        raise SystemExit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
