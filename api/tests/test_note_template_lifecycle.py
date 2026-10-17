"""Task 20261017-devotion-note-format, testing gate: the per-schedule note
template lifecycle against the REAL AgentManager and a REAL Postgres DB (only
the three LLM calls are stubbed: template derivation, timeline planning, note
generation).

Bug class: the same schedule's notes differed day to day in layout because
the model wrote free-form text. Proves, end to end:

  A. add_heartbeat: invalid derivation output is retried a bounded number of
     times, then throws TemplateDerivationError and creates NO row; an
     API error throws too; invalid-then-valid succeeds and stores the
     template + prompt hash. get_heartbeats hides the internal columns.
  B. update_heartbeat: a non-prompt edit never re-derives; a prompt edit
     whose derivation fails throws and leaves prompt, template, hash and
     timeline untouched; a successful prompt edit re-derives and updates the
     hash.
  C. Fire: two days of the SAME schedule, model output sloppy and different
     each day -> notes have identical layout skeleton; theme and verses
     populated; invalid model output is retried within the cap and, if it
     never validates, no note is saved and the claim is unwound.
  D. Check-in: day 2's prompt cites day 1's saved application (follow-up);
     day 1's prompt has no follow-up claim.
  E. Lazy derivation: a pre-feature row with no template and a LEGACY
     plain-string timeline derives on its first fire (once), keeps working,
     and never re-derives on the next fire. A failed lazy derivation fails
     the fire loudly: no note, claim unwound, timeline untouched, retried
     (and succeeds) on the next fire.
  F. Template re-derived only on prompt change (stale hash re-derives at
     fire; matching hash does not).
  G. Timeline planner: structured template -> contract day entries (passage,
     theme, check_in_rule, lengths) via real _generate_timeline_days with a
     bad-then-good stubbed planner response; a plain-string day is rejected
     and retried; legacy decode still works.

Run: cd api && ../.venv/bin/python tests/test_note_template_lifecycle.py
"""
import _pathfix  # noqa: F401

import json
import re
import sys
import uuid
from datetime import datetime, timezone

from db import DBManager
from backend.errors import TemplateDerivationError, TimelineGenerationError
from backend.interactions import note_template as nt
from backend.interactions.agent import AgentManager, _TEMPLATE_DERIVATION_MAX_ATTEMPTS, _HB_JSON_PARSE_MAX_ATTEMPTS
from schemas.agent import AgentHeartbeats

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


FIVE = {
    "kind": "structured",
    "title": {"mode": "pattern", "pattern": "{theme}: {reference}"},
    "sections": [
        {"key": "check_in", "title": "Check-in", "layout": "heading", "kind": "text", "role": "check_in", "max_words": 40},
        {"key": "scripture", "title": "Scripture", "layout": "heading", "kind": "scripture", "max_words": 200},
        {"key": "summary", "title": "Scripture summary", "layout": "heading", "kind": "text", "max_words": 120},
        {"key": "discussion", "title": "Discussion prompt", "layout": "label", "kind": "text", "max_words": 50},
        {"key": "application", "title": "Application prompt", "layout": "label", "kind": "text", "role": "application", "max_words": 50},
    ],
}
FIVE_JSON = json.dumps(FIVE)
FREEFORM_JSON = json.dumps({"kind": "freeform"})


class Script:
    """Per-test scripted LLM responses, popped in order (last one repeats)."""

    def __init__(self, *responses):
        self.responses, self.calls, self.prompts = list(responses), 0, []

    def next(self, prompt=""):
        self.calls += 1
        self.prompts.append(prompt)
        r = self.responses[0] if len(self.responses) == 1 else self.responses.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


class M(AgentManager):
    tmpl: Script = Script(FIVE_JSON)
    tl: Script = Script("{}")
    note: Script = Script("{}")

    def _call_template_api(self, prompt):
        return type(self).tmpl.next(prompt)

    def _call_timeline_api(self, prompt):
        return type(self).tl.next(prompt)

    def _call_api(self, agent_role, messages, summary=None):
        return type(self).note.next(messages[0]["content"])


