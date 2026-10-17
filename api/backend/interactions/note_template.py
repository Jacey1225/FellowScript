"""Per-schedule note templates for scheduled devotion notes (task
20261017-devotion-note-format).

A scheduled event's own standing prompt decides what its notes look like, and
that differs from schedule to schedule. The model used to write each day's
note as free-form ``text``, so one schedule's notes drifted day to day in
whitespace, heading markup, colons, quote style and where the scripture
reference sat. This module fixes that without imposing one layout:

  * ``validate_template`` strictly validates a template (derived ONCE from the
    schedule's prompt by a model call, then stored on the schedule). The
    template is untrusted model output, so it is checked at the boundary and
    rejected, never repaired.
  * ``build_note_prompt`` asks the model for structured fields keyed to the
    template; the model never decides formatting.
  * ``validate_fields`` checks one day's fields against the template (throw,
    never fabricate) so the caller can retry within its bounded retry.
  * ``render_note`` is the ONLY producer of a scheduled note's stored text:
    plain text, newlines and blank-line separators, no HTML, no markdown, so
    it reads correctly on web (escHtml + pre-wrap) and iOS (HTML conversion
    maps newlines to line breaks).
  * the per-day content contract (passage, theme, check-in rule, section
    lengths) used by the timeline plan lives here too.

Pure module: no database or network access. All limits are code constants.
"""
import hashlib
import json
import re
from typing import Optional

TEMPLATE_VERSION = 1

KIND_STRUCTURED = "structured"
KIND_FREEFORM = "freeform"

LAYOUT_HEADING = "heading"      # "Title\nvalue"
LAYOUT_LABEL = "label"          # "Title: value"
LAYOUT_PARAGRAPH = "paragraph"  # "value" (no title)
_LAYOUTS = (LAYOUT_HEADING, LAYOUT_LABEL, LAYOUT_PARAGRAPH)

FIELD_TEXT = "text"
FIELD_QUOTE = "quote"
FIELD_REFERENCE = "reference"
FIELD_LIST = "list"
FIELD_SCRIPTURE = "scripture"   # a reference plus quoted passage text
_FIELD_KINDS = (FIELD_TEXT, FIELD_QUOTE, FIELD_REFERENCE, FIELD_LIST, FIELD_SCRIPTURE)
_REFERENCE_KINDS = (FIELD_REFERENCE, FIELD_SCRIPTURE)

ROLE_CHECK_IN = "check_in"
ROLE_APPLICATION = "application"
_ROLES = (ROLE_CHECK_IN, ROLE_APPLICATION)

TITLE_FREE = "free"        # the model writes the title
TITLE_PATTERN = "pattern"  # built from {theme} / {reference}

MAX_SECTIONS = 12
MAX_SECTION_TITLE_CHARS = 60
MIN_WORDS, MAX_WORDS = 3, 600
MAX_LIST_ITEMS = 10
MAX_TITLE_CHARS = 100
MAX_TITLE_PATTERN_CHARS = 80
MAX_TEMPLATE_JSON_CHARS = 8000
MAX_THEME_CHARS = 100
MAX_VERSES_IN_RANGE = 60
LENGTH_HARD_FACTOR = 1.5  # validation rejects only above this x the target
RESERVED_KEYS = frozenset({"title", "theme", "verses", "__action"})
NOTE_ACTION = "create_note"

CHECK_IN_FOLLOW_UP = "follow_up_previous_application"
CHECK_IN_THEME = "theme_question"
_CHECK_IN_RULES = (CHECK_IN_FOLLOW_UP, CHECK_IN_THEME)

_KEY_RE = re.compile(r"^[a-z][a-z0-9_]{0,23}$")
_PLACEHOLDER_RE = re.compile(r"\{([a-z_]+)\}")
_HTML_TAG_RE = re.compile(r"</?[A-Za-z!][^>]*>")
_ENTITY_RE = re.compile(r"&#?\w+;")
_MD_LINE_START_RE = re.compile(r"(?m)^[ \t]*(?:#{1,6}[ \t]+|>[ \t]?|[-*+•][ \t]+|\d+[.)][ \t]+)")
_TITLE_BAD_CHARS_RE = re.compile(r"[<>*`#\n\r\t{}]")
_GENERIC_CHECK_IN_RE = re.compile(r"check[\s-]*in with (the )?group", re.IGNORECASE)
_REFERENCE_RE = re.compile(
    r"^(?P<book>(?:[1-3]\s+)?[A-Za-z][A-Za-z.]*(?:\s+[A-Za-z][A-Za-z.]*)*)\s+"
    r"(?P<c1>\d{1,3}):(?P<v1>\d{1,3})"
    r"(?:\s*[-–—]\s*(?:(?P<c2>\d{1,3}):)?(?P<v2>\d{1,3}))?$"
)

