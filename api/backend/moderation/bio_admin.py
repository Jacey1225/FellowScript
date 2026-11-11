"""Admin removal of a reported user bio (task 20261030-user-profiles, D7).

A bio is reported through the existing user report (content_type ``user``), whose
registered remover has nothing to delete (the report is about the account), so
clearing a bio is its own explicit action rather than a side effect of resolving
any user report (block auto-reports are also ``user`` reports):

    python -m backend.moderation.bio_admin clear <user_id>

Suspending the user (``admin_actions resolve --eject``) already hides the whole
profile. The bio text is never printed or logged.
"""
from __future__ import annotations

import sys
import uuid

from db import DBManager


def clear_bio(cur, user_id: str) -> bool:
    """NULL the user's bio on ``cur``'s transaction (caller commits). True if a user row matched."""
    cur.execute("UPDATE users SET bio = NULL WHERE _id = %s", (user_id,))
    return cur.rowcount == 1


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] != "clear":
        print("usage: python -m backend.moderation.bio_admin clear <user_id>", file=sys.stderr)
        return 2
    try:
        uuid.UUID(argv[2])
    except ValueError:
        print("user_id must be a UUID", file=sys.stderr)
        return 2
    db = DBManager()
    try:
        ok = clear_bio(db.cur, argv[2])
        db.conn.commit()
    finally:
        db.close()
    print("Bio cleared." if ok else "No such user.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
