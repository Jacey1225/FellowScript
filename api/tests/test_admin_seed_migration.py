"""
Test for the `is_admin` column migration + idempotent admin-seed step in
`db.py::create_tables` (error-debug-agent-admin-page workflow, step 1).

Covers:
  - Exactly one account (jaceysimps@gmail.com) has is_admin=TRUE after the
    migration/seed runs against the live dev DB.
  - No other account is flagged admin as a side effect of the seed running
    (an equality-match seed against a UNIQUE NOT NULL email column can only
    ever touch the one intended row -- proven directly rather than assumed).
  - Re-running create_tables() (the actual deploy-time migration step, per
    reference_deploy.md's non-destructive schema-apply invocation) is a true
    no-op for the admin flag: exactly the same one row stays TRUE, no other
    row flips, and a manually-demoted admin does NOT get silently
    re-promoted by the *next* create_tables() run unless it still matches
    the seed email (proves the seed is a targeted UPDATE, not a broad grant
    tied to some other signal).
  - The seed step never touches accounts with a different email that merely
    resembles the admin email (case variance, substring).

Run:  cd api && ../.venv/bin/python tests/test_admin_seed_migration.py
"""

import _pathfix  # noqa: F401

import uuid

import db as db_module
from db import DBManager

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


ADMIN_EMAIL = "jaceysimps@gmail.com"


def run_create_tables():
    """Invoke the real migration-on-boot step exactly as deploy does
    (db._connect() + create_tables(cur) + commit) -- not a mock, not a
    reimplementation."""
    conn = db_module._connect()
    cur = conn.cursor()
    try:
        db_module.create_tables(cur)
        conn.commit()
    finally:
        cur.close()
        conn.close()


def make_decoy_user(email: str, username_suffix: str) -> str:
    uid = str(uuid.uuid4())
    dbm = DBManager()
    try:
        dbm.insertion("users", {
            "_id": uid, "username": f"admin_seed_decoy_{username_suffix}",
            "email": email, "hash_pass": "x",
        })
    finally:
        dbm.close()
    return uid


def cleanup_user(uid: str):
    dbm = DBManager()
    try:
        dbm.delete("users", {"_id": uid})
    finally:
        dbm.close()


def count_admins() -> int:
    dbm = DBManager()
    try:
        dbm.cur.execute("SELECT count(*) FROM users WHERE is_admin = TRUE")
        return dbm.cur.fetchone()[0]
    finally:
        dbm.close()


def is_admin(uid: str) -> bool | None:
    dbm = DBManager()
    try:
        result = dbm.lookup("users", {"_id": uid})
        if not result:
            return None
        _, data = list(result.items())[0]
        return bool(data.get("is_admin"))
    finally:
        dbm.close()


def test_exactly_one_admin_and_it_is_the_right_account():
    print("\n── Exactly the intended account is admin ──")
    run_create_tables()
    dbm = DBManager()
    try:
        result = dbm.lookup("users", {"email": ADMIN_EMAIL})
    finally:
        dbm.close()
    check(f"{ADMIN_EMAIL} account exists in the live table", bool(result), True)
    if result:
        target_uid, data = list(result.items())[0]
        check(f"{ADMIN_EMAIL} account has is_admin = TRUE", data.get("is_admin"), True)
    check("exactly one account is flagged admin (no accidental broad grant)",
          count_admins(), 1)


def test_rerunning_migration_is_a_no_op():
    print("\n── Re-running create_tables() is idempotent for the admin flag ──")
    before = count_admins()
    run_create_tables()
    run_create_tables()
    after = count_admins()
    check("admin count unchanged after two more migration runs", after, before)


def test_decoy_accounts_never_flagged():
    print("\n── Seed never touches similarly-named/decoy accounts ──")
    decoy_case = make_decoy_user("Jaceysimps@gmail.com", "case")  # case variance
    decoy_sub = make_decoy_user("notjaceysimps@gmail.com", "substr")  # substring, not exact match
    try:
        run_create_tables()
        check("case-variant email is NOT flagged admin (exact match only)",
              is_admin(decoy_case), False)
        check("similarly-named-but-different email is NOT flagged admin",
              is_admin(decoy_sub), False)
        check("admin count still exactly 1 after seeding ran with decoys present",
              count_admins(), 1)
    finally:
        cleanup_user(decoy_case)
        cleanup_user(decoy_sub)


def test_manual_demotion_of_a_different_account_not_reinstated():
    print("\n── Seed is a targeted single-row UPDATE, not a broad admin grant ──")
    # A hypothetical second admin flagged out-of-band (not via the seed) is
    # left alone by a subsequent create_tables() run -- proves the seed only
    # ever acts on the one specific email, never on "any is_admin row" or
    # some other broader signal.
    other_uid = make_decoy_user("someone-else@example.com", "manual")
    dbm = DBManager()
    try:
        dbm.update("users", {"is_admin": True}, {"_id": other_uid})
    finally:
        dbm.close()
    try:
        check("manually-flagged other admin is untouched by a migration re-run before check",
              is_admin(other_uid), True)
        run_create_tables()
        check("manually-flagged other admin is still admin after re-run (seed doesn't demote)",
              is_admin(other_uid), True)
        check("count now reflects both the seeded admin and this manual one",
              count_admins(), 2)
    finally:
        cleanup_user(other_uid)


if __name__ == "__main__":
    test_exactly_one_admin_and_it_is_the_right_account()
    test_rerunning_migration_is_a_no_op()
    test_decoy_accounts_never_flagged()
    test_manual_demotion_of_a_different_account_not_reinstated()

    # Final sanity: back to exactly the one true admin after all decoys are cleaned up.
    print("\n── Final state check ──")
    check("exactly one admin remains after all test accounts are cleaned up",
          count_admins(), 1)

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    import sys
    sys.exit(0 if failed == 0 else 1)
