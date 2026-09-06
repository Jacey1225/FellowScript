import requests
import asyncio
import functools
import logging
import time
import uuid
import psycopg2
from collections import deque
from datetime import datetime, date, timedelta
from zoneinfo import ZoneInfo
from typing import Optional
from schemas.agent import Agent, AgentMessages, AgentHeartbeats
from schemas.users import Note
import os
from pathlib import Path
from dotenv import load_dotenv
from db import DBManager
from backend.errors import SaveFailedError, TimelineGenerationError
from backend.interactions.groups import GroupsManager
from fastapi import WebSocket
from starlette.websockets import WebSocketDisconnect
import json

load_dotenv()

logger = logging.getLogger(__name__)

MODELNAME = "deepseek/deepseek-chat"
BASEURL   = "https://openrouter.ai/api/v1/chat/completions"
HEADERS   = {
    "Authorization": f"Bearer {os.getenv('OPENROUTER_API_KEY')}",
    "Content-Type":  "application/json",
}

PROMPT = (Path(__file__).parent / "agent_prompt.txt").read_text(encoding="utf-8").strip()

# System prompt for the dedicated timeline-planning agent (task
# 20260906-heartbeat-timeline-instructions) -- a separate, purpose-built
# prompt from PROMPT/agent_role above: this agent plans WHAT a heartbeat's
# future notes should cover, it never writes a note itself. Externalized to
# its own file for the same maintainability reason PROMPT is (easy to tune
# without touching this module).
TIMELINE_PROMPT = (Path(__file__).parent / "timeline_prompt.txt").read_text(encoding="utf-8").strip()

# Per-connection cap on the agent chat WebSocket: every HTTP write on
# agent_router is gated by check_limit's free-tier caps, but connect_agent's
# loop had no equivalent, so a connected client could otherwise trigger
# unlimited billed OpenRouter calls (LLM10 Unbounded Consumption).
_CHAT_RATE_LIMIT_MESSAGES = 20
_CHAT_RATE_LIMIT_WINDOW_SECONDS = 60.0

# Bounded retry cap for _generate_and_save_note's JSON-parse-failure path
# (the LLM's response comes back either with no "{"/"}" pair at all, or with
# one that doesn't parse as JSON). Confirmed intermittent rather than
# deterministic per-model output-formatting noise, so a few retries
# meaningfully cut user-visible failures without ever retrying indefinitely.
# This is a TOTAL attempt count (first try + retries), always compared with
# a fixed for-range loop -- a future delay/backoff between attempts could be
# added at the single `self._call_api(...)` call site inside that loop
# without restructuring it, so this constant intentionally isn't split into
# a separate "retries" + "backoff" pair until that's actually needed.
_HB_JSON_PARSE_MAX_ATTEMPTS = 3

# Bounded retry cap for the timeline-planning agent's own JSON-parse/shape-
# validation failure path (AgentManager._generate_timeline_days), mirroring
# _HB_JSON_PARSE_MAX_ATTEMPTS above -- same "confirmed intermittent
# output-formatting noise" precedent, same total-attempt-count semantics.
_TIMELINE_JSON_PARSE_MAX_ATTEMPTS = 3

# Named per Configuration Philosophy Q1/Q13 (proactive configuration for a
# foreseeable, currently-hardcoded literal) rather than a bare "31" -- this
# is the maximum span (in days) a single `agent_heartbeats.timeline_instruction`
# window covers, matching AgentHeartbeats.timestamps' fixed 31-slot
# day-of-month array. Not split into a separate "days-of-month array size"
# constant per Q14 (don't over-configure beyond what's concretely
# foreseeable): the two happen to share a value today because a calendar
# month is at most 31 days, but timestamps' array size is a day-of-month
# indexing choice, not itself a window-length choice.
TIMELINE_WINDOW_DAYS = 31


