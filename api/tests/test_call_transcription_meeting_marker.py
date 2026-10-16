"""Regression coverage for task 20261015-call-transcription-start-and-diagnostics.

Bug: the "transcription active" marker was keyed only by session, so after a
failed/empty call it stayed set and later joins (same or recreated Chime
meeting) skipped starting transcription. Now the marker is meeting-scoped,
cleared on last-attendee leave and on meeting recreate.

Covered: meeting-keyed marker, last-leave clearing (present vs absent caller,
remaining attendee), recreate clearing, join (re)start, ConflictException =
running (real chime_meetings.start_transcription with a stub client), failed
start not marking active, non-paid joiner behaviour, leave never calling
Chime stop, no transcript text kept in the marker / logs.

No database needed (pure in-memory modules, paid check stubbed).

Run:  cd api && ../.venv/bin/python tests/test_call_transcription_meeting_marker.py
"""
import _pathfix  # noqa: F401,E402

import dataclasses
import logging
import os

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")

from botocore.exceptions import ClientError  # noqa: E402

from backend.interactions import chime_meetings  # noqa: E402
from backend.interactions import session_call_transcription as sct  # noqa: E402
from backend.interactions import session_relay as relay  # noqa: E402
from backend.interactions import session_transcript as st  # noqa: E402
from backend.interactions import session_transcription_config as cfgmod  # noqa: E402

PASSED, FAILED = [], []


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


PAID = {"a", "b"}
sct._is_paid = lambda uid: uid in PAID
base = cfgmod.get_session_transcription_config()
cfgmod._cached = dataclasses.replace(base, enabled=True)

started, stopped = [], []


def install_chime(result=True):
    started.clear(); stopped.clear()
    chime_meetings.start_transcription = lambda m, lang: (started.append(m) or result)
    chime_meetings.stop_transcription = lambda m: (stopped.append(m) or True)


def reset():
    relay.reset_for_tests()
    st._active.clear()
    install_chime(True)


class _Capture(logging.Handler):
    def __init__(self):
        super().__init__(); self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


def test_marker_is_meeting_keyed():
    print("\n=== marker keyed by meeting ===")
    reset()
    st.mark_active("s1", "m1")
    check("matches same meeting", st.is_active("s1", "m1"))
    check("does NOT match another meeting", not st.is_active("s1", "m2"))
    check("session-only query still sees it", st.is_active("s1"))
    check("other session unaffected", not st.is_active("s2", "m1"))
    # THE regression: old-meeting marker must not suppress a start for a new meeting
    f = sct.join_transcription_fields("s1", "m2", "a", "a")
    check("stale marker for old meeting does not suppress start for new meeting",
          started == ["m2"] and f["transcription_active"] is True, str((started, f)))
    check("marker now belongs to the new meeting", st.is_active("s1", "m2") and not st.is_active("s1", "m1"))


def test_failed_call_then_rejoin_same_meeting_after_last_leave():
    print("\n=== failed/empty call then rejoin ===")
    reset()
    f = sct.join_transcription_fields("s1", "m1", "a", "a")
    check("first join starts", started == ["m1"] and f["transcription_active"])
    sct.on_attendee_leave("s1", "a")
    check("last leave cleared marker", not st.is_active("s1"))
    f = sct.join_transcription_fields("s1", "m1", "a", "a")
    check("rejoin same meeting restarts transcription", started == ["m1", "m1"] and f["transcription_active"], str(started))


def test_last_leave_semantics():
    print("\n=== last-leave clearing ===")
    reset()
    sct.join_transcription_fields("s1", "m1", "a", "a")
    sct.join_transcription_fields("s1", "m1", "b", "a")
    sct.on_attendee_leave("s1", "a")
    check("remaining attendee keeps marker", st.is_active("s1", "m1"))
    sct.on_attendee_leave("s1", "zzz")
    check("absent caller cannot clear marker", st.is_active("s1", "m1"))
    check("record_leave False for absent caller", relay.record_leave("s1", "zzz") is False)
    sct.on_attendee_leave("s1", "b")
    check("last attendee leaving clears marker", not st.is_active("s1"))
    sct.on_attendee_leave("s1", "b")
    check("repeat leave is idempotent", not st.is_active("s1"))

    reset()
    sct.join_transcription_fields("s2", "m1", "a", "a")
    check("absent caller on lone-attendee session does not clear", (sct.on_attendee_leave("s2", "nobody"), st.is_active("s2", "m1"))[1])


def test_leave_never_stops_chime():
    print("\n=== leave never calls Chime stop; transcript kept ===")
    reset()
    sct.join_transcription_fields("s1", "m1", "a", "a")
    st.ingest("s1", "a", "hello this is spoken words long enough")
    sct.on_attendee_leave("s1", "a")
    check("no stop_transcription on last leave", stopped == [], str(stopped))
    check("transcript lines kept for summarize", len(st.peek_lines("s1")) == 1)
    check("marker cleared though", not st.is_active("s1"))


