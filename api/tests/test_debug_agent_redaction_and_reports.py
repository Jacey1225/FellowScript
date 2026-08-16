"""
Test for `backend/monitoring/debug_agent.py::DebugAgentManager`
(error-debug-agent-admin-page workflow, steps 3-4).

Covers:
  - Redaction: `_redact_text`/`_scrub` actually strip realistic secret/PII
    shapes (connection-string password, JWT, AWS access key id, Bearer
    token, key=value credential pairs including compound identifiers,
    multiline PEM blocks, email addresses) from a detection's message AND
    its context payload before it would ever reach a prompt -- verified by
    inspecting the actual string handed to the mocked OpenRouter call, not
    just that a report gets produced.
  - A value that looks like ordinary non-secret data (a plain user_id UUID,
    a normal English sentence) survives redaction unchanged -- proves the
    patterns aren't so aggressive they destroy the report's diagnostic
    usefulness.
  - Report generation + persistence: generate_report() persists a
    DetectionReport row linked to the detection (detection_id FK), the
    detection's status flips from "new" to "diagnosed", and a subsequent
    get_report() returns the persisted row. The OpenRouter call itself is
    mocked (no real API call, no cost, deterministic) -- this test verifies
    our own code's behavior around that call, not OpenRouter's.
  - A failed OpenRouter call leaves the detection un-diagnosed (status stays
    "new", no report row created) rather than silently faking success.
  - Rerun (generate_report called twice) upserts in place -- exactly one
    report row per detection, not an accumulating history.

Run:  cd api && ../.venv/bin/python tests/test_debug_agent_redaction_and_reports.py
"""

import _pathfix  # noqa: F401

import json
import uuid
from datetime import datetime, timezone

import backend.monitoring.debug_agent as debug_agent_module
from backend.monitoring.debug_agent import DebugAgentManager, _redact_text, _scrub
from backend.monitoring.watchdog import WatchdogManager
from db import DBManager
from schemas.watchdog import ErrorDetection

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


def contains(label, haystack, needle, should_contain=True):
    ok = (needle in haystack) == should_contain
    results.append(ok)
    verb = "contains" if should_contain else "does NOT contain"
    print(f"  [{PASS if ok else FAIL}] {label}: {verb} {needle!r} -> {ok}")


LOG_GROUP = f"/test/debug-agent-{uuid.uuid4()}"


def make_detection(message: str, context: dict) -> str:
    wm = WatchdogManager()
    try:
        d = ErrorDetection(
            log_group_name=LOG_GROUP, message=message, matched_signal="error_level",
            context=context, event_timestamp=datetime.now(timezone.utc),
        )
        wm.save_detection(d)
        return d.id
    finally:
        wm.close()


def get_detection_status(detection_id: str) -> str | None:
    dbm = DBManager()
    try:
        result = dbm.lookup("error_detections", {"_id": detection_id})
        if not result:
            return None
        _, data = list(result.items())[0]
        return data.get("status")
    finally:
        dbm.close()


def cleanup_detections():
    wm = WatchdogManager()
    try:
        wm.cur.execute("DELETE FROM error_detections WHERE log_group_name = %s", (LOG_GROUP,))
        wm.conn.commit()
    finally:
        wm.close()


def count_reports_for(detection_id: str) -> int:
    dbm = DBManager()
    try:
        dbm.cur.execute(
            "SELECT count(*) FROM error_detection_reports WHERE detection_id = %s", (detection_id,)
        )
        return dbm.cur.fetchone()[0]
    finally:
        dbm.close()


# ── Redaction unit tests (no DB/network needed) ─────────────────────────