def today_day() -> int:
    return datetime.now(timezone.utc).day  # users.timezone defaults to UTC


def fires_today_ts() -> list:
    ts = [None] * 31
    ts[today_day() - 1] = "09:00"
    return ts


def tl_response(passage="1 Thessalonians 5:12-15", theme="Peace"):
    return json.dumps({"days": {"0": {"instruction": "Cover the passage", "theme": theme, "passage": passage}},
                       "coverage_summary": "covered"})


def make_user() -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": f"nt_{uid[:8]}", "email": f"nt_{uid[:8]}@example.com", "hash_pass": "x"})
    finally:
        db.close()
    return uid


def make_agent(uid) -> str:
    aid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("agents", {"_id": aid, "user_id": uid, "role": "", "chats": []})
    finally:
        db.close()
    return aid


def raw_hb(aid, uid, prompt="Daily devotion.", timeline=None, template=None, thash=None) -> str:
    hid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt, timeline_instruction, "
            "note_template, note_template_prompt_hash) VALUES (%s,%s,%s,%s::jsonb,%s,%s,%s,%s)",
            (hid, aid, uid, json.dumps(fires_today_ts()), prompt, timeline, template, thash))
        db.conn.commit()
    finally:
        db.close()
    return hid


def row(hid) -> dict:
    db = DBManager()
    try:
        db.cur.execute("SELECT prompt, note_template, note_template_prompt_hash, timeline_instruction, "
                       "last_fired, last_application FROM agent_heartbeats WHERE _id=%s", (hid,))
        r = db.cur.fetchone()
        return dict(zip(("prompt", "template", "hash", "timeline", "last_fired", "last_application"), r)) if r else {}
    finally:
        db.close()


def count_hb(uid) -> int:
    db = DBManager()
    try:
        db.cur.execute("SELECT count(*) FROM agent_heartbeats WHERE user_id=%s", (uid,))
        return db.cur.fetchone()[0]
    finally:
        db.close()


def notes(uid) -> list:
    db = DBManager()
    try:
        db.cur.execute("SELECT _id, title, text, theme FROM notes WHERE user_id=%s ORDER BY timestamp, created_at", (uid,))
        return db.cur.fetchall()
    finally:
        db.close()


def verses_for(note_id) -> list:
    db = DBManager()
    try:
        db.cur.execute("SELECT * FROM note_verses WHERE note_id=%s", (note_id,))
        return db.cur.fetchall()
    except Exception:
        db.conn.rollback()
        return None
    finally:
        db.close()


def cleanup(uid):
    db = DBManager()
    try:
        db.delete("notes", {"user_id": uid})
        db.delete("users", {"_id": uid})
    finally:
        db.close()


def fire(uid, aid, hid, force=True):
    m = M(uid)
    try:
        return m.commit_hb_response(aid, hid, "Daily devotion.", force=force)
    finally:
        m.close()


def note_json(passage, **over):
    d = {
        "__action": "create_note", "theme": "Peace",
        "check_in": "How did yesterday's kindness go?",
        "scripture": {"reference": passage, "text": "Be at peace."},
        "summary": "Paul urges peace.", "discussion": "Where is peace hard?",
        "application": "Offer one act of patience.",
    }
    d.update(over)
    return json.dumps(d)


def skeleton(text):
    out = []
    for line in text.split("\n"):
        if not line.strip():
            out.append("<blank>")
        elif line in ("Check-in", "Scripture", "Scripture summary"):
            out.append(f"H[{line}]")
        elif line.startswith(("Discussion prompt: ", "Application prompt: ")):
            out.append("L[" + line.split(":")[0] + "]")
        elif re.match(r"^[1-3]?\s?[A-Za-z ]+ \d+:\d+(-\d+)?$", line):
            out.append("<ref>")
        elif line.startswith("“"):
            out.append("<quoted>")
        else:
            out.append("<body>")
    return out


