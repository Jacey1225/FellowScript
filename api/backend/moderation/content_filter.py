"""Local keyword-based objectionable-content filter (Guideline 1.2, "a method
for filtering objectionable content"). Runs entirely server-side — no user
text is sent to a third-party moderation API.

Severity-graded policy (2026-08): ordinary profanity is allowed. A note,
devotion, group, or chat message is hard-rejected (422) only when it contains
genuinely explicit content — graphic sexual acts/content, sexual exploitation
(rape, bestiality, incest, minors), or hateful slurs — not just any hit
against a broad profanity wordlist. This replaces the previous all-or-nothing
policy, under which mild/borderline language ("damn", "hell", ordinary
swearing) was rejected exactly like genuinely explicit content.

Submission is still hard-rejected rather than auto-flagged-and-posted: even a
brief window where explicit content is visible to other members is
unacceptable for a faith-community app, so flagged text is stopped before
it's ever persisted or shown to anyone but its author.

CONTENT_FILTER_SEVERITY (env var, default "explicit") selects which entry of
_SEVERITY_TIERS is active — a named, documented setting so a future
stricter/looser mode is a config change, not another code change. Only the
"explicit" tier is populated today; "moderate" is scaffolded for a possible
future stricter mode. An unrecognized/misconfigured value fails closed to the
strictest known tier rather than silently loading an empty (permissive)
list — see `_active_terms`.

_EXPLICIT_TERMS is a curated, intentionally narrow list — not
better_profanity's much broader default wordlist, which conflates mild
swearing, anatomical/medical vocabulary, drug slang, and topical words (e.g.
"kill", "virgin", "drunk") with genuinely explicit content. It's deliberately
scoped to three categories: (1) explicit sexual acts/hardcore sexual slang,
(2) sexual exploitation and non-consensual content, and (3) hateful slurs.
Mild profanity, plain anatomical terms, and identity words (e.g. "gay") are
intentionally NOT included. `_CUSTOM_TERMS` remains the operator's place to
add further explicit terms as real cases surface, exactly as before — it's
folded into every severity tier.

better_profanity's own character-substitution matching (a/@/4, i/1/l, o/0,
etc.) still applies to every entry below, so common leetspeak variants of a
listed term are caught without needing to list every obfuscated spelling.
"""
import os

from better_profanity import profanity

# ── Curated explicit-content wordlist ───────────────────────────────────────
# See the module docstring for what is and isn't in scope. This is a starting
# set, not exhaustive — extend `_CUSTOM_TERMS` below as real cases surface.
_EXPLICIT_TERMS: list[str] = [
    # Explicit sexual acts / hardcore sexual slang
    "2 girls 1 cup", "anal", "assfucker", "assbang", "auto erotic", "autoerotic",
    "bdsm", "blow job", "blowjob", "blue waffle", "bondage", "brown shower",
    "bukkake", "carpet muncher", "cocksucker", "cumshot", "cunnilingus",
    "cuntlicker", "deep throat", "deepthroat", "dildo", "doggystyle",
    "ejaculate", "ejaculation", "felch", "fellatio", "feltch", "femdom",
    "fingerfuck", "fisting", "fistfuck", "footjob", "futanari", "gang bang",
    "gangbang", "goatse", "gokkun", "golden shower", "handjob", "hardcoresex",
    "hentai", "rimjob", "rimming", "shibari", "spooge", "teabagging",
    "tittyfuck", "titwank", "tubgirl",
    # Sexual exploitation / non-consensual content
    "rape", "raped", "raping", "rapist", "pedophile", "pedophilia",
    "pedophiliac", "incest", "shota", "beastiality", "bestiality",
    # Hateful slurs
    "nigger", "chink", "spic", "kike", "wetback", "gook", "paki", "coon",
    "dyke", "faggot", "retard", "retarded", "shemale", "honky",
]

# Operator-added explicit terms as real cases surface, folded into every tier.
_CUSTOM_TERMS: list[str] = []

# Scaffolded for a possible future stricter mode; not populated yet. Keeping
# the tier present (even empty) means turning on a stricter mode later is a
# config change (CONTENT_FILTER_SEVERITY=moderate) plus populating this list,
# not a rewrite of the severity mechanism itself.
_MODERATE_ADDITIONAL_TERMS: list[str] = []

_SEVERITY_TIERS: dict[str, list[str]] = {
    "explicit": _EXPLICIT_TERMS + _CUSTOM_TERMS,
    "moderate": _EXPLICIT_TERMS + _CUSTOM_TERMS + _MODERATE_ADDITIONAL_TERMS,
}
_DEFAULT_SEVERITY = "explicit"
_FAIL_CLOSED_SEVERITY = "moderate"  # strictest known tier

# Named, documented, overridable setting (Configuration Philosophy: a
# foreseeable future variation, exposed proactively even though only one
# value is used today).
CONTENT_FILTER_SEVERITY = os.getenv("CONTENT_FILTER_SEVERITY", _DEFAULT_SEVERITY)


def _active_terms() -> list[str]:
    """Wordlist for the configured severity tier, failing closed on an
    unrecognized/misconfigured `CONTENT_FILTER_SEVERITY` value rather than
    silently loading an empty (permissive) list."""
    tier = _SEVERITY_TIERS.get(CONTENT_FILTER_SEVERITY)
    if tier is None:
        return _SEVERITY_TIERS[_FAIL_CLOSED_SEVERITY]
    return tier


profanity.load_censor_words(custom_words=_active_terms())


class ContentRejected(Exception):
    """Raised with the field name and the specific matched text found to
    contain explicit content, so callers can tell the user what to revise
    without resorting to a generic/clinical message."""

    def __init__(self, field: str, matched: str):
        self.field = field
        self.matched = matched
        super().__init__(f"Explicit content detected in '{field}': {matched!r}")


def _flagged_span(text: str) -> str:
    """Best-effort extraction of the specific word/phrase in `text` that
    triggered the match, for surfacing back to the user. Falls back to a
    generic phrase if a specific span can't be isolated (e.g. the match spans
    punctuation) — that only affects message specificity, not the reject
    decision itself, which has already been made by the time this runs."""
    censored = profanity.censor(text)
    original_words = text.split()
    censored_words = censored.split()
    for original, replaced in zip(original_words, censored_words):
        if replaced != original and "*" in replaced:
            return original.strip(".,!?;:\"'()")
    return "that part"


def check_clean(**fields: str | None) -> None:
    """Raise ContentRejected(field, matched) for the first field containing
    highly-explicit content, per the active severity tier
    (CONTENT_FILTER_SEVERITY). Blank/None fields are skipped (nothing to
    check). Ordinary profanity is allowed under the current policy — only
    genuinely explicit content (see module docstring) blocks."""
    for field, text in fields.items():
        if text and profanity.contains_profanity(text):
            raise ContentRejected(field, _flagged_span(text))


def rejection_message(e: ContentRejected) -> str:
    """Warm, on-brand 422 message naming the specific flagged text, used at
    every check_clean() call site so tone and shape stay consistent app-wide
    rather than drifting per feature."""
    return (
        f"We couldn't save that — \"{e.matched}\" in your {e.field} is a bit too "
        "explicit for FellowScript. Mind revising that part and giving it another try?"
    )
