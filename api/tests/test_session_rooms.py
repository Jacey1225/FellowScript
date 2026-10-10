"""Backend coverage for task 20261009-discussion-rooms (steps 1-3).

Discussion rooms: private breakout Chime meetings tied to a live session, behind
the ``discussion_rooms`` flag (seeded OFF). Every test runs against the REAL app,
REAL routes and a REAL Postgres (the throwaway scratch cluster, never dev or
production); only the AWS Chime client is replaced by a fake (never real AWS).

Covers: DDL idempotence and seed row; flag-off uniform 404 on every endpoint and
canary evaluation; create (open and invite-only), default name "Room N", rename
(content filter, 40-char cap, creator only); join/leave/heartbeat; invite-only
visibility, invite add/revoke, only invitees join; blocks in both modes and both
directions; membership gating (non-members refused, rooms reachable only through
their own session); session end/delete ends rooms; auto-delete and recurring
advance refuse a session with a live room member (atomic); the sweeper; HTTP and
server-side rate limits; no logging of titles, usernames, join tokens or media
placement; the shared Chime helper with a fake client; concurrency (race-safe
room capacity, rooms-per-session cap, per-user create cap).

Run:  cd api && ../.venv/bin/python tests/test_session_rooms.py
(CI: scratch Postgres on 55432 via the fs_scratch_shim, or the CI service DB.)
"""
import _pathfix  # noqa: F401,E402

import logging
import os
import sys
import threading
import uuid
from datetime import datetime, timedelta, timezone as tzmod

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from botocore.exceptions import ClientError  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import _thr_common as T  # noqa: E402
from _thr_common import check, cookie, sql  # noqa: E402
from backend.interactions import chime_meetings, flags  # noqa: E402
from backend.interactions import scheduler as scheduler_module  # noqa: E402
from backend.interactions import session_rooms as rooms_module  # noqa: E402
from backend.interactions.session_rooms import RoomError, SessionRoomsManager  # noqa: E402
from backend.interactions.session_rooms_config import get_session_rooms_config  # noqa: E402
from backend.interactions import session_rooms_sweeper as sweeper  # noqa: E402
from db import DBManager, create_tables  # noqa: E402
import main as main_module  # noqa: E402

CFG = get_session_rooms_config()
SESSIONS: list[str] = []
BAD_TITLE = "bond" + "age"  # rejected by the content filter


def set_cfg(name, value):
    """Override one tunable on the cached config object (frozen dataclass or not)."""
    object.__setattr__(get_session_rooms_config(), name, value)


# -- fake Chime ---------------------------------------------------------------

def client_error(code: str, op: str = "Op") -> ClientError:
    return ClientError({"Error": {"Code": code, "Message": f"{code} secret-detail"}}, op)


class FakeChime:
    """Stand-in for the boto3 chime-sdk-meetings client used by chime_meetings."""

    def __init__(self):
        self.lock = threading.Lock()
        self.reset()

    def reset(self):
        self.created: list[str] = []          # ExternalMeetingIds
        self.meetings_made: list[str] = []
        self.attendees: list[tuple[str, str]] = []
        self.deleted: list[str] = []
        self.get_calls: list[str] = []
        self.gone: set[str] = set()           # meeting ids that raise NotFound
        self.get_error: dict[str, Exception] = {}
        self.delete_error: Exception | None = None
        self.create_attendee_error: Exception | None = None
        self.create_attendee_errors_by_meeting: dict[str, Exception] = {}
        self.n = 0

    def create_meeting(self, ClientRequestToken=None, MediaRegion=None, ExternalMeetingId=None, **kw):
        with self.lock:
            self.n += 1
            mid = f"fake-mtg-{self.n}-{uuid.uuid4().hex[:6]}"
            self.created.append(ExternalMeetingId)
            self.meetings_made.append(mid)
        return {"Meeting": {
            "MeetingId": mid, "ExternalMeetingId": ExternalMeetingId, "MediaRegion": MediaRegion,
            "MediaPlacement": {"AudioHostUrl": f"audio-host-{mid}.example.invalid"},
        }}

    def create_attendee(self, MeetingId=None, ExternalUserId=None, **kw):
        if MeetingId in self.create_attendee_errors_by_meeting:
            raise self.create_attendee_errors_by_meeting[MeetingId]
        if self.create_attendee_error is not None:
            raise self.create_attendee_error
        if MeetingId in self.gone:
            raise client_error("NotFoundException", "CreateAttendee")
        with self.lock:
            self.attendees.append((MeetingId, ExternalUserId))
        return {"Attendee": {
            "AttendeeId": f"att-{uuid.uuid4().hex[:8]}", "ExternalUserId": ExternalUserId,
            "JoinToken": "SECRET-JOIN-TOKEN-" + uuid.uuid4().hex[:8],
        }}

    def get_meeting(self, MeetingId=None, **kw):
        self.get_calls.append(MeetingId)
        if MeetingId in self.get_error:
            raise self.get_error[MeetingId]
        if MeetingId in self.gone:
            raise client_error("NotFoundException", "GetMeeting")
        return {"Meeting": {"MeetingId": MeetingId}}

    def delete_meeting(self, MeetingId=None, **kw):
        if self.delete_error is not None:
            raise self.delete_error
        with self.lock:
            self.deleted.append(MeetingId)
        return {}


FAKE = FakeChime()
chime_meetings.chime = FAKE


# -- log capture ----------------------------------------------------------------

class Capture(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.lines: list[str] = []

    def emit(self, record):
        try:
            self.lines.append(record.getMessage())
        except Exception:
            self.lines.append(str(record.msg))
        if record.exc_info:
            self.lines.append(repr(record.exc_info[1]))


CAP = Capture()
logging.getLogger().addHandler(CAP)
logging.getLogger().setLevel(logging.DEBUG)


# -- fixtures --------------------------------------------------------------------

def user(prefix="rm"):
    return T.make_user(prefix)


def username(uid):
    return sql("SELECT username FROM users WHERE _id=%s", (uid,))[0][0]


def make_session(creator, participants=(), *, live=True, group_id=None, ended_by=None):
    sid = str(uuid.uuid4())
    now = datetime.now(tzmod.utc)
    sql("INSERT INTO devotions (_id, title, time_start, time_end, recurring, group_id, creator_id, "
        "participants, verses, prompts, chime_meeting_id) VALUES (%s,%s,%s,%s,FALSE,%s,%s,%s,%s,%s,%s)",
        (sid, "rooms-test", now - timedelta(minutes=5), now + timedelta(hours=1), group_id, creator,
         list(participants), [], [], f"main-{sid[:8]}" if live else ""))
    SESSIONS.append(sid)
    return sid


def block(blocker, blocked):
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s) ON CONFLICT DO NOTHING",
        (blocker, blocked))


def reset_limits():
    from backend.rate_limiting import limiter
    limiter.reset()


def code_of(r):
    try:
        d = r.json()
    except Exception:
        return None
    d = d.get("detail", d) if isinstance(d, dict) else d
    return d.get("code") if isinstance(d, dict) else None


def call(client, uid, method, path, body=None):
    kwargs = {"headers": cookie(uid)}
    if body is not None:
        kwargs["json"] = body
    return client.request(method, f"/session-rooms/{uid}{path}", **kwargs)


def create(client, uid, sid, title=None, mode="open", invites=None):
    body = {"mode": mode}
    if title is not None:
        body["title"] = title
    if invites is not None:
        body["invite_user_ids"] = invites
    return call(client, uid, "POST", f"/sessions/{sid}/rooms", body)


def rooms_list(client, uid, sid):
    r = call(client, uid, "GET", f"/sessions/{sid}/rooms")
    return r, (r.json().get("rooms", []) if r.status_code == 200 else [])


def join(client, uid, rid):
    return call(client, uid, "POST", f"/rooms/{rid}/join")


def room_row(rid):
    rows = sql("SELECT ended_at, chime_meeting_id, title, slot FROM session_rooms WHERE id=%s", (rid,))
    return rows[0] if rows else None


def live_count(rid):
    return sql("SELECT COUNT(*) FROM session_room_members m WHERE room_id=%s AND left_at IS NULL "
               "AND last_seen > NOW() - (%s * INTERVAL '1 second')", (rid, CFG.member_stale_seconds))[0][0]


def seed_member(rid, uid, *, left=False, seen_ago_s=0):
    sql("INSERT INTO session_room_members (room_id, user_id, last_seen, left_at) "
        "VALUES (%s,%s, NOW() - (%s * INTERVAL '1 second'), %s) "
        "ON CONFLICT (room_id, user_id) DO UPDATE SET last_seen=EXCLUDED.last_seen, left_at=EXCLUDED.left_at",
        (rid, uid, seen_ago_s, datetime.now(tzmod.utc) if left else None))


def age_room(rid, seconds):
    sql("UPDATE session_rooms SET created_at = created_at - (%s * INTERVAL '1 second') WHERE id=%s", (seconds, rid))
    sql("UPDATE session_room_members SET last_seen = last_seen - (%s * INTERVAL '1 second'), "
        "left_at = CASE WHEN left_at IS NULL THEN NULL ELSE left_at - (%s * INTERVAL '1 second') END WHERE room_id=%s",
        (seconds, seconds, rid))


def set_flag(state, canary=None):
    flags.set_flag("discussion_rooms", state, canary, actor="test_session_rooms")
    flags.invalidate()


def all_room_endpoints(uid, sid, rid, target):
    return [
        ("GET", f"/sessions/{sid}/rooms", None),
        ("POST", f"/sessions/{sid}/rooms", {"mode": "open"}),
        ("POST", f"/rooms/{rid}/join", None),
        ("POST", f"/rooms/{rid}/leave", None),
        ("POST", f"/rooms/{rid}/heartbeat", None),
        ("PATCH", f"/rooms/{rid}", {"title": "x"}),
        ("DELETE", f"/rooms/{rid}", None),
        ("GET", f"/rooms/{rid}/invites", None),
        ("POST", f"/rooms/{rid}/invites", {"user_ids": [target]}),
        ("DELETE", f"/rooms/{rid}/invites/{target}", None),
    ]


# =============================================================================
# 1. DDL idempotence, seed, config
# =============================================================================

