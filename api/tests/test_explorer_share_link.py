"""Tests for GET /explorer/{user_id}/groups/{group_id}/share-link (task
20261011-ios-share-notes-highlights, step 4).

Properties proved:
  1. A member gets exactly {"public_id": <the listing's id>} and Cache-Control no-store.
  2. Non-member, missing group, malformed group id, draft / pending / unpublished /
     hidden / rejected listing, owner left, owner suspended, requests closed and the
     explorer_browse flag off all answer the IDENTICAL 404 body and status.
  3. Another user's session cannot read the path user's link (require_match).
  4. The rate limit is configured and trips after the configured count.

Scratch database only (SHOW port 55432). Run with:
  cd api && ../.venv/bin/python tests/test_explorer_share_link.py
"""
import _pathfix  # noqa: F401

import _jrq_common as J
from _jrq_common import call, check, make_listing, make_user, sql
from backend.interactions.listings_config import get_listings_config

NOT_FOUND = {"detail": {"code": "not_found", "message": "Not found"}}


def url(uid, gid):
    return f"/explorer/{uid}/groups/{gid}/share-link"


def get(cli, uid, gid, path_uid=None):
    return call(cli, "get", url(path_uid or uid, gid), uid)


def is_404(r):
    return r.status_code == 404 and r.json() == NOT_FOUND


def main():
    cli, _ = J.start()
    try:
        owner, member, outsider = make_user("sl"), make_user("sl"), make_user("sl")
        gid, pid = make_listing(owner, [member])
        J.set_flags(owner)

        print("member allowed")
        r = get(cli, member, gid)
        check("member 200", r.status_code == 200, r.text)
        check("body is exactly {public_id}", r.json() == {"public_id": pid}, r.json())
        check("Cache-Control no-store", r.headers.get("cache-control") == "no-store", r.headers)
        check("owner 200", get(cli, owner, gid).json() == {"public_id": pid})
        check("member id match is case-insensitive",
              (sql("UPDATE groups SET users = array_replace(users, %s, upper(%s)) WHERE _id = %s",
                   (member, member, gid)) or True) and get(cli, member, gid).status_code == 200)
        sql("UPDATE groups SET users = array_replace(users, upper(%s), %s) WHERE _id = %s", (member, member, gid))

        print("denied: identical 404")
        bad = {}
        bad["non-member"] = get(cli, outsider, gid)
        bad["missing group"] = get(cli, member, "00000000-0000-4000-8000-000000000000")
        bad["malformed group id"] = get(cli, member, "not-a-uuid")
        bad["sql-ish group id"] = get(cli, member, "x'%20OR%201=1")
        for label, r in bad.items():
            check(f"{label} -> generic 404", is_404(r), (r.status_code, r.text))

        for status in ("draft", "pending_review", "unpublished", "hidden", "rejected"):
            sql("UPDATE group_listings SET status = %s WHERE group_id = %s", (status, gid))
            check(f"status {status} -> generic 404", is_404(get(cli, member, gid)), status)
        sql("UPDATE group_listings SET status = 'published' WHERE group_id = %s", (gid,))
        check("republished works again", get(cli, member, gid).status_code == 200)

        sql("UPDATE group_listings SET accepting_requests = FALSE WHERE group_id = %s", (gid,))
        check("requests closed -> generic 404", is_404(get(cli, member, gid)))
        sql("UPDATE group_listings SET accepting_requests = TRUE WHERE group_id = %s", (gid,))

        sql("UPDATE users SET suspended_at = now() WHERE _id = %s", (owner,))
        check("owner suspended -> generic 404", is_404(get(cli, member, gid)))
        sql("UPDATE users SET suspended_at = NULL WHERE _id = %s", (owner,))

        sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id = %s", (owner, gid))
        check("owner left -> generic 404", is_404(get(cli, member, gid)))
        sql("UPDATE groups SET users = array_append(users, %s) WHERE _id = %s", (owner, gid))
        check("owner back -> 200", get(cli, member, gid).status_code == 200)

        print("auth and flag")
        r = call(cli, "get", url(member, gid), outsider)
        check("another user's session on the path user -> not 200", r.status_code in (401, 403, 404), r.status_code)
        r = cli.get(url(member, gid))
        check("no session -> not 200", r.status_code in (401, 403), r.status_code)
        J.set_flags(owner, explorer_browse="off")
        check("explorer_browse off -> generic 404", is_404(get(cli, member, gid)))
        J.set_flags(owner)
        check("flag back on -> 200", get(cli, member, gid).status_code == 200)

        print("rate limit")
        limit = get_listings_config().rate_limits["share_link"]
        check("share_link limit is configured", bool(limit), limit)
        n = int(limit.split("/")[0])
        from backend.rate_limiting import limiter
        limiter.reset()
        codes = [cli.get(url(member, gid), headers=J.H(member)).status_code for _ in range(n + 2)]
        check("limit trips with 429 after the configured count", codes[:n] == [200] * n and 429 in codes[n:], codes)
        limiter.reset()
    finally:
        J.finish()


if __name__ == "__main__":
    main()