def main():
    uid = make_user()
    aid = make_agent(uid)
    try:
        print("=== A. add_heartbeat derivation ===")
        M.tl = Script(tl_response())
        M.tmpl = Script('{"kind": "structured", "sections": []}')  # always invalid
        db = M(uid)
        try:
            raised = False
            try:
                db.add_heartbeat(AgentHeartbeats(agent_id=aid, user_id=uid, timestamps=fires_today_ts(), prompt="p"))
            except TemplateDerivationError:
                raised = True
        finally:
            db.close()
        check("invalid derivation output throws TemplateDerivationError", raised)
        check("derivation retried exactly the bounded cap", M.tmpl.calls == _TEMPLATE_DERIVATION_MAX_ATTEMPTS, str(M.tmpl.calls))
        check("no heartbeat row created on failure", count_hb(uid) == 0)
        check("no timeline planning attempted after failed derivation", M.tl.calls == 0)

        M.tmpl = Script(ConnectionError("down"))
        db = M(uid)
        try:
            raised = False
            try:
                db.add_heartbeat(AgentHeartbeats(agent_id=aid, user_id=uid, timestamps=fires_today_ts(), prompt="p"))
            except TemplateDerivationError:
                raised = True
        finally:
            db.close()
        check("API error during derivation throws, no row", raised and count_hb(uid) == 0 and M.tmpl.calls == 1)

        M.tmpl = Script("not json at all", "{bad json}", f"Sure! {FIVE_JSON} done")
        db = M(uid)
        try:
            hid = db.add_heartbeat(AgentHeartbeats(agent_id=aid, user_id=uid, timestamps=fires_today_ts(), prompt="Five section prompt"))
            listed = db.get_heartbeats(aid)
        finally:
            db.close()
        r = row(hid)
        check("invalid-then-valid derivation succeeds on the last allowed attempt", bool(hid) and M.tmpl.calls == 3)
        check("template stored and valid", nt.load_stored_template(r["template"]) == nt.validate_template(FIVE))
        check("prompt hash stored", r["hash"] == nt.prompt_hash("Five section prompt"))
        check("timeline planned with the contract (dict days)",
              isinstance(AgentManager(uid)._decode_timeline(r["timeline"])["days"][0], dict))
        check("get_heartbeats hides internal columns",
              len(listed) == 1 and not any(k in listed[0] for k in ("note_template", "note_template_prompt_hash", "last_application")),
              str(list(listed[0])))
        hb_a = hid

        M.tmpl = Script(FREEFORM_JSON)
        M.tl = Script(json.dumps({"days": {"0": "just write"}, "coverage_summary": "s"}))
        db = M(uid)
        try:
            hid_ff = db.add_heartbeat(AgentHeartbeats(agent_id=aid, user_id=uid, timestamps=fires_today_ts(), prompt="Write something nice"))
        finally:
            db.close()
        r = row(hid_ff)
        check("unstructured prompt stores the explicit freeform template", json.loads(r["template"])["kind"] == "freeform")
        check("freeform schedule keeps plain-string timeline days",
              AgentManager(uid)._decode_timeline(r["timeline"])["days"][0] == "just write")

        print("\n=== B. update_heartbeat ===")
        M.tmpl = Script(FIVE_JSON)
        before = row(hb_a)
        calls0 = M.tmpl.calls
        db = M(uid)
        try:
            db.update_heartbeat(hb_a, AgentHeartbeats(agent_id=aid, user_id=uid, timestamps=fires_today_ts(),
                                                      prompt="Five section prompt", notes_public=True))
        finally:
            db.close()
        after = row(hb_a)
        check("non-prompt edit does not re-derive", M.tmpl.calls == calls0)
        check("non-prompt edit leaves template/hash/timeline intact",
              (after["template"], after["hash"], after["timeline"]) == (before["template"], before["hash"], before["timeline"]))

        M.tmpl = Script("garbage")
        db = M(uid)
        try:
            raised = False
            try:
                db.update_heartbeat(hb_a, AgentHeartbeats(agent_id=aid, user_id=uid, timestamps=[None] * 31, prompt="NEW prompt"))
            except TemplateDerivationError:
                raised = True
        finally:
            db.close()
        after = row(hb_a)
        check("prompt edit with failing derivation throws", raised and M.tmpl.calls == _TEMPLATE_DERIVATION_MAX_ATTEMPTS)
        check("failed edit leaves prompt, template, hash and timeline untouched",
              after["prompt"] == "Five section prompt" and (after["template"], after["hash"], after["timeline"])
              == (before["template"], before["hash"], before["timeline"]))

        other = {"kind": "structured", "title": {"mode": "free"},
                 "sections": [{"key": "body", "title": None, "layout": "paragraph", "kind": "text", "max_words": 100}]}
        M.tmpl = Script(json.dumps(other))
        db = M(uid)
        try:
            db.update_heartbeat(hb_a, AgentHeartbeats(agent_id=aid, user_id=uid, timestamps=fires_today_ts(), prompt="NEW prompt"))
        finally:
            db.close()
        after = row(hb_a)
        check("successful prompt edit re-derives once and updates template + hash",
              M.tmpl.calls == 1 and after["hash"] == nt.prompt_hash("NEW prompt")
              and [s["key"] for s in json.loads(after["template"])["sections"]] == ["body"])

        print("\n=== C/D. Fires: same schedule, different days -> identical layout ===")
        hb_c = raw_hb(aid, uid, prompt="Five section prompt", template=nt.dump_template(nt.validate_template(FIVE)),
                      thash=nt.prompt_hash("Five section prompt"))
        M.tmpl = Script(FIVE_JSON)
        M.tl = Script(tl_response("1 Thessalonians 5:12-15"))
        M.note = Script(note_json("1 Thessalonians 5:12-15"))
        res1 = fire(uid, aid, hb_c)
        check("day 1 fire saves a note", res1 == {"success": "saved note"}, str(res1))
        check("no template derivation on a fire when template matches prompt", M.tmpl.calls == 0)
        prompt_day1 = M.note.prompts[0]
        check("day 1 prompt carries no follow-up claim (no prior application)",
              "previous note" not in prompt_day1 and "Do not refer to any earlier note" in prompt_day1)
        check("day 1 prompt carries the planned passage",
              "1 Thessalonians 5:12-15" in prompt_day1)
        check("last_application recorded after day 1", row(hb_c)["last_application"] == "Offer one act of patience.")

        # Day 2: pretend a later day. New stored timeline day 0 with another passage; sloppy model output.
        db = DBManager()
        try:
            raw = AgentManager(uid)._encode_timeline(
                datetime.now(timezone.utc).date(),
                {0: nt.build_day_entry({"instruction": "Day two", "theme": "Joy", "passage": "1 Thessalonians 5:16-22"},
                                       nt.validate_template(FIVE), nt.CHECK_IN_FOLLOW_UP)}, "covered")
            db.cur.execute("UPDATE agent_heartbeats SET timeline_instruction=%s WHERE _id=%s", (raw, hb_c))
            db.conn.commit()
        finally:
            db.close()
        sloppy = note_json(
            "1 Thessalonians 5:16-22", theme="**Joy**",
            check_in="<p>How did **that** go?</p>\n\n\n",
            scripture={"reference": "1  Thessalonians 5:16-22", "text": '"Rejoice always."'},
            summary="## Joy\n\n- rejoice &amp; pray\n\n\nGive thanks.", discussion="  > What steals joy?  ",
            application="<b>Thank</b> God daily.",
        )
        # first response is invalid JSON, second fails validation (generic check-in), third is the sloppy-valid one
        M.note = Script("oops not json", note_json("1 Thessalonians 5:16-22", check_in="Check in with group for past applications"), sloppy)
        res2 = fire(uid, aid, hb_c)
        check("day 2 recovers within the bounded retry cap", res2 == {"success": "saved note"} and M.note.calls == 3, f"{res2} {M.note.calls}")
        check("day 2 prompt follows up on day 1's recorded application",
              "Offer one act of patience." in M.note.prompts[0])
        check("retry prompt feeds back the concrete validation reason",
              "generic prompt" in M.note.prompts[2] or "real question" in M.note.prompts[2], M.note.prompts[2][-300:])
        ns = notes(uid)
        check("two notes saved for the schedule", len(ns) == 2, str(len(ns)))
        t1, t2 = ns[0][2], ns[1][2]
        sk1, sk2 = skeleton(t1), skeleton(t2)
        check("day 1 and day 2 share heading/label/reference placement",
              [s for s in sk1 if s.startswith(("H[", "L[", "<ref>"))] == [s for s in sk2 if s.startswith(("H[", "L[", "<ref>"))],
              f"{sk1}\n{sk2}")
        check("both notes have single blank-line separators and no markup",
              all("\n\n\n" not in t and "<" not in t and "*" not in t and "&amp;" not in t for t in (t1, t2)), t2)
        check("titles follow the pattern", ns[0][1] == "Peace: 1 Thessalonians 5:12-15" and ns[1][1] == "Joy: 1 Thessalonians 5:16-22", str([n[1] for n in ns]))
        check("theme metadata populated (planned theme)", ns[0][3] == "Peace" and ns[1][3] == "Joy")
        v = verses_for(ns[1][0])
        check("verses metadata populated from the reference", v is not None and len(v) == 7, str(v))
        check("last_application advanced to day 2's application", row(hb_c)["last_application"] == "Thank God daily.")

        print("\n=== C2. Never-valid model output: nothing saved, claim unwound ===")
        db = DBManager()
        try:
            db.cur.execute("UPDATE agent_heartbeats SET last_fired=NULL WHERE _id=%s", (hb_c,))
            db.conn.commit()
        finally:
            db.close()
        n_before, app_before = len(notes(uid)), row(hb_c)["last_application"]
        M.note = Script(note_json("1 Thessalonians 5:16-22", summary=""))  # always an empty section
        res3 = fire(uid, aid, hb_c, force=False)
        check("invalid fields on every attempt -> invalid response", res3 == {"error": "invalid response"}, str(res3))
        check("retried exactly the cap", M.note.calls == _HB_JSON_PARSE_MAX_ATTEMPTS, str(M.note.calls))
        check("no note saved, last_application untouched", len(notes(uid)) == n_before and row(hb_c)["last_application"] == app_before)
        M.note = Script(note_json("1 Thessalonians 5:99-100"))  # wrong passage vs the plan
        res4 = fire(uid, aid, hb_c)
        check("model straying from the planned passage is rejected, nothing saved",
              res4 == {"error": "invalid response"} and len(notes(uid)) == n_before)

        print("\n=== E/F. Lazy derivation for pre-feature rows ===")
        legacy_tl = AgentManager(uid)._encode_timeline(datetime.now(timezone.utc).date(), {0: "Read Romans 8 today"}, "s")
        hb_e = raw_hb(aid, uid, prompt="Old schedule prompt", timeline=legacy_tl)  # no template, legacy string day
        M.tmpl = Script("nope")
        M.note = Script(note_json("Romans 8:1-4"))
        n0 = len(notes(uid))
        res = fire(uid, aid, hb_e)
        r = row(hb_e)
        check("failed lazy derivation fails the fire loudly (explicit error, no silent old-style output)",
              "error" in res and "format" in res["error"].lower(), str(res))
        check("failed lazy derivation saves no note, calls no note model", len(notes(uid)) == n0 and M.note.calls == 0)
        check("failed lazy derivation leaves template and stored (legacy) timeline untouched",
              r["template"] is None and r["timeline"] == legacy_tl)
        check("failed lazy derivation unwinds last_fired claim so the next fire can retry", r["last_fired"] is None, str(r["last_fired"]))

        M.tmpl = Script(FIVE_JSON)
        res = fire(uid, aid, hb_e, force=False)
        r = row(hb_e)
        check("next fire derives lazily (once) and saves a note on a legacy plain-string timeline",
              res == {"success": "saved note"} and M.tmpl.calls == 1, f"{res} {M.tmpl.calls}")
        check("lazy template and hash stored", r["hash"] == nt.prompt_hash("Old schedule prompt")
              and nt.load_stored_template(r["template"]) is not None)
        check("legacy timeline string preserved on the row", r["timeline"] == legacy_tl)
        last = notes(uid)[-1]
        check("lazy-derived note is rendered by the template", last[2].startswith("Check-in\n") and "Scripture\nRomans 8:1-4\n" in last[2], last[2])
        check("legacy-planned note has no pattern-title surprise (title built from theme + reference)",
              last[1].endswith(": Romans 8:1-4"), last[1])

        M.tmpl = Script(FIVE_JSON)
        M.note = Script(note_json("Romans 8:1-4"))
        fire(uid, aid, hb_e)
        check("template not re-derived on later fires when prompt unchanged", M.tmpl.calls == 0)

        db = DBManager()
        try:
            db.cur.execute("UPDATE agent_heartbeats SET prompt='Prompt changed behind the scenes' WHERE _id=%s", (hb_e,))
            db.conn.commit()
        finally:
            db.close()
        M.tmpl = Script(FIVE_JSON)
        M.note = Script(note_json("Romans 8:1-4"))
        fire(uid, aid, hb_e)
        check("stale prompt hash triggers re-derivation at fire", M.tmpl.calls == 1
              and row(hb_e)["hash"] == nt.prompt_hash("Prompt changed behind the scenes"))

        print("\n=== G. Timeline planner contract (real _generate_timeline_days) ===")
        tpl = nt.validate_template(FIVE)
        good = tl_response("Romans 8:1-4")
        bad_string_day = json.dumps({"days": {"0": "just a string"}, "coverage_summary": "s"})
        bad_no_passage = json.dumps({"days": {"0": {"instruction": "x", "theme": "t"}}, "coverage_summary": "s"})
        M.tl = Script(bad_string_day, bad_no_passage, good)
        m = M(uid)
        try:
            planned = m._generate_timeline_days("p", [0], None, template=tpl)
        finally:
            m.close()
        d0 = planned["days"][0]
        check("malformed day entries are rejected and retried, then a valid contract is accepted",
              M.tl.calls == 3 and d0["passage"] == "Romans 8:1-4" and d0["theme"] == "Peace", str(d0))
        check("contract carries lengths from the template and a check-in rule",
              d0["lengths"]["summary"] == 120 and d0["check_in_rule"] in (nt.CHECK_IN_THEME, nt.CHECK_IN_FOLLOW_UP))
        check("planner prompt describes the note layout", "NOTE LAYOUT" in M.tl.prompts[0])
        M.tl = Script(bad_string_day)
        m = M(uid)
        try:
            raised = False
            try:
                m._generate_timeline_days("p", [0], None, template=tpl)
            except TimelineGenerationError:
                raised = True
        finally:
            m.close()
        check("never-valid plan throws TimelineGenerationError (bounded)", raised)
        m = M(uid)
        try:
            check("timeline encode/decode round-trips contract dicts and legacy strings",
                  m._decode_timeline(m._encode_timeline(datetime.now(timezone.utc).date(), {0: d0, 1: "legacy"}, "s"))["days"] == {0: d0, 1: "legacy"})
        finally:
            m.close()
    finally:
        cleanup(uid)

    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    if FAILED:
        for label, detail in FAILED:
            print(f"  FAILED: {label}: {detail}")
        sys.exit(1)


if __name__ == "__main__":
    main()