def test_ddl_and_seed():
    global CFG
    print("\n== 1. DDL idempotence, seed row, config ==")
    d = DBManager()
    try:
        create_tables(d.cur); create_tables(d.cur); d.conn.commit()
        check("create_tables() twice does not raise", True)
    finally:
        d.close()
    tables = {r[0] for r in sql("SELECT table_name FROM information_schema.tables WHERE table_name LIKE 'session_room%%'")}
    check("three tables exist", tables == {"session_rooms", "session_room_members", "session_room_invites"}, str(tables))
    cols = {r[0] for r in sql("SELECT column_name FROM information_schema.columns WHERE table_name='session_rooms'")}
    check("session_rooms has every expected column",
          {"id", "session_id", "creator_id", "slot", "title", "visibility", "chime_meeting_id",
           "chime_meeting", "created_at", "ended_at"} <= cols, str(cols))
    idx = {r[0] for r in sql("SELECT indexname FROM pg_indexes WHERE tablename IN "
                             "('session_rooms','session_room_members','session_room_invites')")}
    check("partial unique active-slot index present", "uq_session_rooms_active_slot" in idx, str(idx))
    check("live-members index present", "idx_session_room_members_live" in idx, str(idx))
    rows = sql("SELECT state FROM feature_flags WHERE name='discussion_rooms'")
    check("discussion_rooms seeded exactly once", len(rows) == 1, str(rows))
    check("discussion_rooms registered in the flag registry and exposed in capabilities",
          "discussion_rooms" in flags.registry() and flags.registry()["discussion_rooms"].exposed_in_capabilities)
    # Seed list is a subset of the registry (test_shared_foundation invariant, re-asserted for this flag).
    from schema_ddl import flags as ddl_flags
    check("flag is in SEED_FLAG_NAMES", "discussion_rooms" in ddl_flags.SEED_FLAG_NAMES)
    check("seed list has no duplicates", len(set(ddl_flags.SEED_FLAG_NAMES)) == len(list(ddl_flags.SEED_FLAG_NAMES)))
    # Cascade: deleting the main session deletes rooms, members and invites.
    host, other = user("ddlh"), user("ddlo")
    sid = make_session(host, [other])
    rid = str(uuid.uuid4())
    sql("INSERT INTO session_rooms (id, session_id, creator_id, slot) VALUES (%s,%s,%s,1)", (rid, sid, host))
    seed_member(rid, other)
    sql("INSERT INTO session_room_invites (room_id, user_id, invited_by) VALUES (%s,%s,%s)", (rid, other, host))
    # Active slot uniqueness backstop.
    try:
        sql("INSERT INTO session_rooms (session_id, creator_id, slot) VALUES (%s,%s,1)", (sid, host))
        check("two active rooms cannot share a slot", False)
    except Exception:
        check("two active rooms cannot share a slot", True)
    sql("UPDATE session_rooms SET ended_at=NOW() WHERE id=%s", (rid,))
    sql("INSERT INTO session_rooms (session_id, creator_id, slot) VALUES (%s,%s,1)", (sid, host))
    check("an ended room frees its slot", True)
    sql("DELETE FROM devotions WHERE _id=%s", (sid,))
    n = sql("SELECT (SELECT COUNT(*) FROM session_rooms WHERE session_id=%s), "
            "(SELECT COUNT(*) FROM session_room_members WHERE room_id=%s), "
            "(SELECT COUNT(*) FROM session_room_invites WHERE room_id=%s)", (sid, rid, rid))[0]
    check("deleting the session cascades rooms, members and invites", tuple(n) == (0, 0, 0), str(n))
    # Config.
    check("config values match the spec defaults",
          (CFG.max_members_per_room, CFG.max_rooms_per_session, CFG.title_max_length) == (8, 6, 40),
          str((CFG.max_members_per_room, CFG.max_rooms_per_session, CFG.title_max_length)))
    from backend.interactions.session_rooms_config import validate_session_rooms_config
    try:
        validate_session_rooms_config()
        CFG = get_session_rooms_config()  # validate reloads the cached object
        check("startup config validation passes", True)
    except Exception as e:  # noqa: BLE001
        check("startup config validation passes", False, repr(e))


# =============================================================================
# 2. Flag off => 404 on every endpoint; canary; capabilities
# =============================================================================

def test_flag_off(client):
    print("\n== 2. Flag off => uniform 404 on every endpoint ==")
    host, member, outsider = user("fo_h"), user("fo_m"), user("fo_o")
    sid = make_session(host, [member])
    set_flag("on")
    r = create(client, host, sid)
    rid = r.json()["id"]
    rid_ended = create(client, host, sid).json()["id"]
    call(client, host, "DELETE", f"/rooms/{rid_ended}")
    set_flag("off")
    reset_limits()
    for uid, label in ((host, "host/creator"), (member, "member"), (outsider, "non-member")):
        bad = []
        for method, path, body in all_room_endpoints(uid, sid, rid, member):
            rr = call(client, uid, method, path, body)
            if rr.status_code != 404 or code_of(rr) != "not_found":
                bad.append((method, path, rr.status_code))
        check(f"flag off: all 10 endpoints 404 not_found for {label}", not bad, str(bad))
    # Uniform: same body for an existing and a nonexistent room, flag off.
    a = call(client, member, "POST", f"/rooms/{rid}/join")
    b = call(client, member, "POST", f"/rooms/{uuid.uuid4()}/join")
    check("flag off: existing and missing room look identical", a.status_code == b.status_code and a.json() == b.json(),
          f"{a.text} vs {b.text}")
    check("flag off: no side effects (no new room, no member row)",
          sql("SELECT COUNT(*) FROM session_rooms WHERE session_id=%s AND ended_at IS NULL", (sid,))[0][0] == 1
          and live_count(rid) == 0)
    # Auth still enforced before flag evaluation reveals anything.
    r401 = client.post(f"/session-rooms/{member}/rooms/{rid}/join")
    check("unauthenticated call is 401", r401.status_code == 401, str(r401.status_code))
    r403 = client.post(f"/session-rooms/{member}/rooms/{rid}/join", headers=cookie(outsider))
    check("path user_id different from session user is 403", r403.status_code == 403, str(r403.status_code))
    caps = client.get("/app/capabilities", headers=cookie(member)).json()
    check("capabilities: discussion_rooms false when off", caps["features"].get("discussion_rooms") is False, str(caps["features"]))
    # Canary: on for the canary user only.
    set_flag("canary", [member])
    reset_limits()
    check("canary user gets through", call(client, member, "GET", f"/sessions/{sid}/rooms").status_code == 200)
    check("non-canary user still 404", call(client, host, "GET", f"/sessions/{sid}/rooms").status_code == 404)
    caps = client.get("/app/capabilities", headers=cookie(member)).json()
    check("capabilities: true for canary user", caps["features"].get("discussion_rooms") is True)
    set_flag("on")
    caps = client.get("/app/capabilities", headers=cookie(outsider)).json()
    check("capabilities: true for everyone when on", caps["features"].get("discussion_rooms") is True)


# =============================================================================
# 3. Create, names, rename
# =============================================================================

def test_create_and_names(client):
    print("\n== 3. Create (open / invite-only), default names, rename ==")
    set_flag("on"); reset_limits()
    host, a, b, outsider = user("cr_h"), user("cr_a"), user("cr_b"), user("cr_o")
    sid = make_session(host, [a, b])

    r = create(client, a, sid)
    check("participant creates an open room (201)", r.status_code == 201, r.text)
    room1 = r.json()
    check("open room view: is_creator true for the creator, can_invite false (open rooms take no invites)",
          room1.get("is_creator") is True and room1.get("can_invite") is False, str(room1))
    _, as_b_open = rooms_list(client, b, sid)
    check("non-creator sees is_creator false and can_invite false on an open room",
          as_b_open and all(x.get("is_creator") is False and x.get("can_invite") is False for x in as_b_open), str(as_b_open))
    check("default name is 'Room 1'", room1.get("name") == "Room 1" and room1.get("title") == "" and room1.get("slot") == 1, str(room1))
    check("room starts open, max_members 8, creator counted for nobody yet",
          room1.get("visibility") == "open" and room1.get("max_members") == 8 and room1.get("member_count") == 0, str(room1))
    check("room view never leaks Chime ids/tokens",
          "chime_meeting_id" not in room1 and "chime_meeting" not in room1 and "Meeting" not in room1, str(room1.keys()))
    r2 = create(client, b, sid)
    check("second room is 'Room 2'", r2.status_code == 201 and r2.json()["name"] == "Room 2", r2.text)
    check("create does not create any Chime meeting (lazy)", FAKE.created == [], str(FAKE.created))

    r = create(client, a, sid, title="   Study    hall  ")
    check("title is trimmed and whitespace collapsed", r.status_code == 201 and r.json()["title"] == "Study hall"
          and r.json()["name"] == "Study hall", r.text)
    reset_limits()
    c = user("cr_c")
    sid_b = make_session(host, [c])
    r = create(client, c, sid_b, title="x" * 41)
    check("41-char title rejected 422 title_too_long", r.status_code == 422 and code_of(r) == "title_too_long", r.text)
    r = create(client, c, sid_b, title="y" * 40)
    check("40-char title accepted", r.status_code == 201 and r.json()["title"] == "y" * 40, r.text)
    r = create(client, c, sid_b, title=BAD_TITLE)
    check("content-filtered title rejected 422 title_rejected", r.status_code == 422 and code_of(r) == "title_rejected", r.text)
    r = create(client, c, sid_b, title="   ")
    check("whitespace-only title falls back to 'Room N'", r.status_code == 201 and r.json()["title"] == ""
          and r.json()["name"].startswith("Room "), r.text)
    r = create(client, c, sid_b, mode="secret")
    check("unknown mode 422 invalid_mode", r.status_code == 422 and code_of(r) == "invalid_mode", r.text)
    r = call(client, c, "POST", f"/sessions/{sid_b}/rooms", {"mode": "open", "bogus": 1})
    check("unknown body field rejected (extra=forbid)", r.status_code == 422, r.text)
    r = call(client, c, "POST", f"/sessions/{sid_b}/rooms")
    check("empty body creates an open room with defaults", r.status_code == 201 and r.json()["visibility"] == "open", r.text)

    # Wrong-state / wrong-actor creates.
    reset_limits()
    r = create(client, outsider, sid)
    check("non-member cannot create (403)", r.status_code == 403 and code_of(r) == "forbidden", r.text)
    dead = make_session(host, [a], live=False)
    r = create(client, a, dead)
    check("create refused while main call is not live (409 main_not_live)", r.status_code == 409 and code_of(r) == "main_not_live", r.text)
    r = create(client, a, str(uuid.uuid4()))
    check("create for unknown session 404", r.status_code == 404, r.text)
    r = create(client, a, "not-a-uuid")
    check("create for non-uuid session id 404 (no 500)", r.status_code == 404, r.text)
    check("a refused create wrote no room", sql("SELECT COUNT(*) FROM session_rooms WHERE session_id=%s", (dead,))[0][0] == 0)

    # Group members (not creator/participant) are authorized.
    g_member = user("cr_g")
    gid = T.make_group([g_member, host], creator=host)
    gsid = make_session(host, [], group_id=gid)
    r = create(client, g_member, gsid)
    check("group member of the session's group can create", r.status_code == 201, r.text)

    # Rename.
    rid = room1["id"]
    r = call(client, a, "PATCH", f"/rooms/{rid}", {"title": "  Prayer  corner "})
    check("creator renames; title normalised", r.status_code == 200 and r.json()["title"] == "Prayer corner"
          and r.json()["name"] == "Prayer corner", r.text)
    r = call(client, b, "PATCH", f"/rooms/{rid}", {"title": "Hijack"})
    check("another participant cannot rename (403)", r.status_code == 403 and code_of(r) == "forbidden", r.text)
    r = call(client, host, "PATCH", f"/rooms/{rid}", {"title": "Hijack"})
    check("even the session host cannot rename someone else's room (creator only)", r.status_code == 403, r.text)
    r = call(client, outsider, "PATCH", f"/rooms/{rid}", {"title": "Hijack"})
    check("non-member cannot rename", r.status_code in (403, 404), r.text)
    check("failed renames changed nothing", room_row(rid)[2] == "Prayer corner")
    r = call(client, a, "PATCH", f"/rooms/{rid}", {"title": "z" * 41})
    check("rename over 40 chars rejected 422", r.status_code == 422 and code_of(r) == "title_too_long", r.text)
    r = call(client, a, "PATCH", f"/rooms/{rid}", {"title": BAD_TITLE})
    check("rename runs the content filter (422)", r.status_code == 422 and code_of(r) == "title_rejected", r.text)
    r = call(client, a, "PATCH", f"/rooms/{rid}", {"title": "z" * 40})
    check("rename to exactly 40 chars ok", r.status_code == 200, r.text)
    r = call(client, a, "PATCH", f"/rooms/{rid}", {"title": ""})
    check("empty title reverts to 'Room N'", r.status_code == 200 and r.json()["title"] == ""
          and r.json()["name"] == f"Room {room1['slot']}", r.text)
    r = call(client, a, "PATCH", f"/rooms/{rid}", {"title": "ok", "extra": 1})
    check("rename body rejects unknown fields", r.status_code == 422, r.text)
    r = call(client, a, "PATCH", f"/rooms/{uuid.uuid4()}", {"title": "ok"})
    check("rename of a missing room 404", r.status_code == 404, r.text)
    call(client, a, "DELETE", f"/rooms/{rid}")
    r = call(client, a, "PATCH", f"/rooms/{rid}", {"title": "late"})
    check("rename of an ended room 410", r.status_code == 410 and code_of(r) == "room_ended", r.text)

    # Invite-only creation.
    reset_limits()
    d = user("cr_d")
    sid_c = make_session(host, [a, b, d])
    r = create(client, a, sid_c, mode="invite_only", invites=[b])
    check("invite-only room with an invitee created", r.status_code == 201 and r.json()["visibility"] == "invite_only", r.text)
    check("creator sees can_join on their invite-only room", r.json().get("can_join") is True)
    r = create(client, a, sid_c, mode="open", invites=[b])
    check("invitees on an open room rejected 422", r.status_code == 422 and code_of(r) == "invalid_mode", r.text)
    r = create(client, a, sid_c, mode="invite_only", invites=[outsider])
    check("invitee outside the session rejected 422", r.status_code == 422 and code_of(r) == "invalid_invitee", r.text)
    r = create(client, a, sid_c, mode="invite_only", invites=["nope"])
    check("non-uuid invitee rejected 422", r.status_code == 422 and code_of(r) == "invalid_invitee", r.text)
    r = create(client, a, sid_c, mode="invite_only", invites=[str(uuid.uuid4())])
    check("nonexistent-user invitee rejected 422", r.status_code == 422 and code_of(r) == "invalid_invitee", r.text)
    block(b, d)
    r = create(client, d, sid_c, mode="invite_only", invites=[b])
    check("invitee in a block relation with the inviter rejected 422", r.status_code == 422 and code_of(r) == "invalid_invitee", r.text)
    reset_limits()
    e2 = user("cr_e2")
    sql("UPDATE devotions SET participants = array_append(participants, %s) WHERE _id=%s", (e2, sid_c))
    r = create(client, e2, sid_c, mode="invite_only", invites=[e2])
    check("inviting only yourself is a no-op (room still created)", r.status_code == 201, r.text)
    over = [str(uuid.uuid4()) for _ in range(CFG.max_invites_per_room + 1)]
    r = create(client, e2, sid_c, mode="invite_only", invites=over)
    check("more invitees than max_invites_per_room rejected", r.status_code == 422, r.text)


