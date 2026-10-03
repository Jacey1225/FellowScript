"""One-off: give legacy ownerless groups a creator.

``groups.creator_id`` was added after the first groups existed, so those rows
have NULL (and so never show up as "owned" for Explore listing, join requests
or creator-only actions). ``create_group`` always put the creator first in
``groups.users``, so for a legacy group the first member that is a live user is
the creator. This sets ``creator_id`` to that member for groups where it is NULL.

Run by the operator, never automatically:

    docker exec fellowscript-api python -m backend.maintenance.backfill_group_creators          # dry run
    docker exec fellowscript-api python -m backend.maintenance.backfill_group_creators --apply

The default is a DRY RUN that prints counts only. Groups that already have a
creator are never touched; groups with no live member are left as they are.
Re-running is a no-op.
"""
import argparse

from db import DBManager

_FIRST_LIVE = (
    "SELECT u._id FROM unnest(g.users) WITH ORDINALITY AS m(member_id, ord) "
    "JOIN users u ON u._id::text = lower(m.member_id) ORDER BY m.ord LIMIT 1"
)

_COUNTS_SQL = f"""
SELECT
  count(*) FILTER (WHERE g.creator_id IS NULL)                              AS ownerless,
  count(*) FILTER (WHERE g.creator_id IS NULL AND ({_FIRST_LIVE}) IS NOT NULL) AS fixable
FROM groups g
"""

_APPLY_SQL = f"""
UPDATE groups g SET creator_id = ({_FIRST_LIVE})
WHERE g.creator_id IS NULL AND ({_FIRST_LIVE}) IS NOT NULL
"""


def backfill(apply: bool) -> dict[str, int]:
    db = DBManager()
    try:
        db.cur.execute(_COUNTS_SQL)
        ownerless, fixable = db.cur.fetchone()
        result = {"groups_without_creator": int(ownerless), "groups_fixable": int(fixable)}
        if apply:
            db.cur.execute(_APPLY_SQL)
            result["groups_updated"] = db.cur.rowcount
            db.conn.commit()
        else:
            db.conn.rollback()
        return result
    except Exception:
        db.conn.rollback()
        raise
    finally:
        db.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--apply", action="store_true",
                        help="Set creator_id (default is a dry run that changes nothing).")
    args = parser.parse_args()
    result = backfill(args.apply)
    print("APPLIED" if args.apply else "DRY RUN (nothing changed)")
    for key, value in result.items():
        print(f"{key}={value}")
    if not args.apply and result["groups_fixable"]:
        print("Re-run with --apply to set them.")


if __name__ == "__main__":
    main()