def test_redact_text_strips_realistic_secrets():
    print("\n── _redact_text strips realistic secret/PII shapes ──")
    conn_str = "postgres://appuser:SuperSecretPass123@db.internal:5432/prod"
    redacted = _redact_text(conn_str)
    contains("connection-string password is redacted", redacted, "SuperSecretPass123", should_contain=False)
    contains("connection-string username survives (not a secret)", redacted, "appuser")

    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
    redacted = _redact_text(f"Authorization failed for token {jwt}")
    contains("JWT is redacted", redacted, jwt, should_contain=False)
    contains("JWT placeholder present", redacted, "[REDACTED_JWT]")

    aws_key = "AKIAABCDEFGHIJKLMNOP"
    redacted = _redact_text(f"Using access key {aws_key} for S3 upload")
    contains("AWS access key id is redacted", redacted, aws_key, should_contain=False)

    # Isolate the Bearer-token pattern from the key=value "authorization"
    # pattern (both would independently catch a raw "Authorization: Bearer
    # ..." header -- covered together below) by using a request-log phrasing
    # with no "authorization"-shaped key name present.
    redacted = _redact_text("Incoming request carried header value Bearer sk-abcdefghij1234567890XYZ")
    contains("Bearer token value is redacted", redacted, "sk-abcdefghij1234567890XYZ", should_contain=False)
    contains("Bearer prefix kept, value replaced", redacted, "Bearer [REDACTED]")

    # Realistic combined case: an actual "Authorization: Bearer <token>"
    # header line. Two patterns (Bearer + key=value's "authorization" key
    # name) both fire on this shape -- the important security property is
    # that the raw secret never survives either way, not the exact
    # placeholder text produced.
    redacted = _redact_text("Authorization: Bearer sk-abcdefghij1234567890XYZ")
    contains("secret value never survives an 'Authorization: Bearer <token>' header line",
              redacted, "sk-abcdefghij1234567890XYZ", should_contain=False)

    redacted = _redact_text('OPENROUTER_API_KEY="or-v1-1234567890abcdef"')
    contains("compound-identifier key=value secret is redacted", redacted, "or-v1-1234567890abcdef",
              should_contain=False)

    redacted = _redact_text("DB_PASSWORD: hunter2VerySecret")
    contains("key: value (colon form) secret is redacted", redacted, "hunter2VerySecret", should_contain=False)

    pem = ("-----BEGIN PRIVATE KEY-----\n"
           "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQ==\n"
           "-----END PRIVATE KEY-----")
    redacted = _redact_text(f"Failed to load cert: {pem}")
    contains("PEM block body is redacted", redacted, "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQ==",
              should_contain=False)
    contains("PEM placeholder present", redacted, "[REDACTED_PEM_BLOCK]")

    redacted = _redact_text("User signup failed for jane.doe@example.com")
    contains("email address is redacted", redacted, "jane.doe@example.com", should_contain=False)
    contains("email placeholder present", redacted, "[REDACTED_EMAIL]")


def test_redact_text_leaves_benign_content_alone():
    print("\n── _redact_text does not over-redact benign content ──")
    uid = str(uuid.uuid4())
    text = f"user_id={uid} requested resource /notes/42, got 500"
    redacted = _redact_text(text)
    contains("plain user_id UUID (not credential-keyed) survives", redacted, uid)
    contains("normal sentence content survives untouched",
              redacted, "requested resource /notes/42, got 500")


def test_scrub_recurses_through_context_payload():
    print("\n── _scrub redacts secrets nested inside dict/list context ──")
    context = {
        "nearby_events": [
            {"message": "connected with token=abcd1234EFGH5678"},
            {"message": "normal info line, nothing sensitive"},
        ],
        "analysis": {"summary": "spike detected", "sample_header": "Bearer zzzTOPSECRETvalue999"},
    }
    scrubbed = _scrub(context)
    dumped = json.dumps(scrubbed)
    contains("nested key=value token is redacted", dumped, "abcd1234EFGH5678", should_contain=False)
    contains("nested Bearer value is redacted", dumped, "zzzTOPSECRETvalue999", should_contain=False)
    contains("unrelated nested text survives", dumped, "spike detected")
    contains("unrelated nested text survives (2)", dumped, "normal info line, nothing sensitive")


# ── Report generation + persistence (DB, mocked OpenRouter) ────────────

class _FakeResponse:
    def __init__(self, content: str, ok: bool = True):
        self._content = content
        self._ok = ok
        # 2026-08-15 incident-fix follow-up: _call_debug_api now checks
        # resp.status_code (in (401, 403)) before raise_for_status() -- see
        # DebugAgentAuthError / cloudwatch-watchdog-memory-leak workflow
        # step 2. A real requests.Response always has this attribute; this
        # fake needs one too so these non-auth-path tests keep exercising
        # the generic success/failure branches they're actually testing,
        # not an incidental AttributeError from an incomplete test double.
        # 500 (not 401/403) for the failure case so it still reaches
        # raise_for_status() below, matching this test file's original
        # "simulated OpenRouter failure" (non-auth) scenario -- the
        # dedicated auth-failure path (401/403) is covered separately in
        # test_debug_agent_auth_failure_handling.py.
        self.status_code = 200 if ok else 500

    def raise_for_status(self):
        if not self._ok:
            raise RuntimeError("simulated OpenRouter failure")

    def json(self):
        return {"choices": [{"message": {"content": self._content}}]}