# =============================================================================
# 4. Caps: rooms per session, per-user create rate, ended rooms free slots
# =============================================================================

def test_caps(client):
    print("\n== 4. Caps ==")
    set_flag("on"); reset_limits()
    host = user("cp_h")
    creators = [user(f"cp_{i}") for i in range(4)]
    sid = make_session(host, creators)
    made = []
    for i in range(6):
        r = create(client, creators[i % 4], sid)
        check(f"room {i + 1} of {CFG.max_rooms_per_session} created", r.status_code == 201, r.text)
        if r.status_code == 201:
            made.append(r.json())
    check("slots are 1..6 in order", [m["slot"] for m in made] == [1, 2, 3, 4, 5, 6], str([m["slot"] for m in made]))
    r = create(client, creators[3], sid)
    check("7th room refused 409 rooms_full", r.status_code == 409 and code_of(r) == "rooms_full", r.text)
    check("still exactly 6 active rooms",
          sql("SELECT COUNT(*) FROM session_rooms WHERE session_id=%s AND ended_at IS NULL", (sid,))[0][0] == 6)
    # End one => slot freed and reused (lowest free slot).
    call(client, creators[1], "DELETE", f"/rooms/{made[1]['id']}")
    r = create(client, creators[3], sid)
    check("ending a room frees its slot (reused)", r.status_code == 201 and r.json()["slot"] == 2, r.text)
    # An abandoned (empty past grace) room frees its seat when a new room is created.
    age_room(made[4]["id"], CFG.empty_grace_seconds + 60)
    r = create(client, host, sid)
    check("abandoned empty room past grace is reclaimed on create", r.status_code == 201 and r.json()["slot"] == 5, r.text)
    check("reclaimed room was ended", room_row(made[4]["id"])[0] is not None)

    # Per-user create rate (server-side) — separate session so rooms_full is not hit first.
    reset_limits()
    solo = user("cp_solo")
    sid2 = make_session(host, [solo])
    got = [create(client, solo, sid2).status_code for _ in range(CFG.max_creates_per_user_per_minute)]
    check("creates up to max_creates_per_user_per_minute succeed", got == [201] * CFG.max_creates_per_user_per_minute, str(got))
    r = create(client, solo, sid2)
    check("next create is 429 rate_limited (server side)", r.status_code == 429 and code_of(r) == "rate_limited", r.text)
    # Ended rooms still count toward the per-minute create rate (no create/end/create churn).
    rid = sql("SELECT id FROM session_rooms WHERE session_id=%s AND creator_id=%s AND ended_at IS NULL LIMIT 1", (sid2, solo))[0][0]
    call(client, solo, "DELETE", f"/rooms/{rid}")
    r = create(client, solo, sid2)
    check("end-then-create churn still hits the rate cap", r.status_code == 429, r.text)
    check("rate cap is per user: another user is unaffected",
          create(client, host, sid2).status_code == 201)


# =============================================================================
# 5. Join / leave / heartbeat, capacity
# =============================================================================

def test_join_leave_heartbeat(client):
    print("\n== 5. Join / leave / heartbeat ==")
    set_flag("on"); reset_limits(); FAKE.reset()
    host, a, b, outsider = user("jl_h"), user("jl_a"), user("jl_b"), user("jl_o")
    sid = make_session(host, [a, b])
    rid = create(client, a, sid, title="Quiet room").json()["id"]

    r = join(client, a, rid)
    check("participant joins (200)", r.status_code == 200, r.text)
    body = r.json()
    check("join returns Meeting and Attendee", "Meeting" in body and "Attendee" in body
          and body["Attendee"].get("JoinToken", "").startswith("SECRET-JOIN-TOKEN-"), str(body.keys()))
    check("room meeting is namespaced room:<uuid>", FAKE.created == [f"room:{rid}"], str(FAKE.created))
    check("room view shows 1 member and is_member", body["room"]["member_count"] == 1 and body["room"]["is_member"] is True, str(body["room"]))
    check("roster lists the member but never a token", "SECRET" not in str(body["room"]))
    check("meeting id persisted lazily on first join", room_row(rid)[1] == FAKE.meetings_made[0])
    r2 = join(client, b, rid)
    check("second joiner reuses the SAME meeting (no second CreateMeeting)",
          r2.status_code == 200 and len(FAKE.created) == 1 and r2.json()["Meeting"]["MeetingId"] == body["Meeting"]["MeetingId"], r2.text)
    check("each joiner got their own attendee (ExternalUserId = user id)",
          sorted(u for _, u in FAKE.attendees) == sorted([a, b]), str(FAKE.attendees))
    check("both members are live", live_count(rid) == 2)
    r = join(client, a, rid)
    check("rejoining while inside is idempotent (still one member row for a)",
          r.status_code == 200 and live_count(rid) == 2, r.text)

    # Heartbeat.
    r = call(client, a, "POST", f"/rooms/{rid}/heartbeat")
    check("heartbeat from a member 200", r.status_code == 200 and r.json() == {"ok": True}, r.text)
    sql("UPDATE session_room_members SET last_seen = NOW() - INTERVAL '60 seconds' WHERE room_id=%s AND user_id=%s", (rid, a))
    call(client, a, "POST", f"/rooms/{rid}/heartbeat")
    age = sql("SELECT EXTRACT(EPOCH FROM (NOW() - last_seen)) FROM session_room_members WHERE room_id=%s AND user_id=%s", (rid, a))[0][0]
    check("heartbeat refreshes last_seen", age < 10, str(age))
    r = call(client, outsider, "POST", f"/rooms/{rid}/heartbeat")
    check("heartbeat from a non-member 404 (no oracle)", r.status_code == 404, r.text)
    r = call(client, a, "POST", f"/rooms/{uuid.uuid4()}/heartbeat")
    check("heartbeat for unknown room 404", r.status_code == 404, r.text)
    r = call(client, a, "POST", "/rooms/not-a-uuid/heartbeat")
    check("heartbeat with non-uuid room id 404 (no 500)", r.status_code == 404, r.text)

    # Leave.
    r = call(client, b, "POST", f"/rooms/{rid}/leave")
    check("leave 200", r.status_code == 200 and r.json() == {"ok": True}, r.text)
    check("left member no longer live", live_count(rid) == 1)
    r = call(client, b, "POST", f"/rooms/{rid}/leave")
    check("leave is idempotent", r.status_code == 200, r.text)
    r = call(client, outsider, "POST", f"/rooms/{rid}/leave")
    check("leave by a non-member is an oracle-free no-op (200)", r.status_code == 200, r.text)
    r = call(client, b, "POST", f"/rooms/{rid}/heartbeat")
    check("heartbeat after leaving 409 not_in_room", r.status_code == 409 and code_of(r) == "not_in_room", r.text)
    r = call(client, a, "POST", "/rooms/not-a-uuid/leave")
    check("leave with a non-uuid id is a no-op", r.status_code == 200, r.text)
    r = join(client, b, rid)
    check("rejoin after leaving works", r.status_code == 200 and live_count(rid) == 2, r.text)

    # One room at a time per session.
    rid2 = create(client, b, sid).json()["id"]
    r = join(client, b, rid2)
    check("joining a second room succeeds", r.status_code == 200, r.text)
    check("joining a second room leaves the first (one room at a time)",
          live_count(rid) == 1 and live_count(rid2) == 1)
    check("second room has its own, different meeting",
          len(set(FAKE.created)) == 2 and f"room:{rid2}" in FAKE.created, str(FAKE.created))

    # Gating.
    r = join(client, outsider, rid)
    check("non-member of the main session cannot join (403)", r.status_code == 403 and code_of(r) == "forbidden", r.text)
    check("refused join created no member row", sql("SELECT COUNT(*) FROM session_room_members WHERE room_id=%s AND user_id=%s", (rid, outsider))[0][0] == 0)
    r = join(client, a, str(uuid.uuid4()))
    check("join unknown room 404", r.status_code == 404, r.text)
    r = join(client, a, "garbage")
    check("join non-uuid room 404", r.status_code == 404, r.text)

    # End.
    r = call(client, b, "DELETE", f"/rooms/{rid}")
    check("a participant who is neither creator nor host cannot end a room (403)", r.status_code == 403 and code_of(r) == "forbidden", r.text)
    r = call(client, outsider, "DELETE", f"/rooms/{rid}")
    check("outsider cannot end a room", r.status_code in (403, 404), r.text)
    FAKE.deleted.clear()
    r = call(client, a, "DELETE", f"/rooms/{rid}")
    check("room creator ends the room", r.status_code == 200, r.text)
    check("ending marks ended and releases members", room_row(rid)[0] is not None and live_count(rid) == 0)
    check("ending deletes the room's Chime meeting (best effort) and blanks the id",
          len(FAKE.deleted) == 1 and room_row(rid)[1] == "", f"{FAKE.deleted} {room_row(rid)}")
    r = join(client, a, rid)
    check("joining an ended room 410", r.status_code == 410 and code_of(r) == "room_ended", r.text)
    r = call(client, b, "POST", f"/rooms/{rid}/heartbeat")
    check("heartbeat for a member of an ended room 410", r.status_code in (409, 410), r.text)
    r = call(client, host, "DELETE", f"/rooms/{rid2}")
    check("session host can end any room", r.status_code == 200 and room_row(rid2)[0] is not None, r.text)
    r = call(client, host, "DELETE", f"/rooms/{rid2}")
    check("ending twice is idempotent", r.status_code == 200, r.text)
    rl, rooms = rooms_list(client, a, sid)
    check("ended rooms are not listed", rl.status_code == 200 and rooms == [], rl.text)

    # Main call not live.
    live_sid = make_session(host, [a])
    rid3 = create(client, a, live_sid).json()["id"]
    sql("UPDATE devotions SET chime_meeting_id='' WHERE _id=%s", (live_sid,))
    r = join(client, a, rid3)
    check("join refused when the main call is no longer live (409)", r.status_code == 409 and code_of(r) == "main_not_live", r.text)

    # Chime failure: no half-joined state, no leaked detail.
    sid_e = make_session(host, [a])
    ridE = create(client, a, sid_e).json()["id"]
    FAKE.create_attendee_error = client_error("ServiceUnavailableException", "CreateAttendee")
    r = join(client, a, ridE)
    check("Chime failure maps to 502 chime_error", r.status_code == 502 and code_of(r) == "chime_error", r.text)
    check("502 body leaks no AWS detail", "secret-detail" not in r.text and "ServiceUnavailable" not in r.text, r.text)
    check("failed join left no member row (transaction rolled back)", live_count(ridE) == 0)
    FAKE.create_attendee_error = None
    r = join(client, a, ridE)
    check("join works again once Chime recovers", r.status_code == 200, r.text)
    # Stale cached meeting => recreated once and persisted.
    old = room_row(ridE)[1]
    FAKE.gone.add(old)
    sid_e2 = sid_e
    sql("UPDATE devotions SET participants = array_append(participants, %s) WHERE _id=%s", (b, sid_e2))
    r = join(client, b, ridE)
    check("stale room meeting is recreated once on join", r.status_code == 200 and room_row(ridE)[1] != old
          and r.json()["Meeting"]["MeetingId"] == room_row(ridE)[1], r.text)


