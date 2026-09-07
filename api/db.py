import psycopg2 as sql
import os
import re
import logging
from typing import Any
from dotenv import load_dotenv

load_dotenv()

# No implicit default: an unset DB_PASSWORD previously passed straight
# through to psycopg2.connect(...) as None, which fails with an opaque
# connection error deep inside the first DBManager() call instead of a clear
# error at startup. Fail fast here instead, mirroring the
# APPLE_ALLOW_SANDBOX precedent (backend/subscription/apple_service.py).
_DB_PASSWORD = os.getenv("DB_PASSWORD")
if not _DB_PASSWORD:
    raise RuntimeError(
        "DB_PASSWORD is not set. The app cannot connect to Postgres without "
        "it -- set DB_PASSWORD explicitly rather than relying on an "
        "implicit empty/None password."
    )

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

# ── Sensitive-value redaction for caught DB write errors ────────────────
#
# db-write-failure-signaling workflow, step 1 (Security Posture Q13:
# proactively redact potentially-sensitive log content by default, in
# every environment, not limited to a fixed known-fields list). A caught
# sql.Error's own message can echo back the actual value that triggered
# it -- most commonly postgres's constraint-violation DETAIL line, e.g.
# `duplicate key value violates unique constraint "users_email_key"
# DETAIL:  Key (email)=(someone@example.com) already exists.` -- and that
# can happen for *any* column, not just email, so this deliberately
# doesn't key off a fixed list of "sensitive" column names. Two
# independent patterns: the `Key (col)=(value)` shape postgres uses for
# unique/FK-violation DETAIL lines (redacts the value regardless of which
# column it names), the `Failing row contains (...)` shape postgres uses
# for NOT NULL and check-constraint violations (this one dumps *every*
# column of the offending row -- not just the one that failed -- so on a
# table like `users` a caught NOT NULL violation could otherwise echo the
# raw email, phone, or password hash of the whole row into the log line),
# and a plain email-shaped backstop for any other error text that happens
# to echo one back outside either of those two DETAIL shapes.
_DB_ERROR_KEY_VALUE_RE = re.compile(r"(Key \([^)]*\)=\()[^)]*(\))")
_DB_ERROR_FAILING_ROW_RE = re.compile(r"(Failing row contains \()[^)]*(\))")
_DB_ERROR_EMAIL_RE = re.compile(r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b")


def _redact_db_error(e: sql.Error) -> str:
    """Return a log-safe rendering of a caught DB error.

    Strips the offending value out of postgres's "Key (col)=(value) ..."
    detail line, blanks out the entire row dumped by a "Failing row
    contains (...)" detail line (NOT NULL / check-constraint violations),
    and scrubs any email-shaped text, so a constraint violation never
    echoes a raw sensitive value into the log line this module emits --
    that line ships to CloudWatch via the external agent `watchdog.py`
    polls (see `DB_WRITE_FAILURE` marker below), so this is the point
    before it ever leaves the process, not a downstream cleanup.
    """
    text = str(e)
    text = _DB_ERROR_KEY_VALUE_RE.sub(r"\1[REDACTED]\2", text)
    text = _DB_ERROR_FAILING_ROW_RE.sub(r"\1[REDACTED_ROW]\2", text)
    text = _DB_ERROR_EMAIL_RE.sub("[REDACTED_EMAIL]", text)
    return text


def create_tables(cur):
    logger.info("Creating tables...")
    # ── Level 0: no foreign keys ───────────────────────────────────────────────
    cur.execute(
        "CREATE TABLE IF NOT EXISTS users"
        "(_id UUID PRIMARY KEY NOT NULL,"
        "username VARCHAR(64) UNIQUE NOT NULL,"
        "email VARCHAR(255) UNIQUE NOT NULL,"
        "hash_pass VARCHAR(255) NOT NULL,"
        # Stable provider identifiers for social sign-in (nullable — password
        # accounts have neither; each is backfilled on that provider's sign-in).
        "apple_sub TEXT,"
        "google_sub TEXT,"
        # User-set IANA timezone name; drives the local-3am nightly backup job.
        "timezone TEXT NOT NULL DEFAULT 'UTC',"
        # Email-code two-factor auth toggle (web only, for now).
        "mfa_enabled BOOLEAN NOT NULL DEFAULT FALSE,"
        # Guideline 1.2 EULA gate: when the account accepted Terms, and which
        # version — a version bump forces re-consent (see CURRENT_TERMS_VERSION
        # in schemas/users.py) rather than silently grandfathering old accounts.
        "terms_accepted_at TIMESTAMPTZ,"
        "terms_version TEXT,"
        # Set only by the moderation eject action (backend/moderation/admin_actions.py)
        # — deliberately excluded from save_users_data's upsert so a routine
        # profile edit can never accidentally un-suspend someone.
        "suspended_at TIMESTAMPTZ,"
        # True when an Apple-created account is missing the username/email Apple
        # only ever supplies once (first authorization) — prompts the client to
        # ask the user to set them, since Apple can never resupply them later.
        "needs_profile_completion BOOLEAN NOT NULL DEFAULT FALSE,"
        # Staff/admin flag gating admin-only surfaces (e.g. the CloudWatch
        # error-detection monitoring endpoints, routes/monitoring.py) via
        # backend/auth/dependencies.py::require_admin. Distinct from the
        # unrelated `role` column on the `agents` table (AI persona config).
        "is_admin BOOLEAN NOT NULL DEFAULT FALSE,"
        # S3 object key for the user's profile photo (task 20260905-profile-
        # photo) -- nullable (most rows have none, falling back to an
        # initials avatar client-side). Mirrors attachments.py's convention
        # exactly: only the object key is ever persisted, never a full/
        # permanent URL -- rendering resolves it to a fresh, short-lived
        # presigned GET at read time (see backend/interactions/attachments.py
        # ::generate_download_url). Deliberately excluded from
        # helpers.py::_upsert_user_row's INSERT/UPDATE column list, same as
        # suspended_at -- only the dedicated upload/confirm/remove endpoints
        # in routes/profile_photo.py may ever set or clear it, never a
        # routine PUT /user/{id} profile edit.
        "profile_photo_key TEXT)"
    )
    # Migrations for databases created before the social-sign-in columns existed.
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS apple_sub TEXT")
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS google_sub TEXT")
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS timezone TEXT NOT NULL DEFAULT 'UTC'")
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS mfa_enabled BOOLEAN NOT NULL DEFAULT FALSE")
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS terms_accepted_at TIMESTAMPTZ")
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS terms_version TEXT")
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS suspended_at TIMESTAMPTZ")
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS needs_profile_completion BOOLEAN NOT NULL DEFAULT FALSE")
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS is_admin BOOLEAN NOT NULL DEFAULT FALSE")
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS profile_photo_key TEXT")

    # One-time admin seed, re-applied (idempotently) every time create_tables()
    # runs -- i.e. on every non-destructive schema-apply deploy step (see
    # reference_deploy.md). Resolves the admin account by a live email lookup
    # against *this* users table rather than a hardcoded _id: the legacy
    # data/users.json seed file's UUID for this account is not authoritative
    # for the live table and must never be trusted here.
    # Deploy-specific value -- overridable via env so a second environment
    # (staging, a different admin) doesn't require an in-code edit. The
    # fallback preserves today's production behavior for any deploy that
    # hasn't set ADMIN_SEED_EMAIL yet.
    _ADMIN_SEED_EMAIL = os.getenv("ADMIN_SEED_EMAIL", "jaceysimps@gmail.com")
    cur.execute(
        "UPDATE users SET is_admin = TRUE WHERE email = %s AND is_admin = FALSE",
        (_ADMIN_SEED_EMAIL,),
    )
    if cur.rowcount == 0:
        cur.execute("SELECT 1 FROM users WHERE email = %s", (_ADMIN_SEED_EMAIL,))
        if cur.fetchone() is None:
            # Real finding, not a silent no-op: surface loudly so a deploy
            # doesn't quietly leave the app with zero admin accounts.
            logger.warning(
                "Admin seed: no user found with email %s -- is_admin was not "
                "set for any account. Verify this is still the correct admin "
                "account before assuming the admin page is reachable.",
                _ADMIN_SEED_EMAIL,
            )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS groups"
        "(_id UUID PRIMARY KEY NOT NULL,"
        "title VARCHAR(255) NOT NULL,"
        "users TEXT[])"
    )

    # ── Level 1: depend on users / groups ──────────────────────────────────────
    cur.execute(
        "CREATE TABLE IF NOT EXISTS user_friends"
        "(user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "friend_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "PRIMARY KEY (user_id, friend_id))"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS friend_requests"
        "(to_user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "from_user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "PRIMARY KEY (to_user_id, from_user_id))"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS blocked_users"
        "(blocker_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "blocked_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "created_at TIMESTAMPTZ DEFAULT NOW(),"
        "PRIMARY KEY (blocker_id, blocked_id))"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_blocked_users_blocked ON blocked_users(blocked_id)"
    )

    # Task 20260906-friend-nudges: per (sender, recipient) rate-limit marker
    # for the "nudge" push action -- same single-row-per-pair dedup-marker
    # shape as user_activity's friend_notified_at/midday_reminder_sent_date/
    # guilt_reminder_sent_at (only the most recent send matters for the
    # window check), rather than an append-only log. Sender+recipient
    # scoped, so it's its own table rather than a column on user_friends
    # (undirected-ish, PK'd both ways) or user_activity (single-user
    # scoped). Claimed atomically BEFORE the push is sent, and released
    # (deleted) if the send then fails -- see
    # FriendsManager.claim_nudge_slot/release_nudge_claim.
    cur.execute(
        "CREATE TABLE IF NOT EXISTS friend_nudges"
        "(sender_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "recipient_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "last_nudged_at TIMESTAMPTZ NOT NULL,"
        "PRIMARY KEY (sender_id, recipient_id))"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS highlights"
        "(user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "key VARCHAR(128) NOT NULL,"
        "color VARCHAR(16) NOT NULL,"
        "PRIMARY KEY (user_id, key))"
    )
    # CREATE TABLE IF NOT EXISTS above doesn't retroactively add columns to
    # an already-existing table (same precedent as user_activity.
    # last_activity_type below), so this needs its own idempotent ALTER. Task
    # 20260904-friend-activity-push-triggers: ActivityManager.
    # most_recent_highlight and FriendsManager.get_friend_activity's new
    # highlight_preview both need "this friend's most recent highlight",
    # which wasn't derivable before -- highlight_verse (routes/notes.py) now
    # sets/refreshes this on every write (including a re-highlight of an
    # already-highlighted verse, via its ON CONFLICT clause), so it reflects
    # last-written, not first-written.
    cur.execute("ALTER TABLE highlights ADD COLUMN IF NOT EXISTS timestamp TIMESTAMPTZ DEFAULT NOW()")

    cur.execute(
        "CREATE TABLE IF NOT EXISTS bookmarks"
        "(user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "key VARCHAR(128) NOT NULL,"
        "label VARCHAR(255) DEFAULT '',"
        "PRIMARY KEY (user_id, key))"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS notes"
        "(_id UUID PRIMARY KEY NOT NULL,"
        "user_id UUID REFERENCES users(_id),"
        "title VARCHAR(255) DEFAULT '',"
        "text TEXT DEFAULT '',"
        "public BOOLEAN DEFAULT FALSE,"
        "group_id UUID REFERENCES groups(_id) ON DELETE SET NULL,"
        "is_reply BOOLEAN DEFAULT FALSE,"
        "parent_note_id UUID REFERENCES notes(_id) ON DELETE CASCADE,"
        "timestamp TIMESTAMPTZ DEFAULT NOW())"
    )
    cur.execute("ALTER TABLE notes ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT NOW()")
    # AgentManager.note_via_hb persists the LLM's self-reported "theme"
    # field here per note (see agent_prompt.txt's create_note schema), kept
    # as recorded metadata about the note. As of task
    # 20260906-heartbeat-timeline-instructions, heartbeat no-duplication is
    # driven upfront by `agent_heartbeats.timeline_instruction`'s per-day
    # plan rather than a live-recomputed aggregate of past notes' themes --
    # this column is no longer read back by anything (the old
    # `agentic_context`-joined get_context() aggregate it fed was removed
    # along with that table). Manually-created notes (routes/notes.py)
    # simply leave this at its default.
    cur.execute("ALTER TABLE notes ADD COLUMN IF NOT EXISTS theme TEXT DEFAULT ''")
    # Speeds up the free-tier weekly note count (LimitsManager).
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_notes_user_timestamp "
        "ON notes(user_id, timestamp)"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS messages"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "from_user UUID REFERENCES users(_id),"
        "group_id UUID REFERENCES groups(_id) ON DELETE SET NULL,"
        "text TEXT NOT NULL,"
        "timestamp TIMESTAMPTZ DEFAULT NOW())"
    )
    # Attachment support (task 20260904-messaging-attachments): nullable,
    # coexisting with `text` rather than a new table -- a message may now
    # carry an image/video/file/gif attachment alongside or instead of text.
    # `attachment_key` stores only the S3 *object key* (never a URL) for
    # image/video/file kinds; rendering issues a fresh, short-lived presigned
    # GET at read time (backend/interactions/attachments.py) instead of ever
    # persisting a URL, so a leaked/stored value alone can't grant durable
    # access. GIF attachments never populate attachment_key at all -- only
    # the provider's id/url (in attachment_meta) is stored; GIF bytes never
    # touch our own storage, per the existing no-hosting design decision.
    # Recognized attachment_kind values are enforced at the app layer
    # (ConnectionManager.send_msg fails closed on anything not in
    # schemas.message.ATTACHMENT_KINDS) rather than a DB CHECK constraint,
    # since `ALTER TABLE ... ADD CONSTRAINT` has no idempotent
    # `IF NOT EXISTS` form and this function re-runs on every boot.
    cur.execute("ALTER TABLE messages ADD COLUMN IF NOT EXISTS attachment_kind TEXT")
    cur.execute("ALTER TABLE messages ADD COLUMN IF NOT EXISTS attachment_key TEXT")
    cur.execute("ALTER TABLE messages ADD COLUMN IF NOT EXISTS attachment_meta JSONB DEFAULT '{}'")

    cur.execute(
        "CREATE TABLE IF NOT EXISTS devotions"
        "(_id UUID PRIMARY KEY NOT NULL,"
        "title VARCHAR(255) DEFAULT '',"
        "time_start TIMESTAMPTZ,"
        "time_end TIMESTAMPTZ,"
        "recurring BOOLEAN DEFAULT FALSE,"
        # A session's room id: a group id OR a DM room key (userA|userB), so it
        # is free-form text, not an FK to groups.
        "group_id TEXT,"
        "creator_id UUID REFERENCES users(_id),"
        "participants TEXT[],"
        "verses TEXT[],"
        "prompts TEXT[],"
        "chime_meeting_id VARCHAR(255) DEFAULT '',"
        "chime_meeting JSONB DEFAULT '{}')"
    )
    # Session-start reminder push dedup (task
    # 20260904-session-push-notifications): a session's time_start reminder
    # must fire exactly once, ever — not a per-day/rolling-window guard.
    # Per the explicit precedent in
    # .claude/pipeline/20260825-scheduled-event-duplicate-fire, a rolling
    # time window is not sufficient to prevent a duplicate fire for this
    # "fires once when a scheduled moment arrives" family of jobs; the
    # scheduler claims a session atomically via
    # `UPDATE ... WHERE reminder_sent_at IS NULL`, so Postgres row locking
    # guarantees at most one concurrent claim wins regardless of how many
    # poll cycles or concurrent pollers see the row as a candidate.
    cur.execute("ALTER TABLE devotions ADD COLUMN IF NOT EXISTS reminder_sent_at TIMESTAMPTZ")

    cur.execute(
        "CREATE TABLE IF NOT EXISTS agents"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        # TEXT, not VARCHAR(128): routes/agent.py's create_agent falls back to
        # schemas.agent._DEFAULT_ROLE (the full agent_prompt.txt system prompt,
        # ~4.9KB) whenever the caller doesn't supply a custom role — the common
        # case for a "default" agent. A VARCHAR(128) cap made every such INSERT
        # fail with "value too long for type character varying(128)".
        "role TEXT DEFAULT '',"
        "chats TEXT[],"
        # name/enabled added after the table's original creation —
        # routes/agent.py's create_agent/update_agent and iOS's FSAgent both
        # read/write these, but they were never declared here or backfilled
        # via ALTER TABLE, so every INSERT/UPDATE referencing them failed at
        # the DB level too.
        # Both of the above failed silently: DBManager.insertion/update
        # swallow sql.Error (log + rollback, no exception raised), so
        # create_agent's route still returned 201 with a generated id even
        # though the row never persisted. See the migrations below for
        # existing databases.
        "name VARCHAR(255) DEFAULT '',"
        "enabled BOOLEAN NOT NULL DEFAULT TRUE)"
    )
    # Migrations for databases created before role was TEXT and before
    # name/enabled existed on agents.
    cur.execute("ALTER TABLE agents ALTER COLUMN role TYPE TEXT")
    cur.execute("ALTER TABLE agents ADD COLUMN IF NOT EXISTS name VARCHAR(255) DEFAULT ''")
    cur.execute("ALTER TABLE agents ADD COLUMN IF NOT EXISTS enabled BOOLEAN NOT NULL DEFAULT TRUE")

    cur.execute(
        "CREATE TABLE IF NOT EXISTS subscriptions"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        # The host who owns and pays for the plan.
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "plan_type TEXT NOT NULL DEFAULT 'group',"             # 'free' | 'group'
        "provider TEXT NOT NULL DEFAULT 'stripe',"            # 'stripe' | 'apple'
        # Opaque processor references — never raw card data.
        "stripe_customer_id TEXT DEFAULT '',"
        "stripe_subscription_id TEXT DEFAULT '',"
        "apple_original_transaction_id TEXT DEFAULT '',"
        "default_payment_method_id TEXT DEFAULT '',"
        # Display-only, PCI-safe card metadata.
        "card_brand TEXT DEFAULT '',"
        "card_last4 TEXT DEFAULT '',"
        "card_exp_month TEXT DEFAULT '',"
        "card_exp_year TEXT DEFAULT '',"
        "status TEXT NOT NULL DEFAULT 'inactive',"
        "price_cents INTEGER NOT NULL DEFAULT 1000,"          # derived from member_count (max_members)
        "max_members INTEGER NOT NULL DEFAULT 1,"             # host-selected member_count, 1-8
        # trial_end = first billing date (created_at + trial); current_period_end
        # is the rolling next-billing date, monitored by the scheduler.
        "trial_end TIMESTAMPTZ,"
        "current_period_end TIMESTAMPTZ,"
        "created_at TIMESTAMPTZ DEFAULT NOW())"
    )
    # Migrations for a subscriptions table created before these plan columns
    # existed (no-op on a fresh DB where CREATE TABLE already added them).
    # NOTE: the old 'individual' plan_type was folded into 'group' (member_count=1,
    # same price) when dynamic group pricing shipped. Run once on the live DB:
    #   UPDATE subscriptions SET plan_type = 'group' WHERE plan_type = 'individual';
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(_id) ON DELETE CASCADE")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS plan_type TEXT NOT NULL DEFAULT 'group'")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS price_cents INTEGER NOT NULL DEFAULT 1000")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS max_members INTEGER NOT NULL DEFAULT 1")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS card_exp_month TEXT DEFAULT ''")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS card_exp_year TEXT DEFAULT ''")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS trial_end TIMESTAMPTZ")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS stripe_subscription_id TEXT DEFAULT ''")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS apple_original_transaction_id TEXT DEFAULT ''")
    # A user's plan membership is a pointer on the users row (single source of
    # truth): a plan's members are the users pointing at it, the host is
    # subscriptions.user_id. Added here (after subscriptions exists) to avoid a
    # circular create-time FK. ON DELETE SET NULL detaches members if the plan
    # is removed.
    cur.execute(
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS subscription_id UUID "
        "REFERENCES subscriptions(_id) ON DELETE SET NULL"
    )

    # ── Level 2: depend on Level 1 ─────────────────────────────────────────────
    cur.execute(
        "CREATE TABLE IF NOT EXISTS note_verses"
        "(note_id UUID REFERENCES notes(_id) ON DELETE CASCADE,"
        "position INTEGER NOT NULL,"
        "book VARCHAR(64),"
        "chapter INTEGER,"
        "verse INTEGER,"
        "PRIMARY KEY (note_id, position))"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS message_recipients"
        "(message_id UUID REFERENCES messages(_id) ON DELETE CASCADE,"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "PRIMARY KEY (message_id, user_id))"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS agent_heartbeats"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "agent_id UUID REFERENCES agents(_id) ON DELETE CASCADE,"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        # 31-item list indexed by day-of-month (index i == day i+1), each
        # slot an "HH:mm" string or null. Interpreted as literal wall-clock
        # time local to the OWNING USER's own `users.timezone` (IANA name),
        # not UTC -- see the timezone_handling revision
        # (.claude/pipeline/20260901-heartbeat-backend-scheduling) and its
        # scheduler.py::_fire_due_heartbeats / AgentManager.commit_hb_response
        # consumers. iOS (EventSetupSheet.swift) authors/reads this same
        # field as the device's own local wall-clock digits (task
        # 20260905-heartbeat-timezone-duplicate-bugs, step 3) so the two
        # sides agree on one semantic; a user whose account `users.timezone`
        # doesn't match their device's actual current timezone will still
        # see a mismatch, but that is a separate timezone-accuracy concern
        # (see that task's own open questions), not a storage-format one.
        "timestamps JSONB DEFAULT '[]',"
        "prompt TEXT DEFAULT '',"
        # Timestamp of the most recent fire. Used to make commit_hb_response
        # idempotent so repeated same-day calls (e.g. the iOS client
        # re-checking on every app foreground) can't create more than one
        # note for the same scheduled slot — the calendar-day boundary this
        # claims against is computed in the OWNING USER's own local timezone
        # (users.timezone), not a fixed UTC date -- see the per-user-local
        # calendar-day claim in AgentManager.commit_hb_response (this was
        # UTC-calendar-day before the timezone_handling revision; this
        # comment previously went stale and wasn't updated along with that
        # change -- see task 20260905-heartbeat-timezone-duplicate-bugs).
        "last_fired TIMESTAMPTZ,"
        # Optional group this scheduled event is tied to. Nullable -- an
        # event can remain personal/ungrouped exactly as before. When set,
        # the note a fire of this heartbeat generates inherits this value
        # (see AgentManager.commit_hb_response/note_via_hb) rather than the
        # per-fire LLM response ever supplying it.
        "group_id UUID REFERENCES groups(_id) ON DELETE SET NULL,"
        # Deny-by-default (task 20260903-notes-public-repurpose, step 3):
        # explicit, user-configured value for the `public` field of every
        # note this heartbeat generates on fire -- i.e. whether other
        # members of `group_id` may edit the AI-generated note, mirroring
        # notes.public's post-repurpose meaning (edit permission, not
        # visibility). Set from the event-editing screen at configuration
        # time (add_heartbeat/update_heartbeat), never from the per-fire
        # LLM response -- the model has no basis to decide a group-edit
        # grant any more than it has a basis to decide group_id itself
        # (see note_via_hb's docstring on that same reasoning for group_id).
        "notes_public BOOLEAN DEFAULT FALSE,"
        # Bug 2 fix (task 20260905-heartbeat-timezone-duplicate-bugs): a
        # client-generated token, one per Save *attempt* (not regenerated on
        # an internal retry of that same attempt -- see EventSetupSheet.swift
        # step 4). Paired with the UNIQUE index below on
        # (user_id, agent_id, idempotency_key), this is what actually makes
        # double-submit protection concurrency-safe (Q28): two near-
        # simultaneous INSERTs racing on the same key can't both land, since
        # Postgres itself -- not a check-then-insert race in application code
        # -- enforces the constraint. Nullable only so a pre-migration row
        # (or a call from a not-yet-updated client, which
        # AgentManager.add_heartbeat backfills with a server-generated key
        # that provides no dedup protection) isn't rejected by this ALTER.
        "idempotency_key TEXT,"
        # Task 20260906-heartbeat-timeline-instructions: replaces the old
        # `agentic_context` table + AgentManager.save_context/get_context
        # entirely. A single JSON-encoded string (not a separate table --
        # see the user's 2026-09-06 amendment to that task's spec) holding
        # this heartbeat's current up-to-31-day content plan:
        # {"window_start": "<ISO date>", "days": {"<offset>": "<instruction>",
        # ...}, "coverage_summary": "<rolling digest>"}. `days` is keyed by
        # WINDOW-OFFSET (0..30, calendar days elapsed since window_start),
        # one entry per offset this row's `timestamps` fires on -- not by
        # day-of-month, since a 31-day window crossing a short month
        # revisits day-of-month values a day-of-month key couldn't
        # represent without collision. `coverage_summary` is what carries
        # no-duplication context across window rollovers now that only the
        # current window is kept (see AgentManager.ensure_current_timeline).
        # NULL means "no current timeline" -- generate a fresh one on this
        # heartbeat's next fire (AgentManager.ensure_current_timeline):
        # either it predates this feature, its window has elapsed, or
        # update_heartbeat nulled it out because `timestamps` changed since
        # it was built. Set atomically with the row's own INSERT by
        # add_heartbeat (a heartbeat is never created without one), and
        # overwritten only by a single UPDATE once a regeneration succeeds
        # -- a failed regeneration attempt leaves this column's existing
        # value completely untouched.
        "timeline_instruction TEXT)"
    )
    # Migrations for databases created before these columns existed.
    cur.execute(
        "ALTER TABLE agent_heartbeats ADD COLUMN IF NOT EXISTS last_fired TIMESTAMPTZ"
    )
    cur.execute(
        "ALTER TABLE agent_heartbeats ADD COLUMN IF NOT EXISTS group_id UUID REFERENCES groups(_id) ON DELETE SET NULL"
    )
    cur.execute(
        "ALTER TABLE agent_heartbeats ADD COLUMN IF NOT EXISTS notes_public BOOLEAN DEFAULT FALSE"
    )
    cur.execute(
        "ALTER TABLE agent_heartbeats ADD COLUMN IF NOT EXISTS idempotency_key TEXT"
    )
    cur.execute(
        "ALTER TABLE agent_heartbeats ADD COLUMN IF NOT EXISTS timeline_instruction TEXT"
    )
    # A UNIQUE index, not a plain column-level UNIQUE constraint: uniqueness
    # is scoped to the (user_id, agent_id, idempotency_key) triple, not to
    # idempotency_key alone -- two different users' (or one user's two
    # different agents') attempts landing on coincidentally-identical tokens
    # must never collide with each other. `ALTER TABLE ... ADD CONSTRAINT`
    # has no idempotent `IF NOT EXISTS` form (same gap noted on the
    # `messages.attachment_kind` ALTERs above), so this uses
    # `CREATE UNIQUE INDEX IF NOT EXISTS` instead, which enforces the
    # identical guarantee and re-runs cleanly on every boot.
    #
    # NULL is allowed and deliberately never collides with another NULL
    # (standard SQL/Postgres unique-index semantics) -- every row that
    # predates this column, including the two known duplicate rows this
    # very task investigated, has idempotency_key = NULL and so cannot block
    # this index's creation or each other.
    cur.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_heartbeats_idempotency "
        "ON agent_heartbeats (user_id, agent_id, idempotency_key)"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS agent_messages"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "title VARCHAR(255) DEFAULT '',"
        "agent_id UUID REFERENCES agents(_id) ON DELETE CASCADE,"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "timestamp TIMESTAMPTZ DEFAULT NOW(),"
        "content TEXT DEFAULT '')"
    )
    # Migration for a pre-existing agent_messages table from an earlier
    # schema (columns `conversation_id`/`role` instead of today's
    # `agent_id`/`user_id`/`title`) -- same class of gap as the `agents`
    # table's name/enabled columns above, and the same silent-failure
    # consequence: db-write-failure-signaling workflow step 2 found this
    # by having AgentManager.save_agent_message/note_via_hb's insertion()
    # call finally raise on a caught error instead of swallowing it, which
    # surfaced "column \"title\" of relation \"agent_messages\" does not
    # exist" against any database whose agent_messages predates this
    # column set -- previously every chat/heartbeat message write against
    # such a database failed exactly this way and was reported as sent
    # anyway. The old `conversation_id`/`role` columns are dropped outright
    # (not just left in place) rather than merely added-around: no code
    # reads either one, and the old `role` column's leftover NOT NULL
    # constraint would otherwise reject every insert going forward too,
    # since nothing populates it anymore -- same "nothing reads or writes
    # it anymore" reasoning as the `notifications` DROP TABLE a few tables
    # below.
    cur.execute("ALTER TABLE agent_messages ADD COLUMN IF NOT EXISTS title VARCHAR(255) DEFAULT ''")
    cur.execute("ALTER TABLE agent_messages ADD COLUMN IF NOT EXISTS agent_id UUID REFERENCES agents(_id) ON DELETE CASCADE")
    cur.execute("ALTER TABLE agent_messages ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(_id) ON DELETE CASCADE")
    cur.execute("ALTER TABLE agent_messages DROP COLUMN IF EXISTS conversation_id")
    cur.execute("ALTER TABLE agent_messages DROP COLUMN IF EXISTS role")

    # One-time cleanup migration: the `notifications` table backed the
    # removed agentic/custom notification subsystem (user-authored AI-prompt
    # reminders on a 31-day schedule). It's dropped outright rather than
    # retained/archived — nothing reads or writes it anymore, and it carries
    # no data other systems depend on. See
    # .claude/pipeline/20260826-activity-based-notifications. No FK from any
    # other table points at it, so a plain drop is safe.
    cur.execute("DROP TABLE IF EXISTS notifications")

    cur.execute(
        "CREATE TABLE IF NOT EXISTS device_tokens"
        "(user_id UUID PRIMARY KEY REFERENCES users(_id) ON DELETE CASCADE,"
        "token TEXT NOT NULL,"
        "updated_at TIMESTAMP DEFAULT NOW())"
    )

    # Backs the activity-tracked/fixed-notification system that replaced the
    # agentic/custom notification subsystem (see
    # .claude/pipeline/20260826-activity-based-notifications, step 2). One
    # row per user, written only from the note/highlight create paths
    # (backend/interactions/activity.py::ActivityManager.record_activity) —
    # no user-facing surface, no CRUD routes. Deliberately doesn't add a
    # timestamp column to `highlights` itself (that table's composite PK and
    # upsert-on-conflict shape make "created_at" ambiguous on re-highlight);
    # a highlight write instead bumps this table directly, same as a note
    # write, so both signals share one last-activity marker without a
    # highlights schema migration.
    cur.execute(
        "CREATE TABLE IF NOT EXISTS user_activity"
        "(user_id UUID PRIMARY KEY REFERENCES users(_id) ON DELETE CASCADE,"
        # Last time this user created a note (incl. replies) or a highlight.
        "last_activity_at TIMESTAMPTZ,"
        # Set to `last_activity_at`'s value whenever record_activity detects
        # an inactive→active transition (no prior activity, or the prior
        # last_activity_at is more than INACTIVITY_THRESHOLD old). NULL
        # between transitions.
        "became_active_at TIMESTAMPTZ,"
        # NULL immediately after a transition (queues the friend-went-active
        # job to pick it up); set once that job actually sends, so a single
        # transition is only ever broadcast to friends once.
        "friend_notified_at TIMESTAMPTZ,"
        # Local calendar date (per the user's `users.timezone`) the midday
        # no-activity-yet-today reminder last fired — caps it at once/day.
        "midday_reminder_sent_date DATE,"
        # Last time the >24h guilt reminder fired — caps it at once per
        # INACTIVITY_THRESHOLD window rather than on every scheduler poll.
        "guilt_reminder_sent_at TIMESTAMPTZ)"
    )
    # CREATE TABLE IF NOT EXISTS above doesn't retroactively add columns to
    # an already-existing table (same precedent as agent_heartbeats.
    # timeline_instruction above), so this column needs its own idempotent
    # ALTER. Which of
    # note_created / note_edited / verse_highlighted (see
    # backend/interactions/activity.py's NOTE_CREATED/NOTE_EDITED/
    # VERSE_HIGHLIGHTED constants) produced the current last_activity_at,
    # so _friend_went_active_notify can name the action instead of sending a
    # generic "came back" push. Nullable: rows written before this column
    # existed, or a write that didn't pass a recognized type, fall back to
    # that generic text rather than failing the job.
    cur.execute("ALTER TABLE user_activity ADD COLUMN IF NOT EXISTS last_activity_type TEXT")

    # `agentic_context` (and its `note_id` FK link into `notes`) was removed
    # outright, task 20260906-heartbeat-timeline-instructions: it only ever
    # held a durable heartbeat_id -> note_id link plus a live-recomputed
    # CHAPTERS/VERSES/THEME aggregate, never source-of-truth data, and is
    # fully superseded by `agent_heartbeats.timeline_instruction` (see that
    # column's own comment above) -- no export/backfill was needed before
    # dropping it. A database that still has the table from before this
    # change keeps it (this file only ever CREATEs, never DROPs), but
    # nothing in the app reads or writes it anymore.

    cur.execute(
        "CREATE TABLE IF NOT EXISTS subscription_request"
        "(subscription_id UUID REFERENCES subscriptions(_id) ON DELETE CASCADE,"
        "from_user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "created_at TIMESTAMPTZ DEFAULT NOW(),"
        "PRIMARY KEY (subscription_id, from_user_id))"
    )

    # Server-side session store backing the login cookie. The cookie holds an
    # opaque random token; only its sha256 hash is stored, mirroring hash_pass.
    cur.execute(
        "CREATE TABLE IF NOT EXISTS sessions"
        "(token_hash VARCHAR(64) PRIMARY KEY,"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "created_at TIMESTAMPTZ DEFAULT NOW(),"
        "expires_at TIMESTAMPTZ NOT NULL)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id)"
    )

    # Single-use, hashed password-reset links emailed to the account's address.
    # Mirrors the sessions table's pattern: only the sha256 hash of the opaque
    # token is stored, never the token itself.
    cur.execute(
        "CREATE TABLE IF NOT EXISTS password_reset_tokens"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "token_hash VARCHAR(64) NOT NULL,"
        "created_at TIMESTAMPTZ DEFAULT NOW(),"
        "expires_at TIMESTAMPTZ NOT NULL,"
        "used BOOLEAN NOT NULL DEFAULT FALSE)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_password_reset_user ON password_reset_tokens(user_id)"
    )

    # Single-use, hashed 6-digit codes emailed for the email-based 2FA login
    # challenge. Same hash-at-rest pattern as sessions/password_reset_tokens.
    cur.execute(
        "CREATE TABLE IF NOT EXISTS mfa_codes"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "code_hash VARCHAR(64) NOT NULL,"
        "created_at TIMESTAMPTZ DEFAULT NOW(),"
        "expires_at TIMESTAMPTZ NOT NULL,"
        "used BOOLEAN NOT NULL DEFAULT FALSE)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_mfa_codes_user ON mfa_codes(user_id)"
    )

    # Guideline 1.2 report/flag queue. content_type is polymorphic (note,
    # message, devotion_prompt, group_title, or a direct user report), so
    # content_id has no single FK target — content_snippet freezes the
    # offending text at report time so it survives a later edit/delete and the
    # operator can still see what was actually reported hours later.
    cur.execute(
        "CREATE TABLE IF NOT EXISTS content_reports"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "reporter_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "reported_user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "content_type TEXT NOT NULL,"
        "content_id UUID,"
        "content_snippet TEXT DEFAULT '',"
        "reason TEXT NOT NULL,"
        "detail TEXT DEFAULT '',"
        "status TEXT NOT NULL DEFAULT 'open',"
        "created_at TIMESTAMPTZ DEFAULT NOW(),"
        "resolved_at TIMESTAMPTZ)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_content_reports_status ON content_reports(status, created_at)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_content_reports_reported_user ON content_reports(reported_user_id)"
    )

    # CloudWatch error watchdog (cloudwatch-error-remediation workflow, step
    # 3). Both tables are Level 0 (no FKs) — they're system/infra records,
    # not scoped to any user.
    #
    # Per-log-group watermark: last_seen_time is the exclusive lower bound of
    # the next poll's query window, so consecutive watchdog runs never
    # re-process or skip events (see WatchdogManager.run_cycle).
    cur.execute(
        "CREATE TABLE IF NOT EXISTS log_group_cursors"
        "(log_group_name TEXT PRIMARY KEY,"
        "last_seen_time TIMESTAMPTZ NOT NULL,"
        "updated_at TIMESTAMPTZ DEFAULT NOW())"
    )

    # One row per detected error event plus its assembled surrounding
    # context (nearby log lines + the MCP log-analyzer's output, if any) —
    # the context-handoff payload a later read-only admin endpoint (and,
    # eventually, a write-capable remediation agent) would consume. `status`
    # defaults to 'new' and is forward-compatible with a later
    # acknowledged/resolved workflow, but nothing writes to it besides the
    # watchdog job in this step — no remediation action reads or acts on it
    # yet.
    cur.execute(
        "CREATE TABLE IF NOT EXISTS error_detections"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "log_group_name TEXT NOT NULL,"
        "log_stream_name TEXT,"
        "event_timestamp TIMESTAMPTZ NOT NULL,"
        "message TEXT NOT NULL,"
        "matched_signal TEXT NOT NULL,"
        "context JSONB NOT NULL DEFAULT '{}',"
        "detected_at TIMESTAMPTZ DEFAULT NOW(),"
        "status TEXT NOT NULL DEFAULT 'new')"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_error_detections_detected_at "
        "ON error_detections(detected_at DESC)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_error_detections_log_group "
        "ON error_detections(log_group_name, detected_at DESC)"
    )

    # 2026-08-14 incident-window noise backfill (cloudwatch-watchdog-memory-
    # leak workflow, step 4), re-applied idempotently every create_tables()
    # run -- same non-destructive, targeted-UPDATE pattern as the admin seed
    # above. Flags error_detections rows written during the ~5-hour
    # production OOM incident (commit a8a22ecc) as noise: that incident's
    # self-amplifying feedback loop produced a large volume of detections
    # that are the watchdog re-detecting its own/the debug agent's failure
    # logs, not distinct real application errors (see
    # backend/monitoring/watchdog.py's self-exclusion filter + per-cycle
    # cap, added in the same workflow, which prevent this going forward).
    # Flagged, never deleted -- the incident window stays inspectable for
    # postmortem review via `include_noise=True` on the list endpoint, or a
    # direct detection-id fetch (WatchdogManager.get_detection never filters
    # by status). error_detection_reports needs no equivalent flag: it has
    # no status column of its own and is only ever reached via its parent
    # detection's id, so flagging the detection is sufficient.
    #
    # Window bounds: the incident report (commit a8a22ecc, "~5 hours"
    # tonight) is the only record of its duration -- there's no logged exact
    # start second to key off, so this conservatively covers the whole
    # calendar day up to the disable commit's timestamp
    # (2026-08-14 15:54:16-07:00) rather than guess a tighter start bound
    # that might miss real incident rows. The `status IN (...)` guard means
    # a later manually-reviewed status (if that concept is ever added) is
    # never silently overwritten by a subsequent create_tables() re-run.
    _INCIDENT_NOISE_WINDOW_START = "2026-08-14 00:00:00-07:00"
    _INCIDENT_NOISE_WINDOW_END = "2026-08-14 15:54:16-07:00"
    cur.execute(
        "UPDATE error_detections SET status = 'noise' "
        "WHERE detected_at >= %s AND detected_at <= %s "
        "AND status IN ('new', 'diagnosed')",
        (_INCIDENT_NOISE_WINDOW_START, _INCIDENT_NOISE_WINDOW_END),
    )
    if cur.rowcount:
        logger.info(
            "Incident-window backfill: flagged %d error_detections row(s) from "
            "2026-08-14 as status='noise' (excluded from the default admin "
            "triage feed, never deleted).",
            cur.rowcount,
        )

    # Debugging agent's diagnostic report for a detection (error-debug-agent-
    # admin-page workflow, step 3). Level 1: references error_detections.
    # `detection_id` is UNIQUE so a rerun (POST /monitoring/detections/{id}/
    # report) is a plain upsert in place rather than accumulating a report
    # row per rerun -- matches log_group_cursors' single-current-value
    # pattern. Cascades away with its parent detection.
    cur.execute(
        "CREATE TABLE IF NOT EXISTS error_detection_reports"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "detection_id UUID NOT NULL UNIQUE REFERENCES error_detections(_id) ON DELETE CASCADE,"
        "root_cause TEXT NOT NULL DEFAULT '',"
        "remediation_narrative TEXT NOT NULL DEFAULT '',"
        "model TEXT NOT NULL,"
        "generated_at TIMESTAMPTZ DEFAULT NOW())"
    )

    logger.info("All tables created.")


