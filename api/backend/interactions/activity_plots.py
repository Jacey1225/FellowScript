"""Server-side matplotlib rendering for the admin Activity Monitoring panel
(task 20260918-admin-activity-monitoring, step 2).

`matplotlib.use("Agg")` must run before `pyplot` is ever imported -- this
process has no display, and the default backend probes for one at import
time and fails loudly on a headless server without this. Set once here, at
this module's own import time, rather than left to whichever route imports
it first.

Styling (UI/UX Design Philosophy Q16): pulls the same dark/gold/parchment
palette the rest of the app uses (frontend/src/styles/global.css's
`--bg-page`/`--card-bg`/`--gold`/`--gold-dim`/`--parchment` tokens,
hand-copied here since Python can't read a CSS custom property file) rather
than matplotlib's default light/blue chart chrome -- this was backend's
first pass; design step 3 (dataviz skill's `validate_palette.js`) refined
the two-series visits palette below. Only this module changed for that
refinement, not the routes/manager calling it, per backend's own note.

Design step 3 accessibility finding: `_GOLD` (#FFC61A) vs `_GOLD_DIM`
(#C99A10) -- the pair backend's first pass used to color-distinguish the
visits chart's two series -- fails the dataviz skill's normal-vision-floor
check hard (ΔE 14.6, below the 15 floor: full-color-vision readers cannot
reliably tell them apart by color alone, and this floor is NOT waived by
secondary encoding, unlike the CVD 6-8 band). Re-picked the second series
color as `_ACCENT` (#C98A4B, the existing warm secondary accent already
used for the reader icon-rail's active state in global.css -- not a new
color, not a reserved status color) instead of introducing an off-brand
hue. Validated via
`dataviz` skill's `scripts/validate_palette.js "#FFC61A,#C98A4B" --mode
dark --surface "#1A1A1C"`: normal-vision floor ΔE 18.8 (pass), CVD
separation 14.9-18.5 (pass). The "lightness band" / "chroma floor" checks
that script also runs still fail for `_GOLD` itself (it's a deliberately
very bright, highly saturated brand accent used everywhere in this app,
not a generic chart hue) -- an intentional, documented brand-fidelity
deviation per the intake spec's Q16 ("room to bend a data-viz convention
for the visual identity's sake"), not an oversight; the two hard
accessibility floors (normal-vision, CVD) are what must never be waived,
and both now pass.

This module still only produces static PNGs, not an interactive chart --
security step 1 / backend step 2 already decided images-not-JSON for the
Cache-Control/no-store, PII-adjacent-data reasoning, so the dataviz
skill's default "ship a hover/tooltip layer" guidance is a deliberate,
already-made architectural tradeoff this step doesn't reopen. Design step
3's design-notes.md covers the frontend-side accessibility compensation
(alt text, a text legend under each image) instead.
"""
import io

import matplotlib

matplotlib.use("Agg")

from datetime import date  # noqa: E402

import matplotlib.dates as mdates  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

# Hand-copied from frontend/src/styles/global.css's :root tokens -- see
# module docstring for why these can't just be imported/read from that file.
_BG_PAGE = "#0A0A0A"
_CARD_BG = "#1A1A1C"
_GOLD = "#FFC61A"
_GOLD_DIM = "#C99A10"
_PARCHMENT = "#F2F2F2"
# Existing warm secondary accent (global.css .icon-chip.active .icon-chip-icon
# background) -- design step 3's replacement for `_GOLD_DIM` as the visits
# chart's second series color; see module docstring for the accessibility
# finding that motivated the swap.
_ACCENT = "#C98A4B"

_FIGSIZE = (8, 3.2)
_DPI = 150
# Mark spec (dataviz skill references/marks-and-anatomy.md): markers legible
# at a glance rather than backend's first-pass markersize=3 (~6px at this
# DPI, under the >=8px-equivalent guidance).
_MARKER_SIZE = 5
_LINE_WIDTH = 2.2