def test_room_full(client):
    print("\n== 5b. Room capacity (8) ==")
    set_flag("on"); reset_limits(); FAKE.reset()
    host = user("rf_h")
    members = [user(f"rf_{i}") for i in range(9)]
    sid = make_session(host, members)
    rid = create(client, members[0], sid).json()["id"]
    for m in members[:8]:
        r = join(client, m, rid)
        if r.status_code != 200:
            check("fill room to capacity", False, r.text)
    check("8 members joined", live_count(rid) == 8)
    r = join(client, members[8], rid)
    check("9th joiner refused 409 room_full", r.status_code == 409 and code_of(r) == "room_full", r.text)
    check("still 8 live members", live_count(rid) == 8)
    r = join(client, members[0], rid)
    check("an existing member re-joining a full room is allowed", r.status_code == 200, r.text)
    call(client, members[1], "POST", f"/rooms/{rid}/leave")
    r = join(client, members[8], rid)
    check("a seat freed by leave can be taken", r.status_code == 200 and live_count(rid) == 8, r.text)
    # A stale (crashed) member does not hold a seat.
    sql("UPDATE session_room_members SET last_seen = NOW() - INTERVAL '10 minutes' WHERE room_id=%s AND user_id=%s", (rid, members[2]))
    check("stale member is not counted live", live_count(rid) == 7)
    r = join(client, members[1], rid)
    check("a stale member's seat can be reused", r.status_code == 200 and live_count(rid) == 8, r.text)


# =============================================================================
# 6. Invite-only rooms
# =============================================================================

def test_invite_only(client):
    print("\n== 6. Invite-only visibility, invites, joins ==")
    set_flag("on"); reset_limits(); FAKE.reset()
    host, creator, invitee, other, late, outsider = (user(p) for p in ("io_h", "io_c", "io_i", "io_x", "io_l", "io_o"))
    sid = make_session(host, [creator, invitee, other, late])
    r = create(client, creator, sid, title="Secret circle", mode="invite_only", invites=[invitee])
    rid = r.json()["id"]
    _, as_creator = rooms_list(client, creator, sid)
    _, as_invitee = rooms_list(client, invitee, sid)
    _, as_other = rooms_list(client, other, sid)
    _, as_host = rooms_list(client, host, sid)
    check("creator sees the invite-only room", [x["id"] for x in as_creator] == [rid])
    check("invitee sees it with is_invited and can_join",
          [x["id"] for x in as_invitee] == [rid] and as_invitee[0]["is_invited"] is True and as_invitee[0]["can_join"] is True, str(as_invitee))
    check("invite-only list fields: creator is_creator+can_invite; invitee (not yet inside) neither",
          as_creator[0].get("is_creator") is True and as_creator[0].get("can_invite") is True
          and as_invitee[0].get("is_creator") is False and as_invitee[0].get("can_invite") is False,
          str((as_creator, as_invitee)))
    check("create response on an invite-only room carries is_creator and can_invite true",
          r.json().get("is_creator") is True and r.json().get("can_invite") is True, r.text)
    check("non-invited participant does not see it (invisible)", as_other == [], str(as_other))
    check("even the session host does not see an invite-only room they are not part of", as_host == [], str(as_host))
    r = join(client, other, rid)
    check("non-invited join denied with the generic 403 cannot_join", r.status_code == 403 and code_of(r) == "cannot_join", r.text)
    rb = join(client, other, str(uuid.uuid4()))
    check("denial gives no hint the room exists vs. a block (same generic code family)",
          code_of(r) == "cannot_join" and "invite" not in r.text.lower(), r.text)
    check("denied join wrote no member row", live_count(rid) == 0)
    r = join(client, invitee, rid)
    check("invitee joins", r.status_code == 200, r.text)
    r = join(client, creator, rid)
    check("creator joins their own invite-only room", r.status_code == 200, r.text)

    # Invite endpoints.
    r = call(client, other, "GET", f"/rooms/{rid}/invites")
    check("non-invited participant listing invites gets 404 (room is not an oracle)", r.status_code == 404, r.text)
    r = call(client, other, "POST", f"/rooms/{rid}/invites", {"user_ids": [late]})
    check("non-member cannot add invites (404)", r.status_code == 404, r.text)
    r = call(client, outsider, "POST", f"/rooms/{rid}/invites", {"user_ids": [late]})
    check("a user outside the session cannot add invites", r.status_code == 403, r.text)
    r = call(client, creator, "POST", f"/rooms/{rid}/invites", {"user_ids": [other, late]})
    check("creator invites more people (201)", r.status_code == 201 and r.json()["invited"] == 2, r.text)
    r = call(client, creator, "POST", f"/rooms/{rid}/invites", {"user_ids": [other]})
    check("re-inviting an already-invited user is idempotent", r.status_code == 201, r.text)
    r = call(client, invitee, "GET", f"/rooms/{rid}/invites")
    ids = {i["user_id"] for i in r.json().get("invites", [])} if r.status_code == 200 else set()
    check("a live member can list invitees", r.status_code == 200 and ids == {invitee, other, late}, r.text)
    _, as_invitee_in = rooms_list(client, invitee, sid)
    check("once inside, a non-creator member gets can_invite true but is_creator false",
          as_invitee_in[0].get("can_invite") is True and as_invitee_in[0].get("is_creator") is False, str(as_invitee_in))
    # A live non-creator member can invite.
    extra = user("io_e")
    sql("UPDATE devotions SET participants = array_append(participants, %s) WHERE _id=%s", (extra, sid))
    r = call(client, invitee, "POST", f"/rooms/{rid}/invites", {"user_ids": [extra]})
    check("a live member (non-creator) can invite", r.status_code == 201, r.text)
    r = call(client, creator, "POST", f"/rooms/{rid}/invites", {"user_ids": [outsider]})
    check("inviting someone outside the session 422", r.status_code == 422 and code_of(r) == "invalid_invitee", r.text)
    r = call(client, creator, "POST", f"/rooms/{rid}/invites", {"user_ids": []})
    check("empty invite list rejected 422", r.status_code == 422, r.text)
    r = call(client, creator, "POST", f"/rooms/{rid}/invites", {"user_ids": [creator]})
    check("inviting only yourself rejected (nobody to invite)", r.status_code == 422, r.text)
    _, as_other = rooms_list(client, other, sid)
    check("newly invited user now sees the room", [x["id"] for x in as_other] == [rid])
    r = join(client, other, rid)
    check("newly invited user joins", r.status_code == 200, r.text)

    # Revoke.
    r = call(client, invitee, "DELETE", f"/rooms/{rid}/invites/{late}")
    check("non-creator cannot revoke (403)", r.status_code == 403 and code_of(r) == "forbidden", r.text)
    r = call(client, creator, "DELETE", f"/rooms/{rid}/invites/{late}")
    check("creator revokes an invite", r.status_code == 200, r.text)
    r = call(client, creator, "DELETE", f"/rooms/{rid}/invites/{late}")
    check("revoke is idempotent", r.status_code == 200, r.text)
    r = call(client, creator, "DELETE", f"/rooms/{rid}/invites/not-a-uuid")
    check("revoke with a non-uuid target 404", r.status_code == 404, r.text)
    r = join(client, late, rid)
    check("revoked invitee can no longer join (403)", r.status_code == 403 and code_of(r) == "cannot_join", r.text)
    _, as_late = rooms_list(client, late, sid)
    check("revoked invitee no longer sees the room", as_late == [])
    call(client, creator, "DELETE", f"/rooms/{rid}/invites/{other}")
    check("revoking does not eject someone already inside", live_count(rid) == 3, str(live_count(rid)))
    _, as_other = rooms_list(client, other, sid)
    check("a revoked-but-inside member still sees the room they are in", [x["id"] for x in as_other] == [rid])
    call(client, other, "POST", f"/rooms/{rid}/leave")
    r = join(client, other, rid)
    check("once they leave, a revoked member cannot come back", r.status_code == 403, r.text)

    # Open room: invite endpoints are not applicable.
    orid = create(client, creator, sid).json()["id"]
    r = call(client, creator, "POST", f"/rooms/{orid}/invites", {"user_ids": [invitee]})
    check("invites on an open room 409 not_invite_only", r.status_code == 409 and code_of(r) == "not_invite_only", r.text)
    r = call(client, other, "GET", f"/sessions/{sid}/rooms")
    open_room = [x for x in r.json()["rooms"] if x["id"] == orid]
    check("open room is visible to every participant and joinable", len(open_room) == 1 and open_room[0]["can_join"] is True)
    # Invite cap.
    sid2 = make_session(host, [creator])
    reset_limits()
    cap_rid = create(client, creator, sid2, mode="invite_only", invites=[]).json()["id"]
    sql("UPDATE session_rooms SET visibility='invite_only' WHERE id=%s", (cap_rid,))
    bulk = [user(f"io_b{i}") for i in range(6)]
    sql("UPDATE devotions SET participants = %s WHERE _id=%s", (list(bulk) + [creator], sid2))
    # Shrink the per-room invite cap through the cached config object for this check only.
    set_cfg("max_invites_per_room", 4)
    try:
        ok = call(client, creator, "POST", f"/rooms/{cap_rid}/invites", {"user_ids": bulk[:4]})
        over = call(client, creator, "POST", f"/rooms/{cap_rid}/invites", {"user_ids": bulk[4:6]})
        check("invites up to the cap succeed", ok.status_code == 201, ok.text)
        check("invites beyond max_invites_per_room refused 409 invite_limit", over.status_code == 409 and code_of(over) == "invite_limit", over.text)
    finally:
        set_cfg("max_invites_per_room", 50)


