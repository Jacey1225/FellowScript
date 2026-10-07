"""DDL module ``affiliate_milestones`` (task 20261007-affiliates-page).

One row per (affiliate, tier) once that tier has been reached, so an earned
milestone never regresses when subscribers later churn (one-time per tier per
affiliate). The affiliate is identified by the lowercased creator-code owner
email (a creator may hold several creators/codes rows). ``bonus_cents`` is a
snapshot of the configured bonus at the time the tier was earned. Payout is
manual; nothing here moves money.
"""


def apply(cur) -> None:
    cur.execute(
        "CREATE TABLE IF NOT EXISTS affiliate_milestones("
        "owner_email TEXT NOT NULL CHECK (owner_email = LOWER(owner_email)),"
        "tier_subscribers INTEGER NOT NULL CHECK (tier_subscribers > 0),"
        "bonus_cents INTEGER NOT NULL CHECK (bonus_cents >= 0),"
        "earned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "PRIMARY KEY (owner_email, tier_subscribers))"
    )