def test_recreate_clears():
    print("\n=== meeting recreate clears marker ===")
    reset()
    sct.join_transcription_fields("s1", "m1", "a", "a")
    sct.on_meeting_recreated("s1")
    check("recreate clears marker", not st.is_active("s1"))
    sct.on_meeting_recreated("s1")  # idempotent, no raise
    f = sct.join_transcription_fields("s1", "m9", "a", "a")
    check("join after recreate starts on new meeting", started[-1] == "m9" and f["transcription_active"])


def test_conflict_is_running_and_failure_fail_closed():
    print("\n=== Conflict = running; failed start not active ===")
    reset()
    orig_chime = chime_meetings.chime
    importlib_mod = __import__("importlib").reload(chime_meetings)  # restore real start_transcription
    globals()["chime_meetings"] = importlib_mod
    sct_chime = importlib_mod

    class Stub:
        def __init__(self, code=None, exc=None):
            self.code, self.exc = code, exc

        def start_meeting_transcription(self, **kw):
            if self.code:
                raise ClientError({"Error": {"Code": self.code, "Message": "x SECRET-TEXT"}}, "StartMeetingTranscription")
            if self.exc:
                raise self.exc

    importlib_mod.stop_transcription = lambda m: (stopped.append(m) or True)
    importlib_mod.chime = Stub("ConflictException")
    check("ConflictException -> start_transcription True", importlib_mod.start_transcription("m1", "en-US") is True)
    f = sct.join_transcription_fields("s1", "m1", "a", "a")
    check("Conflict marks active and shows banner", f["transcription_active"] and st.is_active("s1", "m1"), str(f))

    reset_keep = lambda: (relay.reset_for_tests(), st._active.clear())
    reset_keep()
    for label, stub in (("AccessDenied", Stub("AccessDeniedException")), ("generic exception", Stub(exc=RuntimeError("boom")))):
        importlib_mod.chime = stub
        reset_keep()
        f = sct.join_transcription_fields("s1", "m1", "a", "a")
        check(f"start failure ({label}) is fail-closed",
              f == {"transcription_active": False, "transcript_relay": False, "transcript_poll_seconds": 0}
              and not st.is_active("s1"), str(f))
    importlib_mod.chime = orig_chime
    # failure then success on next join recovers
    reset()
    chime_meetings.start_transcription = lambda m, l: False
    sct.join_transcription_fields("s1", "m1", "a", "a")
    chime_meetings.start_transcription = lambda m, l: (started.append(m) or True)
    f = sct.join_transcription_fields("s1", "m1", "a", "a")
    check("failed start retried on next join and then active", started == ["m1"] and f["transcription_active"])


def test_non_paid_joiner():
    print("\n=== non-paid joiner ===")
    reset()
    f = sct.join_transcription_fields("s1", "m1", "free", "a")
    check("free joiner never starts, no banner when nothing runs",
          started == [] and f["transcription_active"] is False)
    sct.join_transcription_fields("s1", "m1", "a", "a")
    f = sct.join_transcription_fields("s1", "m1", "free", "a")
    check("free late joiner sees banner for this meeting, not relay",
          f["transcription_active"] is True and f["transcript_relay"] is False and started == ["m1"])
    f = sct.join_transcription_fields("s1", "m2", "free", "a")
    check("free joiner with stale-meeting marker gets False and starts nothing",
          f["transcription_active"] is False and started == ["m1"], str((f, started)))


def test_flag_off_and_no_text_logged():
    print("\n=== flag off inert; logs carry no transcript text ===")
    reset()
    cfgmod._cached = dataclasses.replace(base, enabled=False)
    f = sct.join_transcription_fields("s1", "m1", "a", "a")
    check("flag off -> nothing started or marked", started == [] and not st.is_active("s1") and not f["transcription_active"])
    cfgmod._cached = dataclasses.replace(base, enabled=True)
    reset()
    cap = _Capture()
    lg = logging.getLogger("backend.interactions.session_call_transcription")
    lg.addHandler(cap); lg.setLevel(logging.INFO)
    try:
        sct.join_transcription_fields("s1", "m1", "a", "a")
        st.ingest("s1", "a", "SECRET-TRANSCRIPT-WORDS spoken")
        sct.on_attendee_leave("s1", "a")
        sct.on_meeting_recreated("s1")
    finally:
        lg.removeHandler(cap)
    check("AUDIT start and clear logged", any("AUDIT transcription started" in l for l in cap.lines)
          and any("AUDIT transcription marker cleared" in l for l in cap.lines), str(cap.lines))
    check("no transcript text in logs", not any("SECRET" in l for l in cap.lines))


def main():
    for t in (test_marker_is_meeting_keyed, test_failed_call_then_rejoin_same_meeting_after_last_leave,
              test_last_leave_semantics, test_leave_never_stops_chime, test_recreate_clears,
              test_conflict_is_running_and_failure_fail_closed, test_non_paid_joiner,
              test_flag_off_and_no_text_logged):
        t()
    print("\n" + "=" * 60)
    print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} failed")
    for label, detail in FAILED:
        print(f"  FAILED: {label} -- {detail}")
    print("STATUS:", "ALL PASS" if not FAILED else "FAILURES")
    raise SystemExit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
