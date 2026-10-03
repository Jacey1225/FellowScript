"""Legacy groups with creator_id NULL never showed up in the Explore owner
list ("groups you own"). backend/maintenance/backfill_group_creators.py gives
them a creator (first live member). Scratch database only (guard in
_thr_common.require_scratch_db)."""
import _thr_common as t
from _thr_common import check, make_user, make_group, sql

t.require_scratch_db()

from backend.maintenance import backfill_group_creators as bf  # noqa: E402
from backend.interactions.listings import ListingsManager  # noqa: E402

u1, u2, u3 = make_user("bf"), make_user("bf"), make_user("bf")
GHOST = "11111111-1111-1111-1111-111111111111"  # not a user

a = make_group([u1, u2])                 # ownerless, first member live -> u1
b = make_group([GHOST, u2])              # ownerless, first live member -> u2
c = make_group([u1, u3], creator=u3)     # already owned -> unchanged
d = make_group([])                       # ownerless, nobody -> stays NULL


def creator(gid):
    return sql("SELECT creator_id::text FROM groups WHERE _id=%s", (gid,))[0][0]


def owned_by(uid):
    m = ListingsManager(uid)
    try:
        return {g["group_id"] for g in m.list_groups()["groups"]}
    finally:
        m.close()


check("before: legacy group not in owner's list", a not in owned_by(u1))

res = bf.backfill(apply=False)
check("dry run reports fixable groups", res["groups_fixable"] >= 2 and "groups_updated" not in res, res)
check("dry run changes nothing", creator(a) is None and creator(b) is None)

res = bf.backfill(apply=True)
check("apply updates at least our two groups", res["groups_updated"] >= 2, res)
check("first member becomes creator", creator(a) == u1)
check("first LIVE member becomes creator (ghost id skipped)", creator(b) == u2)
check("existing creator untouched", creator(c) == u3)
check("group with no members stays ownerless", creator(d) is None)
check("legacy group now listed for its owner", a in owned_by(u1))
check("and for the owner of the second group", b in owned_by(u2))
check("not listed for a non-first member", a not in owned_by(u2))

res = bf.backfill(apply=True)
check("re-run is a no-op for our groups", creator(a) == u1 and creator(b) == u2 and creator(c) == u3)

t.finish(flag_names=())