BACKUP_DB_NAME = "fellowscript_backup"


def create_backup_tables(cur) -> None:
    """Schema for the separate nightly-backup database (BACKUP_DB_NAME).

    Deliberately FK-light and denormalized relative to the primary schema —
    a backup destination must never refuse a write because some other row
    hasn't been mirrored yet. Each table's primary key mirrors the source
    table's so a re-run just refreshes existing rows (upsert, never fails on
    a duplicate). ``backed_up_at`` records when *this* copy was written, not
    when the original data was created/changed.
    """
    logger.info("Creating backup-database tables...")
    cur.execute(
        "CREATE TABLE IF NOT EXISTS users"
        "(_id UUID PRIMARY KEY,"
        "username VARCHAR(64),"
        "email VARCHAR(255),"
        "timezone TEXT,"
        "backed_up_at TIMESTAMPTZ DEFAULT NOW())"
    )
    cur.execute(
        "CREATE TABLE IF NOT EXISTS notes"
        "(_id UUID PRIMARY KEY,"
        "user_id UUID,"
        "title VARCHAR(255),"
        "text TEXT,"
        "public BOOLEAN,"
        "group_id UUID,"
        "is_reply BOOLEAN,"
        "parent_note_id UUID,"
        "timestamp TIMESTAMPTZ,"
        "created_at TIMESTAMPTZ,"
        "backed_up_at TIMESTAMPTZ DEFAULT NOW())"
    )
    cur.execute(
        "CREATE TABLE IF NOT EXISTS note_verses"
        "(note_id UUID,"
        "position INTEGER,"
        "book VARCHAR(64),"
        "chapter INTEGER,"
        "verse INTEGER,"
        "PRIMARY KEY (note_id, position))"
    )
    cur.execute(
        "CREATE TABLE IF NOT EXISTS highlights"
        "(user_id UUID,"
        "key VARCHAR(128),"
        "color VARCHAR(16),"
        "backed_up_at TIMESTAMPTZ DEFAULT NOW(),"
        "PRIMARY KEY (user_id, key))"
    )
    cur.execute(
        "CREATE TABLE IF NOT EXISTS bookmarks"
        "(user_id UUID,"
        "key VARCHAR(128),"
        "label VARCHAR(255),"
        "backed_up_at TIMESTAMPTZ DEFAULT NOW(),"
        "PRIMARY KEY (user_id, key))"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_backup_notes_user ON notes(user_id)"
    )
    logger.info("Backup-database tables created.")


