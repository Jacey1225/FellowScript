import json
import logging
import os
from db import DBManager
from backend.errors import SaveFailedError
from schemas.devotion import DevotionPlan

logger = logging.getLogger(__name__)

# ── Ring feature config (task 20260916-call-ring-members) ───────────────────
#
# Mirrors friends.py's NUDGE_FEATURE_ENABLED/NUDGE_RATE_LIMIT_HOURS precedent
# exactly (Configuration Philosophy Q1/Q4/Q8): both vars are new *required*
# config, not optional knobs with a silently-guessed fallback. The raw
# strings are only read here, at import time; validate_ring_config() must be
# called eagerly at process startup (main.py's lifespan, alongside
# push.py's validate_apns_config() and friends.py's validate_nudge_config())
# to parse and populate the typed globals below -- a deploy that hasn't set
# them explicitly fails loudly at boot instead of the ring endpoint silently
# running with a guessed cooldown window or an implicitly-on/off feature
# flag. RING_FEATURE_ENABLED is expected to be deployed as "false" initially
# (off-by-default proactive-flagging stance) and flipped to "true" for
# rollout -- that's a deploy-time value choice, not a code-level fallback.
_RING_FEATURE_ENABLED_RAW = os.getenv("RING_FEATURE_ENABLED")
_RING_COOLDOWN_MINUTES_RAW = os.getenv("RING_COOLDOWN_MINUTES")

# ── VoIP/CallKit delivery config (task 20260916-callkit-voip-ring) ──────────
#
# A second, independent flag from RING_FEATURE_ENABLED above -- that one
# gates whether the ring feature exists at all; this one gates *which*
# delivery mechanism ring_members uses once it's on. Off-by-default per this
# project's proactive-flagging convention (same posture RING_FEATURE_ENABLED
# itself started from), and deliberately kept operable independently of
# RING_FEATURE_ENABLED: this is materially riskier App Review surface
# (PushKit's VoIP background mode) than the plain-alert-push ring feature it
# extends (see Configuration Philosophy Q1/Q8/Q4 in this task's spec), so
# ops needs a way to turn VoIP+CallKit delivery back off at runtime --
# reverting ring_members to the exact plain-APNs-push behavior it already
# had -- without needing a full redeploy or disabling ring entirely, in case
# an App Review or field issue turns up in the new mechanism specifically.
# This also resolves this task's own open question on whether the old plain
# push should be kept as a fallback: yes, operator-controlled via this flag,
# not a silent per-recipient fallback.
_RING_VOIP_ENABLED_RAW = os.getenv("RING_VOIP_ENABLED")
_RING_TIMEOUT_SECONDS_RAW = os.getenv("RING_TIMEOUT_SECONDS")

# Populated by validate_ring_config(); read via is_ring_enabled() rather than
# importing this name by value elsewhere, since `from module import NAME`
# binds the value at import time and would never observe the update
# validate_ring_config() makes after that import runs.
RING_FEATURE_ENABLED = False
RING_COOLDOWN_MINUTES = 0
RING_VOIP_ENABLED = False
RING_TIMEOUT_SECONDS = 0


class RingConfigError(RuntimeError):
    """RING_FEATURE_ENABLED/RING_COOLDOWN_MINUTES are unset or invalid.

    Deliberately never swallowed -- mirrors push.py's APNsConfigError and
    friends.py's NudgeConfigError precedent exactly (see those classes'
    docstrings): a misconfigured ring rollout must fail loudly at boot
    rather than the endpoint silently running with a guessed or nonsensical
    cooldown window.
    """