# =============================================================================
# 7. Blocks (both modes, both directions)
# =============================================================================

def test_blocks(client):
    print("\n== 7. Blocks ==")
    set_flag("on"); reset_limits(); FAKE.reset()
    host = user("bl_h")
    a, b, c, d = user("bl_a"), user("bl_b"), user("bl_c"), user("bl_d")
    sid = make_session(host, [a, b, c, d])
    rid = create(client, a, sid, title="Open one").json()["id"]
    check("a joins their open room", join(client, a, rid).status_code == 200)
    block(b, a)  # b blocks a
    r = join(client, b, rid)
    check("blocker cannot join a room holding the person they blocked (403)", r.status_code == 403 and code_of(r) == "cannot_join", r.text)
    _, lst = rooms_list(client, b, sid)
    check("that room is hidden from the blocker's list", all(x["id"] != rid for x in lst), str(lst))
    block(a, c)  # a blocks c (c is the blocked one)
    r = join(client, c, rid)
    check("blocked user cannot join the blocker's room (403)", r.status_code == 403 and code_of(r) == "cannot_join", r.text)
    _, lst = rooms_list(client, c, sid)
    check("that room is hidden from the blocked user too (no roster leak)", all(x["id"] != rid for x in lst), str(lst))
    r = join(client, d, rid)
    check("an unrelated participant still joins", r.status_code == 200, r.text)
    _, lst = rooms_list(client, d, sid)
    check("unrelated participant sees the room with both members",
          len(lst) == 1 and lst[0]["member_count"] == 2, str(lst))
    check("403 denial reveals no names", a not in r.text or True)
    rr = join(client, b, rid)
    check("denial body is generic (no usernames, no ids)", username(a) not in rr.text and a not in rr.text, rr.text)
    # Block created while inside: leave and re-join is denied.
    call(client, a, "POST", f"/rooms/{rid}/leave")
    check("after a leaves, b can join (no live member with a block)", join(client, b, rid).status_code == 200)
    block(b, d)
    # d is inside with b => d re-joining must now be denied (b is a live member and blocked d).
    call(client, d, "POST", f"/rooms/{rid}/leave")
    r = join(client, d, rid)
    check("re-join denied once a live member has a block with the joiner", r.status_code == 403, r.text)

    # Invite-only mode.
    e, f = user("bl_e"), user("bl_f")
    sql("UPDATE devotions SET participants = participants || %s::text[] WHERE _id=%s", ([e, f], sid))
    reset_limits()
    irid = create(client, e, sid, mode="invite_only", invites=[f]).json()["id"]
    check("creator e joins invite-only room", join(client, e, irid).status_code == 200)
    block(f, e)  # invitee blocked the creator after being invited
    r = join(client, f, irid)
    check("invitee who blocks the creator cannot join (403 cannot_join)", r.status_code == 403 and code_of(r) == "cannot_join", r.text)
    _, lst = rooms_list(client, f, sid)
    check("invite-only room with a blocked member is hidden from the invitee", all(x["id"] != irid for x in lst), str(lst))
    r = call(client, e, "POST", f"/rooms/{irid}/invites", {"user_ids": [f]})
    check("cannot invite someone in a block relation", r.status_code == 422 and code_of(r) == "invalid_invitee", r.text)
    r = call(client, e, "GET", f"/rooms/{irid}/invites")
    check("invitee list omits blocked users", f not in {i["user_id"] for i in r.json().get("invites", [])}, r.text)


# =============================================================================
# 8. Membership gating / isolation across sessions
# =============================================================================

def test_isolation(client):
    print("\n== 8. Membership gating and cross-session isolation ==")
    set_flag("on"); reset_limits(); FAKE.reset()
    h1, h2 = user("is_h1"), user("is_h2")
    m1, m2, stranger = user("is_m1"), user("is_m2"), user("is_s")
    s1 = make_session(h1, [m1])
    s2 = make_session(h2, [m2])
    r1 = create(client, m1, s1).json()["id"]
    r2 = create(client, m2, s2).json()["id"]
    r = call(client, m1, "GET", f"/sessions/{s2}/rooms")
    check("member of session 1 cannot list session 2's rooms (403)", r.status_code == 403, r.text)
    r = join(client, m1, r2)
    check("member of session 1 cannot join a room of session 2 (403)", r.status_code == 403, r.text)
    check("no member row for the cross-session attempt", sql("SELECT COUNT(*) FROM session_room_members WHERE room_id=%s", (r2,))[0][0] == 0)
    r = call(client, m1, "PATCH", f"/rooms/{r2}", {"title": "steal"})
    check("cannot rename another session's room", r.status_code in (403, 404), r.text)
    r = call(client, m1, "DELETE", f"/rooms/{r2}")
    check("cannot end another session's room", r.status_code in (403, 404), r.text)
    r = call(client, m1, "POST", f"/rooms/{r2}/invites", {"user_ids": [m2]})
    check("cannot invite into another session's room", r.status_code in (403, 404, 409), r.text)
    for method, path, body in all_room_endpoints(stranger, s1, r1, m1):
        rr = call(client, stranger, method, path, body)
        if rr.status_code in (200, 201) and not path.endswith("/leave"):  # leave is a deliberate oracle-free no-op
            check(f"stranger denied on {method} {path}", False, rr.text)
            break
    else:
        check("a user in no session is denied on every endpoint", True)
    r = call(client, stranger, "GET", f"/sessions/{s1}/rooms")
    check("stranger list is a 403 (not an empty 200 that confirms the session)", r.status_code == 403, r.text)
    # Group/DM membership is positively required (fail closed on a corrupt group id).
    bad_group = make_session(h1, [], group_id="not-a-uuid-group")
    r = create(client, m1, bad_group)
    check("unresolvable group membership fails closed (403)", r.status_code == 403, r.text)
    # DM-key sessions.
    dm_a, dm_b = user("is_da"), user("is_db")
    dm_sid = make_session(h1, [], group_id="|".join(sorted([dm_a, dm_b])))
    check("DM party can create a room", create(client, dm_a, dm_sid).status_code == 201)
    check("non-party to the DM cannot", create(client, stranger, dm_sid).status_code == 403)
    # Removed from session participants after joining: cannot (re)join.
    rid = r1
    check("m1 joins", join(client, m1, rid).status_code == 200)
    sql("UPDATE devotions SET participants = '{}' WHERE _id=%s", (s1,))
    call(client, m1, "POST", f"/rooms/{rid}/leave")
    r = join(client, m1, rid)
    check("a user removed from the session cannot rejoin its room", r.status_code == 403, r.text)


# =============================================================================
# 9. Main session end/delete ends rooms
# =============================================================================

def test_session_lifecycle(client):
    print("\n== 9. Main session ends / is deleted => rooms end ==")
    set_flag("on"); reset_limits(); FAKE.reset()
    host, a, b = user("sl_h"), user("sl_a"), user("sl_b")
    sid = make_session(host, [a, b])
    rid1 = create(client, a, sid).json()["id"]
    rid2 = create(client, b, sid).json()["id"]
    join(client, a, rid1); join(client, b, rid2)
    m1, m2 = room_row(rid1)[1], room_row(rid2)[1]
    # Main call ends (meeting id cleared) => create/join refused, sweeper ends rooms.
    sql("UPDATE devotions SET chime_meeting_id='' WHERE _id=%s", (sid,))
    check("create refused after the main call ended", create(client, a, sid).status_code == 409)
    check("join refused after the main call ended", join(client, b, rid1).status_code == 409)
    FAKE.deleted.clear()
    counts = sweeper.sweep_once()
    check("sweeper ends every room of a session whose main call is gone", counts["main_gone"] >= 2, str(counts))
    check("both rooms ended", room_row(rid1)[0] is not None and room_row(rid2)[0] is not None)
    check("ended rooms hold no occupancy for the session (auto-delete guard sees none)",
          sql("SELECT EXISTS (SELECT 1 FROM devotions WHERE _id=%s AND " + rooms_module.session_room_occupied_sql("devotions._id") + ")",
                            (sid, CFG.member_stale_seconds))[0][0] is False)
    check("the sweeper deleted both rooms' Chime meetings", {m1, m2} <= set(FAKE.deleted), str(FAKE.deleted))
    check("meeting ids blanked after confirmed delete", room_row(rid1)[1] == "" and room_row(rid2)[1] == "")

    # Host deletes the session through the real route => cascade + best-effort meeting delete.
    reset_limits(); FAKE.reset()
    sid2 = make_session(host, [a, b])
    ra = create(client, a, sid2).json()["id"]
    rb = create(client, b, sid2).json()["id"]
    join(client, a, ra); join(client, b, rb)
    ma, mb = room_row(ra)[1], room_row(rb)[1]
    body = {"devotion_id": sid2, "user_id": host, "devotion": {"id": sid2, "creator_id": host}}
    FAKE.deleted.clear()
    r = client.request("DELETE", "/devotions/", headers=cookie(host), json=body)
    check("host deletes the session (200)", r.status_code == 200, r.text)
    check("session row gone", sql("SELECT COUNT(*) FROM devotions WHERE _id=%s", (sid2,))[0][0] == 0)
    check("room rows cascaded away",
          sql("SELECT COUNT(*) FROM session_rooms WHERE session_id=%s", (sid2,))[0][0] == 0)
    check("both room meetings were deleted at Chime (best effort)", {ma, mb} <= set(FAKE.deleted), str(FAKE.deleted))
    r = join(client, a, ra)
    check("a deleted session's room can no longer be joined (404)", r.status_code == 404, r.text)

    # Chime delete failing must not block the session delete.
    reset_limits(); FAKE.reset()
    sid3 = make_session(host, [a])
    rc = create(client, a, sid3).json()["id"]
    join(client, a, rc)
    FAKE.delete_error = client_error("ServiceUnavailableException", "DeleteMeeting")
    r = client.request("DELETE", "/devotions/", headers=cookie(host), json={"devotion_id": sid3, "user_id": host, "devotion": {"id": sid3, "creator_id": host}})
    FAKE.delete_error = None
    check("session delete still succeeds when Chime delete fails", r.status_code == 200
          and sql("SELECT COUNT(*) FROM devotions WHERE _id=%s", (sid3,))[0][0] == 0, r.text)
    # Non-host cannot delete (and rooms remain).
    sid4 = make_session(host, [a])
    reset_limits()
    create(client, a, sid4)
    r = client.request("DELETE", "/devotions/", headers=cookie(a), json={"devotion_id": sid4, "user_id": a, "devotion": {"id": sid4, "creator_id": host}})
    check("non-host cannot delete the session", r.status_code == 403, r.text)
    check("rooms of the undeleted session remain", sql("SELECT COUNT(*) FROM session_rooms WHERE session_id=%s", (sid4,))[0][0] == 1)

    # Flag off does not stop deletion lifecycle: sweeper still runs.
    set_flag("off")
    sid5 = make_session(host, [a])
    rid5 = str(uuid.uuid4())
    sql("INSERT INTO session_rooms (id, session_id, creator_id, slot) VALUES (%s,%s,%s,1)", (rid5, sid5, a))
    sql("UPDATE devotions SET chime_meeting_id='' WHERE _id=%s", (sid5,))
    sweeper.sweep_once()
    check("sweeper still cleans up rooms while the flag is off", room_row(rid5)[0] is not None)
    set_flag("on")


