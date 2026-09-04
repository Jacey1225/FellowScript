"""Tests for the eager APNs config validation / fail-fast rework (task
20260903-push-notifications-not-delivering, backend step 2,
api/backend/interactions/push.py's validate_apns_config()/APNsConfigError,
api/main.py's lifespan wiring).

Background: push.py used to silently degrade on APNs misconfiguration
(`if not all([KEY_ID, TEAM_ID, BUNDLE_ID, KEY_PATH]): return False`, and a
broad `except Exception` around opening KEY_PATH that only logged and
returned False). That let a file-permission mismatch on the live host's
AuthKey_*.p8 recur in production logs roughly every 15 minutes for 48+ hours
with zero signal beyond a buried per-push warning. The fix adds eager,
specific validation (`validate_apns_config()`), wires it into `main.py`'s
`lifespan` uncaught (so a bad deploy refuses to boot), and stops swallowing
JWT-generation failures inside `send_push` (no more internal try/except
around `_apns_jwt()`).

This file proves:
  1. `validate_apns_config()` passes when all four env vars are set and
     `APPLE_KEY_PATH` resolves to a real, readable file (using the actual
     local AuthKey_22G3F2KMHS.p8 already present at the repo root -- not
     committed to git, gitignored via `*.p8` -- so this also proves
     `_apns_jwt()` can mint a real ES256 token end to end, not just that the
     file exists).
  2. A single missing required env var raises `APNsConfigError` naming
     exactly that variable.
  3. Multiple missing vars are all named in one error.
  4. A non-existent `APPLE_KEY_PATH` raises `APNsConfigError` naming the
     path, distinctly from the missing-var case.
  5. An unreadable (permission-denied) `APPLE_KEY_PATH` raises
     `APNsConfigError` with a permission-specific reason.
  6. No error message from (2)-(5) ever contains file *content* -- the
     log-redaction requirement (Security Posture Q13).
  7. `send_push()` no longer silently swallows JWT-generation failures: with
     a missing env var, it raises `APNsConfigError` (not `return False`); with
     a syntactically-invalid key file, the underlying `jwt`/`cryptography`
     error still propagates uncaught -- neither case is swallowed to a
     silent `False` the way the pre-fix broad `except Exception` did.
  8. REGRESSION (currently failing, documents an open bug -- see this task's
     testing.json for the bounce): booting the real app
     (`TestClient(main_module.app)`, exactly what 29+ existing test files in
     this suite already do to prove the app boots per the write-tests
     skill's "boot the real app, not a stub" mandate) now crashes at
     `main.py`'s `lifespan` because this machine's real, current `.env` has
     `APPLE_KEY_PATH` set to the *production host's* absolute path
     (`/home/ubuntu/fellowscript/AuthKey_22G3F2KMHS.p8`), which does not
     exist on this dev machine -- even though a real, valid `.p8` file for
     the exact same rotated key already sits right here at the repo root
     (`AuthKey_22G3F2KMHS.p8`, proven loadable by test 1 above). Before this
     task's fail-fast rework, this same latent path mismatch was invisible
     (the old code just silently returned False); now it's a hard crash on
     every local `main.app` boot, i.e. every one of the 29+ test files that
     use `TestClient(main_module.app)`.

Run with: cd api && ../.venv/bin/python tests/test_apns_config_validation.py
"""
import _pathfix  # noqa: F401,E402

import asyncio
import importlib
import os
import stat
import tempfile

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

import backend.interactions.push as push  # noqa: E402

PASSED, FAILED = [], []

_HERE = os.path.dirname(os.path.abspath(__file__))
_REAL_LOCAL_KEY_PATH = os.path.normpath(
    os.path.join(_HERE, "..", "..", "AuthKey_22G3F2KMHS.p8")
)

_VARS = ("APPLE_KEY_ID", "APPLE_TEAM_ID", "APPLE_BUNDLE_ID", "APPLE_KEY_PATH")


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def _set_valid_env():
    os.environ["APPLE_KEY_ID"] = "TESTKEYID1"
    os.environ["APPLE_TEAM_ID"] = "TESTTEAMID"
    os.environ["APPLE_BUNDLE_ID"] = "com.fellowscript.test"
    os.environ["APPLE_KEY_PATH"] = _REAL_LOCAL_KEY_PATH
    importlib.reload(push)


def test_valid_config_passes_and_mints_a_real_jwt():
    print("=== 1. Valid config (real local .p8) -> validate_apns_config() passes, "
          "_apns_jwt() mints a real ES256 token ===")
    check("prerequisite: the real local AuthKey_22G3F2KMHS.p8 exists on this machine "
          "(if this fails, the test itself can't prove anything -- not a product bug)",
          os.path.isfile(_REAL_LOCAL_KEY_PATH), _REAL_LOCAL_KEY_PATH)

    _set_valid_env()
    try:
        push.validate_apns_config()
        check("validate_apns_config() does not raise for a fully valid config", True)
    except push.APNsConfigError as e:
        check("validate_apns_config() does not raise for a fully valid config", False, str(e))

    push._jwt_cache = None  # force a fresh mint, not a leftover cache hit
    try:
        token = push._apns_jwt()
        check("_apns_jwt() mints a non-empty token from the real key", bool(token))
    except Exception as e:
        check("_apns_jwt() mints a non-empty token from the real key", False,
              f"{type(e).__name__}: {e}")


