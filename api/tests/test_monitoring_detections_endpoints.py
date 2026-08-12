"""
Integration test for GET /monitoring/detections and
GET /monitoring/detections/{id} (routes/monitoring.py, cloudwatch-error-
remediation workflow step 4, auth model updated by the
error-debug-agent-admin-page workflow step 1).

Covers:
  - Auth boundary: `require_admin` (session auth + is_admin lookup) rejects
    unauthenticated requests (401) AND authenticated-but-non-admin requests
    (403) -- the old any-authenticated-user placeholder is fully gone, so
    both rejection paths are exercised, not just the 401 one.
  - An authenticated admin succeeds (200) -- the happy path that proves the
    placeholder's removal didn't also break the real admin caller.
  - Pagination (limit/offset, `total` independent of paging) and filtering
    (by log_group_name, by detected_at time range).
  - List rows omit the `context` blob; the detail endpoint includes it.
  - 404 for a detection ID that doesn't exist.

Run:  cd api && ../.venv/bin/python tests/test_monitoring_detections_endpoints.py
"""

import _pathfix  # noqa: F401

import uuid
from datetime import datetime, timedelta, timezone

from fastapi import FastAPI
from fastapi.testclient import TestClient

from db import DBManager
from backend.auth.sessions import SessionManager
from backend.monitoring.watchdog import WatchdogManager
from schemas.watchdog import ErrorDetection
from routes.monitoring import monitoring_router

app = FastAPI()
app.include_router(monitoring_router)
client = TestClient(app)

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


def make_test_user(is_admin: bool = False) -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {
            "_id": uid, "username": f"monitor_test_{uid[:8]}",
            "email": f"monitor_test_{uid[:8]}@example.com", "hash_pass": "x",
            "is_admin": is_admin,
        })
    finally:
        db.close()
    return uid


def make_session(uid: str) -> str:
    sm = SessionManager()
    try:
        return sm.create_session(uid)
    finally:
        sm.close()


def cleanup_user(uid: str):
    db = DBManager()
    try:
        db.delete("users", {"_id": uid})  # cascades sessions per this app's FK convention
    finally:
        db.close()


LOG_GROUP = f"/test/monitoring-endpoint-{uuid.uuid4()}"
OTHER_LOG_GROUP = f"/test/monitoring-endpoint-other-{uuid.uuid4()}"


def seed_detections() -> dict:
    """Three detections in LOG_GROUP at distinct times (oldest -> newest),
    one in OTHER_LOG_GROUP, so filtering/pagination/ordering are all
    independently verifiable. Returns their ids keyed by label."""
    wm = WatchdogManager()
    now = datetime.now(timezone.utc)
    ids = {}
    try:
        d_old = ErrorDetection(
            log_group_name=LOG_GROUP, message="ERROR - oldest", matched_signal="error_level",
            event_timestamp=now - timedelta(minutes=30), detected_at=now - timedelta(minutes=30),
            context={"nearby_events": [], "analysis": {}},
        )
        d_mid = ErrorDetection(
            log_group_name=LOG_GROUP, message="ERROR - middle", matched_signal="error_level",
            event_timestamp=now - timedelta(minutes=20), detected_at=now - timedelta(minutes=20),
            context={"nearby_events": ["line1"], "analysis": {"pattern": "spike"}},
        )
        d_new = ErrorDetection(
            log_group_name=LOG_GROUP, message="ERROR - newest", matched_signal="error_level",
            event_timestamp=now - timedelta(minutes=10), detected_at=now - timedelta(minutes=10),
            context={"nearby_events": [], "analysis": {}},
        )
        d_other = ErrorDetection(
            log_group_name=OTHER_LOG_GROUP, message="ERROR - other group", matched_signal="error_level",
            event_timestamp=now - timedelta(minutes=15), detected_at=now - timedelta(minutes=15),
            context={},
        )
        for d in (d_old, d_mid, d_new, d_other):
            wm.save_detection(d)
        ids = {"old": d_old.id, "mid": d_mid.id, "new": d_new.id, "other": d_other.id}
    finally:
        wm.close()
    return ids


def cleanup_detections():
    wm = WatchdogManager()
    try:
        wm.cur.execute("DELETE FROM error_detections WHERE log_group_name IN (%s, %s)",
                        (LOG_GROUP, OTHER_LOG_GROUP))
        wm.conn.commit()
    finally:
        wm.close()