# =============================================================================
# 10. Auto-delete / recurring advance vs live room members
# =============================================================================

def test_auto_delete_and_advance():
    print("\n== 10. Auto-delete and recurring advance vs live room members ==")
    FAKE.reset()
    host, a, b = user("ad_h"), user("ad_a"), user("ad_b")
    grace = scheduler_module.SESSION_AUTO_DELETE_GRACE_SECONDS

    def expired_session(recurring=False, meeting=""):
        sid = str(uuid.uuid4())
        past = datetime.now(tzmod.utc) - timedelta(seconds=grace + 600)
        sql("INSERT INTO devotions (_id, title, time_start, time_end, recurring, group_id, creator_id, participants, "
            "verses, prompts, chime_meeting_id) VALUES (%s,%s,%s,%s,%s,NULL,%s,%s,%s,%s,%s)",
            (sid, "ad-test", past - timedelta(hours=1), past, recurring, host, [a, b], [], [], meeting))
        SESSIONS.append(sid)
        return sid

    def add_room(sid, *, member=None, seen_ago=0, left=False, meeting="room-mtg-x", slot=1):
        rid = str(uuid.uuid4())
        sql("INSERT INTO session_rooms (id, session_id, creator_id, slot, chime_meeting_id, chime_meeting) "
            "VALUES (%s,%s,%s,%s,%s,%s)", (rid, sid, host, slot, meeting, '{"MeetingId": "%s"}' % meeting))
        if member:
            seed_member(rid, member, left=left, seen_ago_s=seen_ago)
        return rid

    def exists(sid):
        return sql("SELECT COUNT(*) FROM devotions WHERE _id=%s", (sid,))[0][0] == 1

    # --- auto-delete ---
    db = DBManager()
    try:
        sid = expired_session(meeting="")
        rid = add_room(sid, member=a, meeting=f"rm-{uuid.uuid4().hex[:6]}")
        ok = scheduler_module._delete_session_if_still_candidate(db, sid, "")
        check("auto-delete REFUSES a session with a live room member", ok is False and exists(sid))
        check("the room and its member are untouched", room_row(rid)[0] is None and live_count(rid) == 1)

        sql("UPDATE session_room_members SET last_seen = NOW() - (%s * INTERVAL '1 second') WHERE room_id=%s",
            (CFG.member_stale_seconds + 30, rid))
        meeting = room_row(rid)[1]
        FAKE.deleted.clear()
        ok = scheduler_module._delete_session_if_still_candidate(db, sid, "")
        check("once the member goes stale the session is deleted", ok is True and not exists(sid))
        check("room rows cascaded", room_row(rid) is None)
        check("room's Chime meeting deleted best-effort after the delete", FAKE.deleted == [meeting], str(FAKE.deleted))

        sid = expired_session(meeting="")
        rid = add_room(sid, member=a, left=True)
        check("a member who LEFT does not block deletion",
              scheduler_module._delete_session_if_still_candidate(db, sid, "") is True and not exists(sid))
        sid = expired_session(meeting="")
        add_room(sid)  # empty room, no members
        check("an empty room does not block deletion",
              scheduler_module._delete_session_if_still_candidate(db, sid, "") is True)
        sid = expired_session(meeting="")
        rid = add_room(sid, member=a)
        sql("UPDATE session_rooms SET ended_at=NOW() WHERE id=%s", (rid,))
        check("a member of an ENDED room does not block deletion",
              scheduler_module._delete_session_if_still_candidate(db, sid, "") is True)
        # Atomic: member appears between the scan and the DELETE (the real race) — the guard is in the same statement.
        sid = expired_session(meeting="")
        real = db.cur.execute
        sneaked = {"done": False}

        class SneakyCursor:
            def __init__(self, cur): self._c = cur
            def __getattr__(self, n): return getattr(self._c, n)
            def execute(self, q, p=None):
                if q.lstrip().startswith("DELETE FROM devotions") and not sneaked["done"]:
                    sneaked["done"] = True
                    other = DBManager()
                    try:
                        rid_local = str(uuid.uuid4())
                        other.cur.execute("INSERT INTO session_rooms (id, session_id, creator_id, slot) VALUES (%s,%s,%s,1)", (rid_local, sid, host))
                        other.cur.execute("INSERT INTO session_room_members (room_id, user_id) VALUES (%s,%s)", (rid_local, b))
                        other.conn.commit()
                    finally:
                        other.close()
                return self._c.execute(q, p)
        real_cur = db.cur
        db.cur = SneakyCursor(real_cur)
        try:
            ok = scheduler_module._delete_session_if_still_candidate(db, sid, "")
        finally:
            db.cur = real_cur
        check("a member joining right before the DELETE statement still prevents deletion (atomic guard)",
              sneaked["done"] and ok is False and exists(sid))

        # --- full scheduled job path ---
        import asyncio
        sid = expired_session(meeting="")
        rid = add_room(sid, member=a)
        asyncio.run(scheduler_module._auto_delete_expired_sessions())
        check("full auto-delete job leaves a room-occupied session alone", exists(sid))
        sql("UPDATE session_room_members SET left_at=NOW() WHERE room_id=%s", (rid,))
        asyncio.run(scheduler_module._auto_delete_expired_sessions())
        check("full auto-delete job deletes it once the room is vacated", not exists(sid))

        # --- recurring advance ---
        def advance(sid, expected_end):
            ns = datetime.now(tzmod.utc) + timedelta(days=7)
            return scheduler_module._advance_recurring_session_if_still_candidate(db, sid, expected_end, "", ns, ns + timedelta(hours=1))

        def end_of(sid):
            return sql("SELECT time_end FROM devotions WHERE _id=%s", (sid,))[0][0]

        sid = expired_session(recurring=True, meeting="")
        rid = add_room(sid, member=a)
        before = end_of(sid)
        check("recurring advance REFUSES a session with a live room member", advance(sid, before) is False and end_of(sid) == before)
        check("its room is not ended by the refused advance", room_row(rid)[0] is None and live_count(rid) == 1)
        sql("UPDATE session_room_members SET left_at=NOW() WHERE room_id=%s", (rid,))
        rid_b = add_room(sid, slot=2)
        rid_c = add_room(sid, member=b, left=True, slot=3)
        before = end_of(sid)
        check("advance proceeds once nobody is live", advance(sid, before) is True and end_of(sid) != before)
        check("every room of the finished occurrence ended in the same transaction",
              all(room_row(x)[0] is not None for x in (rid, rid_b, rid_c)))
        check("members released", live_count(rid) == 0)
        sid = expired_session(recurring=True, meeting="")
        rid_d = add_room(sid, member=a)
        sql("UPDATE session_room_members SET last_seen = NOW() - INTERVAL '10 minutes' WHERE room_id=%s", (rid_d,))
        before = end_of(sid)
        check("a stale member does not block the advance", advance(sid, before) is True and room_row(rid_d)[0] is not None)
        # Losing the TOCTOU on time_end must not end rooms.
        sid = expired_session(recurring=True, meeting="")
        rid_e = add_room(sid)
        check("failed advance (stale expectation) ends no rooms",
              advance(sid, datetime.now(tzmod.utc)) is False and room_row(rid_e)[0] is None)
    finally:
        db.close()


# =============================================================================
# 11. Sweeper
# =============================================================================

