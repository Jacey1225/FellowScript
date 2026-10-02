"""One-off cleanup of dangling ids in ``groups.users``.

Before the shared-foundation change, deleting an account never touched
``groups.users`` (a TEXT[] with no FK), so deleted ids stayed in member lists.
Run by the operator (action A14), never by a pipeline gate:

    docker exec fellowscript-api python -m backend.maintenance.prune_group_members          # dry run
    docker exec fellowscript-api python -m backend.maintenance.prune_group_members --apply

The default is a DRY RUN that prints counts only (no ids, no titles). ``--apply``
runs one idempotent UPDATE that keeps only entries present in ``users``, with
array order preserved. Groups left with zero members are reported, never
deleted by this script.
"""
import argparse

from db import DBManager

# An entry is "live" when it equals the text of an existing user id. A one-off
# single pass, so the text form is fine here (the hot-path readers use
# groups.LIVE_MEMBER_JOIN instead).
_LIVE = "COALESCE(m.member_id IN (SELECT _id::text FROM users), false)"

_COUNTS_SQL = f"""
SELECT
  count(*)                                                         AS groups_total,
  count(*) FILTER (WHERE d.dangling > 0)                           AS groups_with_dangling,
  COALESCE(sum(d.dangling), 0)                                     AS dangling_ids,
  count(*) FILTER (WHERE d.dangling > 0 AND d.live = 0)            AS groups_that_would_be_empty
FROM groups g
CROSS JOIN LATERAL (
  SELECT count(*) FILTER (WHERE NOT ({_LIVE})) AS dangling,
         count(*) FILTER (WHERE {_LIVE})       AS live
  FROM unnest(g.users) AS m(member_id)
) d
"""

_APPLY_SQL = f"""
UPDATE groups g
SET users = COALESCE((
    SELECT array_agg(m.member_id ORDER BY m.ord)
    FROM unnest(g.users) WITH ORDINALITY AS m(member_id, ord)
    WHERE {_LIVE}
), '{{}}')
WHERE g.users IS NOT NULL AND EXISTS (
    SELECT 1 FROM unnest(g.users) AS m(member_id) WHERE NOT ({_LIVE})
)
"""


def counts(cur) -> dict[str, int]:
    cur.execute(_COUNTS_SQL)
    total, with_dangling, dangling, would_be_empty = cur.fetchone()
    return {
        "groups_total": int(total),
        "groups_with_dangling": int(with_dangling),
        "dangling_ids": int(dangling),
        "groups_that_would_be_empty": int(would_be_empty),
    }


def prune(apply: bool) -> dict[str, int]:
    db = DBManager()
    try:
        result = counts(db.cur)
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
                        help="Remove dangling ids (default is a dry run that changes nothing).")
    args = parser.parse_args()
    result = prune(args.apply)
    print(("APPLIED" if args.apply else "DRY RUN (nothing changed)"))
    for key, value in result.items():
        print(f"{key}={value}")
    if not args.apply and result["groups_with_dangling"]:
        print("Re-run with --apply to remove them.")


if __name__ == "__main__":
    main()