# The explicit outcome of derivation for a prompt with no clear structure.
FREEFORM_TEMPLATE = {
    "version": TEMPLATE_VERSION,
    "kind": KIND_FREEFORM,
    "title": {"mode": TITLE_FREE},
    "sections": [{
        "key": "text", "title": None, "layout": LAYOUT_PARAGRAPH, "kind": FIELD_TEXT,
        "role": None, "max_words": MAX_WORDS, "paragraphs": True,
    }],
}


class TemplateValidationError(ValueError):
    """A derived or stored template is malformed. Raised, never repaired."""


class NoteValidationError(ValueError):
    """The model's fields for a day's note were missing, empty, malformed or
    over length. The message is safe to hand back to the model on a retry."""


def prompt_hash(prompt: str) -> str:
    return hashlib.sha256((prompt or "").encode("utf-8")).hexdigest()


# ── Text cleaning (model output is untrusted) ────────────────────────────────

def _strip_markup(value: str) -> str:
    """Remove HTML tags/entities and markdown syntax; keep the words."""
    v = re.sub(r"(?i)<br\s*/?>", "\n", value)
    v = re.sub(r"(?i)</p\s*>", "\n\n", v)
    v = _HTML_TAG_RE.sub(" ", v)
    v = _ENTITY_RE.sub(" ", v)
    v = v.replace("<", " ").replace(">", " ")
    v = _MD_LINE_START_RE.sub("", v)
    v = v.replace("**", "").replace("__", "").replace("`", "").replace("~~", "")
    return v


def _normalize_quotes(text: str) -> str:
    """One quote style: straight double quotes become curly pairs, apostrophes
    become typographic."""
    out = []
    for i, ch in enumerate(text):
        prev = text[i - 1] if i else " "
        if ch == '"':
            at_open = prev.isspace() or prev in "([{—-‘'“"
            out.append("“" if at_open else "”")
        elif ch == "'":
            out.append("‘" if (prev.isspace() or prev in "([{“") else "’")
        else:
            out.append(ch)
    return "".join(out)


def _strip_wrapping_quotes(text: str) -> str:
    quotes = "\"“”„"
    while len(text) >= 2 and text[0] in quotes and text[-1] in quotes:
        text = text[1:-1].strip()
    return text