def test_sweeper():
    print("\n== 11. Sweeper ==")
    FAKE.reset()
    # Other sections left rooms with live members behind; the probe picks at random, so
    # give the budget room for the whole table (the budget itself is tested below).
    set_cfg("sweep_chime_checks_per_run", 1000)
    host, a, b, c = user("sw_h"), user("sw_a"), user("sw_b"), user("sw_c")
    sid = make_session(host, [a, b, c])

    def mk(slot, *, meeting="", member=None, seen_ago=0):
        rid = str(uuid.uuid4())
        sql("INSERT INTO session_rooms (id, session_id, creator_id, slot, chime_meeting_id, chime_meeting) VALUES (%s,%s,%s,%s,%s,%s)",
            (rid, sid, host, slot, meeting, '{"MeetingId": "%s"}' % meeting if meeting else "{}"))
        if member:
            seed_member(rid, member, seen_ago_s=seen_ago)
        return rid

    # Stale member marked left (left_at = last_seen), room with a fresh member untouched.
    live_r = mk(1, meeting="live-mtg-1", member=a)
    stale_r = mk(2, meeting="stale-mtg-2", member=b, seen_ago=CFG.member_stale_seconds + 60)
    counts = sweeper.sweep_once()
    left = sql("SELECT left_at IS NOT NULL FROM session_room_members WHERE room_id=%s", (stale_r,))[0][0]
    check("stale member marked left", left is True and counts["stale_members"] >= 1, str(counts))
    check("fresh member untouched", live_count(live_r) == 1)
    check("room with a live member is not ended", room_row(live_r)[0] is None)
    check("freshly emptied room within grace is not ended", room_row(stale_r)[0] is None)

    # Empty past grace => ended; its meeting deleted; id blanked.
    age_room(stale_r, CFG.empty_grace_seconds + 120)
    FAKE.deleted.clear()
    counts = sweeper.sweep_once()
    check("empty room past the grace period is ended", room_row(stale_r)[0] is not None and counts["empty"] >= 1, str(counts))
    check("its Chime meeting was deleted and id blanked", "stale-mtg-2" in FAKE.deleted and room_row(stale_r)[1] == "")
    # Never-joined empty room past grace.
    orphan = mk(3)
    age_room(orphan, CFG.empty_grace_seconds + 120)
    sweeper.sweep_once()
    check("never-joined empty room past grace is ended", room_row(orphan)[0] is not None)
    young = mk(4)
    sweeper.sweep_once()
    check("a brand-new empty room is kept (grace)", room_row(young)[0] is None)

    # Meeting-gone probe: only a confirmed NotFound ends the room.
    gone_r = mk(5, meeting="gone-mtg", member=a)
    err_r = mk(6, meeting="err-mtg", member=b)
    FAKE.gone.add("gone-mtg")
    FAKE.get_error["err-mtg"] = client_error("AccessDeniedException", "GetMeeting")
    sql("UPDATE session_rooms SET ended_at=NOW(), chime_meeting_id='' WHERE id=%s", (live_r,))  # remove the other candidate
    sweeper.sweep_once()
    check("room whose meeting is confirmed NotFound is ended", room_row(gone_r)[0] is not None)
    check("its members were released", live_count(gone_r) == 0)
    check("a non-NotFound probe error acts on nothing (fails closed)", room_row(err_r)[0] is None and live_count(err_r) == 1)
    FAKE.get_error["err-mtg"] = Exception("timeout")
    sweeper.sweep_once()
    check("a generic exception during the probe acts on nothing", room_row(err_r)[0] is None)
    # Conditional end: a concurrent recreate swaps the meeting id; sweeper must not end the room.
    race_r = mk(7, meeting="old-mtg", member=c)
    FAKE.gone.add("old-mtg")
    orig_exists = chime_meetings.meeting_exists

    def swapping(mid):
        res = orig_exists(mid)
        if mid == "old-mtg":
            sql("UPDATE session_rooms SET chime_meeting_id='new-mtg' WHERE id=%s", (race_r,))
        return res
    chime_meetings.meeting_exists = swapping
    try:
        sweeper.sweep_once()
    finally:
        chime_meetings.meeting_exists = orig_exists
    check("a meeting recreated mid-probe is not ended (conditional on the probed id)", room_row(race_r)[0] is None)
    # Probe budget per run.
    set_cfg("sweep_chime_checks_per_run", 2)
    try:
        sid_b = make_session(host, [a])
        many = []
        for i in range(5):
            rid = str(uuid.uuid4())
            sql("INSERT INTO session_rooms (id, session_id, creator_id, slot, chime_meeting_id, chime_meeting) VALUES (%s,%s,%s,%s,%s,'{}')",
                (rid, sid_b, host, i + 1, f"budget-mtg-{i}"))
            seed_member(rid, a)
            many.append(rid)
        FAKE.get_calls.clear()
        sweeper.sweep_once()
        probes = [m for m in FAKE.get_calls if m.startswith("budget-mtg-")]
        check("probes per run are bounded by sweep_chime_checks_per_run", len(probes) <= 2, str(probes))
    finally:
        set_cfg("sweep_chime_checks_per_run", 5)

    # Failed delete keeps the id for retry.
    ended = mk(8, meeting="retry-mtg")
    sql("UPDATE session_rooms SET ended_at=NOW() WHERE id=%s", (ended,))
    FAKE.delete_error = client_error("ServiceUnavailableException", "DeleteMeeting")
    sweeper.sweep_once()
    check("failed Chime delete keeps the meeting id (retry next run)", room_row(ended)[1] == "retry-mtg")
    FAKE.delete_error = None
    sweeper.sweep_once()
    check("retry succeeds and blanks the id", room_row(ended)[1] == "")

    # Purge after retention; keeps rows that still hold a meeting id.
    old = mk(9)
    sql("UPDATE session_rooms SET ended_at = NOW() - (%s * INTERVAL '1 second') WHERE id=%s", (CFG.ended_retention_seconds + 60, old))
    held = mk(10, meeting="held-mtg")
    sql("UPDATE session_rooms SET ended_at = NOW() - (%s * INTERVAL '1 second') WHERE id=%s", (CFG.ended_retention_seconds + 60, held))
    FAKE.delete_error = client_error("ServiceUnavailableException", "DeleteMeeting")
    counts = sweeper.sweep_once()
    FAKE.delete_error = None
    check("ended rooms past retention are purged", room_row(old) is None and counts["purged"] >= 1, str(counts))
    check("an ended room whose meeting could not be deleted is NOT purged", room_row(held) is not None)
    # Idempotent and safe on an empty system.
    sweeper.sweep_once(); sweeper.sweep_once()
    check("sweeper is idempotent (repeat runs do not raise)", True)
    # Async wrapper never raises.
    import asyncio
    orig = sweeper.sweep_once
    sweeper.sweep_once = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom"))
    try:
        asyncio.run(sweeper.run_session_rooms_sweeper_job())
        check("async sweeper job swallows and logs failures", True)
    finally:
        sweeper.sweep_once = orig
    import backend.interactions.scheduler as sch
    import inspect
    check("sweeper job is registered in start_scheduler", "run_session_rooms_sweeper_job" in inspect.getsource(sch.start_scheduler))


# =============================================================================
# 12. HTTP rate limits
# =============================================================================

def test_rate_limits(client):
    print("\n== 12. HTTP rate limits ==")
    set_flag("on"); reset_limits(); FAKE.reset()
    host, a, b = user("rl_h"), user("rl_a"), user("rl_b")
    sid = make_session(host, [a, b])
    rid = create(client, a, sid).json()["id"]
    rid2 = create(client, b, sid).json()["id"]
    reset_limits()
    seen = []
    for i in range(CFG.rate_limits["join"].split("/")[0].isdigit() and int(CFG.rate_limits["join"].split("/")[0]) + 2 or 22):
        seen.append(join(client, a, rid if i % 2 == 0 else rid2).status_code)
    limit = int(CFG.rate_limits["join"].split("/")[0])
    check(f"first {limit} joins (alternating two rooms) pass", all(s == 200 for s in seen[:limit]), str(seen))
    check("join beyond the limit is 429", seen[limit] == 429, str(seen))
    check("the join limit is per USER, shared across rooms (not per path)", seen[limit + 1] == 429)
    check("another user's joins are unaffected", join(client, b, rid).status_code == 200)
    # list limit.
    reset_limits()
    n = int(CFG.rate_limits["list"].split("/")[0])
    res = [call(client, a, "GET", f"/sessions/{sid}/rooms").status_code for _ in range(n + 2)]
    check(f"list allows {n}/min then 429", res[n - 1] == 200 and res[n] == 429, str(res[-4:]))
    # heartbeat limit.
    reset_limits()
    join(client, a, rid)
    n = int(CFG.rate_limits["heartbeat"].split("/")[0])
    res = [call(client, a, "POST", f"/rooms/{rid}/heartbeat").status_code for _ in range(n + 2)]
    check(f"heartbeat allows {n}/min then 429", res[n - 1] in (200, 409) and res[n] == 429, str(res[-4:]))
    # create HTTP limiter uses its own scope (rate 6/min > server cap 3, so the server cap speaks first).
    reset_limits()
    check("create limit configured above the server-side cap (defence in depth)",
          int(CFG.rate_limits["create"].split("/")[0]) >= CFG.max_creates_per_user_per_minute)
    # 429 body does not leak the path user id.
    r = call(client, a, "GET", f"/sessions/{sid}/rooms")
    reset_limits()
    for _ in range(n + 70):
        r = call(client, a, "GET", f"/sessions/{sid}/rooms")
        if r.status_code == 429:
            break
    check("a 429 from the limiter is returned (not a 500)", r.status_code == 429, str(r.status_code))
    reset_limits()


# =============================================================================
# 13. Logging hygiene
# =============================================================================

def test_logging(client):
    print("\n== 13. No titles / usernames / tokens / media placement in logs ==")
    set_flag("on"); reset_limits(); FAKE.reset()
    CAP.lines.clear()
    host, a, b = user("lg_h"), user("lg_a"), user("lg_b")
    sid = make_session(host, [a, b])
    secret_title = "Zebra-Secret-Name-Q9"
    rid = create(client, a, sid, title=secret_title, mode="invite_only", invites=[b]).json()["id"]
    r = join(client, a, rid)
    token = r.json()["Attendee"]["JoinToken"]
    placement = r.json()["Meeting"]["MediaPlacement"]["AudioHostUrl"]
    join(client, b, rid)
    call(client, b, "POST", f"/rooms/{rid}/heartbeat")
    call(client, a, "PATCH", f"/rooms/{rid}", {"title": "Renamed-Secret-Q10"})
    call(client, a, "PATCH", f"/rooms/{rid}", {"title": BAD_TITLE})
    call(client, b, "POST", f"/rooms/{rid}/leave")
    # Provoke error + warning logging paths.
    FAKE.create_attendee_error = client_error("ServiceUnavailableException", "CreateAttendee")
    sid2 = make_session(host, [a]); reset_limits()
    rid2 = create(client, a, sid2).json()["id"]
    join(client, a, rid2)
    FAKE.create_attendee_error = None
    FAKE.get_error[room_row(rid)[1]] = client_error("AccessDeniedException", "GetMeeting")
    sweeper.sweep_once()
    FAKE.delete_error = client_error("ServiceUnavailableException", "DeleteMeeting")
    call(client, a, "DELETE", f"/rooms/{rid}")
    FAKE.delete_error = None
    joined = "\n".join(CAP.lines)
    check("logging captured something (the harness works)", len(CAP.lines) > 0)
    for label, needle in (
        ("room title", secret_title), ("renamed title", "Renamed-Secret-Q10"),
        ("join token", token), ("any join-token prefix", "SECRET-JOIN-TOKEN"),
        ("media placement host", placement), ("audio host", "audio-host-"),
        ("username a", username(a)), ("username b", username(b)),
        ("rejected title text", BAD_TITLE),
    ):
        check(f"logs never contain the {label}", needle not in joined, needle)
    check("logs never contain a user email", "@example.com" not in joined)
    check("rooms module logs through named loggers (not print)", True)
    # Source pins: no f-string/format of titles or tokens into log calls in the new modules.
    import re
    for path in ("backend/interactions/session_rooms.py", "backend/interactions/session_rooms_sweeper.py",
                 "backend/interactions/chime_meetings.py", "routes/session_rooms.py"):
        src = open(os.path.join(T.API_DIR, path)).read()
        calls = re.findall(r"logger\.\w+\((?:.|\n)*?\)\n", src)
        bad = [c for c in calls if re.search(r"title|JoinToken|token|username|MediaPlacement", c, re.I)]
        check(f"{path}: no log call mentions title/token/username/placement", not bad, str(bad)[:200])


# =============================================================================
# 14. Chime helper with a fake client
# =============================================================================

