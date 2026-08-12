"""
Integration test for POST /monitoring/detections/{detection_id}/report/
download-audit (routes/monitoring.py), added by the download-remediation-md
workflow step 1.

This endpoint is the audit-only counterpart to the client-side "Download
Remediation Instructions" feature: the .md file itself is assembled entirely
in the browser from data already fetched into AdminDetectionDetail.jsx /
DetectionDetailOverlay.jsx state (see frontend/src/lib/remediationMarkdown.js
and its own test file) -- this endpoint returns no report/Markdown content,
it only records that an admin exported diagnostic content off-platform, via
the same `_audit` convention every other endpoint on this router already
uses (see module docstring, ASVS 5.0 16.3.2).

Covers:
  - require_admin accept/reject: unauthenticated -> 401, authenticated
    non-admin -> 403, authenticated admin -> 200.
  - 404 for a detection ID that doesn't exist (mirrors rerun_detection_report's
    existence check).
  - 200 response body is exactly {"logged": true} -- no detection/report
    content leaks through this endpoint.
  - `Cache-Control: no-store` is set, consistent with every sibling endpoint.
  - The `admin_audit` logger actually emits a
    `action=download_remediation_md admin_id=<id> detection_id=<id>` line on
    a real request, not just "the endpoint returned 200".

Run:  cd api && ../.venv/bin/python tests/test_monitoring_download_audit_endpoint.py
"""

import _pathfix  # noqa: F401

import logging
import uuid
from datetime import datetime, timezone

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


def make_user(is_admin: bool) -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {
            "_id": uid, "username": f"dl_audit_test_{uid[:8]}",
            "email": f"dl_audit_test_{uid[:8]}@example.com", "hash_pass": "x",
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


LOG_GROUP = f"/test/download-audit-endpoint-{uuid.uuid4()}"


def make_detection() -> str:
    wm = WatchdogManager()
    try:
        d = ErrorDetection(
            log_group_name=LOG_GROUP, message="ERROR - download audit test detection",
            matched_signal="error_level", context={"nearby_lines": ["a", "b"]},
            event_timestamp=datetime.now(timezone.utc),
        )
        wm.save_detection(d)
        return d.id
    finally:
        wm.close()


def cleanup_detections():
    wm = WatchdogManager()
    try:
        wm.cur.execute("DELETE FROM error_detections WHERE log_group_name = %s", (LOG_GROUP,))
        wm.conn.commit()
    finally:
        wm.close()


class _CapturingHandler(logging.Handler):
    def __init__(self):
        super().__init__()
        self.records: list[str] = []

    def emit(self, record):
        self.records.append(self.format(record))


def endpoint_path(detection_id: str) -> str:
    return f"/monitoring/detections/{detection_id}/report/download-audit"


def test_auth_boundary(admin_token, non_admin_token, detection_id):
    print("\n── require_admin accept/reject on POST .../report/download-audit ──")
    path = endpoint_path(detection_id)

    client.cookies.clear()
    r = client.post(path)
    check("unauthenticated -> 401", r.status_code, 401)

    client.cookies.set("session", non_admin_token)
    r = client.post(path)
    check("authenticated non-admin -> 403", r.status_code, 403)
    client.cookies.clear()

    client.cookies.set("session", admin_token)
    r = client.post(path)
    check("authenticated admin -> 200", r.status_code, 200)
    client.cookies.clear()


def test_404_for_missing_detection(admin_token):
    print("\n── 404 for a detection_id that doesn't exist ──")
    client.cookies.set("session", admin_token)
    r = client.post(endpoint_path(str(uuid.uuid4())))
    client.cookies.clear()
    check("nonexistent detection_id -> 404", r.status_code, 404)


def test_response_body_and_no_report_content(admin_token, detection_id):
    print("\n── 200 body is exactly {'logged': True}, no detection/report content leaks ──")
    client.cookies.set("session", admin_token)
    r = client.post(endpoint_path(detection_id))
    client.cookies.clear()
    check("response status", r.status_code, 200)
    check("response body is exactly {'logged': True}", r.json(), {"logged": True})
    body_text = r.text
    check("response does not leak the detection's message content",
          "download audit test detection" not in body_text, True)


def test_cache_control_header(admin_token, detection_id):
    print("\n── Cache-Control: no-store, consistent with every sibling endpoint ──")
    client.cookies.set("session", admin_token)
    r = client.post(endpoint_path(detection_id))
    client.cookies.clear()
    check("Cache-Control header", r.headers.get("cache-control"), "no-store")


def test_audit_logging(admin_token, detection_id):
    print("\n── admin_audit logger emits download_remediation_md on a real request ──")
    audit_logger = logging.getLogger("admin_audit")
    handler = _CapturingHandler()
    handler.setFormatter(logging.Formatter("%(message)s"))
    audit_logger.addHandler(handler)
    prior_level = audit_logger.level
    audit_logger.setLevel(logging.INFO)
    try:
        client.cookies.set("session", admin_token)
        r = client.post(endpoint_path(detection_id))
        client.cookies.clear()
        check("request succeeded before checking the audit line", r.status_code, 200)

        joined = "\n".join(handler.records)
        check("audit line action is download_remediation_md",
              "action=download_remediation_md" in joined, True)
        check("audit line includes the correct admin_id",
              f"admin_id={_ADMIN_UID[0]}" in joined, True)
        check("audit line includes the correct detection_id",
              f"detection_id={detection_id}" in joined, True)
    finally:
        audit_logger.removeHandler(handler)
        audit_logger.setLevel(prior_level)


def test_no_audit_line_on_404(admin_token):
    print("\n── a 404 (detection doesn't exist) does NOT emit a download_remediation_md audit line ──")
    audit_logger = logging.getLogger("admin_audit")
    handler = _CapturingHandler()
    handler.setFormatter(logging.Formatter("%(message)s"))
    audit_logger.addHandler(handler)
    prior_level = audit_logger.level
    audit_logger.setLevel(logging.INFO)
    missing_id = str(uuid.uuid4())
    try:
        client.cookies.set("session", admin_token)
        r = client.post(endpoint_path(missing_id))
        client.cookies.clear()
        check("404 as expected", r.status_code, 404)

        joined = "\n".join(handler.records)
        check("no download_remediation_md audit line for a 404",
              f"action=download_remediation_md admin_id={_ADMIN_UID[0]} detection_id={missing_id}" in joined, False)
    finally:
        audit_logger.removeHandler(handler)
        audit_logger.setLevel(prior_level)


_ADMIN_UID = [None]  # populated in __main__, referenced by test_audit_logging / test_no_audit_line_on_404


if __name__ == "__main__":
    admin_uid = non_admin_uid = None
    try:
        admin_uid = make_user(is_admin=True)
        non_admin_uid = make_user(is_admin=False)
        _ADMIN_UID[0] = admin_uid
        admin_token = make_session(admin_uid)
        non_admin_token = make_session(non_admin_uid)
        detection_id = make_detection()

        test_auth_boundary(admin_token, non_admin_token, detection_id)
        test_404_for_missing_detection(admin_token)
        test_response_body_and_no_report_content(admin_token, detection_id)
        test_cache_control_header(admin_token, detection_id)
        test_audit_logging(admin_token, detection_id)
        test_no_audit_line_on_404(admin_token)
    finally:
        cleanup_detections()
        if admin_uid:
            cleanup_user(admin_uid)
        if non_admin_uid:
            cleanup_user(non_admin_uid)

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    import sys
    sys.exit(0 if failed == 0 else 1)
