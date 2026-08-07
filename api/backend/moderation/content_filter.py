"""Local keyword-based objectionable-content filter (Guideline 1.2, "a method
for filtering objectionable content"). Runs entirely server-side — no user
text is sent to a third-party moderation API.

Hard-rejects submission (422) rather than auto-flagging-and-posting: in a
faith-community app, even a brief window where flagged content is visible to
other members undermines the zero-tolerance commitment the Terms make
explicit. better_profanity's curated default wordlist keeps false positives
low; _CUSTOM_TERMS is where the operator adds terms as real cases surface.

_WHITELIST_TERMS excludes default-wordlist entries that are ordinary Bible
study vocabulary rather than objectionable content in this app's context
(e.g. "god"/"hell"/"damn"/"sodom" show up in routine Scripture discussion,
and "ass"/"prick" appear literally in KJV text) — genuine profanity/slurs
stay censored.
"""
from better_profanity import profanity

_CUSTOM_TERMS: list[str] = []

_WHITELIST_TERMS: list[str] = [
    "god", "hell", "ass", "damn", "damnation", "whore", "prick", "pricks", "sodom",
]

profanity.load_censor_words(custom_words=_CUSTOM_TERMS, whitelist_words=_WHITELIST_TERMS)


class ContentRejected(Exception):
    """Raised with the name of the first field found to contain objectionable content."""

    def __init__(self, field: str):
        self.field = field
        super().__init__(f"Objectionable content detected in '{field}'")


def check_clean(**fields: str | None) -> None:
    """Raise ContentRejected(field) for the first field containing objectionable
    content. Blank/None fields are skipped (nothing to check)."""
    for field, text in fields.items():
        if text and profanity.contains_profanity(text):
            raise ContentRejected(field)