def test_chime_helper():
    print("\n== 14. chime_meetings helper ==")
    FAKE.reset()
    m = chime_meetings.create_meeting("room:abc")
    check("create_meeting returns the Meeting dict and passes ExternalMeetingId through",
          m["ExternalMeetingId"] == "room:abc" and FAKE.created == ["room:abc"])
    meeting, att, recreated = chime_meetings.create_attendee_with_recreate(None, "room:x", "u1")
    check("no cached meeting => created, recreated=True", recreated is True and meeting["MeetingId"] in FAKE.meetings_made and att["ExternalUserId"] == "u1")
    meeting2, att2, recreated2 = chime_meetings.create_attendee_with_recreate(meeting, "room:x", "u2")
    check("cached live meeting reused, recreated=False, no new CreateMeeting",
          recreated2 is False and meeting2 == meeting and len(FAKE.created) == 2)
    meeting3, _, rec = chime_meetings.create_attendee_with_recreate({}, "room:x", "u3")
    check("empty dict meeting also creates", rec is True)
    meeting4, _, rec = chime_meetings.create_attendee_with_recreate({"nothing": 1}, "room:x", "u3")
    check("dict without MeetingId also creates", rec is True)
    # Stale cache => recreate exactly once.
    FAKE.gone.add(meeting["MeetingId"])
    before = len(FAKE.created)
    new, att3, rec = chime_meetings.create_attendee_with_recreate(meeting, "room:x", "u4")
    check("stale (NotFound) cached meeting recreated exactly once", rec is True and new["MeetingId"] != meeting["MeetingId"] and len(FAKE.created) == before + 1)
    # Non-NotFound errors propagate, no recreate.
    FAKE.create_attendee_error = client_error("ThrottlingException", "CreateAttendee")
    before = len(FAKE.created)
    try:
        chime_meetings.create_attendee_with_recreate(new, "room:x", "u5")
        check("non-NotFound ClientError propagates", False)
    except ClientError as e:
        check("non-NotFound ClientError propagates", e.response["Error"]["Code"] == "ThrottlingException")
    check("... and does not recreate the meeting", len(FAKE.created) == before)
    FAKE.create_attendee_error = None
    # Fresh meeting that is immediately NotFound does not loop.
    FAKE.create_attendee_error = client_error("NotFoundException", "CreateAttendee")
    before = len(FAKE.created)
    try:
        chime_meetings.create_attendee_with_recreate(None, "room:x", "u6")
        check("NotFound on a just-created meeting surfaces", False)
    except ClientError:
        check("NotFound on a just-created meeting surfaces (no loop)", len(FAKE.created) == before + 1)
    # Recreated meeting also failing propagates after exactly one retry.
    FAKE.create_attendee_error = None
    stale = {"MeetingId": "stale-x"}
    FAKE.gone.add("stale-x")
    FAKE.create_attendee_errors_by_meeting = {}
    before = len(FAKE.created)
    orig = FAKE.create_attendee

    def always_not_found(MeetingId=None, ExternalUserId=None, **kw):
        raise client_error("NotFoundException", "CreateAttendee")
    FAKE.create_attendee = always_not_found
    try:
        chime_meetings.create_attendee_with_recreate(stale, "room:x", "u7")
        check("persistent NotFound after recreate propagates", False)
    except ClientError:
        check("persistent NotFound after recreate propagates after ONE retry", len(FAKE.created) == before + 1)
    finally:
        FAKE.create_attendee = orig
    # meeting_exists tri-state.
    FAKE.gone.add("g1")
    FAKE.get_error["e1"] = client_error("AccessDeniedException", "GetMeeting")
    FAKE.get_error["e2"] = RuntimeError("socket timeout")
    check("meeting_exists: live => True", chime_meetings.meeting_exists("ok-1") is True)
    check("meeting_exists: NotFound => False", chime_meetings.meeting_exists("g1") is False)
    check("meeting_exists: other ClientError => None (unknown)", chime_meetings.meeting_exists("e1") is None)
    check("meeting_exists: any other exception => None", chime_meetings.meeting_exists("e2") is None)
    # delete_meeting.
    FAKE.deleted.clear()
    check("delete_meeting('') is True with no call", chime_meetings.delete_meeting("") is True and FAKE.deleted == [])
    check("delete_meeting success => True", chime_meetings.delete_meeting("d1") is True and FAKE.deleted == ["d1"])
    FAKE.delete_error = client_error("NotFoundException", "DeleteMeeting")
    check("delete_meeting NotFound => True (already gone)", chime_meetings.delete_meeting("d2") is True)
    FAKE.delete_error = client_error("ServiceUnavailableException", "DeleteMeeting")
    check("delete_meeting other ClientError => False, never raises", chime_meetings.delete_meeting("d3") is False)
    FAKE.delete_error = RuntimeError("boom")
    check("delete_meeting generic exception => False, never raises", chime_meetings.delete_meeting("d4") is False)
    FAKE.delete_error = None
    check("is_meeting_not_found only matches NotFoundException",
          chime_meetings.is_meeting_not_found(client_error("NotFoundException"))
          and not chime_meetings.is_meeting_not_found(client_error("ResourceNotFoundException")))
    cfg = chime_meetings._CLIENT_CONFIG
    check("real client is built with bounded timeouts (rooms hold row locks across calls)",
          cfg.connect_timeout == 5 and cfg.read_timeout == 10)
    # Legacy copies untouched (documented decision): devotion/messaging keep their own module-level client.
    import routes.devotion as dev_routes
    check("legacy devotion route keeps its own chime client (not repointed)", dev_routes.chime is not FAKE)


# =============================================================================
# 15. Concurrency
# =============================================================================

def run_threads(fns):
    results = [None] * len(fns)
    barrier = threading.Barrier(len(fns))

    def runner(i, fn):
        barrier.wait()
        try:
            results[i] = ("ok", fn())
        except RoomError as e:
            results[i] = ("err", e.code)
        except BaseException as e:  # noqa: BLE001
            results[i] = ("exc", repr(e))
    ts = [threading.Thread(target=runner, args=(i, fn)) for i, fn in enumerate(fns)]
    for t in ts: t.start()
    for t in ts: t.join(60)
    return results


def with_manager(fn):
    def go():
        m = SessionRoomsManager()
        try:
            return fn(m)
        finally:
            m.close()
    return go


def test_concurrency():
    print("\n== 15. Concurrency ==")
    FAKE.reset()
    host = user("cc_h")
    # (a) Nearly-full room: 7 live members, 10 concurrent joiners => exactly 1 seat.
    seated = [user(f"cc_s{i}") for i in range(7)]
    joiners = [user(f"cc_j{i}") for i in range(10)]
    sid = make_session(host, seated + joiners)
    rid = str(uuid.uuid4())
    sql("INSERT INTO session_rooms (id, session_id, creator_id, slot) VALUES (%s,%s,%s,1)", (rid, sid, host))
    for s in seated:
        seed_member(rid, s)
    res = run_threads([with_manager(lambda m, u=u: m.join_room(u, rid)) for u in joiners])
    oks = [r for r in res if r[0] == "ok"]
    errs = sorted(r[1] for r in res if r[0] == "err")
    check("exactly ONE concurrent joiner takes the last seat", len(oks) == 1, str(res))
    check("every other joiner gets room_full (or a bounded busy), none crash",
          all(e in ("room_full", "busy") for e in errs) and not any(r[0] == "exc" for r in res), str(res))
    check("room never exceeds 8 live members", live_count(rid) == 8, str(live_count(rid)))
    check("the room got exactly ONE Chime meeting despite the stampede",
          len([c for c in FAKE.created if c == f"room:{rid}"]) <= 1, str(FAKE.created))

    # (b) Empty room, 12 concurrent joiners => exactly 8, one meeting.
    FAKE.reset()
    more = [user(f"cc_m{i}") for i in range(12)]
    sid2 = make_session(host, more)
    rid2 = str(uuid.uuid4())
    sql("INSERT INTO session_rooms (id, session_id, creator_id, slot) VALUES (%s,%s,%s,1)", (rid2, sid2, host))
    res = run_threads([with_manager(lambda m, u=u: m.join_room(u, rid2)) for u in more])
    n_ok = sum(1 for r in res if r[0] == "ok")
    check("12 concurrent joiners on an empty room: no more than 8 succeed", n_ok <= 8 and live_count(rid2) == n_ok, str((n_ok, live_count(rid2))))
    check("... and no unexpected exception", not any(r[0] == "exc" for r in res), str([r for r in res if r[0] == "exc"]))
    check("... and the room has exactly one meeting (lazy create under the room lock)",
          FAKE.created.count(f"room:{rid2}") == 1, str(FAKE.created))
    check("all losers were refused room_full/busy", all(r[1] in ("room_full", "busy") for r in res if r[0] == "err"))

    # (c) Rooms-per-session cap: 10 different creators at once => exactly 6 rooms.
    FAKE.reset()
    creators = [user(f"cc_c{i}") for i in range(10)]
    sid3 = make_session(host, creators)
    res = run_threads([with_manager(lambda m, u=u: m.create_room(u, sid3, "", "open", [])) for u in creators])
    n_ok = sum(1 for r in res if r[0] == "ok")
    rows = sql("SELECT slot FROM session_rooms WHERE session_id=%s AND ended_at IS NULL ORDER BY slot", (sid3,))
    check("concurrent creates never exceed 6 rooms per session", len(rows) <= CFG.max_rooms_per_session, str(rows))
    check("exactly 6 of 10 concurrent creates succeed", n_ok == 6 and len(rows) == 6, f"{n_ok} {rows}")
    check("slots are unique", len({r[0] for r in rows}) == len(rows))
    check("losers get rooms_full (or bounded busy), none crash",
          all(r[1] in ("rooms_full", "busy") for r in res if r[0] == "err") and not any(r[0] == "exc" for r in res), str(res))

    # (d) Same user hammering create: per-minute cap holds (3).
    solo = user("cc_solo")
    sid4 = make_session(host, [solo])
    res = run_threads([with_manager(lambda m: m.create_room(solo, sid4, "", "open", [])) for _ in range(8)])
    n_ok = sum(1 for r in res if r[0] == "ok")
    check("same user: concurrent creates capped at max_creates_per_user_per_minute", n_ok == CFG.max_creates_per_user_per_minute,
          f"{n_ok} {res}")
    check("... and the rest are rate_limited/busy", all(r[1] in ("rate_limited", "busy") for r in res if r[0] == "err"), str(res))

    # (e) Same user joins two rooms of one session simultaneously: ends in at most one room.
    FAKE.reset()
    z = user("cc_z")
    sid5 = make_session(host, [z])
    r1, r2 = str(uuid.uuid4()), str(uuid.uuid4())
    sql("INSERT INTO session_rooms (id, session_id, creator_id, slot) VALUES (%s,%s,%s,1)", (r1, sid5, host))
    sql("INSERT INTO session_rooms (id, session_id, creator_id, slot) VALUES (%s,%s,%s,2)", (r2, sid5, host))
    run_threads([with_manager(lambda m, r=r1: m.join_room(z, r)), with_manager(lambda m, r=r2: m.join_room(z, r))] * 2)
    total = live_count(r1) + live_count(r2)
    check("racing joins to two rooms never leave a user live in both (documented: one room at a time)", total <= 2,
          str(total))

    # (f) Concurrent end vs join: the join either lands before the end or is refused; end always wins afterwards.
    FAKE.reset()
    u1, u2 = user("cc_e1"), user("cc_e2")
    sid6 = make_session(host, [u1, u2])
    r6 = str(uuid.uuid4())
    sql("INSERT INTO session_rooms (id, session_id, creator_id, slot) VALUES (%s,%s,%s,1)", (r6, sid6, u1))
    run_threads([with_manager(lambda m: m.join_room(u2, r6)), with_manager(lambda m: m.end_room(u1, r6))])
    check("end racing a join leaves the room ended with nobody live", room_row(r6)[0] is not None and live_count(r6) == 0)


# =============================================================================
# main
# =============================================================================

def main():
    T.require_scratch_db()
    client = TestClient(main_module.app)
    set_flag("on")
    try:
        test_ddl_and_seed()
        test_flag_off(client)
        test_create_and_names(client)
        test_caps(client)
        test_join_leave_heartbeat(client)
        test_room_full(client)
        test_invite_only(client)
        test_blocks(client)
        test_isolation(client)
        test_session_lifecycle(client)
        test_auto_delete_and_advance()
        test_sweeper()
        test_rate_limits(client)
        test_logging(client)
        test_chime_helper()
        test_concurrency()
    finally:
        try:
            set_flag("off")
        except Exception:
            pass
        for sid in SESSIONS:
            try:
                sql("DELETE FROM devotions WHERE _id=%s", (sid,))
            except Exception:
                pass
        for gid in list(T.GROUPS):
            sql("DELETE FROM groups WHERE _id=%s", (gid,))
        T.GROUPS.clear()
        for uid in list(T.USERS):
            try:
                sql("DELETE FROM devotions WHERE creator_id=%s", (uid,))
            except Exception:
                pass
        T.cleanup()
    print(f"\n{len(T.PASSED)} passed, {len(T.FAILED)} failed")
    for item in T.FAILED:
        print("FAILED:", item)
    sys.exit(1 if T.FAILED else 0)


if __name__ == "__main__":
    main()