def validate_ring_config() -> None:
    """Eagerly validate and parse RING_FEATURE_ENABLED/RING_COOLDOWN_MINUTES,
    and (task 20260916-callkit-voip-ring) RING_VOIP_ENABLED/
    RING_TIMEOUT_SECONDS -- all four are the same "ring feature config"
    family, validated together from the one existing call site rather than
    adding a second lifespan call for what's conceptually one group.

    Call once, at process startup (main.py's lifespan), before serving
    traffic -- same placement/reasoning as push.py's validate_apns_config()
    and friends.py's validate_nudge_config(). Required regardless of
    RING_FEATURE_ENABLED/RING_VOIP_ENABLED's own value -- a currently-off
    feature's config still can't be left unset (Configuration Philosophy
    Q4).

    Raises:
        RingConfigError: If any of the four vars is unset or invalid --
            RING_FEATURE_ENABLED/RING_VOIP_ENABLED must be exactly
            "true"/"false" (case-insensitive); RING_COOLDOWN_MINUTES/
            RING_TIMEOUT_SECONDS must each be a positive integer.
    """
    global RING_FEATURE_ENABLED, RING_COOLDOWN_MINUTES, RING_VOIP_ENABLED, RING_TIMEOUT_SECONDS

    if _RING_FEATURE_ENABLED_RAW is None:
        raise RingConfigError(
            "RING_FEATURE_ENABLED is not set. There is no implicit "
            "default -- set it explicitly to \"false\" (off) or \"true\" "
            "before this process can start."
        )
    normalized = _RING_FEATURE_ENABLED_RAW.strip().lower()
    if normalized not in ("true", "false"):
        raise RingConfigError(
            f"RING_FEATURE_ENABLED ({_RING_FEATURE_ENABLED_RAW!r}) must be "
            "exactly \"true\" or \"false\"."
        )
    RING_FEATURE_ENABLED = normalized == "true"

    if _RING_COOLDOWN_MINUTES_RAW is None or not _RING_COOLDOWN_MINUTES_RAW.strip():
        raise RingConfigError(
            "RING_COOLDOWN_MINUTES is not set. There is no implicit "
            "default for the ring cooldown window -- set it explicitly "
            "(e.g. 5)."
        )
    try:
        minutes = int(_RING_COOLDOWN_MINUTES_RAW)
    except ValueError:
        raise RingConfigError(
            f"RING_COOLDOWN_MINUTES ({_RING_COOLDOWN_MINUTES_RAW!r}) is "
            "not a valid integer."
        )
    if minutes <= 0:
        raise RingConfigError(
            f"RING_COOLDOWN_MINUTES ({minutes}) must be a positive number of minutes."
        )
    RING_COOLDOWN_MINUTES = minutes

    if _RING_VOIP_ENABLED_RAW is None:
        raise RingConfigError(
            "RING_VOIP_ENABLED is not set. There is no implicit default -- "
            "set it explicitly to \"false\" (off, plain-APNs ring push) or "
            "\"true\" (VoIP push + CallKit) before this process can start."
        )
    voip_normalized = _RING_VOIP_ENABLED_RAW.strip().lower()
    if voip_normalized not in ("true", "false"):
        raise RingConfigError(
            f"RING_VOIP_ENABLED ({_RING_VOIP_ENABLED_RAW!r}) must be "
            "exactly \"true\" or \"false\"."
        )
    RING_VOIP_ENABLED = voip_normalized == "true"

    if _RING_TIMEOUT_SECONDS_RAW is None or not _RING_TIMEOUT_SECONDS_RAW.strip():
        raise RingConfigError(
            "RING_TIMEOUT_SECONDS is not set. There is no implicit default "
            "for how long a CallKit-presented ring stays up before timing "
            "out -- set it explicitly (e.g. 30)."
        )
    try:
        timeout_seconds = int(_RING_TIMEOUT_SECONDS_RAW)
    except ValueError:
        raise RingConfigError(
            f"RING_TIMEOUT_SECONDS ({_RING_TIMEOUT_SECONDS_RAW!r}) is not "
            "a valid integer."
        )
    if timeout_seconds <= 0:
        raise RingConfigError(
            f"RING_TIMEOUT_SECONDS ({timeout_seconds}) must be a positive "
            "number of seconds."
        )
    RING_TIMEOUT_SECONDS = timeout_seconds