def _new_axes():
    fig, ax = plt.subplots(figsize=_FIGSIZE, dpi=_DPI)
    fig.patch.set_facecolor(_BG_PAGE)
    ax.set_facecolor(_CARD_BG)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.spines["left"].set_color(_GOLD_DIM)
    ax.spines["bottom"].set_color(_GOLD_DIM)
    ax.tick_params(colors=_PARCHMENT, labelsize=8)
    ax.grid(True, axis="y", color=_GOLD_DIM, alpha=0.15, linewidth=0.6)
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%b %d"))
    fig.autofmt_xdate(rotation=30)
    return fig, ax


def _finish(fig, ax, title: str, ylabel: str) -> bytes:
    # Serif title (gesturing at the app's Playfair Display headline
    # convention -- a real web font file isn't available to a headless
    # matplotlib render, so this falls back to the platform's own serif,
    # design step 3) plus generous `pad`/`tight_layout` padding for the
    # "spacious, breathing-room" layout default (Q16) even on a dense
    # data-bearing panel.
    ax.set_title(title, color=_PARCHMENT, fontsize=12, fontfamily="serif", fontweight="bold", pad=14, loc="left")
    ax.set_ylabel(ylabel, color=_PARCHMENT, fontsize=9)
    fig.tight_layout(pad=1.6)
    buf = io.BytesIO()
    fig.savefig(buf, format="png", facecolor=fig.get_facecolor())
    plt.close(fig)
    buf.seek(0)
    return buf.getvalue()


def render_line_chart(series: list[tuple[date, float]], title: str, ylabel: str) -> bytes:
    """Render one gold line-chart PNG (average-per-user metrics: notes,
    highlights, logins, messages) and return its raw bytes.

    `series` is a list of (day, value) tuples in day order, e.g. from
    `ActivityMonitoringManager.daily_average_per_user`.
    """
    days = [d for d, _ in series]
    values = [v for _, v in series]
    fig, ax = _new_axes()
    ax.plot(days, values, color=_GOLD, linewidth=_LINE_WIDTH, marker="o", markersize=_MARKER_SIZE)
    ax.fill_between(days, values, color=_GOLD, alpha=0.1)
    return _finish(fig, ax, title, ylabel)


def render_visits_chart(
    raw: list[tuple[date, int]], unique: list[tuple[date, int]], title: str
) -> bytes:
    """Render the raw-visits-vs-unique-device-visitors dual-line PNG and
    return its raw bytes.

    `raw` and `unique` are same-length, same-day-order (day, count) lists
    from `ActivityMonitoringManager.daily_visits` -- visually distinguished
    by both color AND shape/line-style (never color alone, dataviz skill's
    accessibility check 6), plus an explicit legend, per the acceptance
    criteria that these two figures be "visibly distinguished," never
    collapsed into one number.

    Color assignment (design step 3): `_GOLD` (the brand's single most
    saturated accent) goes to "Unique devices" -- the headline, corrected
    audience number an admin actually cares about -- and the quieter
    `_ACCENT` goes to "Raw visits," the denominator/context figure.
    `_GOLD` vs the original `_GOLD_DIM` pairing failed the dataviz skill's
    validator hard (normal-vision ΔE 14.6, below the 15 floor -- see module
    docstring); `_GOLD` vs `_ACCENT` passes (ΔE 18.8). Solid circle vs
    dashed square markers are kept as a secondary (non-color) encoding on
    top of that fixed color pair, not as a substitute for it.
    """
    days = [d for d, _ in raw]
    raw_values = [v for _, v in raw]
    unique_values = [v for _, v in unique]
    fig, ax = _new_axes()
    ax.plot(days, raw_values, color=_ACCENT, linewidth=_LINE_WIDTH, marker="o", markersize=_MARKER_SIZE, label="Raw visits")
    ax.plot(
        days, unique_values, color=_GOLD, linewidth=_LINE_WIDTH, linestyle="--",
        marker="s", markersize=_MARKER_SIZE, label="Unique devices",
    )
    legend = ax.legend(loc="upper left", frameon=False, fontsize=8)
    for text in legend.get_texts():
        text.set_color(_PARCHMENT)
    return _finish(fig, ax, title, "Visits")
