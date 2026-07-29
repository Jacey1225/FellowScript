"""Manual moderation CLI for the Guideline 1.2 report queue.

No self-service admin web UI exists yet (direct SSH/psql access already runs
this project day to day) — this script is the "act within 24 hours" tool the
content_report_email points at.

Usage (from api/, with the venv active):
    python -m backend.moderation.admin_actions list
    python -m backend.moderation.admin_actions resolve <report_id> --remove-content --eject
    python -m backend.moderation.admin_actions resolve <report_id> --dismiss
"""
import argparse
import sys
from datetime import datetime, timezone

from db import DBManager
from backend.auth.sessions import SessionManager


def list_open_reports() -> None:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT _id, reporter_id, reported_user_id, content_type, content_id, "
            "reason, created_at FROM content_reports WHERE status = 'open' ORDER BY created_at"
        )
        rows = db.cur.fetchall()
    finally:
        db.close()
    if not rows:
        print("No open reports.")
        return
    for _id, reporter_id, reported_user_id, content_type, content_id, reason, created_at in rows:
        print(f"{_id}  [{created_at}]  {content_type} (content_id={content_id})  "
              f"reason={reason}  reporter={reporter_id}  reported_user={reported_user_id}")


def _remove_content(db: DBManager, content_type: str, content_id: str | None) -> None:
    if content_type == "note" and content_id:
        db.cur.execute("DELETE FROM notes WHERE _id = %s", (content_id,))
    elif content_type == "message" and content_id:
        db.cur.execute("DELETE FROM messages WHERE _id = %s", (content_id,))
    elif content_type == "devotion_prompt" and content_id:
        db.cur.execute("UPDATE devotions SET prompts = '{}' WHERE _id = %s", (content_id,))
    elif content_type == "group_title" and content_id:
        db.cur.execute("UPDATE groups SET title = 'Group' WHERE _id = %s", (content_id,))
    # content_type == "user": nothing to remove, the report is about the account itself.
    db.conn.commit()


def _eject_user(db: DBManager, reported_user_id: str | None) -> None:
    if not reported_user_id:
        print("No reported_user_id on this report — cannot eject.", file=sys.stderr)
        return
    db.cur.execute(
        "UPDATE users SET suspended_at = %s WHERE _id = %s",
        (datetime.now(timezone.utc), reported_user_id),
    )
    db.conn.commit()
    # Kill any active session immediately — a suspension shouldn't wait for
    # the user's cookie to expire or for them to happen to log out.
    sm = SessionManager()
    try:
        sm.delete_all_for_user(reported_user_id)
    finally:
        sm.close()


def resolve(report_id: str, remove_content: bool, eject: bool, dismiss: bool) -> None:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT reported_user_id, content_type, content_id FROM content_reports WHERE _id = %s",
            (report_id,),
        )
        row = db.cur.fetchone()
        if not row:
            print(f"No report found with id {report_id}", file=sys.stderr)
            sys.exit(1)
        reported_user_id, content_type, content_id = row

        if dismiss:
            db.cur.execute(
                "UPDATE content_reports SET status = 'dismissed', resolved_at = %s WHERE _id = %s",
                (datetime.now(timezone.utc), report_id),
            )
            db.conn.commit()
            print(f"Report {report_id} dismissed.")
            return

        if remove_content:
            _remove_content(db, content_type, content_id)
            print(f"Removed {content_type} (content_id={content_id}).")
        if eject:
            _eject_user(db, str(reported_user_id) if reported_user_id else None)
            print(f"Suspended user {reported_user_id} and killed their active sessions.")

        db.cur.execute(
            "UPDATE content_reports SET status = 'actioned', resolved_at = %s WHERE _id = %s",
            (datetime.now(timezone.utc), report_id),
        )
        db.conn.commit()
        print(f"Report {report_id} marked actioned.")
    finally:
        db.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list", help="List all open reports.")

    resolve_parser = sub.add_parser("resolve", help="Resolve a report.")
    resolve_parser.add_argument("report_id")
    resolve_parser.add_argument("--remove-content", action="store_true", help="Delete/reset the offending content.")
    resolve_parser.add_argument("--eject", action="store_true", help="Suspend the reported user and kill their sessions.")
    resolve_parser.add_argument("--dismiss", action="store_true", help="Mark as dismissed (false positive) instead of acting.")

    args = parser.parse_args()
    if args.command == "list":
        list_open_reports()
    elif args.command == "resolve":
        resolve(args.report_id, args.remove_content, args.eject, args.dismiss)


if __name__ == "__main__":
    main()