def is_ring_enabled() -> bool:
    """Current RING_FEATURE_ENABLED value -- always looked up fresh (see the
    module-global comment above) so callers see validate_ring_config()'s
    result regardless of import order."""
    return RING_FEATURE_ENABLED


def is_ring_voip_enabled() -> bool:
    """Current RING_VOIP_ENABLED value -- same fresh-lookup reasoning as
    is_ring_enabled() above. When True, ring_members sends via
    send_voip_push()+CallKit instead of the plain APNs alert push."""
    return RING_VOIP_ENABLED


def ring_timeout_seconds() -> int:
    """Current RING_TIMEOUT_SECONDS value -- same fresh-lookup reasoning as
    is_ring_enabled()/is_ring_voip_enabled() above (a `from module import
    RING_TIMEOUT_SECONDS` at another call site would bind the pre-
    validate_ring_config() value of 0 forever)."""
    return RING_TIMEOUT_SECONDS


class DevotionManager(DBManager):
    """Handles all devotion session data operations."""

    def is_authorized(self, session: dict, user_id: str) -> bool:
        """True if ``user_id`` may view, join, leave, or join the call for
        this session: its creator, an existing participant, or a member of
        the group/DM room it belongs to.

        ``session["group_id"]`` is free-form text (see db.py's comment on
        the devotions table) — either a real ``groups._id`` or a DM room key
        ``"uidA|uidB"`` (sorted, see frontend's roomKey()) — so branch on
        whether it contains the DM separator rather than assuming either.

        Task 20260916-group-session-join-failure (backend step 1): the
        creator and every existing participant short-circuit above and never
        reach the ``groups`` lookup below at all -- only a non-creator,
        non-participant *group* member's join/view/leave exercises it. Live
        reproduction (real Postgres, real signup + group + devotion rows)
        confirmed the lookup itself is correct for a well-formed
        ``group_id`` (a genuine ``groups._id``, present or added to the
        group after creation) in every case tried. It also confirmed a
        concrete failure mode matching the reported symptom exactly: a
        ``group_id`` that is not valid ``uuid`` syntax (e.g. a corrupted/
        stale value -- this column has no DB- or app-level format
        constraint; it's free-form client-supplied text all the way from
        iOS's ``createSession``/``SessionCreatorSheet``) makes Postgres raise
        ``invalid input syntax for type uuid`` on ``_id = %s`` below. That
        was previously caught by the bare ``except Exception`` and logged at
        ``warning`` level as if it were an ordinary "not a member" result --
        completely indistinguishable from a real denial from every caller's
        point of view (the join route just sees ``is_authorized`` return
        ``False`` and 403s), and easy to miss/ignore in logs at that level.
        Since the creator never touches this branch, that pattern denies
        every OTHER member while leaving the creator's own join unaffected --
        exactly this bug's reported shape.

        Q14 (fail-closed) still applies: any failure to positively confirm
        membership here still returns ``False`` -- this change does not
        relax who gets denied. What it changes (Q26/Q27) is that a failure
        to *resolve* membership (a real error) is no longer silently folded
        into the same log line as a legitimate "not a member" outcome, so
        the next occurrence is loud and diagnosable instead of requiring the
        kind of live multi-account reproduction this task needed.
        """
        if not session:
            return False
        if str(session.get("creator_id") or "") == user_id:
            return True
        if user_id in (session.get("participants") or []):
            return True
        group_id = str(session.get("group_id") or "")
        if not group_id:
            return False
        if "|" in group_id:
            return user_id in group_id.split("|")
        try:
            self.cur.execute(
                "SELECT 1 FROM groups WHERE _id = %s AND %s = ANY(users)",
                (group_id, user_id),
            )
            return self.cur.fetchone() is not None
        except Exception:
            # logger.exception (not .warning) -- this branch means membership
            # could NOT be resolved (a real error, e.g. a malformed group_id
            # failing Postgres's uuid cast), not that it was resolved and
            # came back negative. Still denies (fail-closed, Q14), but now at
            # a severity/detail level that surfaces in monitoring instead of
            # blending into routine "not authorized" traffic.
            logger.exception(
                "Devotion group-membership check errored for group_id=%r, user_id=%r -- "
                "denying (fail-closed), but this is NOT a confirmed non-membership result.",
                group_id, user_id,
            )
            self.conn.rollback()
            return False

    def resolve_members(self, session: dict) -> list[str]:
        """Every user_id this session's own membership rules (``is_authorized``
        above) would grant access to: the creator, any existing participants,
        and the full group/DM roster. Returns a deduped list rather than
        checking one candidate user at a time -- the push-notification call
        sites (creation push, time_start reminder) need the whole audience at
        once, but the membership concept itself is deliberately the same one
        ``is_authorized`` already encodes, not a new definition (task
        20260904-session-push-notifications).
        """
        members: set[str] = set()
        creator_id = str(session.get("creator_id") or "")
        if creator_id:
            members.add(creator_id)
        members.update(session.get("participants") or [])
        group_id = str(session.get("group_id") or "")
        if not group_id:
            return list(members)
        if "|" in group_id:
            members.update(group_id.split("|"))
            return list(members)
        try:
            self.cur.execute("SELECT users FROM groups WHERE _id = %s", (group_id,))
            row = self.cur.fetchone()
            if row and row[0]:
                members.update(str(u) for u in row[0])
        except Exception as e:
            logger.warning("Devotion group-roster resolve failed for group_id=%s: %s", group_id, e)
            self.conn.rollback()
        return list(members)

    def real_group_roster(self, group_id: str) -> set[str]:
        """The verifiable membership of ``group_id`` -- resolved ONLY from
        the real ``groups`` table row (or a friendship/block-verified
        DM-pair split), never from ``session.creator_id``/
        ``session.participants``.

        Task 20260916-call-ring-members (post-security-bounce rework):
        both of those session fields are fully client-supplied and
        unvalidated at devotion-session creation time -- ``DevotionPlan``
        has no server-side check tying either to real group membership
        (see architecture.json's ``revision_note``/``separately_scoped_
        issue`` for this task). ``is_authorized``/``resolve_members`` fold
        those fields in, which is fine for their existing callers
        (join/view/leave/create/join_call -- fixing *that* root cause is a
        separately-scoped issue) but reusing either for ring's own
        authorization would let a caller mint a session with a forged
        ``group_id``/``participants`` and ring real members of a group
        they were never actually part of. Ring uses this method instead,
        for both the caller check and target eligibility, and no longer
        consults ``resolve_members`` at all.

        Task 20260916-call-ring-members (2nd security-bounce rework): the
        DM-pair branch (``group_id`` containing ``"|"``) used to trust the
        literal id-split as-is -- since ``group_id`` is free-form,
        client-supplied text with no server-side format validation at
        session-creation time (same root cause noted above), a caller could
        self-mint ``group_id="<attacker>|<victim>"`` and have both the
        caller-membership and target-eligibility checks pass purely from
        string-splitting, with zero real relationship behind it. The split
        pair is now only trusted as a roster once it's independently
        verified to be a real, current, non-blocked mutual friendship --
        the same defense-in-depth ``user_friends``/``blocked_users``
        ``NOT EXISTS`` check shape as
        ``FriendsManager.check_nudge_allowed``/``get_friend_activity``,
        adapted to require a ``user_friends`` row in *both* directions
        (rather than trusting the one-directional row ``add_friend``'s
        symmetric insert implies) since this method has no
        ``FriendsManager`` instance's own invariants to lean on. A pair
        that isn't a verified mutual-friend, non-blocked pair yields an
        empty set for the whole DM session -- same fail-closed shape as
        the real-group branch's blank/errored ``group_id`` case, and the
        denial never distinguishes "not friends" from "blocked" (merged,
        enumeration-avoidance posture, matching ``check_nudge_allowed``).

        Fails closed (Q14) to an empty set for a blank ``group_id`` --
        there's no independently-verifiable roster behind an empty value,
        so nothing is authorized against it rather than falling back to
        session fields -- for a DM-pair that isn't a verified, non-blocked
        mutual friendship, and for any error resolving either roster.

        Args:
            group_id: Either a real ``groups._id`` or a DM room key
                ``"uidA|uidB"`` (sorted, see frontend's ``roomKey()``).

        Returns:
            set[str]: The real member ids, or an empty set if ``group_id``
                is blank, the DM pair isn't a verified non-blocked mutual
                friendship, or the lookup fails.
        """
        if not group_id:
            return set()
        if "|" in group_id:
            parts = group_id.split("|")
            if len(parts) != 2 or not parts[0] or not parts[1] or parts[0] == parts[1]:
                # Malformed/degenerate split (not the well-formed 2-distinct
                # -id shape frontend's roomKey() produces) -- no roster to
                # verify a relationship for. Fail closed rather than guess.
                return set()
            uid_a, uid_b = parts
            try:
                self.cur.execute(
                    "SELECT 1 FROM user_friends uf_fwd "
                    "JOIN user_friends uf_rev "
                    "  ON uf_rev.user_id = uf_fwd.friend_id "
                    "  AND uf_rev.friend_id = uf_fwd.user_id "
                    "WHERE uf_fwd.user_id = %s AND uf_fwd.friend_id = %s "
                    "AND NOT EXISTS ("
                    "  SELECT 1 FROM blocked_users b "
                    "  WHERE (b.blocker_id = %s AND b.blocked_id = %s) "
                    "     OR (b.blocker_id = %s AND b.blocked_id = %s)"
                    ")",
                    (uid_a, uid_b, uid_a, uid_b, uid_b, uid_a),
                )
                if self.cur.fetchone() is None:
                    # Merged denial (Q_enumeration-avoidance): could be "not
                    # friends" (in either or both directions) or "blocked"
                    # (either direction) -- never distinguished, same as
                    # FriendsManager.check_nudge_allowed's "not_friends".
                    return set()
                return {uid_a, uid_b}
            except Exception:
                logger.exception(
                    "Devotion real_group_roster DM-pair friendship/block "
                    "verification errored for group_id=%r -- denying "
                    "(fail-closed), but this is NOT a confirmed "
                    "not-friends/blocked result.",
                    group_id,
                )
                self.conn.rollback()
                return set()
        try:
            self.cur.execute("SELECT users FROM groups WHERE _id = %s", (group_id,))
            row = self.cur.fetchone()
            return {str(u) for u in row[0]} if row and row[0] else set()
        except Exception:
            logger.exception(
                "Devotion real_group_roster lookup errored for group_id=%r -- "
                "denying (fail-closed), but this is NOT a confirmed empty-roster result.",
                group_id,
            )
            self.conn.rollback()
            return set()

    def device_tokens_bulk(self, user_ids: list[str]) -> dict[str, str]:
        """{user_id: token} for every user in ``user_ids`` with a registered
        device token -- one batched query instead of one per recipient,
        matching the existing bulk-lookup pattern (``websockets.py``'s
        ``send_msg``, ``ActivityManager.friend_device_tokens_bulk``).
        """
        if not user_ids:
            return {}
        try:
            self.cur.execute(
                "SELECT user_id, token FROM device_tokens WHERE user_id = ANY(%s::uuid[])",
                (list(user_ids),),
            )
            return {str(r[0]): r[1] for r in self.cur.fetchall()}
        except Exception as e:
            logger.error("Devotion batch device-token lookup failed: %s", e)
            self.conn.rollback()
            return {}

    def voip_device_tokens_bulk(self, user_ids: list[str]) -> dict[str, str]:
        """{user_id: token} for every user in ``user_ids`` with a registered
        VoIP push token (task 20260916-callkit-voip-ring) -- same shape and
        batching rationale as ``device_tokens_bulk`` above, but reading the
        distinct ``voip_device_tokens`` table (a VoIP token is a different
        token type in Apple's system from the APNs remote-notification
        token ``device_tokens`` holds; a user's client registers both
        independently, see ``routes/notifications.py``'s
        ``register_voip_device_token``). Never falls back to
        ``device_tokens`` -- a user who hasn't granted/registered a VoIP
        token has no entry here even if they have a plain APNs token, which
        is exactly what lets ``ring_members`` fail loud with a distinct
        ``"no_voip_token"`` reason instead of silently reusing the wrong
        token type.
        """
        if not user_ids:
            return {}
        try:
            self.cur.execute(
                "SELECT user_id, token FROM voip_device_tokens WHERE user_id = ANY(%s::uuid[])",
                (list(user_ids),),
            )
            return {str(r[0]): r[1] for r in self.cur.fetchall()}
        except Exception as e:
            logger.error("Devotion batch VoIP device-token lookup failed: %s", e)
            self.conn.rollback()
            return {}

    def get_username(self, user_id: str) -> str:
        """Best-effort display name for a push body (e.g. "{username}
        scheduled a new session"); empty string if the user can't be
        resolved -- callers fall back to a generic label rather than fail."""
        result = self.lookup("users", {"_id": user_id})
        if not result:
            return ""
        _, data = list(result.items())[0]
        return data.get("username", "") or ""

    def claim_ring_slot(self, sender_id: str, recipient_id: str) -> bool:
        """Atomically check-and-claim the cross-session (sender, recipient)
        ring cooldown in a single round trip -- same concurrency-safe
        ``INSERT ... ON CONFLICT ... WHERE ... RETURNING`` shape as
        ``FriendsManager.claim_nudge_slot`` (task 20260906-friend-nudges),
        which closes the "two unsynchronized round trips" race that shape
        exists to prevent: Postgres's own row lock on the conflicting
        ``(sender_id, recipient_id)`` row serializes concurrent callers for
        the same key instead of letting both observe "cooldown elapsed" at
        once.

        Revised (task 20260916-call-ring-members, post-security-bounce
        rework) from the original per-(sender, recipient, session) key to
        this cross-session (sender, recipient)-only key: security's
        re-review found that a fresh ``session_id`` reset the old key's
        cooldown for free, and nothing about session creation was
        throttled or (at the time) verified against real group membership
        -- together those let a sender mint a new session and re-ring the
        same target with no effective limit. Dropping ``session_id`` from
        the key entirely closes that: no session_id can ever reset this
        cooldown again. A legitimate re-ring after
        ``RING_COOLDOWN_MINUTES`` elapses still works identically whether
        it's the same session or a new one, so nothing about the
        already-shipped-in-spirit cooldown UX changes.

        Must be called -- and must return ``True`` -- BEFORE the push is
        sent, never after. Call ``release_ring_claim`` afterward if the send
        itself then fails, so a failed send doesn't consume the cooldown for
        nothing.

        Task 20260916-callkit-voip-ring open question resolved: whether a
        CallKit-presented ring that's declined or times out should still
        count against the cooldown the same way a delivered-but-ignored
        plain push did. Answer: unchanged, and deliberately so -- this
        method is (and remains) called once, at successful-send time, same
        as before this task. Decline/timeout/answer are all client-local
        CallKit outcomes that happen strictly after a push already claimed
        its slot and was delivered; this task adds no backend endpoint for
        CallKit's callbacks to report an outcome back (that would be new API
        surface out of this step's scope), so the backend has no more
        visibility into "declined" vs. "timed out" vs. "left ringing
        unanswered" than it ever had into a plain push being ignored. A
        delivered ring consumes the sender's cooldown regardless of what the
        recipient's device does with it afterward -- exactly today's
        semantics, just now also covering CallKit's three outcomes instead
        of plain-push's one.

        Returns:
            bool: ``True`` if this call claimed the slot (no prior ring for
                this (sender, recipient) pair, or the prior claim's
                ``last_rung_at`` is already older than
                ``RING_COOLDOWN_MINUTES``) -- the caller may proceed to
                send. ``False`` if an existing claim is still within the
                window -- the caller must deny with reason
                ``"rate_limited"`` and must NOT send.
        """
        self.cur.execute(
            "INSERT INTO ring_cooldowns (sender_id, recipient_id, last_rung_at) "
            "VALUES (%s, %s, NOW()) "
            "ON CONFLICT (sender_id, recipient_id) DO UPDATE "
            "SET last_rung_at = NOW() "
            "WHERE ring_cooldowns.last_rung_at < NOW() - (%s * INTERVAL '1 minute') "
            "RETURNING sender_id",
            (sender_id, recipient_id, RING_COOLDOWN_MINUTES),
        )
        claimed = self.cur.fetchone() is not None
        self.conn.commit()
        return claimed

    def release_ring_claim(self, sender_id: str, recipient_id: str) -> None:
        """Undo a winning ``claim_ring_slot`` call after the push send
        itself failed, so the sender's cooldown isn't consumed for a ring
        that never actually reached the recipient -- mirrors
        ``FriendsManager.release_nudge_claim`` exactly, including its
        "only ever safe to call on behalf of a claim this same request
        already won" precondition (see that method's docstring).

        Best-effort/non-fatal on failure -- the push already failed by the
        time this is called, so a failure here is logged, not raised, and
        must never mask the original send failure the caller is already
        handling.
        """
        try:
            self.cur.execute(
                "DELETE FROM ring_cooldowns WHERE sender_id = %s AND recipient_id = %s",
                (sender_id, recipient_id),
            )
            self.conn.commit()
        except Exception as e:
            logger.warning(
                "Ring claim release failed (%s -> %s): %s",
                sender_id, recipient_id, e,
            )
            self.conn.rollback()

    def save_devotion(self, devotion: DevotionPlan) -> str:
        # Security fix (task 20260916-call-ring-members, 3rd security
        # re-review): `chime_meeting_id`/`chime_meeting` must never be
        # taken from client-supplied `DevotionPlan` input on create --
        # ring's whole `live_call_gating` decision (routes/devotion.py::
        # ring_members's "no_active_call" check) depends on
        # `chime_meeting_id` only ever reflecting a genuine AWS Chime
        # `CreateMeeting` response (written exclusively via
        # `save_chime_meeting`, after `join_call`/`_get_or_create_meeting`
        # succeeds). `DevotionPlan.chime_meeting_id` has a client-settable
        # default of `""` with no server-side override here previously --
        # a caller could POST /devotions/ with a self-chosen non-empty
        # `chime_meeting_id` string and immediately pass the ring route's
        # live-call gate for a session with no real call behind it at all,
        # letting them send a "join the call now" push to a real group
        # member/verified friend for a call that never existed. Neither
        # field is ever legitimately populated by a client at creation
        # time (confirmed: no iOS model sends either), so both are hard
        # coded to their empty defaults here regardless of what the
        # request body contains -- only `save_chime_meeting` may ever set
        # a real value, later.
        self.cur.execute(
            "INSERT INTO devotions (_id, title, time_start, time_end, recurring, "
            "group_id, creator_id, participants, verses, prompts, chime_meeting_id, chime_meeting, summarize) "
            "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
            (devotion.id, devotion.title,
             devotion.time_start or None, devotion.time_end or None,
             devotion.recurring,
             devotion.group_id or None, devotion.creator_id or None,
             devotion.participants, devotion.verses, devotion.prompts,
             "", json.dumps({}),
             devotion.summarize)
        )
        self.conn.commit()
        return devotion.id

    def read_devotion(self, devotion_id: str) -> DevotionPlan | None:
        result = self.lookup("devotions", {"_id": devotion_id})
        if not result:
            return None
        _, data = list(result.items())[0]
        return self._to_plan(devotion_id, data)

    def remove_devotion(self, devotion_id: str) -> None:
        # Callers (routes/devotion.py::delete_devotion) already confirmed the
        # session exists via read_devotion immediately before calling this,
        # so a False return here is a real write failure, not an expected
        # no-op.
        if not self.delete("devotions", {"_id": devotion_id}):
            raise SaveFailedError()

    def fetch_by_contact(self, contact_id: str, viewer_id: str | None = None) -> list[dict]:
        result = self.lookup("devotions", {"group_id": contact_id})
        sessions = [{"id": did, **data} for did, data in result.items()]
        if viewer_id:
            # Guideline 1.2: hide devotions created by someone in a blocked
            # relationship with the viewer, either direction.
            self.cur.execute(
                "SELECT blocked_id FROM blocked_users WHERE blocker_id = %s "
                "UNION SELECT blocker_id FROM blocked_users WHERE blocked_id = %s",
                (viewer_id, viewer_id),
            )
            blocked = {str(r[0]) for r in self.cur.fetchall()}
            sessions = [s for s in sessions if str(s.get("creator_id")) not in blocked]
        return sessions

    def add_participant(self, session_id: str, user_id: str) -> None:
        self.cur.execute(
            "UPDATE devotions SET participants = array_append(participants, %s) "
            "WHERE _id = %s AND NOT (%s = ANY(participants))",
            (user_id, session_id, user_id)
        )
        self.conn.commit()

    def remove_participant(self, session_id: str, user_id: str) -> None:
        self.cur.execute(
            "UPDATE devotions SET participants = array_remove(participants, %s) WHERE _id = %s",
            (user_id, session_id)
        )
        self.conn.commit()

    def update_devotion(self, session_id: str, devotion: DevotionPlan) -> bool:
        existing = self.lookup("devotions", {"_id": session_id})
        if not existing:
            return False
        _, ex = list(existing.items())[0]
        self.cur.execute(
            "UPDATE devotions SET title=%s, time_start=%s, time_end=%s, recurring=%s, "
            "group_id=%s, creator_id=%s, verses=%s, prompts=%s WHERE _id=%s",
            (devotion.title,
             devotion.time_start or None, devotion.time_end or None,
             devotion.recurring,
             devotion.group_id or None, devotion.creator_id or None,
             devotion.verses, devotion.prompts,
             session_id)
        )
        self.conn.commit()
        return True

    def save_chime_meeting(self, session_id: str, meeting_id: str, meeting_data: dict) -> None:
        self.cur.execute(
            "UPDATE devotions SET chime_meeting_id=%s, chime_meeting=%s WHERE _id=%s",
            (meeting_id, json.dumps(meeting_data), session_id)
        )
        self.conn.commit()

    def get_session(self, session_id: str) -> dict:
        result = self.lookup("devotions", {"_id": session_id})
        if not result:
            return {}
        did, data = list(result.items())[0]
        return {"id": did, **data}

    def _to_plan(self, devotion_id: str, data: dict) -> DevotionPlan:
        chime = data.get("chime_meeting")
        if isinstance(chime, str):
            chime = json.loads(chime)
        return DevotionPlan(
            id=devotion_id,
            title=data.get("title", ""),
            time_start=str(data.get("time_start") or ""),
            time_end=str(data.get("time_end") or ""),
            recurring=data.get("recurring", False),
            group_id=str(data.get("group_id") or ""),
            creator_id=str(data.get("creator_id") or ""),
            participants=data.get("participants") or [],
            verses=data.get("verses") or [],
            prompts=data.get("prompts") or [],
            chime_meeting_id=data.get("chime_meeting_id", ""),
            chime_meeting=chime or {},
            summarize=bool(data.get("summarize", False)),
        )