def _clean_line(name: str, value, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        raise NoteValidationError(f"{name} is missing or not a string")
    cleaned = " ".join(_strip_markup(value).split())
    if not cleaned and not allow_empty:
        raise NoteValidationError(f"{name} is empty")
    return _normalize_quotes(cleaned)


def _clean_paragraphs(name: str, value) -> str:
    if not isinstance(value, str):
        raise NoteValidationError(f"{name} is missing or not a string")
    paras = [" ".join(p.split()) for p in re.split(r"\n\s*\n", _strip_markup(value))]
    paras = [p for p in paras if p]
    if not paras:
        raise NoteValidationError(f"{name} is empty")
    return _normalize_quotes("\n\n".join(paras))


def _words(text: str) -> int:
    return len(text.split())


# ── Reference handling ───────────────────────────────────────────────────────

def parse_reference(reference: str) -> tuple[str, int, int, int, int]:
    m = _REFERENCE_RE.match(" ".join(str(reference or "").split()))
    if not m:
        raise NoteValidationError(
            f"reference {reference!r} must be a single passage like 'Romans 8:1-4' (no translation label)"
        )
    c1, v1 = int(m["c1"]), int(m["v1"])
    c2 = int(m["c2"]) if m["c2"] else c1
    v2 = int(m["v2"]) if m["v2"] else v1
    if (c2, v2) < (c1, v1):
        raise NoteValidationError(f"reference {reference!r} ends before it starts")
    if c2 == c1 and v2 - v1 + 1 > MAX_VERSES_IN_RANGE:
        raise NoteValidationError(f"reference {reference!r} spans too many verses")
    return m["book"], c1, v1, c2, v2


def canonical_reference(reference: str) -> str:
    book, c1, v1, c2, v2 = parse_reference(reference)
    book = " ".join(book.split())
    if (c1, v1) == (c2, v2):
        return f"{book} {c1}:{v1}"
    if c1 == c2:
        return f"{book} {c1}:{v1}-{v2}"
    return f"{book} {c1}:{v1}-{c2}:{v2}"


def verses_from_reference(reference: str) -> list[list]:
    """note_verses triples from a reference. A cross-chapter range yields only
    its two endpoints (verse counts per chapter are unknown here and inventing
    the middle would be fabrication)."""
    book, c1, v1, c2, v2 = parse_reference(reference)
    book = " ".join(book.split())
    if c1 == c2:
        return [[book, c1, v] for v in range(v1, v2 + 1)]
    return [[book, c1, v1], [book, c2, v2]]


# ── Template validation ──────────────────────────────────────────────────────

def _req(cond: bool, msg: str) -> None:
    if not cond:
        raise TemplateValidationError(msg)


def _reference_section(template: dict) -> Optional[dict]:
    return next((s for s in template["sections"] if s["kind"] in _REFERENCE_KINDS), None)


def section_with_role(template: dict, role: str) -> Optional[dict]:
    return next((s for s in template["sections"] if s.get("role") == role), None)


def is_freeform(template: dict) -> bool:
    return template["kind"] == KIND_FREEFORM


def validate_template(raw) -> dict:
    """Validate a template (parsed JSON) and return the normalized dict.
    ``{"kind": "freeform"}`` expands to FREEFORM_TEMPLATE. Raises
    TemplateValidationError on the first problem."""
    _req(isinstance(raw, dict), "template is not a JSON object")
    try:
        _req(len(json.dumps(raw)) <= MAX_TEMPLATE_JSON_CHARS, "template is too large")
    except (TypeError, ValueError) as e:
        raise TemplateValidationError(f"template is not JSON-serializable: {e}") from e
    kind = raw.get("kind")
    _req(kind in (KIND_STRUCTURED, KIND_FREEFORM), "kind must be 'structured' or 'freeform'")
    if "version" in raw:
        _req(raw["version"] == TEMPLATE_VERSION, f"unsupported template version {raw['version']!r}")
    if kind == KIND_FREEFORM:
        return json.loads(json.dumps(FREEFORM_TEMPLATE))

    sections_raw = raw.get("sections")
    _req(isinstance(sections_raw, list) and 1 <= len(sections_raw) <= MAX_SECTIONS,
         f"sections must be a list of 1 to {MAX_SECTIONS}")
    sections, keys, roles = [], set(), set()
    for i, s in enumerate(sections_raw):
        _req(isinstance(s, dict), f"section {i} is not an object")
        key = s.get("key")
        _req(isinstance(key, str) and _KEY_RE.match(key), f"section {i}: invalid key {key!r}")
        _req(key not in RESERVED_KEYS, f"section {i}: key {key!r} is reserved")
        _req(key not in keys, f"duplicate section key {key!r}")
        keys.add(key)
        layout = s.get("layout")
        _req(layout in _LAYOUTS, f"section {key}: layout must be one of {_LAYOUTS}")
        fkind = s.get("kind")
        _req(fkind in _FIELD_KINDS, f"section {key}: kind must be one of {_FIELD_KINDS}")
        title = s.get("title")
        if layout == LAYOUT_PARAGRAPH:
            _req(title in (None, ""), f"section {key}: a paragraph section has no title")
            title = None
        else:
            _req(isinstance(title, str) and title.strip(), f"section {key}: title is required for {layout}")
            title = " ".join(title.split())
            _req(len(title) <= MAX_SECTION_TITLE_CHARS, f"section {key}: title too long")
            _req(not _TITLE_BAD_CHARS_RE.search(title), f"section {key}: title has disallowed characters")
        role = s.get("role")
        _req(role in (None,) + _ROLES, f"section {key}: unknown role {role!r}")
        if role:
            _req(role not in roles, f"role {role!r} used by more than one section")
            _req(fkind == FIELD_TEXT, f"section {key}: role {role!r} needs kind 'text'")
            roles.add(role)
        mw = s.get("max_words")
        _req(isinstance(mw, int) and not isinstance(mw, bool) and MIN_WORDS <= mw <= MAX_WORDS,
             f"section {key}: max_words must be an integer {MIN_WORDS}-{MAX_WORDS}")
        sections.append({"key": key, "title": title, "layout": layout, "kind": fkind,
                         "role": role, "max_words": mw, "paragraphs": False})
    _req(sum(1 for s in sections if s["kind"] in _REFERENCE_KINDS) <= 1,
         "at most one reference/scripture section is allowed")

    title_raw = raw.get("title")
    _req(isinstance(title_raw, dict), "title must be an object")
    mode = title_raw.get("mode")
    _req(mode in (TITLE_FREE, TITLE_PATTERN), "title.mode must be 'free' or 'pattern'")
    title_cfg: dict = {"mode": mode}
    has_ref = any(s["kind"] in _REFERENCE_KINDS for s in sections)
    if mode == TITLE_PATTERN:
        pattern = title_raw.get("pattern")
        _req(isinstance(pattern, str) and pattern.strip(), "title.pattern is required")
        pattern = " ".join(pattern.split())
        _req(len(pattern) <= MAX_TITLE_PATTERN_CHARS, "title.pattern too long")
        names = _PLACEHOLDER_RE.findall(pattern)
        _req(names, "title.pattern must use {theme} and/or {reference}")
        allowed = {"theme", "reference"} if has_ref else {"theme"}
        _req(all(n in allowed for n in names), f"title.pattern placeholders must be within {sorted(allowed)}")
        residue = _PLACEHOLDER_RE.sub("", pattern)
        _req(not _TITLE_BAD_CHARS_RE.search(residue), "title.pattern has disallowed characters")
        title_cfg["pattern"] = pattern
    return {"version": TEMPLATE_VERSION, "kind": KIND_STRUCTURED, "title": title_cfg, "sections": sections}


def load_stored_template(raw: Optional[str]) -> Optional[dict]:
    """Decode+revalidate a stored column value. None if absent or no longer
    valid (the caller then re-derives; it never uses an unvalidated template)."""
    if not raw:
        return None
    try:
        return validate_template(json.loads(raw))
    except (ValueError, TypeError):
        return None


def dump_template(template: dict) -> str:
    return json.dumps(template, separators=(",", ":"), ensure_ascii=False)


# ── Day content contract ─────────────────────────────────────────────────────

def wants_contract(template: Optional[dict]) -> bool:
    """Structured templates get a per-day object plan; freeform keeps plain
    string instructions."""
    return bool(template) and not is_freeform(template)


def template_lengths(template: dict) -> dict:
    return {s["key"]: s["max_words"] for s in template["sections"]}


def build_day_entry(raw, template: dict, check_in_rule: Optional[str]):
    """Validate a timeline-agent day entry against the template and return the
    entry to store. Freeform: a plain instruction string. Structured: a dict
    carrying only what the template's sections need. Raises NoteValidationError
    on a malformed entry so the planner can retry."""
    if not wants_contract(template):
        if not isinstance(raw, (str, dict)):
            raise NoteValidationError("day entry must be a string")
        text = raw if isinstance(raw, str) else raw.get("instruction")
        text = " ".join(str(text or "").split())
        if not text:
            raise NoteValidationError("day entry is empty")
        return text
    if not isinstance(raw, dict):
        raise NoteValidationError("day entry must be an object with instruction/theme fields")
    instruction = " ".join(str(raw.get("instruction") or "").split())
    theme = " ".join(_strip_markup(str(raw.get("theme") or "")).split())
    if not instruction:
        raise NoteValidationError("day entry has no instruction")
    if not theme or len(theme) > MAX_THEME_CHARS:
        raise NoteValidationError("day entry needs a short theme")
    entry = {"instruction": instruction, "theme": theme, "lengths": template_lengths(template)}
    if _reference_section(template):
        entry["passage"] = canonical_reference(str(raw.get("passage") or ""))
    if section_with_role(template, ROLE_CHECK_IN):
        entry["check_in_rule"] = check_in_rule if check_in_rule in _CHECK_IN_RULES else CHECK_IN_THEME
    return entry


def normalize_day(raw, template: Optional[dict]) -> Optional[dict]:
    """A stored timeline day (dict contract, legacy plain string, or empty)
    as {"instruction","passage","theme","check_in_rule","lengths"} or None.
    Tolerant on purpose: this is stored data, and a legacy or partly-stale
    entry must keep working (missing parts are simply absent)."""
    if raw is None or raw == "":
        return None
    if isinstance(raw, str):
        return {"instruction": raw.strip(), "passage": None, "theme": None,
                "check_in_rule": None, "lengths": {}}
    if not isinstance(raw, dict):
        return None
    passage = None
    if raw.get("passage"):
        try:
            passage = canonical_reference(str(raw["passage"]))
        except NoteValidationError:
            passage = None
    lengths = {}
    for k, v in (raw.get("lengths") or {}).items():
        if isinstance(k, str) and isinstance(v, int) and not isinstance(v, bool) and MIN_WORDS <= v <= MAX_WORDS:
            lengths[k] = v
    rule = raw.get("check_in_rule")
    return {
        "instruction": str(raw.get("instruction") or "").strip(),
        "passage": passage,
        "theme": " ".join(str(raw.get("theme") or "").split()) or None,
        "check_in_rule": rule if rule in _CHECK_IN_RULES else None,
        "lengths": lengths,
    }


def effective_check_in_rule(day: Optional[dict], prior_application: Optional[str]) -> str:
    """Follow up on the previous note's application whenever a real one is
    on record; otherwise a theme-tied question. Never filler, never an
    invented 'last time you ...'. The plan's stored rule is the planner's
    expectation (the very first day of a schedule has nothing to follow up
    on); the recorded application is what actually decides."""
    if prior_application and prior_application.strip():
        return CHECK_IN_FOLLOW_UP
    return CHECK_IN_THEME


def _section_limit(section: dict, day: Optional[dict]) -> int:
    v = ((day or {}).get("lengths") or {}).get(section["key"])
    return v if isinstance(v, int) else section["max_words"]


# ── Prompt ───────────────────────────────────────────────────────────────────

def describe_for_planner(template: dict) -> str:
    """The NOTE LAYOUT block appended to the timeline-planning request."""
    lines = ["NOTE LAYOUT: each day's note will have these sections (in order):"]
    for s in template["sections"]:
        lines.append(f"- {s['key']} ({s['kind']}{', ' + s['role'] if s.get('role') else ''})")
    need = ['"instruction": what the note covers that day', '"theme": a few words naming the day\'s theme']
    if _reference_section(template):
        need.append('"passage": ONE contiguous passage like "Romans 8:1-4" (no translation label), '
                    "never repeated across days or already covered")
    lines.append("Every entry in \"days\" must be an object with: " + "; ".join(need) + ".")
    return "\n".join(lines)


def build_note_prompt(
    standing_prompt: str, template: dict, day: Optional[dict], prior_application: Optional[str],
) -> str:
    """The note-writing request for one scheduled fire. Structure is fixed by
    the template; the user's standing prompt only steers content and tone."""
    parts = [
        "STANDING REQUEST FROM THE USER (guidance on content and tone only; the platform formats the "
        f"note, so do not add numbering, headings or markup of your own):\n{standing_prompt}"
    ]
    instruction = (day or {}).get("instruction")
    if day and (day.get("passage") or day.get("theme")):
        bits = []
        if day.get("passage"):
            bits.append(f"passage {day['passage']}")
        if day.get("theme"):
            bits.append(f"theme \"{day['theme']}\"")
        parts.append(
            f"TODAY'S PLANNED CONTENT (from this event's timeline): {'; '.join(bits)}; focus: {instruction}\n"
            "STRICT RULE: write about exactly this planned content. Do not substitute other content or "
            "cover material assigned to a different day."
        )
    elif instruction:
        parts.append(
            f"TODAY'S PLANNED CONTENT (from this event's current timeline instruction): {instruction}\n"
            "STRICT RULE: Base your note specifically on today's planned content above -- do not substitute "
            "different content, and do not cover material assigned to a different day of this event's timeline."
        )
    else:
        parts.append("No day-specific timeline instruction found for today — respond directly to the request above.")

    check_in = section_with_role(template, ROLE_CHECK_IN)
    if check_in:
        if effective_check_in_rule(day, prior_application) == CHECK_IN_FOLLOW_UP:
            parts.append(
                f"CHECK-IN RULE: \"{check_in['key']}\" is one real question asking how the reader got on "
                f"with the application from the previous note, which was: {prior_application.strip()}"
            )
        else:
            parts.append(
                f"CHECK-IN RULE: \"{check_in['key']}\" is one real question, tied to today's theme, that "
                "invites the reader to reflect or share. Do not refer to any earlier note."
            )

    shape = [f'  "__action": "{NOTE_ACTION}"']
    if template["title"]["mode"] == TITLE_FREE:
        shape.append('  "title": "<concise plain-text title>"')
    shape.append('  "theme": "<a few words naming the note\'s central theme>"')
    for s in template["sections"]:
        limit = _section_limit(s, day)
        if s["kind"] == FIELD_SCRIPTURE:
            val = '{"reference": "<one passage like \'Romans 8:1-4\', no translation label>", "text": "<the passage text exactly, no surrounding quotation marks>"}'
        elif s["kind"] == FIELD_REFERENCE:
            val = '"<one passage like \'Romans 8:1-4\', no translation label>"'
        elif s["kind"] == FIELD_LIST:
            val = f'["<item>", "<item>"]  (1-{MAX_LIST_ITEMS} items)'
        elif s["kind"] == FIELD_QUOTE:
            val = '"<quoted text, no surrounding quotation marks>"'
        else:
            val = '"<plain text>"'
        what = f" -- {s['title']}" if s["title"] else ""
        shape.append(f'  "{s["key"]}": {val}  /* max {limit} words{what} */')
    if not _reference_section(template):
        shape.append('  "verses": [["<Book>", <chapter>, <verse>]]  /* optional: verses the note is about */')
    parts.append(
        "Respond with exactly one JSON object and nothing else:\n{\n" + ",\n".join(shape) + "\n}\n"
        "Every field is required except where marked optional. Plain text only: no HTML, no markdown, "
        "no bullet characters. Do not include the /* */ comments."
    )
    return "\n\n".join(parts)


# ── Validation ───────────────────────────────────────────────────────────────

def _verses_field(raw) -> list:
    if raw is None:
        return []
    if not isinstance(raw, list) or len(raw) > MAX_VERSES_IN_RANGE:
        raise NoteValidationError("verses must be a short list of [book, chapter, verse]")
    out = []
    for v in raw:
        if not (isinstance(v, list) and len(v) == 3 and isinstance(v[0], str) and v[0].strip()
                and all(isinstance(n, int) and not isinstance(n, bool) and n > 0 for n in v[1:])):
            raise NoteValidationError("verses entries must be [book, chapter, verse]")
        out.append([" ".join(v[0].split()), v[1], v[2]])
    return out


def validate_fields(data, template: dict, day: Optional[dict] = None) -> dict:
    """Validate the model's parsed JSON for one note and return clean values:
    {"title","theme","verses","values":{key: str | list[str] | {"reference","text"}}}.
    Raises NoteValidationError on the first problem; never invents content."""
    if not isinstance(data, dict):
        raise NoteValidationError("response is not a JSON object")
    if data.get("__action") != NOTE_ACTION:
        raise NoteValidationError(f"__action must be \"{NOTE_ACTION}\"")
    freeform = is_freeform(template)

    raw_theme = data.get("theme")
    if freeform and raw_theme is None:
        raw_theme = ""
    theme = _clean_line("theme", raw_theme, allow_empty=freeform)
    planned_theme = (day or {}).get("theme")
    if planned_theme:
        theme = _normalize_quotes(" ".join(_strip_markup(planned_theme).split()))
    if len(theme) > MAX_THEME_CHARS:
        raise NoteValidationError("theme is too long")

    values: dict = {}
    reference: Optional[str] = None
    planned = (day or {}).get("passage")
    for s in template["sections"]:
        key, fkind = s["key"], s["kind"]
        raw = data.get(key)
        limit = _section_limit(s, day)
        if fkind == FIELD_LIST:
            if not isinstance(raw, list) or not (1 <= len(raw) <= MAX_LIST_ITEMS):
                raise NoteValidationError(f"{key} must be a list of 1-{MAX_LIST_ITEMS} items")
            val = [_clean_line(f"{key} item", i) for i in raw]
            count = sum(_words(i) for i in val)
        elif fkind == FIELD_SCRIPTURE:
            if not isinstance(raw, dict):
                raise NoteValidationError(f"{key} must be an object with reference and text")
            ref = canonical_reference(_clean_line(f"{key}.reference", raw.get("reference")))
            body = _clean_line(f"{key}.text", raw.get("text"))
            body = _strip_wrapping_quotes(body)
            if not body:
                raise NoteValidationError(f"{key}.text is empty")
            val, count, reference = {"reference": ref, "text": body}, _words(body), ref
        elif fkind == FIELD_REFERENCE:
            ref = canonical_reference(_clean_line(key, raw))
            val, count, reference = ref, 0, ref
        elif fkind == FIELD_QUOTE:
            val = _strip_wrapping_quotes(_clean_line(key, raw))
            if not val:
                raise NoteValidationError(f"{key} is empty")
            count = _words(val)
        else:
            val = _clean_paragraphs(key, raw) if s.get("paragraphs") else _clean_line(key, raw)
            count = _words(val)
            if s.get("role") == ROLE_CHECK_IN and ("?" not in val or _GENERIC_CHECK_IN_RE.search(val)):
                raise NoteValidationError(f"{key} must be a real question, not a generic prompt")
        if count > limit * LENGTH_HARD_FACTOR:
            raise NoteValidationError(f"{key} is {count} words; the limit is {limit}")
        values[key] = val

    if reference and planned and canonical_reference(planned) != reference:
        raise NoteValidationError(f"the passage must be today's planned passage {canonical_reference(planned)}, got {reference}")

    tcfg = template["title"]
    if tcfg["mode"] == TITLE_PATTERN:
        title = tcfg["pattern"].replace("{theme}", theme)
        if "{reference}" in title:
            title = title.replace("{reference}", reference or "")
        if "{theme}" in tcfg["pattern"] and not theme:
            raise NoteValidationError("theme is required for this note's title")
        title = " ".join(title.split())
    else:
        title = _clean_line("title", data.get("title"))
    if not title or len(title) > MAX_TITLE_CHARS:
        raise NoteValidationError(f"title must be 1-{MAX_TITLE_CHARS} characters")

    verses = verses_from_reference(reference) if reference else _verses_field(data.get("verses"))
    return {"title": title, "theme": theme, "verses": verses, "values": values}


# ── Renderer ─────────────────────────────────────────────────────────────────

def _inner_quotes(text: str) -> str:
    """Double quotes inside a quoted passage become single (nested style)."""
    return text.replace("“", "‘").replace("”", "’")


def _render_value(section: dict, val) -> str:
    kind = section["kind"]
    if kind == FIELD_LIST:
        return "\n".join(f"• {i}" for i in val)
    if kind == FIELD_SCRIPTURE:
        return f"{val['reference']}\n“{_inner_quotes(val['text'])}”"
    if kind == FIELD_QUOTE:
        return f"“{_inner_quotes(val)}”"
    return val


def render_note(template: dict, fields: dict) -> str:
    """The single formatter for a scheduled note's stored text. ``fields`` is
    the output of validate_fields. Identical template + identical field
    values always produce identical text."""
    blocks = []
    for s in template["sections"]:
        body = _render_value(s, fields["values"][s["key"]])
        if s["layout"] == LAYOUT_HEADING:
            blocks.append(f"{s['title']}\n{body}")
        elif s["layout"] == LAYOUT_LABEL:
            sep = ":\n" if "\n" in body else ": "
            blocks.append(f"{s['title']}{sep}{body}")
        else:
            blocks.append(body)
    return "\n\n".join(blocks)


def note_data(template: dict, fields: dict) -> dict:
    """The dict note_via_hb persists."""
    return {
        "title": fields["title"], "text": render_note(template, fields),
        "theme": fields["theme"], "verses": fields["verses"],
    }


def application_text(template: dict, fields: dict) -> Optional[str]:
    """The application-role section's text (carried to the next day's check-in)."""
    s = section_with_role(template, ROLE_APPLICATION)
    return fields["values"][s["key"]] if s else None