def _connect():
    return sql.connect(
        host="localhost",
        dbname="fellowscript",
        user="fellowscript",
        password=_DB_PASSWORD,
        port=5432,
    )


class DBManager:
    def __init__(self, dbname: str = "fellowscript"):
        self.conn = sql.connect(
            host="localhost",
            dbname=dbname,
            user="fellowscript",
            password=_DB_PASSWORD,
            port=5432
        )
        logger.info("Connected.")
        self.cur = self.conn.cursor()
        self.db_name = dbname

    def insertion(self, table: str, values: dict[str, Any], conflict: str = "DO NOTHING") -> bool:
        """Insert one row. Returns True on success, False if the write
        failed (caught sql.Error) -- callers must check this signal rather
        than assuming success, since a caught error here previously
        returned None indistinguishably from the successful (also None)
        path (db-write-failure-signaling workflow, step 1).

        An `ON CONFLICT ... DO NOTHING` no-op (0 rows written because the
        row already exists) is NOT treated as failure here: unlike
        update/delete's zero-rows case below, a `DO NOTHING` conflict is
        the caller's own explicitly-requested idempotent behavior, not an
        unexpected miss -- it ran without error and did exactly what was
        asked.
        """
        cols = ", ".join(values.keys())
        placeholders = ", ".join(["%s"] * len(values))
        try:
            self.cur.execute(
                f"INSERT INTO {table} ({cols}) VALUES ({placeholders}) ON CONFLICT {conflict}",
                list(values.values())
            )
            self.conn.commit()
            return True
        except sql.Error as e:
            # DB_WRITE_FAILURE: dedicated, distinguishable marker matching
            # the CLIENT_DECODE_FAILURE precedent (routes/monitoring.py) --
            # see watchdog.py's _ERROR_SIGNAL_PATTERNS for the matching
            # entry, checked before the generic "error_level" pattern.
            logger.error("DB_WRITE_FAILURE op=insert table=%s error=%s", table, _redact_db_error(e))
            self.conn.rollback()
            return False

    def lookup(self, table: str, conditions: dict[str, Any] = {}) -> dict:
        params = list(conditions.values())
        where = ""
        if conditions:
            clauses = " AND ".join(f"{col} = %s" for col in conditions.keys())
            where = f" WHERE {clauses}"
        try:
            self.cur.execute(f"SELECT * FROM {table}{where}", params)
            if not self.cur.description:
                return {}
            cols = [desc[0] for desc in self.cur.description]
            return {
                row[0]: dict(zip(cols[1:], row[1:]))
                for row in self.cur.fetchall()
            }
        except sql.Error as e:
            logger.error("Error looking up %s: %s", table, e)
            self.conn.rollback()
            return {}

    def delete(self, table: str, conditions: dict[str, Any]) -> bool:
        """Delete rows matching conditions. Returns True only if the
        DELETE both ran without a SQL error AND actually removed at least
        one row.

        Zero rows affected (no exception -- the WHERE clause just matched
        nothing) is treated as failure too, not just "ran clean": with a
        plain bool signal there's no third state to distinguish "deleted
        something" from "matched nothing," and silently reporting the
        latter as success is exactly the fake-success behavior this
        workflow exists to remove (a delete targeting a row that doesn't
        exist / was already removed / doesn't belong to the caller should
        be just as visible to the caller as a real SQL error). Callers for
        whom a zero-row delete is a legitimate, expected no-op (e.g.
        idempotent cleanup) can treat a False return accordingly -- that's
        a call-site decision, not this method's.

        Deliberately does NOT log a DB_WRITE_FAILURE line for the
        zero-rows case (only for the caught-exception path below): a
        no-op delete isn't a DB failure, and logging every ordinary
        zero-match delete as an "error" would flood the CloudWatch-backed
        watchdog pipeline with false signals -- the same class of noisy,
        self-amplifying false-positive this codebase has already had to
        harden watchdog.py against (see its self-exclusion/circuit-breaker
        comments).
        """
        clauses = " AND ".join(f"{col} = %s" for col in conditions.keys())
        try:
            self.cur.execute(f"DELETE FROM {table} WHERE {clauses}", list(conditions.values()))
            deleted = self.cur.rowcount > 0
            self.conn.commit()
            return deleted
        except sql.Error as e:
            logger.error("DB_WRITE_FAILURE op=delete table=%s error=%s", table, _redact_db_error(e))
            self.conn.rollback()
            return False

    def update(self, table: str, values: dict[str, Any], conditions: dict[str, Any]) -> bool:
        """Update rows matching conditions. Returns True only if the
        UPDATE both ran without a SQL error AND actually changed at least
        one row -- same zero-rows-counts-as-failure reasoning as `delete`
        above (a plain bool signal has no room for a distinct "ran clean
        but matched nothing" state), and same choice not to log
        DB_WRITE_FAILURE for that no-op case, only for a real caught
        error.
        """
        set_clause = ", ".join(f"{col} = %s" for col in values.keys())
        where_clause = " AND ".join(f"{col} = %s" for col in conditions.keys())
        params = list(values.values()) + list(conditions.values())
        try:
            self.cur.execute(
                f"UPDATE {table} SET {set_clause} WHERE {where_clause}",
                params
            )
            updated = self.cur.rowcount > 0
            self.conn.commit()
            return updated
        except sql.Error as e:
            logger.error("DB_WRITE_FAILURE op=update table=%s error=%s", table, _redact_db_error(e))
            self.conn.rollback()
            return False

    def close(self):
        self.cur.close()
        self.conn.close()
        logger.info("Connection closed.")