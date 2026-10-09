"""Unit coverage for task 20261008-content-encryption-at-rest: the crypto core
(backend/content_crypto.py), the seal/open helper (backend/content_store.py),
the tunables loader (backend/content_config.py) and the boot-time wiring
(backend/startup_checks.py). No database is touched.

Proves: AES-256-GCM round trip (unicode, long, empty-safe); per-write random
nonce; AAD binds table, column AND row id (wrong row / wrong field / wrong table
all fail); tamper (flipped bit, truncation, bad base64, wrong marker payload);
wrong key; unknown key id; multi-key ring decrypt of old ciphertext + new writes
on the first key; malformed / missing / short / duplicate / out-of-range config
refuses to boot with a message free of key material; the enc:v1:/enc:p: markers
make plaintext vs ciphertext unambiguous (plaintext that merely starts with
'enc:' is escaped, never mistaken for ciphertext); decrypt failures are fail
closed and the error carries ONLY field + row id + key id (no plaintext, no
ciphertext, no key bytes); seal() obeys the write flag and fails closed to
plaintext; content config validation.

Run with: cd api && ../.venv/bin/python tests/test_content_crypto.py
"""
import _pathfix  # noqa: F401

import base64
import copy
import json
import os
import sys
import tempfile
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

K1_RAW, K2_RAW, K3_RAW = b"A" * 32, b"B" * 32, b"C" * 32
K1, K2, K3 = (base64.b64encode(k).decode() for k in (K1_RAW, K2_RAW, K3_RAW))

from backend import content_crypto as cc  # noqa: E402
from backend import content_store as cs  # noqa: E402

PASSED, FAILED = [], []


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def set_ring(value):
    if value is None:
        os.environ.pop(cc.ENV_VAR, None)
    else:
        os.environ[cc.ENV_VAR] = value


def raises(exc, fn, *a, **k):
    try:
        fn(*a, **k)
    except exc as e:
        return e
    except Exception as e:  # wrong type
        return None
    return None


ROW = str(uuid.uuid4())
F_TEXT, F_TITLE = cs.F_NOTE_TEXT, cs.F_NOTE_TITLE
SECRET_TEXT = "Dear God, my private prayer 🙏 about Jordan and the diagnosis"


