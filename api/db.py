import psycopg2 as sql
import os
import sys
import json
import logging
import uuid
from typing import Any
from dotenv import load_dotenv
from schemas.users import User, Note
from schemas.message import Group, Message
from schemas.devotion import DevotionPlan

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

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
        "is_admin BOOLEAN NOT NULL DEFAULT FALSE)"
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

    # One-time admin seed, re-applied (idempotently) every time create_tables()
    # runs -- i.e. on every non-destructive schema-apply deploy step (see
    # reference_deploy.md). Resolves the admin account by a live email lookup
    # against *this* users table rather than a hardcoded _id: the legacy
    # data/users.json seed file's UUID for this account is not authoritative
    # for the live table and must never be trusted here.
    _ADMIN_SEED_EMAIL = "jaceysimps@gmail.com"
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

    cur.execute(
        "CREATE TABLE IF NOT EXISTS highlights"
        "(user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "key VARCHAR(128) NOT NULL,"
        "color VARCHAR(16) NOT NULL,"
        "PRIMARY KEY (user_id, key))"
    )

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
        "timestamps JSONB DEFAULT '[]',"
        "prompt TEXT DEFAULT '',"
        # Timestamp of the most recent fire. Used to make commit_hb_response
        # idempotent so repeated same-day calls (e.g. the iOS client
        # re-checking on every app foreground) can't create more than one
        # note for the same scheduled slot — see the UTC-calendar-day claim
        # in AgentManager.commit_hb_response.
        "last_fired TIMESTAMPTZ)"
    )
    # Migration for databases created before last_fired existed.
    cur.execute(
        "ALTER TABLE agent_heartbeats ADD COLUMN IF NOT EXISTS last_fired TIMESTAMPTZ"
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

    cur.execute(
        "CREATE TABLE IF NOT EXISTS agentic_context"
        "(_id UUID PRIMARY KEY NOT NULL,"
        "heartbeat_id UUID REFERENCES agent_heartbeats(_id) ON DELETE CASCADE,"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        # Which note this context summary was distilled from. Nullable since
        # rows written before this column existed have no note to point at.
        # ON DELETE CASCADE: deleting the note (from any path — the notes
        # route, account deletion, or the Guideline 1.2 moderation CLI) must
        # also remove its trace from the agent's future "previous context"
        # prompts, not just the note itself.
        "note_id UUID REFERENCES notes(_id) ON DELETE CASCADE,"
        "context TEXT[] DEFAULT '{}')"
    )
    cur.execute("ALTER TABLE agentic_context ADD COLUMN IF NOT EXISTS note_id UUID REFERENCES notes(_id) ON DELETE CASCADE")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_agentic_context_note ON agentic_context(note_id)")

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


main_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

def load_users() -> dict:
    path = os.path.join(main_path, "data/users.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}

def load_groups() -> dict:
    path = os.path.join(main_path, "data/groups.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}

def load_notes() -> dict:
    path = os.path.join(main_path, "data/notes.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}

def load_devotions() -> dict:
    path = os.path.join(main_path, "data/devotions.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}

def load_messages() -> list:
    path = os.path.join(main_path, "data/messages.json")
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return []
    
def insert_users(cur, users: dict):
    logger.info("Inserting %d users...", len(users))
    # Pass 1: insert all user rows so every user_id exists before FK references
    parsed = {}
    for uid, data in users.items():
        user = User(**data)
        user.user_id = uid
        cur.execute(
            "INSERT INTO users (_id, username, email, hash_pass)"
            "VALUES (%s, %s, %s, %s) ON CONFLICT DO NOTHING",
            (user.user_id, user.username, user.email, user.hash_pass)
        )
        logger.info("%s added", user.user_id)
        parsed[uid] = user

    # Pass 2: insert relational data now that all users exist
    for uid, user in parsed.items():
        for friend_id in user.friends:
            cur.execute(
                "INSERT INTO user_friends (user_id, friend_id)"
                "VALUES (%s, %s) ON CONFLICT DO NOTHING",
                (user.user_id, friend_id)
            )
        for from_id in user.friend_requests:
            cur.execute(
                "INSERT INTO friend_requests (to_user_id, from_user_id)"
                "VALUES (%s, %s) ON CONFLICT DO NOTHING",
                (user.user_id, from_id)
            )
        for key, color in user.highlights.items():
            cur.execute(
                "INSERT INTO highlights (user_id, key, color)"
                "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
                (user.user_id, key, color)
            )
        for key, label in user.bookmarks.items():
            cur.execute(
                "INSERT INTO bookmarks (user_id, key, label)"
                "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
                (user.user_id, key, label)
            )
        logger.debug("Inserted relations for user %s (%s)", uid, user.username)
    logger.info("Done inserting users.")

def insert_groups(cur, groups: dict):
    logger.info("Inserting %d groups...", len(groups))
    for gid, data in groups.items():
        group = Group(group_id=gid, title=data["title"], users=data.get("users", []))
        cur.execute(
            "INSERT INTO groups (_id, title, users)"
            "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
            (group.group_id, group.title, group.users)
        )
    logger.info("Done inserting groups.")

def insert_notes(cur, notes: dict):
    logger.info("Inserting %d notes...", len(notes))
    # Build a reply→parent map so each reply knows its parent_note_id
    parent_map = {}
    for note_id, data in notes.items():
        for reply_id in data.get("replies", []):
            parent_map[reply_id] = note_id

    for note_id, data in notes.items():
        note = Note(**data)
        group_id = note.group_id if note.group_id else None
        parent_note_id = parent_map.get(note_id)
        cur.execute(
            "INSERT INTO notes (_id, user_id, title, text, public, group_id, is_reply, parent_note_id, timestamp)"
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING",
            (note_id, note.user, note.title, note.text, note.public,
             group_id, note.is_reply, parent_note_id, note.timestamp)
        )
        for position, verse in enumerate(note.verses):
            if isinstance(verse, list) and len(verse) >= 3:
                cur.execute(
                    "INSERT INTO note_verses (note_id, position, book, chapter, verse)"
                    "VALUES (%s, %s, %s, %s, %s) ON CONFLICT DO NOTHING",
                    (note_id, position, verse[0], verse[1], verse[2])
                )
    logger.info("Done inserting notes.")

def _valid_uuid(value: str | None) -> str | None:
    if not value:
        return None
    try:
        uuid.UUID(value)
        return value
    except (ValueError, AttributeError):
        logger.warning("Skipping invalid UUID value: %r", value)
        return None

def insert_devotions(cur, devotions: dict, valid_group_ids: set, valid_user_ids: set):
    logger.info("Inserting %d devotions...", len(devotions))
    for devo_id, data in devotions.items():
        devo = DevotionPlan(**data)
        group_id = _valid_uuid(devo.group_id)
        if group_id and group_id not in valid_group_ids:
            logger.warning("Devotion %s: group_id %s not found, setting NULL", devo_id, group_id)
            group_id = None
        creator_id = _valid_uuid(devo.creator_id)
        if creator_id and creator_id not in valid_user_ids:
            logger.warning("Devotion %s: creator_id %s not found, setting NULL", devo_id, creator_id)
            creator_id = None
        cur.execute(
            "INSERT INTO devotions (_id, title, time_start, time_end, recurring,"
            "group_id, creator_id, participants, verses, prompts, chime_meeting_id, chime_meeting)"
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING",
            (devo_id, devo.title, devo.time_start or None, devo.time_end or None,
             devo.recurring, group_id, creator_id,
             devo.participants, devo.verses, devo.prompts,
             devo.chime_meeting_id, json.dumps(devo.chime_meeting))
        )
    logger.info("Done inserting devotions.")

def insert_messages(cur, messages: list, valid_group_ids: set, valid_user_ids: set):
    logger.info("Inserting %d messages...", len(messages))
    for data in messages:
        msg = Message(**data)
        group_id = _valid_uuid(msg.group_id)
        if group_id and group_id not in valid_group_ids:
            logger.warning("Message from %s: group_id %s not found, setting NULL", msg.from_user, group_id)
            group_id = None
        from_user = _valid_uuid(msg.from_user)
        if from_user and from_user not in valid_user_ids:
            logger.warning("Message: from_user %s not found, skipping", msg.from_user)
            continue
        cur.execute(
            "INSERT INTO messages (from_user, group_id, text, timestamp)"
            "VALUES (%s, %s, %s, %s) RETURNING _id",
            (from_user, group_id, msg.text, msg.timestamp)
        )
        row = cur.fetchone()
        if row:
            message_id = row[0]
            for recipient_id in msg.to_users:
                if _valid_uuid(recipient_id) and recipient_id in valid_user_ids:
                    cur.execute(
                        "INSERT INTO message_recipients (message_id, user_id)"
                        "VALUES (%s, %s) ON CONFLICT DO NOTHING",
                        (message_id, recipient_id)
                    )
    logger.info("Done inserting messages.")


def clear_tables(cur):
    logger.info("Clearing all tables...")
    cur.execute(
        "TRUNCATE TABLE "
        "device_tokens, subscription_request, subscriptions, "
        "agent_messages, agent_heartbeats, message_recipients, note_verses, "
        "agents, devotions, messages, notes, "
        "bookmarks, highlights, friend_requests, user_friends, "
        "groups, users "
        "CASCADE"
    )
    logger.info("All tables cleared.")

def migrate_data(cur):
    logger.info("Loading data from JSON files...")
    users = load_users()
    groups = load_groups()
    notes = load_notes()
    devotions = load_devotions()
    messages = load_messages()
    logger.info("Loaded: %d users, %d groups, %d notes, %d devotions, %d messages",
                len(users), len(groups), len(notes), len(devotions), len(messages))

    insert_users(cur, users)
    insert_groups(cur, groups)
    insert_notes(cur, notes)
    insert_devotions(cur, devotions, valid_group_ids=set(groups.keys()), valid_user_ids=set(users.keys()))
    insert_messages(cur, messages, valid_group_ids=set(groups.keys()), valid_user_ids=set(users.keys()))
    logger.info("Migration complete.")

def _connect():
    return sql.connect(
        host="localhost",
        dbname="fellowscript",
        user="fellowscript",
        password=os.getenv("DB_PASSWORD"),
        port=5432,
    )

def main():
    logger.info("Connecting to PostgreSQL...")
    conn = _connect()
    logger.info("Connected.")
    cur = conn.cursor()
    create_tables(cur)
    clear_tables(cur)
    migrate_data(cur)
    conn.commit()
    logger.info("Changes committed.")
    cur.close()
    conn.close()
    logger.info("Connection closed.")

def main_notes_only():
    """Insert any notes (and their verses) missing from the DB without touching other tables.
    Groups are also upserted first so FK constraints on notes.group_id are satisfied."""
    logger.info("Notes-only migration: connecting...")
    conn = _connect()
    logger.info("Connected.")
    cur = conn.cursor()
    groups = load_groups()
    notes  = load_notes()
    logger.info("Loaded %d groups and %d notes from JSON.", len(groups), len(notes))
    insert_groups(cur, groups)
    insert_notes(cur, notes)
    conn.commit()
    logger.info("Notes committed.")
    cur.close()
    conn.close()
    logger.info("Done.")


class DBManager:
    def __init__(self, dbname: str = "fellowscript"):
        self.conn = sql.connect(
            host="localhost",
            dbname=dbname,
            user="fellowscript",
            password=os.getenv("DB_PASSWORD"),
            port=5432
        )
        logger.info("Connected.")
        self.cur = self.conn.cursor()
        self.db_name = dbname

    def insertion(self, table: str, values: dict[str, Any], conflict: str = "DO NOTHING"):
        cols = ", ".join(values.keys())
        placeholders = ", ".join(["%s"] * len(values))
        try:
            self.cur.execute(
                f"INSERT INTO {table} ({cols}) VALUES ({placeholders}) ON CONFLICT {conflict}",
                list(values.values())
            )
            self.conn.commit()
        except sql.Error as e:
            logger.error("Error inserting into %s: %s", table, e)
            self.conn.rollback()

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

    def delete(self, table: str, conditions: dict[str, Any]):
        clauses = " AND ".join(f"{col} = %s" for col in conditions.keys())
        try:
            self.cur.execute(f"DELETE FROM {table} WHERE {clauses}", list(conditions.values()))
            self.conn.commit()
        except sql.Error as e:
            logger.error("Error deleting from %s: %s", table, e)
            self.conn.rollback()

    def update(self, table: str, values: dict[str, Any], conditions: dict[str, Any]):
        set_clause = ", ".join(f"{col} = %s" for col in values.keys())
        where_clause = " AND ".join(f"{col} = %s" for col in conditions.keys())
        params = list(values.values()) + list(conditions.values())
        try:
            self.cur.execute(
                f"UPDATE {table} SET {set_clause} WHERE {where_clause}",
                params
            )
            self.conn.commit()
        except sql.Error as e:
            logger.error("Error updating %s: %s", table, e)
            self.conn.rollback()

    def close(self):
        self.cur.close()
        self.conn.close()
        logger.info("Connection closed.")

if __name__ == "__main__":
    if "--notes-only" in sys.argv:
        main_notes_only()
    else:
        main()