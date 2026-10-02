"""DDL module ``listings``: Explorer listings (text-only core).

Owns the ONLY CREATE/ALTER of ``group_listings`` and ``group_listing_media``.
The media table is created EMPTY here so the later media task never alters a
table another task owns; nothing in this task writes to it. Join requests key
on ``groups(_id)`` and need no foreign key to these tables.

Order matters and is part of the contract: the IMMUTABLE ``fs_arr_text``
wrapper first (``array_to_string`` alone is STABLE and a generated column
built on it fails with "generation expression is not immutable"), then the
table with its generated ``search_tsv`` column in one statement (so no table
rewrite), then the empty media table, then every partial index.

``fs_arr_text`` is never edited after the first deploy: a changed body would
not recompute stored values. Different behaviour gets a new function name and
a new column.

Every statement is idempotent (CREATE ... IF NOT EXISTS / OR REPLACE) and runs
inside the boot transaction. No backfill: no group is listed until its owner
publishes.
"""

_FS_ARR_TEXT = (
    "CREATE OR REPLACE FUNCTION fs_arr_text(a text[]) RETURNS text "
    "LANGUAGE sql IMMUTABLE PARALLEL SAFE "
    "AS $$ SELECT COALESCE(array_to_string(a, ' '), '') $$"
)

_GROUP_LISTINGS = """
CREATE TABLE IF NOT EXISTS group_listings (
    _id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    public_id TEXT NOT NULL UNIQUE CHECK (public_id ~ '^[0-9A-Za-z]{10}$'),
    group_id UUID NOT NULL UNIQUE REFERENCES groups(_id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft','pending_review','published','unpublished','hidden','rejected')),
    accepting_requests BOOLEAN NOT NULL DEFAULT FALSE,
    title VARCHAR(80) NOT NULL DEFAULT '',
    summary VARCHAR(280),
    description_blocks JSONB,
    description_text TEXT NOT NULL DEFAULT '',
    denominations TEXT[],
    goals TEXT[],
    practices TEXT[],
    hobbies TEXT[],
    free_tags TEXT[],
    age_ranges TEXT[],
    life_stages TEXT[],
    gender_makeup TEXT,
    languages TEXT[],
    meeting_format TEXT,
    frequency TEXT,
    country CHAR(2),
    region TEXT,
    city TEXT,
    city_norm TEXT,
    church_name VARCHAR(120),
    banner_key TEXT,
    photo_key TEXT,
    banner_alt TEXT,
    search_tsv tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('simple'::regconfig, COALESCE(title, '')), 'A')
        || setweight(to_tsvector('simple'::regconfig,
               COALESCE(summary, '') || ' ' || COALESCE(church_name, '') || ' '
               || COALESCE(city, '') || ' ' || fs_arr_text(free_tags) || ' ' || fs_arr_text(hobbies)), 'B')
        || setweight(to_tsvector('simple'::regconfig, COALESCE(description_text, '')), 'C')
    ) STORED,
    consent_version TEXT,
    consented_at TIMESTAMPTZ,
    adult_attested BOOLEAN NOT NULL DEFAULT FALSE,
    approved_at TIMESTAMPTZ,
    reviewed_by UUID,
    reviewed_at TIMESTAMPTZ,
    reject_reason_code TEXT,
    hidden_at TIMESTAMPTZ,
    hidden_reason_code TEXT,
    published_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
"""

_GROUP_LISTING_MEDIA = """
CREATE TABLE IF NOT EXISTS group_listing_media (
    _id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    listing_id UUID NOT NULL REFERENCES group_listings(_id) ON DELETE CASCADE,
    object_key TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL CHECK (kind IN ('image','video','banner','photo')),
    size_bytes BIGINT,
    width INTEGER,
    height INTEGER,
    alt_text TEXT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','ready')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
"""

_PUBLISHED = "WHERE status = 'published'"

_INDEXES = (
    # Keyset paging of the public list: (published_at DESC, public_id DESC).
    "CREATE INDEX IF NOT EXISTS idx_group_listings_keyset "
    f"ON group_listings (published_at DESC, public_id DESC) {_PUBLISHED}",
    "CREATE INDEX IF NOT EXISTS idx_group_listings_country "
    f"ON group_listings (country) {_PUBLISHED}",
    "CREATE INDEX IF NOT EXISTS idx_group_listings_region "
    f"ON group_listings (lower(region) text_pattern_ops) {_PUBLISHED}",
    "CREATE INDEX IF NOT EXISTS idx_group_listings_city "
    f"ON group_listings (city_norm text_pattern_ops) {_PUBLISHED}",
    "CREATE INDEX IF NOT EXISTS idx_group_listings_denominations "
    f"ON group_listings USING GIN (denominations) {_PUBLISHED}",
    "CREATE INDEX IF NOT EXISTS idx_group_listings_goals "
    f"ON group_listings USING GIN (goals) {_PUBLISHED}",
    "CREATE INDEX IF NOT EXISTS idx_group_listings_practices "
    f"ON group_listings USING GIN (practices) {_PUBLISHED}",
    "CREATE INDEX IF NOT EXISTS idx_group_listings_hobbies "
    f"ON group_listings USING GIN (hobbies) {_PUBLISHED}",
    "CREATE INDEX IF NOT EXISTS idx_group_listings_age_ranges "
    f"ON group_listings USING GIN (age_ranges) {_PUBLISHED}",
    "CREATE INDEX IF NOT EXISTS idx_group_listings_life_stages "
    f"ON group_listings USING GIN (life_stages) {_PUBLISHED}",
    "CREATE INDEX IF NOT EXISTS idx_group_listings_languages "
    f"ON group_listings USING GIN (languages) {_PUBLISHED}",
    "CREATE INDEX IF NOT EXISTS idx_group_listings_tsv "
    f"ON group_listings USING GIN (search_tsv) {_PUBLISHED}",
    # Admin queue (oldest first) and the owner-suspension sweeper.
    "CREATE INDEX IF NOT EXISTS idx_group_listings_pending "
    "ON group_listings (updated_at) WHERE status = 'pending_review'",
    "CREATE INDEX IF NOT EXISTS idx_group_listing_media_listing "
    "ON group_listing_media (listing_id)",
)


def apply(cur) -> None:
    cur.execute(_FS_ARR_TEXT)
    cur.execute(_GROUP_LISTINGS)
    cur.execute(_GROUP_LISTING_MEDIA)
    for statement in _INDEXES:
        cur.execute(statement)