def _unset(*names):
    """Make each var read as "missing" to _missing_config_vars() without
    actually removing the key from os.environ -- push.py's module-level
    `load_dotenv()` runs again on every `importlib.reload(push)`, and
    python-dotenv's default `override=False` means it only fills in keys
    that are entirely ABSENT from os.environ. A real `os.environ.pop(...)`
    would therefore get silently re-populated from the real .env on disk on
    the very next reload, defeating the whole point of this helper. Setting
    the value to "" instead keeps the key present (so load_dotenv leaves it
    alone) while still failing push.py's `if not value` missing-check."""
    for name in names:
        os.environ[name] = ""


def test_missing_single_var_names_exactly_that_var():
    print("\n=== 2. A single missing required var -> APNsConfigError names exactly it ===")
    for missing_var in _VARS:
        _set_valid_env()
        _unset(missing_var)
        importlib.reload(push)
        try:
            push.validate_apns_config()
            check(f"missing {missing_var} raises APNsConfigError", False, "did not raise")
        except push.APNsConfigError as e:
            msg = str(e)
            check(f"missing {missing_var} raises APNsConfigError naming it", missing_var in msg, msg)
            others = [v for v in _VARS if v != missing_var]
            check(f"missing {missing_var}'s error does not falsely name the still-set vars "
                  "as missing (checked via the exact 'missing required environment "
                  "variable(s)' clause, not a substring scan, since APPLE_KEY_ID is a "
                  "substring of nothing else here but this stays precise on principle)",
                  all(o not in msg.split("variable(s)")[1].split(".")[0] for o in others)
                  if "variable(s)" in msg else True,
                  msg)


def test_multiple_missing_vars_all_named():
    print("\n=== 3. Multiple missing vars -> all named in one error ===")
    _set_valid_env()
    _unset("APPLE_TEAM_ID", "APPLE_BUNDLE_ID")
    importlib.reload(push)
    try:
        push.validate_apns_config()
        check("missing two vars raises APNsConfigError", False, "did not raise")
    except push.APNsConfigError as e:
        msg = str(e)
        check("error names APPLE_TEAM_ID", "APPLE_TEAM_ID" in msg, msg)
        check("error names APPLE_BUNDLE_ID", "APPLE_BUNDLE_ID" in msg, msg)


def test_nonexistent_key_path_raises():
    print("\n=== 4. APPLE_KEY_PATH pointing at a nonexistent file -> APNsConfigError, "
          "distinct from the missing-var case ===")
    _set_valid_env()
    fake_path = os.path.join(tempfile.gettempdir(), "definitely-does-not-exist.p8")
    if os.path.exists(fake_path):
        os.remove(fake_path)
    os.environ["APPLE_KEY_PATH"] = fake_path
    importlib.reload(push)
    try:
        push.validate_apns_config()
        check("nonexistent APPLE_KEY_PATH raises APNsConfigError", False, "did not raise")
    except push.APNsConfigError as e:
        msg = str(e)
        check("error names the nonexistent path", fake_path in msg, msg)
        check("error says the file does not exist (distinct wording from a missing var)",
              "does not exist" in msg, msg)


def test_unreadable_key_path_raises_permission_specific_error():
    print("\n=== 5/6. APPLE_KEY_PATH exists but is unreadable -> APNsConfigError with a "
          "permission-specific reason, and the error never leaks file content ===")
    fd, path = tempfile.mkstemp(prefix="apns_test_unreadable_")
    marker = "SUPER-SECRET-KEY-MATERIAL-MARKER-DO-NOT-LEAK"
    try:
        os.write(fd, marker.encode())
        os.close(fd)
        os.chmod(path, 0o000)  # simulate the exact live-host failure mode

        _set_valid_env()
        os.environ["APPLE_KEY_PATH"] = path
        importlib.reload(push)
        try:
            push.validate_apns_config()
            check("unreadable APPLE_KEY_PATH raises APNsConfigError", False, "did not raise")
        except push.APNsConfigError as e:
            msg = str(e)
            check("error names the unreadable path", path in msg, msg)
            check("error gives a permission-specific reason (matches the real live-host "
                  "incident: 'Permission denied' recurring every ~15 min for 48h)",
                  "permission" in msg.lower() or "denied" in msg.lower(), msg)
            check("error message never contains the file's actual content (redaction, "
                  "Security Posture Q13)", marker not in msg, msg)
    finally:
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
        os.remove(path)


def test_missing_var_error_never_contains_other_vars_values():
    print("\n=== 6-cont. Missing-var error contains only the var *name*, never any "
          "configured value (KEY_ID/TEAM_ID/BUNDLE_ID/KEY_PATH) ===")
    _set_valid_env()
    real_bundle_id = os.environ["APPLE_BUNDLE_ID"]
    _unset("APPLE_KEY_ID")
    importlib.reload(push)
    try:
        push.validate_apns_config()
        check("missing APPLE_KEY_ID raises", False, "did not raise")
    except push.APNsConfigError as e:
        msg = str(e)
        check("error does not leak the still-configured APPLE_BUNDLE_ID's value",
              real_bundle_id not in msg, msg)