def test_auth_boundary(non_admin_token: str):
    print("\n── Auth boundary: require_admin rejects unauthenticated (401) ──")
    client.cookies.clear()
    r = client.get("/monitoring/detections")
    check("GET /monitoring/detections with no session cookie -> 401", r.status_code, 401)

    r = client.get(f"/monitoring/detections/{uuid.uuid4()}")
    check("GET /monitoring/detections/{id} with no session cookie -> 401", r.status_code, 401)

    client.cookies.set("session", "not-a-real-token")
    r = client.get("/monitoring/detections")
    check("GET /monitoring/detections with a bogus/unknown session token -> 401", r.status_code, 401)
    client.cookies.clear()

    print("\n── Auth boundary: require_admin rejects authenticated-non-admin (403), "
          "not the old any-authenticated-user placeholder's 200 ──")
    client.cookies.set("session", non_admin_token)
    r = client.get("/monitoring/detections")
    check("GET /monitoring/detections as authenticated non-admin -> 403 (not 200)", r.status_code, 403)

    r = client.get(f"/monitoring/detections/{uuid.uuid4()}")
    check("GET /monitoring/detections/{id} as authenticated non-admin -> 403 (not 404/200)",
          r.status_code, 403)
    client.cookies.clear()


def test_list_pagination_and_filtering(ids: dict):
    print("\n── GET /monitoring/detections: pagination + filtering ──────")
    r = client.get("/monitoring/detections", params={"log_group_name": LOG_GROUP})
    check("authenticated list request -> 200", r.status_code, 200)
    body = r.json()
    check("total reflects all 3 rows in LOG_GROUP regardless of paging", body["total"], 3)
    check("list is ordered most-recent-first",
          [item["message"] for item in body["items"]],
          ["ERROR - newest", "ERROR - middle", "ERROR - oldest"])
    check("summary rows omit the context blob",
          all("context" not in item for item in body["items"]), True)
    check("other log group's detection is excluded by the filter",
          any(item["id"] == ids["other"] for item in body["items"]), False)

    r = client.get("/monitoring/detections", params={"log_group_name": LOG_GROUP, "limit": 1, "offset": 0})
    page1 = r.json()
    check("limit=1 offset=0 returns exactly 1 item", len(page1["items"]), 1)
    check("limit=1 offset=0 returns the newest row", page1["items"][0]["message"], "ERROR - newest")
    check("total is independent of limit/offset", page1["total"], 3)

    r = client.get("/monitoring/detections", params={"log_group_name": LOG_GROUP, "limit": 1, "offset": 1})
    page2 = r.json()
    check("limit=1 offset=1 returns the middle row", page2["items"][0]["message"], "ERROR - middle")

    r = client.get("/monitoring/detections", params={"log_group_name": OTHER_LOG_GROUP})
    only_other = r.json()
    check("filtering by OTHER_LOG_GROUP returns only that group's row", only_other["total"], 1)
    check("filtered row belongs to OTHER_LOG_GROUP", only_other["items"][0]["id"], ids["other"])

    r = client.get("/monitoring/detections", params={
        "log_group_name": LOG_GROUP,
        "start_time": (datetime.now(timezone.utc) - timedelta(minutes=25)).isoformat(),
    })
    time_filtered = r.json()
    check("start_time filter excludes the oldest row (30 min ago)",
          any(item["message"] == "ERROR - oldest" for item in time_filtered["items"]), False)
    check("start_time filter keeps the middle/newest rows",
          time_filtered["total"], 2)


def test_detail_endpoint(ids: dict):
    print("\n── GET /monitoring/detections/{id}: detail + context + 404 ─")
    r = client.get(f"/monitoring/detections/{ids['mid']}")
    check("detail request for a real id -> 200", r.status_code, 200)
    body = r.json()
    check("detail response includes the full context payload",
          body.get("context", {}).get("analysis"), {"pattern": "spike"})
    check("detail response includes nearby_events from context",
          body.get("context", {}).get("nearby_events"), ["line1"])

    r = client.get(f"/monitoring/detections/{uuid.uuid4()}")
    check("detail request for a nonexistent id -> 404 (not 500 or 200)", r.status_code, 404)

    r = client.get("/monitoring/detections/not-a-valid-uuid")
    check("detail request with a malformed id -> 404, not 500", r.status_code, 404)


if __name__ == "__main__":
    uid = make_test_user(is_admin=True)
    token = make_session(uid)
    non_admin_uid = make_test_user(is_admin=False)
    non_admin_token = make_session(non_admin_uid)
    ids = seed_detections()
    try:
        test_auth_boundary(non_admin_token)

        client.cookies.set("session", token)
        test_list_pagination_and_filtering(ids)
        test_detail_endpoint(ids)
    finally:
        cleanup_detections()
        cleanup_user(uid)
        cleanup_user(non_admin_uid)

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    import sys
    sys.exit(0 if failed == 0 else 1)