class AgentManager(DBManager):
    def __init__(self, user_id: str):
        super().__init__()
        self.user_id       = user_id
        self.agent_table   = "agents"
        self.hb_table      = "agent_heartbeats"
        self.msg_table     = "agent_messages"
        self.note_table    = "notes"

    # ── Agent CRUD ────────────────────────────────────────────────────────────

    def create_agent(self, agent: Agent) -> str:
        if not self.insertion(self.agent_table, {
            "_id":     agent.id,
            "user_id": agent.user_id,
            "role":    agent.role,
            "chats":   agent.chats,
        }):
            raise SaveFailedError()
        return agent.id

    def get_agent(self, agent_id: str) -> dict | None:
        result = self.lookup(self.agent_table, {"_id": agent_id})
        if not result:
            return None
        return result

    def owns_agent(self, agent_id: str) -> bool:
        """True if ``agent_id`` belongs to ``self.user_id``. Callers that take
        a bare agent_id from the URL/body must check this before reading or
        acting on it — the id alone is not proof of ownership."""
        return bool(self.lookup(self.agent_table, {"_id": agent_id, "user_id": self.user_id}))

    def get_user_agents(self) -> dict:
        return self.lookup(self.agent_table, {"user_id": self.user_id})

    def update_agent(self, agent: Agent) -> None:
        if not self.update(
            self.agent_table,
            {"role": agent.role, "chats": agent.chats},
            {"_id": agent.id, "user_id": self.user_id}
        ):
            raise SaveFailedError()

    def delete_agent(self, agent_id: str) -> None:
        # The WHERE clause enforces ownership itself (unlike other deletes
        # in this file, no separate owns_agent()/lookup precedes this) --
        # a caller-not-owner and an already-deleted agent both come back as
        # a zero-rows False, and neither should raise: the route intends a
        # 204 either way rather than leaking which case it was. A real DB
        # error is still visible via db.py's DB_WRITE_FAILURE log line.
        self.delete(self.agent_table, {"_id": agent_id, "user_id": self.user_id})

    # ── Heartbeat CRUD ────────────────────────────────────────────────────────

    def add_heartbeat(self, heartbeat: AgentHeartbeats, idempotency_key: Optional[str] = None) -> Optional[str]:
        """Create a heartbeat row and return its id.

        Bug 2 fix (task 20260905-heartbeat-timezone-duplicate-bugs):
        ``idempotency_key`` should be a token the CLIENT generates once per
        Save *attempt* (not regenerated on an internal retry of that same
        attempt -- see EventSetupSheet.swift's iOS-side fix). Paired with
        db.py's UNIQUE index on (user_id, agent_id, idempotency_key), a
        double-submit of the same attempt (double-tap, client retry) can
        never create two rows: the second INSERT collides with the first at
        the Postgres constraint level -- not a check-then-insert race in
        this method, which would not be safe against two near-simultaneous
        requests (Q28) -- and this method returns the FIRST attempt's row id
        rather than raising or silently creating a duplicate (Q26: an
        explicit, visible outcome either way, not a silent fallback).

        This constraint is scoped to the per-attempt token, not to
        (prompt, timestamps, group_id) content, so it never blocks a user's
        legitimate, intentional creation of two truly-identical scheduled
        events -- unlike a naive content-based unique constraint would.

        If no ``idempotency_key`` is supplied (e.g. a not-yet-updated
        client during rollout), one is generated here so the INSERT/
        constraint machinery always has a value to key off of -- but a
        server-manufactured key can never coincide with a real double-
        submit's shared client-generated key, so it provides no dedup
        protection for that caller. Every current client is expected to
        always send one once this task's iOS step ships, so a missing key
        is logged as a warning rather than treated as the unremarkable
        common case.

        Returns:
            The id of the row that now represents this (user, agent,
            idempotency_key) triple -- either newly created, or the
            pre-existing row from an earlier attempt with the same key.
            None if the write failed for a reason other than the
            idempotency-key collision (a real DB error); callers must
            treat that as a genuine failure (see SaveFailedError), not a
            silent no-op.

        Raises:
            TimelineGenerationError: if the initial `timeline_instruction`
                (task 20260906-heartbeat-timeline-instructions) can't be
                generated after retries -- deliberately raised BEFORE the
                INSERT below (and outside its own try/except) so no
                heartbeat row is ever created without a timeline: a
                heartbeat that exists but has no content plan is not a
                degraded-but-usable state per the spec's propagate-errors
                preference (Q27), it's a state that must never occur.
        """
        window_start = self._local_date()
        firing_offsets = self._firing_offsets(heartbeat.timestamps, window_start)
        planned = self._generate_timeline_days(heartbeat.prompt, firing_offsets, prior_coverage_summary=None)
        days = {offset: planned["days"].get(offset, "") for offset in firing_offsets}
        timeline_raw = self._encode_timeline(window_start, days, planned.get("coverage_summary", ""))

        hb_id = str(uuid.uuid4())
        if not idempotency_key:
            idempotency_key = str(uuid.uuid4())
            logger.warning(
                "add_heartbeat called with no idempotency_key (user=%s agent=%s) -- "
                "generating one server-side; this request gets no double-submit "
                "protection.",
                heartbeat.user_id, heartbeat.agent_id,
            )
        try:
            self.cur.execute(
                "INSERT INTO agent_heartbeats "
                "(_id, agent_id, user_id, timestamps, prompt, group_id, notes_public, idempotency_key, "
                "timeline_instruction) "
                "VALUES (%s, %s, %s, %s::jsonb, %s, %s, %s, %s, %s)",
                (hb_id, heartbeat.agent_id, heartbeat.user_id,
                 json.dumps(heartbeat.timestamps), heartbeat.prompt, heartbeat.group_id or None,
                 heartbeat.notes_public, idempotency_key, timeline_raw)
            )
            self.conn.commit()
            return hb_id
        except psycopg2.errors.UniqueViolation:
            # Another attempt with this exact (user_id, agent_id,
            # idempotency_key) already landed -- a double-submit, not a new
            # event. Fail toward "return the already-created row" rather
            # than erroring the caller or silently minting a second row.
            self.conn.rollback()
            existing = self.lookup(self.hb_table, {
                "user_id": heartbeat.user_id, "agent_id": heartbeat.agent_id,
                "idempotency_key": idempotency_key,
            })
            if existing:
                return list(existing.keys())[0]
            # Constraint fired but the row it collided with isn't visible to
            # this same-transaction lookup (should not happen in practice,
            # since the constraint only fires when a matching row is
            # committed) -- surfaced loudly rather than assumed benign.
            logger.error(
                "add_heartbeat: unique violation for user=%s agent=%s key=%s but no "
                "existing row was found on lookup.",
                heartbeat.user_id, heartbeat.agent_id, idempotency_key,
            )
            return None
        except Exception as e:
            logger.error("Error adding heartbeat: %s", e)
            self.conn.rollback()
            return None

    def get_heartbeats(self, agent_id: str) -> list[dict]:
        result = self.lookup(self.hb_table, {"agent_id": agent_id, "user_id": self.user_id})
        return [{"_id": k, **v} for k, v in result.items()]

    def update_heartbeat(self, heartbeat_id: str, heartbeat: AgentHeartbeats) -> None:
        """Update a heartbeat row's editable fields.

        If the incoming ``timestamps`` differs from what's currently
        stored, ``timeline_instruction`` is set to NULL in the same
        UPDATE: the current timeline was built against the OLD firing
        schedule, so a schedule edit invalidates it. This is the entire
        migration story for a schedule change -- no separate staleness
        flag -- the next fire's ``ensure_current_timeline`` call sees NULL
        and regenerates lazily, informed by whatever ``coverage_summary``
        the just-invalidated timeline had already consumed on its own last
        regeneration (see ensure_current_timeline's docstring); nothing is
        lost by nulling the column here.
        """
        try:
            existing = self.lookup(self.hb_table, {"_id": heartbeat_id, "user_id": self.user_id})
            clear_timeline = False
            if existing:
                existing_data = list(existing.values())[0]
                if (existing_data.get("timestamps") or []) != (heartbeat.timestamps or []):
                    clear_timeline = True

            set_clause = "timestamps = %s::jsonb, prompt = %s, group_id = %s, notes_public = %s"
            params: list = [
                json.dumps(heartbeat.timestamps), heartbeat.prompt, heartbeat.group_id or None,
                heartbeat.notes_public,
            ]
            if clear_timeline:
                set_clause += ", timeline_instruction = NULL"
            params += [heartbeat_id, self.user_id]

            self.cur.execute(
                f"UPDATE agent_heartbeats SET {set_clause} WHERE _id = %s AND user_id = %s",
                params,
            )
            self.conn.commit()
        except Exception as e:
            logger.error("Error updating heartbeat %s: %s", heartbeat_id, e)
            self.conn.rollback()

    def delete_heartbeat(self, heartbeat_id: str) -> None:
        # Same idempotent/ownership-via-WHERE reasoning as delete_agent above.
        self.delete(self.hb_table, {"_id": heartbeat_id, "user_id": self.user_id})

    def note_via_hb(self, data: dict, group_id: Optional[str] = None, notes_public: bool = False) -> str:
        """Persist a note generated by a heartbeat fire.

        ``group_id`` is the *heartbeat row's own* group_id (read by the
        caller off the ``agent_heartbeats`` table, e.g. commit_hb_response's
        ``owned`` lookup) -- NOT ``data.get("group_id")``. The LLM's own
        create_note response has no reason to ever populate a group_id, so
        trusting it here would silently leave every heartbeat-generated note
        ungrouped even when the heartbeat itself is tied to a group.

        ``notes_public`` is likewise the *heartbeat row's own* stored
        edit-permission choice (``agent_heartbeats.notes_public``, set at
        configuration time on the event-editing screen), never
        ``data.get("public")`` -- the LLM has no basis to decide whether
        other group members may edit its own note, any more than it does
        for group_id. Defaults closed (False) matching the column's own
        deny-by-default.
        """
        note = Note(
            user=self.user_id,
            title=data.get("title", ""),
            text=data.get("text", ""),
            public=notes_public,
            group_id=group_id or "",
            verses=data.get("verses", []),
            # The LLM's self-reported central theme for this note (per
            # agent_prompt.txt's create_note schema) -- recorded metadata
            # only as of task 20260906-heartbeat-timeline-instructions;
            # heartbeat no-duplication is now driven upfront by this
            # heartbeat's timeline_instruction (see ensure_current_timeline/
            # _todays_instruction) rather than a live aggregate of past
            # notes' themes. Left blank if the model omits it rather than
            # failing the note save over it.
            theme=data.get("theme", ""),
        )
        # Historically the exact silent-fake-success case this workflow
        # exists to remove: db.py's create_tables() comment on the
        # `agents` table records a prior incident where a missing column
        # made this INSERT fail, insertion() swallowed it, and the caller
        # (commit_hb_response, via routes/agent.py's commit_heartbeat)
        # still reported success with a generated id even though no note
        # was ever persisted.
        note_id = str(uuid.uuid4())
        if not self.insertion(self.note_table, {
            "_id":      note_id,
            "user_id":  note.user,
            "title":    note.title,
            "text":     note.text,
            "public":   note.public,
            "group_id": note.group_id or None,
            "is_reply": note.is_reply,
            "timestamp": note.timestamp,
            "theme":    note.theme,
        }):
            raise SaveFailedError()
        for i, verse in enumerate(note.verses):
            if isinstance(verse, list) and len(verse) >= 3:
                if not self.insertion("note_verses", {
                    "note_id":  note_id,
                    "position": i,
                    "book":     verse[0],
                    "chapter":  verse[1],
                    "verse":    verse[2],
                }):
                    raise SaveFailedError()
        return note_id

    # ── Timeline instructions ────────────────────────────────────────────────
    # Task 20260906-heartbeat-timeline-instructions: replaces the old
    # agentic_context/get_context/save_context reactive dedup mechanism with
    # an upfront, per-window content plan stored directly on the heartbeat
    # row (see agent_heartbeats.timeline_instruction's comment in db.py).

    def _local_date(self) -> date:
        """Today's calendar date in `self.user_id`'s own local timezone
        (`users.timezone`), matching the per-user-local-day precedent
        already used throughout this file (commit_hb_response's claim,
        scheduler.py's due-scan). Falls back to UTC if the user row is
        missing or its timezone is unset/invalid -- fail-open to a sane
        default here (unlike the fire-time scheduler's fail-closed skip),
        since a wrong-by-a-few-hours window boundary is a much smaller
        problem than refusing to plan a timeline at all.
        """
        result = self.lookup("users", {"_id": self.user_id})
        tzname = list(result.values())[0].get("timezone") if result else None
        try:
            return datetime.now(ZoneInfo(tzname or "UTC")).date()
        except Exception:
            return datetime.now(ZoneInfo("UTC")).date()

    def _firing_offsets(self, timestamps: list, window_start: date) -> list[int]:
        """Which window-offsets (0..TIMELINE_WINDOW_DAYS-1, calendar days
        elapsed since `window_start`) this heartbeat's `timestamps`
        (day-of-month indexed, per AgentHeartbeats.timestamps) actually
        fires on, for the 31-day window starting `window_start`.

        Window-offset, not day-of-month, is the key: a 31-day window
        crossing a short month revisits day-of-month values a day-of-month
        key couldn't represent without collision (see the column comment
        in db.py). `timestamps` remains the sole source of truth for which
        day-of-month values fire -- this just walks the window day by day
        and looks each one up.
        """
        if not timestamps:
            return []
        offsets: list[int] = []
        for offset in range(TIMELINE_WINDOW_DAYS):
            day = window_start + timedelta(days=offset)
            day_idx = day.day - 1
            if day_idx < len(timestamps) and timestamps[day_idx]:
                offsets.append(offset)
        return offsets

    def _encode_timeline(self, window_start: date, days: dict[int, str], coverage_summary: str) -> str:
        return json.dumps({
            "window_start": window_start.isoformat(),
            "days": {str(k): v for k, v in days.items()},
            "coverage_summary": coverage_summary or "",
        })

    def _decode_timeline(self, raw: Optional[str]) -> Optional[dict]:
        """Decode a `timeline_instruction` column value into
        {"window_start": date, "days": {int: str}, "coverage_summary": str},
        or None if there's nothing there yet or it's unreadable (treated as
        "no current timeline" -- ensure_current_timeline regenerates rather
        than raising over a corrupt/legacy value)."""
        if not raw:
            return None
        try:
            data = json.loads(raw)
            return {
                "window_start": date.fromisoformat(data["window_start"]),
                "days": {int(k): v for k, v in (data.get("days") or {}).items()},
                "coverage_summary": data.get("coverage_summary", "") or "",
            }
        except Exception as e:
            logger.error("Could not decode a heartbeat's timeline_instruction -- treating as absent: %s", e)
            return None

    def _build_planning_prompt(
        self, heartbeat_prompt: str, firing_offsets: list[int], prior_coverage_summary: Optional[str],
    ) -> str:
        offsets_str = ", ".join(str(o) for o in firing_offsets) if firing_offsets else "(none)"
        prior_block = (
            f"Content already covered in prior windows for this recurring event "
            f"(do not repeat): {prior_coverage_summary}\n\n"
            if prior_coverage_summary else
            "No prior windows exist yet for this recurring event -- this is its first timeline.\n\n"
        )
        return (
            f"Recurring event request: \"{heartbeat_prompt}\"\n\n"
            f"{prior_block}"
            f"This window's firing days (day-offsets from the window's first day, 0-indexed): {offsets_str}\n\n"
            "Produce the JSON timeline object as specified in your instructions, with exactly one entry "
            "in \"days\" per firing day-offset listed above, and nothing else."
        )

    def _call_timeline_api(self, prompt: str) -> str:
        body = {
            "model":      MODELNAME,
            "messages":   [{"role": "system", "content": TIMELINE_PROMPT}, {"role": "user", "content": prompt}],
            "max_tokens": 4096,
        }
        resp = requests.post(BASEURL, headers=HEADERS, json=body, timeout=60)
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"]

    def _generate_timeline_days(
        self, heartbeat_prompt: str, firing_offsets: list[int], prior_coverage_summary: Optional[str],
    ) -> dict:
        """Call the timeline-planning agent and return a validated
        {"days": {offset: instruction}, "coverage_summary": str} dict
        covering exactly `firing_offsets`.

        Bounded-retry pattern mirrors _generate_and_save_note's
        _HB_JSON_PARSE_MAX_ATTEMPTS loop, using
        _TIMELINE_JSON_PARSE_MAX_ATTEMPTS instead: a response is rejected
        (and retried, with an explicit correction note appended) if it
        isn't valid JSON, or if its "days" doesn't cover every offset in
        `firing_offsets`.

        Raises:
            TimelineGenerationError: the API call itself raised, or every
                attempt was rejected. Per Security Posture Q13, only up to
                200 chars of a REJECTED response is ever logged (matching
                this file's existing _generate_and_save_note precedent for
                the same failure mode) -- a successfully parsed plan's
                content is never logged.
        """
        planning_prompt = self._build_planning_prompt(heartbeat_prompt, firing_offsets, prior_coverage_summary)
        parsed: Optional[dict] = None
        for attempt in range(1, _TIMELINE_JSON_PARSE_MAX_ATTEMPTS + 1):
            attempt_prompt = planning_prompt
            if attempt > 1:
                attempt_prompt = (
                    f"{planning_prompt}\n\nNOTE: Your previous attempt ({attempt - 1} of "
                    f"{_TIMELINE_JSON_PARSE_MAX_ATTEMPTS - 1} allowed retries) was rejected because it "
                    "was not a valid JSON object matching the required shape, or was missing required "
                    "day offsets. Respond with ONLY a single valid JSON object and nothing else."
                )
            try:
                response = self._call_timeline_api(attempt_prompt)
            except Exception as e:
                logger.error("Timeline-planning API error: %s", e)
                raise TimelineGenerationError() from e

            if "{" in response and "}" in response:
                start = response.find("{")
                end = response.rfind("}") + 1
                json_str = response[start:end]
                try:
                    candidate = json.loads(json_str)
                    days_raw = candidate.get("days")
                    summary = candidate.get("coverage_summary", "") or ""
                    days: dict[int, str] = {}
                    if isinstance(days_raw, dict):
                        for k, v in days_raw.items():
                            try:
                                days[int(k)] = str(v)
                            except (TypeError, ValueError):
                                continue
                    if set(firing_offsets).issubset(days.keys()):
                        parsed = {"days": days, "coverage_summary": summary}
                        break
                    logger.error(
                        "Timeline-planning response missing required day offsets (attempt %d/%d).",
                        attempt, _TIMELINE_JSON_PARSE_MAX_ATTEMPTS,
                    )
                except (json.JSONDecodeError, ValueError) as e:
                    logger.error(
                        "Timeline-planning JSON parse error (attempt %d/%d): %s | raw: %.200s",
                        attempt, _TIMELINE_JSON_PARSE_MAX_ATTEMPTS, e, json_str,
                    )
            else:
                logger.error(
                    "Malformed timeline-planning response (attempt %d/%d) -- no JSON object found | raw: %.200s",
                    attempt, _TIMELINE_JSON_PARSE_MAX_ATTEMPTS, response,
                )

        if parsed is None:
            logger.error(
                "Timeline generation giving up after %d attempts -- all rejected.",
                _TIMELINE_JSON_PARSE_MAX_ATTEMPTS,
            )
            raise TimelineGenerationError()
        return parsed

    def ensure_current_timeline(
        self, heartbeat_id: str, timestamps: list, prompt: str, timeline_instruction_raw: Optional[str],
    ) -> dict:
        """Return this heartbeat's current, up-to-date decoded timeline,
        regenerating it first if none exists yet or its window has
        elapsed.

        MUST only be called by a caller that has already won this fire's
        exclusive claim -- the unforced path's atomic `last_fired` UPDATE,
        or the forced path's advisory lock (see commit_hb_response /
        _commit_hb_response_forced below). A regeneration here is a single
        read-then-UPDATE of this one column on the already-claimed row, so
        two racing fires for the same heartbeat can never both regenerate:
        only the fire that won the claim ever gets this far.

        Regeneration is informed by the SAME row's own prior
        timeline_instruction value (its `coverage_summary` plus the
        just-completed window's `days`... in practice just the summary, per
        the storage-location amendment's accepted trade-off of not
        retaining full prior-window detail) so it avoids duplicating
        content already covered across windows, not just within one.

        Raises:
            TimelineGenerationError: if regeneration is needed but fails
                after retries. The existing (possibly window-elapsed)
                `timeline_instruction` value is left completely untouched --
                callers must fail the fire, not fall back to a placeholder.
        """
        today = self._local_date()
        decoded = self._decode_timeline(timeline_instruction_raw)
        needs_regen = decoded is None or (today - decoded["window_start"]).days >= TIMELINE_WINDOW_DAYS
        if not needs_regen:
            return decoded

        window_start = today
        firing_offsets = self._firing_offsets(timestamps, window_start)
        prior_summary = decoded["coverage_summary"] if decoded else None
        planned = self._generate_timeline_days(prompt, firing_offsets, prior_summary)
        days = {offset: planned["days"].get(offset, "") for offset in firing_offsets}
        coverage_summary = planned.get("coverage_summary", "")
        new_raw = self._encode_timeline(window_start, days, coverage_summary)

        self.cur.execute(
            "UPDATE agent_heartbeats SET timeline_instruction = %s WHERE _id = %s AND user_id = %s",
            (new_raw, heartbeat_id, self.user_id),
        )
        self.conn.commit()
        return {"window_start": window_start, "days": days, "coverage_summary": coverage_summary}

    def _todays_instruction(self, timeline: dict) -> Optional[str]:
        """This heartbeat's planned content instruction for today, per its
        current (already-ensured-current) decoded timeline, or None if
        today doesn't fall on a firing offset within that timeline (e.g. a
        forced/manual fire on an otherwise non-firing day)."""
        offset = (self._local_date() - timeline["window_start"]).days
        return timeline["days"].get(offset)

    def commit_hb_response(self, agent_id: str, heartbeat_id: str, heartbeat_content: str, force: bool = False):
        # Ownership guard: heartbeat_id/agent_id come straight off the URL, so
        # confirm both belong to self.user_id before claiming the fire or
        # spending an LLM call on someone else's heartbeat.
        owned = self.lookup(self.hb_table, {"_id": heartbeat_id, "agent_id": agent_id, "user_id": self.user_id})
        if not owned:
            return {"error": "heartbeat not found"}
        # The heartbeat row's own group_id/notes_public -- source of truth
        # for the note this fire will generate (see note_via_hb's
        # docstring). Read once here so both the forced and unforced paths
        # below thread the same values through rather than either one
        # trusting the LLM's response.
        owned_data          = list(owned.values())[0]
        heartbeat_group_id  = owned_data.get("group_id") or None
        heartbeat_notes_public = bool(owned_data.get("notes_public") or False)
        # Threaded into ensure_current_timeline by both the forced and
        # unforced paths below -- read once here, same reasoning as
        # group_id/notes_public just above.
        heartbeat_timestamps = owned_data.get("timestamps") or []
        heartbeat_prompt     = owned_data.get("prompt", "") or ""
        timeline_instruction_raw = owned_data.get("timeline_instruction")

        if force:
            return self._commit_hb_response_forced(
                agent_id, heartbeat_id, heartbeat_content, heartbeat_group_id,
                heartbeat_notes_public=heartbeat_notes_public,
                heartbeat_timestamps=heartbeat_timestamps, heartbeat_prompt=heartbeat_prompt,
                timeline_instruction_raw=timeline_instruction_raw,
            )

        # Idempotency guard. Heartbeats can now fire from either the
        # server-side poller (scheduler.py::_fire_due_heartbeats) or a
        # still-running/older client's own call to this route, so more than
        # one caller for the same heartbeat on the same day is an expected
        # case to guard against, not just a stubborn single client
        # foregrounding repeatedly.
        #
        # A rolling time window (previously 2 minutes) cannot enforce "at
        # most once per day": once more time than the window has elapsed
        # since the first fire, a same-day reopen claims again and produces
        # a second note. The durable invariant is a calendar-day boundary,
        # not a rolling duration, so claim atomically based on whether
        # last_fired already falls on today's date.
        #
        # That calendar-day boundary is computed in the owning user's own
        # local timezone (users.timezone — the same IANA field the nightly
        # backup job already reads via BackupManager.users_due_now), not a
        # fixed UTC date: heartbeats are meant to fire against each user's
        # own clock (per the timezone_handling revision), so "today" for the
        # purpose of this claim must mean the same "today" the poller used
        # to decide the heartbeat was due. Falls back to 'UTC' via COALESCE
        # if a user row somehow has no timezone set, matching every other
        # per-user-timezone job's default. Postgres row locking still
        # guarantees exactly one concurrent caller wins the claim; any other
        # caller (same instant or same local day) gets no row and skips.
        try:
            self.cur.execute(
                "UPDATE agent_heartbeats SET last_fired = NOW() "
                "FROM users "
                "WHERE agent_heartbeats._id = %s "
                "AND users._id = %s "
                "AND (agent_heartbeats.last_fired IS NULL "
                "OR (agent_heartbeats.last_fired AT TIME ZONE COALESCE(users.timezone, 'UTC'))::date "
                "< (NOW() AT TIME ZONE COALESCE(users.timezone, 'UTC'))::date) "
                "RETURNING agent_heartbeats._id",
                (heartbeat_id, self.user_id),
            )
            claimed = self.cur.fetchone()
            self.conn.commit()
        except Exception as e:
            logger.error("Heartbeat claim failed for %s: %s", heartbeat_id, e)
            self.conn.rollback()
            return {"error": "claim failed"}
        if not claimed:
            logger.info("Heartbeat %s already fired today — skipping duplicate.", heartbeat_id)
            return {"skipped": "already fired today"}

        def _unset_claim() -> None:
            # Mirror connect_agent's handling of the same call: the claim
            # above already committed, so an unhandled LLM failure would
            # permanently burn today's fire slot with no note produced and
            # no way to retry (commit_hb_response's own idempotency guard
            # would report "already fired today" on any later attempt).
            # Unset the claim so a retry can go through.
            try:
                self.cur.execute(
                    "UPDATE agent_heartbeats SET last_fired = NULL WHERE _id = %s",
                    (heartbeat_id,),
                )
                self.conn.commit()
            except Exception as rollback_err:
                logger.error("Failed to unset heartbeat claim for %s: %s", heartbeat_id, rollback_err)
                self.conn.rollback()

        # ensure_current_timeline runs only now that the claim above has
        # been won -- see its own docstring on why this composes safely
        # with two racing fires for the same heartbeat.
        try:
            timeline = self.ensure_current_timeline(
                heartbeat_id, heartbeat_timestamps, heartbeat_prompt, timeline_instruction_raw,
            )
        except TimelineGenerationError as e:
            logger.error("Timeline generation failed for heartbeat %s: %s", heartbeat_id, e)
            _unset_claim()
            return {"error": e.message}

        return self._generate_and_save_note(
            agent_id, heartbeat_id, heartbeat_content, on_llm_error=_unset_claim,
            heartbeat_group_id=heartbeat_group_id, heartbeat_notes_public=heartbeat_notes_public,
            day_instruction=self._todays_instruction(timeline),
        )

    def _commit_hb_response_forced(
        self, agent_id: str, heartbeat_id: str, heartbeat_content: str,
        heartbeat_group_id: Optional[str] = None, heartbeat_notes_public: bool = False,
        heartbeat_timestamps: Optional[list] = None, heartbeat_prompt: str = "",
        timeline_instruction_raw: Optional[str] = None,
    ):
        """Manual/forced heartbeat fire: deliberately bypasses the
        once-per-day `last_fired` claim/gate above so a manual trigger
        always proceeds (modulo the weekly notes cap already checked by the
        route before this is ever reached), but this path must never read,
        write, or reset `last_fired` itself -- that column, and the
        day-boundary invariant it enforces, belong solely to the unforced
        path above. scheduler.py's `_fire_due_heartbeats` due-scan
        pre-filter and its own claim both key off `last_fired` and are
        completely unaffected by any number of forced fires happening the
        same day (see architecture.json's forced_path_persistence decision
        -- option (a): no new persisted state for the forced path itself).

        Two forced fires for the same heartbeat racing concurrently (a
        double-tap that slips past the client's in-flight guard, or two
        devices tapping near-simultaneously) must not both succeed and
        produce two notes for the same instant -- guarded here by a
        session-scoped Postgres advisory lock keyed on the heartbeat id,
        entirely independent of `last_fired`. This is a try-acquire, fail
        closed the way this project's security posture requires for any
        concurrency-relevant check that can't be confidently resolved: if
        another forced fire for this exact heartbeat is already in flight,
        this call skips rather than racing it through.
        """
        try:
            self.cur.execute("SELECT pg_try_advisory_lock(hashtext(%s)::bigint)", (heartbeat_id,))
            acquired = self.cur.fetchone()[0]
            self.conn.commit()
        except Exception as e:
            logger.error("Forced-fire advisory lock attempt failed for %s: %s", heartbeat_id, e)
            self.conn.rollback()
            return {"error": "claim failed"}
        if not acquired:
            logger.info(
                "Forced heartbeat fire for %s skipped — another forced fire for it is already in flight.",
                heartbeat_id,
            )
            return {"skipped": "a forced fire for this event is already in progress"}

        # Distinguishable from the automatic/unforced fire's log lines above
        # (Preference Q11 — auditability): this is a deliberate bypass of the
        # daily gate and should leave its own visible record of when/how
        # often that happened, separate from ordinary scheduled-fire logging.
        logger.info(
            "Forced/manual heartbeat fire for %s (user=%s) — bypassing the daily claim.",
            heartbeat_id, self.user_id,
        )
        try:
            # ensure_current_timeline runs only now that the advisory lock
            # above has been acquired -- see its own docstring on why this
            # composes safely with two racing forced fires for the same
            # heartbeat.
            try:
                timeline = self.ensure_current_timeline(
                    heartbeat_id, heartbeat_timestamps or [], heartbeat_prompt, timeline_instruction_raw,
                )
            except TimelineGenerationError as e:
                logger.error("Timeline generation failed for heartbeat %s: %s", heartbeat_id, e)
                return {"error": e.message}

            return self._generate_and_save_note(
                agent_id, heartbeat_id, heartbeat_content, heartbeat_group_id=heartbeat_group_id,
                heartbeat_notes_public=heartbeat_notes_public,
                day_instruction=self._todays_instruction(timeline),
            )
        finally:
            try:
                self.cur.execute("SELECT pg_advisory_unlock(hashtext(%s)::bigint)", (heartbeat_id,))
                self.conn.commit()
            except Exception as e:
                logger.error("Failed to release forced-fire advisory lock for %s: %s", heartbeat_id, e)
                self.conn.rollback()

    def _generate_and_save_note(
        self, agent_id: str, heartbeat_id: str, heartbeat_content: str, on_llm_error=None,
        heartbeat_group_id: Optional[str] = None, heartbeat_notes_public: bool = False,
        day_instruction: Optional[str] = None,
    ):
        """Shared by both the unforced (claim-gated) and forced (advisory-
        lock-gated) paths above: build the note prompt, call the LLM, and
        persist the resulting note. `on_llm_error`, if given, is called
        before returning the connection-trouble error so a caller that
        already claimed some piece of state (e.g. the unforced path's
        `last_fired` UPDATE) can unwind it and allow a retry.

        `heartbeat_group_id`: the firing heartbeat's own group_id (already
        validated as a group `self.user_id` belonged to at the time it was
        set on the heartbeat via add_heartbeat/update_heartbeat). Re-checked
        for *current* membership here, defense-in-depth against the case
        where the user has since left that group between setting it on the
        heartbeat and this fire -- if membership no longer holds, the note
        is generated ungrouped rather than either failing the fire or
        writing into a group the user can no longer post to.

        `heartbeat_notes_public`: the heartbeat row's own stored group-edit
        permission for the note this fire generates (agent_heartbeats.
        notes_public). Forced to False whenever the note ends up ungrouped
        (`effective_group_id` is None below) -- the flag is meaningless
        without a group to grant edit access to, so it must not silently
        carry over if group membership lapsed between configuration and
        this fire.

        `day_instruction`: today's specific content instruction from this
        heartbeat's current timeline_instruction (see
        ensure_current_timeline/_todays_instruction), computed by the
        caller AFTER it's already ensured the timeline is current for this
        fire. Replaces the old get_context()-derived CHAPTERS/VERSES/THEME
        dedup block entirely -- the timeline's upfront per-day plan is now
        what prevents repeated content, not a live aggregate of past notes.
        None only for a fire that doesn't land on a firing offset within
        the current timeline (e.g. a forced/manual fire on an otherwise
        non-scheduled day) -- falls back to responding directly to the
        heartbeat's own standing request with no day-specific steer.
        """
        effective_group_id = None
        if heartbeat_group_id:
            gm = GroupsManager(self.user_id, heartbeat_group_id)
            try:
                if gm.is_member():
                    effective_group_id = heartbeat_group_id
                else:
                    logger.warning(
                        "Heartbeat %s fired with group_id %s but user %s is no longer a "
                        "member -- generating an ungrouped note instead.",
                        heartbeat_id, heartbeat_group_id, self.user_id,
                    )
            finally:
                gm.close()
        effective_notes_public = bool(heartbeat_notes_public) if effective_group_id else False
        result     = self.lookup(self.agent_table, {"_id": agent_id})
        agent_role = list(result.values())[0].get("role", "") if result else ""
        if day_instruction:
            context_str = f"TODAY'S PLANNED CONTENT (from this event's current timeline instruction): {day_instruction}"
            # Materially stronger than a soft "try to follow this" wording --
            # an explicit, unambiguous no-duplication rule, same posture the
            # old CHAPTERS/VERSES/THEME dedup block used before this task
            # replaced it with the upfront timeline plan above.
            dedup_instruction = (
                "STRICT RULE: Base your note specifically on today's planned content above -- do not "
                "substitute different content, and do not cover material assigned to a different day of "
                "this event's timeline.\n\n"
            )
        else:
            context_str = "No day-specific timeline instruction found for today — respond directly to the request below."
            dedup_instruction = ""
        note_prompt = (
            f"{heartbeat_content}\n\n"
            f"{context_str}\n\n"
            f"{dedup_instruction}"
            "Respond with a create_note JSON block as specified in your instructions, "
            "including a \"theme\" field naming this note's central theme. "
            "Output only the JSON block and nothing else."
        )
        # Retry loop covers only the JSON-parse-failure branches below (no
        # "{"/"}" pair found, or a found pair that doesn't json.loads) --
        # this is a transient LLM output-formatting glitch that a same-input
        # retry can plausibly fix. It deliberately does NOT wrap the
        # connection-error except below: that's a different failure mode
        # (the API call itself raising) with its own on_llm_error unwind,
        # out of scope for this retry per the intake spec, and returns
        # immediately exactly as before on the first such error.
        response_dict = None
        parse_failed  = True
        for attempt in range(1, _HB_JSON_PARSE_MAX_ATTEMPTS + 1):
            attempt_prompt = note_prompt
            if attempt > 1:
                # Only appended on retries -- the first attempt's prompt is
                # byte-for-byte the original note_prompt. Telling the model
                # its last attempt was rejected for invalid JSON gives it a
                # concrete, correctable reason (stray prose, unescaped
                # quotes, truncated output) rather than just re-asking the
                # same question and hoping for a different formatting roll.
                attempt_prompt = (
                    f"{note_prompt}\n\n"
                    f"NOTE: Your previous attempt ({attempt - 1} of "
                    f"{_HB_JSON_PARSE_MAX_ATTEMPTS - 1} allowed retries) was rejected because it "
                    "was not valid JSON. Respond with ONLY a single valid JSON create_note block "
                    "and nothing else."
                )
            try:
                response = self._call_api(agent_role, [{"role": "user", "content": attempt_prompt}])
            except Exception as e:
                logger.error("OpenRouter API error in commit_hb_response for heartbeat %s: %s", heartbeat_id, e)
                if on_llm_error:
                    on_llm_error()
                return {"error": "I'm having trouble connecting right now. Please try again in a moment."}

            if "{" in response and "}" in response:
                start = response.find("{")
                end   = response.rfind("}") + 1
                json_str = response[start:end]
                try:
                    response_dict = json.loads(json_str)
                    parse_failed = False
                    break
                except (json.JSONDecodeError, ValueError) as e:
                    logger.error(
                        "JSON parse error in commit_hb_response (attempt %d/%d) for heartbeat %s: %s | raw: %.200s",
                        attempt, _HB_JSON_PARSE_MAX_ATTEMPTS, heartbeat_id, e, json_str,
                    )
            else:
                logger.error(
                    "Malformed LLM response in commit_hb_response (attempt %d/%d) for heartbeat %s: "
                    "no JSON object found | raw: %.200s",
                    attempt, _HB_JSON_PARSE_MAX_ATTEMPTS, heartbeat_id, response,
                )

        if parse_failed:
            logger.error(
                "commit_hb_response giving up for heartbeat %s after %d attempts -- all returned "
                "unparseable JSON.",
                heartbeat_id, _HB_JSON_PARSE_MAX_ATTEMPTS,
            )
            return {"error": "invalid response"}

        if response_dict.get("__action", "") == "create_note":
            # No separate context-link write needed anymore (the old
            # agentic_context.save_context call) -- no-duplication is
            # already handled upfront by this heartbeat's timeline
            # instruction, not by a per-note durable link consumed on a
            # later fire.
            self.note_via_hb(
                response_dict, group_id=effective_group_id, notes_public=effective_notes_public,
            )
            return {"success": "saved note"}
        else:
            return {"error": "cannot find action"}
    # ── Messages CRUD ─────────────────────────────────────────────────────────

    def save_agent_message(self, msg: AgentMessages) -> None:
        """Raises:
            SaveFailedError: If the write fails. ``connect_agent``'s WS loop
                (the only live caller) already wraps its whole message-
                handling loop in a broad ``except Exception`` that logs and
                closes the socket -- this propagates into that existing
                handler rather than needing its own.
        """
        if not self.insertion(self.msg_table, {
            "title":     msg.title,
            "agent_id":  msg.agent_id,
            "user_id":   msg.user_id,
            "timestamp": msg.timestamp,
            "content":   msg.content,
        }):
            raise SaveFailedError()

    def get_messages(self, agent_id: str) -> dict:
        return self.lookup(self.msg_table, {"agent_id": agent_id, "user_id": self.user_id})

    def delete_message(self, message_id: str) -> None:
        # Same idempotent/ownership-via-WHERE reasoning as delete_agent above.
        self.delete(self.msg_table, {"_id": message_id, "user_id": self.user_id})

    # ── AI Chat ───────────────────────────────────────────────────────────────

    def _call_api(self, agent_role: str, messages: list[dict]) -> str:
        system_content = PROMPT
        if agent_role:
            system_content += f"\n\nADDITIONAL AGENT INSTRUCTIONS:\n{agent_role}"
        body = {
            "model":      MODELNAME,
            "messages":   [{"role": "system", "content": system_content}] + messages,
            "max_tokens": 2048,
        }
        resp = requests.post(BASEURL, headers=HEADERS, json=body, timeout=60)
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"]

    def chat(self, agent_id: str, user_content: str) -> str:
        result     = self.lookup(self.agent_table, {"_id": agent_id})
        agent_role = list(result.values())[0].get("role", "") if result else ""
        now = datetime.now()
        self.save_agent_message(AgentMessages(
            chat_id="", agent_id=agent_id, user_id=self.user_id,
            content=user_content, title="user", timestamp=now
        ))
        response_text = self._call_api(agent_role, [{"role": "user", "content": user_content}])
        if "{" in response_text:
            end = response_text.find("{")
            response_text = response_text[:end]
        self.save_agent_message(AgentMessages(
            chat_id="", agent_id=agent_id, user_id=self.user_id,
            content=response_text, title="assistant", timestamp=now
        ))
        return response_text

    async def connect_agent(self, agent_id: str, ws: WebSocket) -> None:
        await ws.accept()
        if not self.owns_agent(agent_id):
            # agent_id is caller-supplied in the URL; without this, any
            # authenticated user could chat through (and read the private
            # persona/role prompt of) an agent they don't own.
            await ws.close(code=4403)
            return
        loop = asyncio.get_running_loop()
        agent_data = self.get_agent(agent_id) or {}
        agent_role = list(agent_data.values())[0].get("role", "") if agent_data else ""
        # Sliding window of recent message timestamps, scoped to this one
        # connection (one per user_id/agent_id pair -- see agent_ws_endpoint).
        message_times: deque[float] = deque()
        try:
            while True:
                payload      = await ws.receive_json()
                user_content = payload.get("content", "").strip()
                if not user_content:
                    continue

                now_monotonic = time.monotonic()
                while message_times and now_monotonic - message_times[0] > _CHAT_RATE_LIMIT_WINDOW_SECONDS:
                    message_times.popleft()
                if len(message_times) >= _CHAT_RATE_LIMIT_MESSAGES:
                    await ws.send_json({
                        "role":      "error",
                        "content":   "You're sending messages too quickly. Please wait a moment and try again.",
                        "agent_id":  agent_id,
                        "timestamp": str(datetime.now()),
                    })
                    continue
                message_times.append(now_monotonic)

                user_ts = datetime.now()
                # Persist user turn immediately so it survives even if the API call fails
                self.save_agent_message(AgentMessages(
                    chat_id="", agent_id=agent_id, user_id=self.user_id,
                    content=user_content, title="user", timestamp=user_ts
                ))

                try:
                    response_text = await loop.run_in_executor(
                        None,
                        functools.partial(
                            self._call_api,
                            agent_role,
                            [{"role": "user", "content": user_content}]
                        )
                    )
                except Exception as api_err:
                    logger.error("OpenRouter API error for agent %s: %s", agent_id, api_err)
                    await ws.send_json({
                        "role":      "error",
                        "content":   "I'm having trouble connecting right now. Please try again in a moment.",
                        "agent_id":  agent_id,
                        "timestamp": str(user_ts),
                    })
                    continue

                assistant_ts = datetime.now()
                self.save_agent_message(AgentMessages(
                    chat_id="", agent_id=agent_id, user_id=self.user_id,
                    content=response_text, title="assistant", timestamp=assistant_ts
                ))

                await ws.send_json({
                    "role":      "assistant",
                    "content":   response_text,
                    "agent_id":  agent_id,
                    "timestamp": str(assistant_ts),
                })

        except WebSocketDisconnect:
            logger.info("Agent WS disconnected: agent=%s user=%s", agent_id, self.user_id)
        except Exception as e:
            logger.error("Agent WS error: agent=%s user=%s error=%s", agent_id, self.user_id, e)
            try:
                await ws.close()
            except Exception:
                pass