def test_generate_report_persists_and_scrubs_before_sending(monkeypatch_target=None):
    print("\n── generate_report: persists report, marks diagnosed, scrubs the outbound prompt ──")
    secret_message = "ERROR - DB_PASSWORD=hunter2VerySecret failed to connect for admin@example.com"
    detection_id = make_detection(secret_message, {"analysis": {"note": "token=SECRETVALUE12345"}})

    captured = {}
    original_post = debug_agent_module.requests.post

    def fake_post(url, headers=None, json=None, timeout=None):
        captured["user_content"] = json["messages"][1]["content"]
        return _FakeResponse(
            '{"root_cause": "DB connection failure", '
            '"remediation_narrative": "Rotate the credential and verify network path."}'
        )

    debug_agent_module.requests.post = fake_post
    try:
        manager = DebugAgentManager()
        try:
            result = manager.generate_report(detection_id)
        finally:
            manager.close()

        check("no error in generate_report result", "error" in result, False)
        check("root_cause persisted", result.get("root_cause"), "DB connection failure")
        check("remediation_narrative persisted",
              result.get("remediation_narrative"), "Rotate the credential and verify network path.")
        check("detection_id on the report matches the source detection",
              result.get("detection_id"), detection_id)

        check("detection status flips to 'diagnosed'", get_detection_status(detection_id), "diagnosed")
        check("exactly one report row now exists for this detection", count_reports_for(detection_id), 1)

        sent = captured.get("user_content", "")
        contains("secret sent to OpenRouter prompt was scrubbed (password)", sent,
                  "hunter2VerySecret", should_contain=False)
        contains("secret sent to OpenRouter prompt was scrubbed (context token)", sent,
                  "SECRETVALUE12345", should_contain=False)
        contains("PII sent to OpenRouter prompt was scrubbed (email)", sent,
                  "admin@example.com", should_contain=False)

        manager2 = DebugAgentManager()
        try:
            fetched = manager2.get_report(detection_id)
        finally:
            manager2.close()
        check("get_report retrieves the persisted report after generation",
              fetched is not None, True)
        if fetched:
            check("fetched report's root_cause matches what generate_report returned",
                  fetched.get("root_cause"), "DB connection failure")
    finally:
        debug_agent_module.requests.post = original_post


def test_failed_openrouter_call_does_not_fake_success():
    print("\n── A failed OpenRouter call leaves the detection un-diagnosed ──")
    detection_id = make_detection("ERROR - transient failure", {})

    original_post = debug_agent_module.requests.post
    debug_agent_module.requests.post = lambda *a, **k: _FakeResponse("", ok=False)
    try:
        manager = DebugAgentManager()
        try:
            result = manager.generate_report(detection_id)
        finally:
            manager.close()
        check("generate_report reports an error on OpenRouter failure", "error" in result, True)
        check("detection status stays 'new' after a failed generation",
              get_detection_status(detection_id), "new")
        check("no report row was created for a failed generation",
              count_reports_for(detection_id), 0)
    finally:
        debug_agent_module.requests.post = original_post


def test_rerun_upserts_in_place():
    print("\n── Rerunning generate_report upserts the same row, not a new one ──")
    detection_id = make_detection("ERROR - flaky dependency timeout", {})

    original_post = debug_agent_module.requests.post
    debug_agent_module.requests.post = lambda *a, **k: _FakeResponse(
        '{"root_cause": "first pass", "remediation_narrative": "retry"}'
    )
    try:
        manager = DebugAgentManager()
        try:
            manager.generate_report(detection_id)
        finally:
            manager.close()
        check("one report row after first generation", count_reports_for(detection_id), 1)

        debug_agent_module.requests.post = lambda *a, **k: _FakeResponse(
            '{"root_cause": "second pass, refined", "remediation_narrative": "restart the dependency"}'
        )
        manager2 = DebugAgentManager()
        try:
            result = manager2.generate_report(detection_id)
        finally:
            manager2.close()
        check("still exactly one report row after a rerun (upsert, not accumulation)",
              count_reports_for(detection_id), 1)
        check("rerun's root_cause overwrote the original in place",
              result.get("root_cause"), "second pass, refined")
    finally:
        debug_agent_module.requests.post = original_post


if __name__ == "__main__":
    try:
        test_redact_text_strips_realistic_secrets()
        test_redact_text_leaves_benign_content_alone()
        test_scrub_recurses_through_context_payload()
        test_generate_report_persists_and_scrubs_before_sending()
        test_failed_openrouter_call_does_not_fake_success()
        test_rerun_upserts_in_place()
    finally:
        cleanup_detections()

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    import sys
    sys.exit(0 if failed == 0 else 1)
