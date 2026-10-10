"""Emoji validation for verse reactions (task 20261009-verse-reactions).

A verse reaction is a highlight with an optional ``emoji`` (nullable column on
``highlights``). The emoji is stored and shown to friends, so it is validated
against a closed allowlist: anything else is rejected, never sanitized.
Stored exactly as listed here (canonical form, including any variation
selector). Gated by the ``verse_reactions`` flag (seeded off).
"""
from __future__ import annotations

from fastapi import HTTPException

from backend.interactions import flags

FLAG_NAME = "verse_reactions"

# Neutral color stored when an emoji reaction carries no highlight color, so
# ``highlights.color`` stays NOT NULL and old clients keep decoding rows.
NEUTRAL_COLOR = "#8E8E93"

VERSE_REACTION_EMOJI: tuple[str, ...] = (
    "❤️",      # red heart
    "\U0001F64F",        # folded hands
    "\U0001F525",        # fire
    "\U0001F44D",        # thumbs up
    "\U0001F622",        # crying face
    "\U0001F62E",        # open mouth
    "✨",            # sparkles
    "\U0001F4D6",        # open book
    "\U0001F64C",        # raising hands
    "\U0001F4A1",        # light bulb
)

_ALLOWED = frozenset(VERSE_REACTION_EMOJI)
MAX_EMOJI_LENGTH = 8


def validate_emoji(emoji, user_id: str) -> str | None:
    """Return the allowlisted emoji, or None when no emoji was supplied.

    Raises:
        HTTPException 400: not a string, over-long, not allowlisted, or the
            ``verse_reactions`` flag is off for this user (fail closed).
    """
    if emoji is None or emoji == "":
        return None
    if not isinstance(emoji, str) or len(emoji) > MAX_EMOJI_LENGTH or emoji not in _ALLOWED:
        raise HTTPException(status_code=400, detail="Unsupported reaction emoji")
    if not flags.is_enabled(FLAG_NAME, user_id):
        raise HTTPException(status_code=400, detail="Verse reactions are not available")
    return emoji