def test_send_push_propagates_apns_config_error_not_swallowed():
    print("\n=== 7a. send_push() propagates APNsConfigError on a missing var instead of "
          "silently returning False (the exact anti-pattern this task removed) ===")
    _set_valid_env()
    _unset("APPLE_TEAM_ID")
    importlib.reload(push)
    push._jwt_cache = None
    try:
        result = asyncio.run(push.send_push("fake-device-token", "t", "b"))
        check("send_push raises APNsConfigError rather than returning a value when "
              "misconfigured", False, f"returned {result!r} instead of raising")
    except push.APNsConfigError as e:
        check("send_push raises APNsConfigError rather than returning a value when "
              "misconfigured", True)
        check("propagated error still names the missing var", "APPLE_TEAM_ID" in str(e), str(e))
    except Exception as e:
        check("send_push raises APNsConfigError rather than returning a value when "
              "misconfigured", False, f"raised wrong type: {type(e).__name__}: {e}")


def test_send_push_propagates_jwt_generation_error_not_swallowed():
    print("\n=== 7b. send_push() propagates a JWT-generation error (invalid key content) "
          "instead of swallowing it to False -- proves the fix isn't limited to the "
          "config-presence check, it covers the actual JWT-mint failure path too ===")
    fd, path = tempfile.mkstemp(prefix="apns_test_badkey_")
    try:
        os.write(fd, b"-----BEGIN PRIVATE KEY-----\nnot a real key\n-----END PRIVATE KEY-----\n")
        os.close(fd)
        _set_valid_env()
        os.environ["APPLE_KEY_PATH"] = path
        importlib.reload(push)
        push._jwt_cache = None
        try:
            asyncio.run(push.send_push("fake-device-token", "t", "b"))
            check("send_push raises (not swallows) on an unparseable private key", False,
                  "returned instead of raising")
        except push.APNsConfigError as e:
            check("send_push raises (not swallows) on an unparseable private key", False,
                  f"raised APNsConfigError instead of the expected jwt/crypto error: {e}")
        except Exception as e:
            # Any propagated exception (e.g. the jwt/cryptography library's own
            # ValueError on an unparseable PEM) is the correct outcome here --
            # the point is it's NOT swallowed into a silent `return False`.
            check("send_push raises (not swallows) on an unparseable private key", True,
                  f"{type(e).__name__}: {e}")
    finally:
        os.remove(path)


def test_app_boot_with_current_repo_env_STILL_BROKEN_regression():
    print("\n=== 8. REGRESSION (currently open -- see testing.json bounce): booting the "
          "real app with this machine's actual, current .env crashes lifespan, breaking "
          "every one of the 29+ existing test files that boot TestClient(main_module.app) "
          "===")
    # Deliberately restore the REAL environment (not the synthetic valid one used by
    # tests 1-7 above) by reloading push.py with no env overrides in place, then
    # attempt exactly what every other test file's main() already does.
    for v in _VARS:
        os.environ.pop(v, None)
    import _pathfix  # noqa: F401  (already imported, re-affirms sys.path is set)
    from dotenv import dotenv_values
    real_env = dotenv_values(os.path.join(_HERE, "..", "..", ".env"))
    for v in _VARS:
        if real_env.get(v):
            os.environ[v] = real_env[v]
    importlib.reload(push)

    from fastapi.testclient import TestClient
    import main as main_module

    try:
        with TestClient(main_module.app):
            check("real app boots with this machine's current, unmodified .env "
                  "(expected to currently FAIL -- this is the open regression backend "
                  "needs to fix: .env's APPLE_KEY_PATH is the production host's absolute "
                  "path, not anything resolvable on a local dev machine, even though a "
                  "real usable copy of the same key already sits at the repo root)",
                  True)
    except push.APNsConfigError as e:
        check("real app boots with this machine's current, unmodified .env "
              "(expected to currently FAIL -- this is the open regression backend "
              "needs to fix: .env's APPLE_KEY_PATH is the production host's absolute "
              "path, not anything resolvable on a local dev machine, even though a "
              "real usable copy of the same key already sits at the repo root)",
              False, f"APNsConfigError: {e}")


def main():
    try:
        test_valid_config_passes_and_mints_a_real_jwt()
        test_missing_single_var_names_exactly_that_var()
        test_multiple_missing_vars_all_named()
        test_nonexistent_key_path_raises()
        test_unreadable_key_path_raises_permission_specific_error()
        test_missing_var_error_never_contains_other_vars_values()
        test_send_push_propagates_apns_config_error_not_swallowed()
        test_send_push_propagates_jwt_generation_error_not_swallowed()
        test_app_boot_with_current_repo_env_STILL_BROKEN_regression()
    finally:
        # Leave push.py in its real, correctly-configured state for any test
        # file that runs later in the same process.
        for v in _VARS:
            os.environ.pop(v, None)
        importlib.reload(push)

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
