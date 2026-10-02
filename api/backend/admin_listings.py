"""Explorer listing moderation without a deploy: run inside the API container.

    docker exec fellowscript-api python -m backend.admin_listings hide <public_id> [--reason CODE]
    docker exec fellowscript-api python -m backend.admin_listings restore <public_id>
    docker exec fellowscript-api python -m backend.admin_listings hide-all

``hide-all`` is the documented rollback lever: every published or in-review
listing becomes ``hidden`` with reason ``bulk`` and the ``listing_hidden`` hooks
run (pending join requests expire). Each listing is its own transaction, so a
failure on one never leaves the rest half done; the exit code is non-zero if any
failed. Prints public ids, codes and counts only.

This is a separate process: ``load_all`` registers the lifecycle hooks first.
"""
from __future__ import annotations

import argparse
import sys

from db import DBManager


def _hide_one(db: DBManager, public_id: str, reason: str) -> None:
    from backend.interactions import listings

    listings.admin_hide(db.cur, public_id, "", reason)
    db.conn.commit()


def cmd_hide(public_id: str, reason: str) -> int:
    from backend.interactions.listing_content import ListingError

    db = DBManager()
    try:
        try:
            _hide_one(db, public_id, reason)
        except ListingError as e:
            db.conn.rollback()
            print(f"refused: {e.code}", file=sys.stderr)
            return 2
    finally:
        db.close()
    print(f"{public_id}\thidden\treason={reason}")
    return 0


def cmd_restore(public_id: str) -> int:
    from backend.interactions import listings
    from backend.interactions.listing_content import ListingError

    db = DBManager()
    try:
        try:
            result = listings.admin_restore(db.cur, public_id, "")
            db.conn.commit()
        except ListingError as e:
            db.conn.rollback()
            print(f"refused: {e.code}", file=sys.stderr)
            return 2
    finally:
        db.close()
    print(f"{public_id}\t{result['status']}")
    return 0


def cmd_hide_all() -> int:
    from backend.interactions import listings

    db = DBManager()
    hidden = failed = 0
    try:
        db.cur.execute(
            "SELECT public_id FROM group_listings WHERE status IN ('pending_review', 'published') ORDER BY public_id"
        )
        ids = [r[0] for r in db.cur.fetchall()]
        db.conn.rollback()
        for public_id in ids:
            try:
                _hide_one(db, public_id, listings.REASON_BULK)
                hidden += 1
            except Exception:  # noqa: BLE001 - keep going; report the count
                db.conn.rollback()
                failed += 1
    finally:
        db.close()
    print(f"hidden={hidden} failed={failed}")
    return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m backend.admin_listings")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_hide = sub.add_parser("hide", help="hide one listing by public id")
    p_hide.add_argument("public_id")
    p_hide.add_argument("--reason", default="other", help="a configured hide reason code (default: other)")
    p_restore = sub.add_parser("restore", help="restore a hidden listing")
    p_restore.add_argument("public_id")
    sub.add_parser("hide-all", help="rollback lever: hide every visible listing (reason bulk)")
    args = parser.parse_args(argv)

    from backend.registrations import load_all

    load_all()
    if args.cmd == "hide":
        return cmd_hide(args.public_id, args.reason)
    if args.cmd == "restore":
        return cmd_restore(args.public_id)
    return cmd_hide_all()


if __name__ == "__main__":
    sys.exit(main())