def main():
    set_ring(f"1:{K1}")

    print("=== round trip / markers / nonce ===")
    ct = cc.encrypt_field(ROW, F_TEXT, SECRET_TEXT)
    check("ciphertext carries enc:v1: marker", ct.startswith("enc:v1:"), ct[:12])
    check("ciphertext does not contain the plaintext", "prayer" not in ct and "Jordan" not in ct)
    check("round trip returns original (unicode)", cc.decrypt_field(ROW, F_TEXT, ct) == SECRET_TEXT)
    long_text = "x" * 200_000
    check("round trip large text", cc.decrypt_field(ROW, F_TEXT, cc.encrypt_field(ROW, F_TEXT, long_text)) == long_text)
    ct2 = cc.encrypt_field(ROW, F_TEXT, SECRET_TEXT)
    check("fresh random nonce per write (two ciphertexts differ)", ct != ct2)
    check("is_ciphertext classifies correctly", cc.is_ciphertext(ct) and not cc.is_ciphertext("hello") and not cc.is_ciphertext(None))
    check("upper-case row id (UUID text form) decrypts the same",
          cc.decrypt_field(ROW.upper(), F_TEXT, ct) == SECRET_TEXT)

    print("\n=== AAD binds row id, column and table ===")
    other_row = str(uuid.uuid4())
    e = raises(cc.ContentDecryptError, cc.decrypt_field, other_row, F_TEXT, ct)
    check("wrong row id -> ContentDecryptError (no cross-row replay)", e is not None)
    e = raises(cc.ContentDecryptError, cc.decrypt_field, ROW, F_TITLE, ct)
    check("wrong column (notes.title vs notes.text) -> ContentDecryptError", e is not None)
    e = raises(cc.ContentDecryptError, cc.decrypt_field, ROW, cs.F_MESSAGE_TEXT, ct)
    check("wrong table (messages.text vs notes.text) -> ContentDecryptError", e is not None)
    e = raises(cc.ContentDecryptError, cs.open_, other_row, F_TEXT, ct)
    check("content_store.open_ also fails closed on a swapped row", e is not None)

    print("\n=== tamper / malformed ciphertext ===")
    body = ct[len("enc:v1:"):]
    raw = bytearray(base64.urlsafe_b64decode(body))
    flipped = bytes(raw[:-1] + bytes([raw[-1] ^ 1]))
    tampered_tag = "enc:v1:" + base64.urlsafe_b64encode(flipped).decode()
    check("flipped tag bit -> ContentDecryptError", raises(cc.ContentDecryptError, cc.decrypt_field, ROW, F_TEXT, tampered_tag) is not None)
    mid = bytearray(raw)
    mid[20] ^= 0x40
    tampered_body = "enc:v1:" + base64.urlsafe_b64encode(bytes(mid)).decode()
    check("flipped ciphertext bit -> ContentDecryptError", raises(cc.ContentDecryptError, cc.decrypt_field, ROW, F_TEXT, tampered_body) is not None)
    trunc = "enc:v1:" + base64.urlsafe_b64encode(bytes(raw[:10])).decode()
    check("truncated blob -> ContentDecryptError", raises(cc.ContentDecryptError, cc.decrypt_field, ROW, F_TEXT, trunc) is not None)
    for bad in ("enc:v1:", "enc:v1:@@@@", "enc:v1:" + "A" * 3):
        check(f"garbage after marker ({bad[:12]!r}) -> ContentDecryptError",
              raises(cc.ContentDecryptError, cc.open_value, ROW, F_TEXT, bad) is not None)

    print("\n=== wrong key / unknown key id / rotation ===")
    set_ring(f"1:{K2}")
    e = raises(cc.ContentDecryptError, cc.decrypt_field, ROW, F_TEXT, ct)
    check("same key id, different key material -> ContentDecryptError", e is not None)
    set_ring(f"2:{K2}")
    e = raises(cc.ContentDecryptError, cc.decrypt_field, ROW, F_TEXT, ct)
    check("ring without the ciphertext's key id -> ContentDecryptError (unknown key id)",
          e is not None and e.key_id == 1 and "unknown key id" in str(e), str(e))
    set_ring(f"2:{K2},1:{K1}")
    check("rotation: new current key (2) still decrypts old key-1 ciphertext", cc.decrypt_field(ROW, F_TEXT, ct) == SECRET_TEXT)
    new_ct = cc.encrypt_field(ROW, F_TEXT, SECRET_TEXT)
    check("rotation: new writes use the FIRST (current) key id", cc.key_id_of(new_ct) == 2 and cc.current_key_id() == 2)
    check("key_id_of on old ciphertext reports 1", cc.key_id_of(ct) == 1)
    set_ring(f"1:{K1}")
    e = raises(cc.ContentDecryptError, cc.decrypt_field, ROW, F_TEXT, new_ct)
    check("after dropping key 2, key-2 ciphertext is unreadable (key loss = data loss, fail closed)", e is not None and e.key_id == 2)

    print("\n=== dual read: plaintext, escaped plaintext, ciphertext ===")
    set_ring(f"1:{K1}")
    check("plain text passes through unchanged", cs.open_(ROW, F_TEXT, "just a note") == "just a note")
    check("None passes through", cs.open_(ROW, F_TEXT, None) is None)
    check("empty string passes through", cs.open_(ROW, F_TEXT, "") == "")
    esc = cc.escape_plain("enc:v1:looks like ciphertext but is the user's text")
    check("plaintext starting with 'enc:' is escaped on write", esc.startswith("enc:p:"))
    check("escaped plaintext reads back verbatim (never treated as ciphertext)",
          cs.open_(ROW, F_TEXT, esc) == "enc:v1:looks like ciphertext but is the user's text")
    check("plaintext not starting with enc: is not escaped", cc.escape_plain("hello") == "hello")
    check("'enc:' alone round-trips via escape", cs.open_(ROW, F_TEXT, cc.escape_plain("enc:")) == "enc:")
    check("user plaintext 'enc:v1:xxxx' does NOT raise when stored escaped",
          raises(cc.ContentDecryptError, cs.open_, ROW, F_TEXT, esc) is None)
    check("an UNescaped 'enc:v1:' value is ciphertext, fail closed (no heuristic fallback to plaintext)",
          raises(cc.ContentDecryptError, cs.open_, ROW, F_TEXT, "enc:v1:notreal") is not None)

    print("\n=== decrypt errors never leak content, ciphertext or key ===")
    leaks = []
    for label, fn in (
        ("wrong row", lambda: cc.decrypt_field(other_row, F_TEXT, ct)),
        ("tamper", lambda: cc.decrypt_field(ROW, F_TEXT, tampered_tag)),
        ("garbage", lambda: cc.decrypt_field(ROW, F_TEXT, "enc:v1:@@@@")),
    ):
        try:
            fn()
        except cc.ContentDecryptError as e:
            msg = f"{e} {e!r} {e.args}"
            for needle in (SECRET_TEXT, "prayer", ct[7:30], tampered_tag[7:30], K1, base64.b64encode(K1_RAW).decode(), "AAAAAAAA"):
                if needle in msg:
                    leaks.append((label, needle[:12]))
            ok_shape = e.field == F_TEXT and e.key_id in (1, None)
            if not ok_shape:
                leaks.append((label, "shape"))
    check("error text carries only field/row/key id (no plaintext, ciphertext or key bytes)", not leaks, str(leaks))
    e = raises(cc.ContentDecryptError, cc.decrypt_field, other_row, F_TEXT, ct)
    check("ContentDecryptError exposes field, row_id, key_id attributes",
          e is not None and e.field == F_TEXT and e.row_id == other_row and e.key_id == 1)
    check("the exception chain does not retain the cryptography InvalidTag context", e is not None and e.__cause__ is None)

    print("\n=== malformed / missing config refuses to boot ===")
    bad_configs = {
        "unset": None,
        "empty": "   ",
        "no colon": K1,
        "non-numeric id": f"x:{K1}",
        "id zero": f"0:{K1}",
        "id 256": f"256:{K1}",
        "bad base64": "1:not*base64*!!",
        "short key": "1:" + base64.b64encode(b"short").decode(),
        "long key": "1:" + base64.b64encode(b"Z" * 33).decode(),
        "duplicate id": f"1:{K1},1:{K2}",
        "trailing empty entry": f"1:{K1},",
        "empty key": "1:",
    }
    for label, value in bad_configs.items():
        set_ring(value)
        e = raises(cc.ContentKeyConfigError, cc.validate_content_keys)
        msg = str(e) if e else ""
        has_key = any(k in msg for k in (K1, K2, "AAAAAAAAAAAAAAAA", "Z" * 20))
        check(f"config '{label}' -> ContentKeyConfigError without key material", e is not None and not has_key, msg)
    set_ring(f"1:{K1}")
    check("encrypt with unset ring raises ContentKeyConfigError (no implicit default)",
          (set_ring(None) or raises(cc.ContentKeyConfigError, cc.encrypt_field, ROW, F_TEXT, "x")) is not None)
    set_ring(f"1:{K1}")
    check("good single-key config validates", raises(Exception, cc.validate_content_keys) is None and cc.validate_content_keys() is None)
    set_ring(f"2:{K2},1:{K1},3:{K3}")
    check("good multi-key ring validates; first entry is current", cc.validate_content_keys() is None and cc.current_key_id() == 2)
    set_ring(f"1:{K1}")
    # ring missing while decrypting existing ciphertext -> ContentDecryptError, not a config crash leaking
    set_ring(None)
    e = raises(cc.ContentDecryptError, cc.decrypt_field, ROW, F_TEXT, ct)
    check("decrypt with the key ring missing fails closed as ContentDecryptError", e is not None, str(e))
    set_ring(f"1:{K1}")

    print("\n=== boot wiring: startup_checks ===")
    import backend.startup_checks as sc  # noqa: E402
    names = [f.__name__ for f in sc.CHECKS]
    check("startup_checks registers content key + config checks",
          "check_content_encryption_keys" in names and "check_content_encryption_config" in names, str(names))
    set_ring(None)
    e = raises(Exception, sc.check_content_encryption_keys)
    check("check_content_encryption_keys fails when CONTENT_ENCRYPTION_KEYS is unset", isinstance(e, cc.ContentKeyConfigError), repr(e))
    set_ring(f"1:{K1}")
    check("check_content_encryption_keys passes with a valid ring", raises(Exception, sc.check_content_encryption_keys) is None)
    check("check_content_encryption_config passes with the shipped config", raises(Exception, sc.check_content_encryption_config) is None)
    set_ring(None)
    e = raises(Exception, sc.validate_all)
    check("startup_checks.validate_all refuses to boot without the key ring (message free of key material)",
          isinstance(e, cc.ContentKeyConfigError) or (e is not None and "CONTENT_ENCRYPTION_KEYS" in str(e)), repr(e))
    set_ring("1:" + base64.b64encode(b"short").decode())
    e = raises(Exception, sc.validate_all)
    check("validate_all refuses a malformed ring", e is not None and base64.b64encode(b"short").decode() not in str(e), repr(e))
    set_ring(f"1:{K1}")

    print("\n=== content_store.seal: flag gating, fail closed ===")
    orig = cs.writes_enabled
    try:
        cs.writes_enabled = lambda: False
        v = cs.seal(ROW, F_TEXT, "plain note")
        check("flag OFF: seal stores plaintext", v == "plain note")
        check("flag OFF: seal escapes enc:-prefixed plaintext", cs.seal(ROW, F_TEXT, "enc:v1:abc").startswith("enc:p:"))
        cs.writes_enabled = lambda: True
        v = cs.seal(ROW, F_TEXT, "plain note")
        check("flag ON: seal stores enc:v1: ciphertext", v.startswith("enc:v1:") and "plain note" not in v)
        check("flag ON: sealed value opens back to the original", cs.open_(ROW, F_TEXT, v) == "plain note")
        check("seal leaves None and '' alone (flag ON)", cs.seal(ROW, F_TEXT, None) is None and cs.seal(ROW, F_TEXT, "") == "")
        check("seal(force=True) encrypts even with the flag OFF", (setattr(cs, "writes_enabled", lambda: False) or cs.seal(ROW, F_TEXT, "t", force=True)).startswith("enc:v1:"))
        check("seal(force=False) never encrypts even with the flag ON", (setattr(cs, "writes_enabled", lambda: True) or cs.seal(ROW, F_TEXT, "t", force=False)) == "t")
        cs.writes_enabled = lambda: True
        sv = cs.seal_values("notes", {"_id": ROW, "title": "T", "text": "B", "public": False})
        check("seal_values seals title+text, leaves other columns", sv["title"].startswith("enc:v1:") and sv["text"].startswith("enc:v1:") and sv["public"] is False)
        check("seal_values on an out-of-scope table is a no-op", cs.seal_values("users", {"username": "x"}) == {"username": "x"})
        check("seal_values refuses a sealed column with no row id (programming error, not guessed)",
              raises(ValueError, cs.seal_values, "notes", {"title": "T"}) is not None)
        opened = cs.open_row("notes", ROW, sv)
        check("open_row restores sealed columns", opened["title"] == "T" and opened["text"] == "B")
    finally:
        cs.writes_enabled = orig

    # the real writes_enabled fails closed to False when flags cannot be read
    import backend.interactions.flags as flags  # noqa: E402
    real_is_enabled = flags.is_enabled
    try:
        def boom(*a, **k):
            raise RuntimeError("db down")
        flags.is_enabled = boom
        check("writes_enabled() fails closed (False) when the flag read raises", cs.writes_enabled() is False)
    finally:
        flags.is_enabled = real_is_enabled

    print("\n=== open_or_none: best-effort reads log only ids ===")
    import logging
    records = []

    class H(logging.Handler):
        def emit(self, r):
            records.append(r.getMessage())

    h = H()
    logging.getLogger("backend.content_store").addHandler(h)
    try:
        out = cs.open_or_none(other_row, F_TEXT, ct, label="preview")
    finally:
        logging.getLogger("backend.content_store").removeHandler(h)
    joined = " ".join(records)
    check("open_or_none returns '' for an undecryptable row (never ciphertext)", out == "")
    check("open_or_none logs field + row id, no ciphertext/plaintext/key",
          F_TEXT in joined and other_row in joined and ct[7:30] not in joined and SECRET_TEXT not in joined and K1 not in joined, joined)

    print("\n=== registry sanity ===")
    check("every field constant in ALL_FIELDS is '<table>.<column>' and registered in TABLE_COLUMNS",
          all(f in {fld for cols in cs.TABLE_COLUMNS.values() for fld in cols.values()} for f in cs.ALL_FIELDS))
    check("registry field names match their table.column",
          all(fld == f"{t}.{c}" for t, cols in cs.TABLE_COLUMNS.items() for c, fld in cols.items()))

    print("\n=== content config validation ===")
    from backend import content_config as ccfg  # noqa: E402
    base = json.load(open(ccfg.CONFIG_PATH))
    check("shipped config loads and exposes tunables", ccfg.get_content_config().search_scan_cap > 0 and ccfg.get_content_config().backfill_batch_size > 0)

    def load_with(mut):
        data = copy.deepcopy(base)
        mut(data["content_encryption"])
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            path = f.name
        old = ccfg.CONFIG_PATH
        ccfg.CONFIG_PATH = type(old)(path)
        try:
            return raises(Exception, ccfg._load), None
        finally:
            ccfg.CONFIG_PATH = old
            os.unlink(path)

    for label, mut in (
        ("missing key", lambda s: s.pop("search_scan_cap")),
        ("unknown key", lambda s: s.__setitem__("surprise", 1)),
        ("wrong type", lambda s: s.__setitem__("search_batch_size", "200")),
        ("zero batch", lambda s: s.__setitem__("backfill_batch_size", 0)),
        ("negative throttle", lambda s: s.__setitem__("backfill_throttle_ms", -1)),
        ("batch over max", lambda s: s.__setitem__("search_batch_size", 10_000_000)),
        ("scan cap over max", lambda s: s.__setitem__("group_search_scan_cap", 10_000_000)),
    ):
        err, _ = load_with(mut)
        check(f"config rejects {label}", err is not None, "accepted")
    err, _ = load_with(lambda s: s.__setitem__("backfill_throttle_ms", 0))
    check("config accepts throttle 0 (valid floor)", err is None, repr(err))

    print(f"\n{'=' * 60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        sys.exit(1)
    print(f"RESULT: {len(PASSED)} passed, 0 failed")


if __name__ == "__main__":
    main()
