from schemas.users import Note
from schemas.filter import Sort, Filter
from typing import Generator
import logging
from datetime import datetime, timezone

logger = logging.getLogger(__name__)


class Filters:
    """Applies predicate-based filters to a nested notes structure.

    Expects notes pre-processed so that the top-level keys are usernames
    (not user IDs), matching the format returned by ``GroupsManager.fetch_notes()``.
    """

    def __init__(self, notes: dict) -> None:
        """Initialise with a username-keyed notes mapping.

        Args:
            notes: Mapping of username -> {note_id -> note data dict}.
        """
        self.notes = notes
        self.date_format = "%Y-%m-%d %H:%M:%S.%f"

    def filter_note(self) -> Generator[tuple[str, str, Note, dict], None, None]:
        """Yield each note as a (username, note_id, Note, raw_data) tuple.

        Iterates over the nested notes structure and constructs a ``Note``
        model for each entry, skipping any malformed top-level values.

        Yields:
            tuple: ``(username, note_id, Note instance, raw note data dict)``
        """
        for uid, n_data in self.notes.items():
            if not isinstance(n_data, dict):
                continue
            for nid, data in n_data.items():
                yield uid, nid, Note(**data), data

    def _collect(self, predicate) -> dict:
        """Return all notes for which ``predicate(note)`` is truthy.

        Args:
            predicate: Callable that accepts a ``Note`` and returns bool.

        Returns:
            dict: Filtered notes in the same nested structure as ``self.notes``.
        """
        result = {}
        debug = logger.isEnabledFor(logging.DEBUG)
        logger.info("filtering %d uid(s): %s", len(self.notes), list(self.notes.keys()))
        for uid, nid, note, data in self.filter_note():
            if debug:
                logger.debug("note title=%r user=%r verses=%s", note.title, note.user, note.verses)
            if not predicate(note):
                if debug:
                    logger.debug("  -> filtered out")
                continue
            if debug:
                logger.debug("  -> matched")
            result.setdefault(uid, {})[nid] = data
        logger.info("filter result: %d notes", sum(len(v) for v in result.values()))
        return result

    def filter_users(self, users: list[str]) -> dict:
        """Keep only notes authored by users in the given list.

        Args:
            users: List of user identifiers to match against ``note.user``.

        Returns:
            dict: Notes whose ``user`` field is in ``users``.
        """
        logger.info("filter_users: %s", users)
        return self._collect(lambda note: note.user in users)

    def filter_date(self, date: str) -> dict:
        """Keep only notes whose timestamp matches the given date (YYYY-MM-DD).

        Comparison is performed on the first 10 characters of the stored
        timestamp so that time-of-day is ignored.

        Args:
            date: Target date string in ``YYYY-MM-DD`` format.

        Returns:
            dict: Notes whose timestamp falls on the specified date.
        """
        logger.info("filter_date: %s", date)
        target = date[:10]
        return self._collect(
            lambda note: note.timestamp[:10] == target
        )

    def filter_book(self, book: str) -> dict:
        """Keep only notes that reference the given book in any verse entry.

        Performs a case-insensitive substring match against the book field
        of every verse in the note's verses list.

        Args:
            book: Book name or partial name to search for (case-insensitive).

        Returns:
            dict: Notes that reference the given book in at least one verse.
        """
        logger.info("filter_book: %s", book)
        def predicate(note):
            return any(
                v and book.lower() in str(v[0]).lower()
                for v in (note.verses or [])
            )
        return self._collect(predicate)

    def filter_title(self, title: str) -> dict:
        """Keep only notes whose title contains the given substring.

        Comparison is case-insensitive.

        Args:
            title: Substring to search for within note titles.

        Returns:
            dict: Notes whose title contains the given string.
        """
        logger.info("filter_title: %s", title)
        return self._collect(lambda note: title.lower() in note.title.lower())


class Sorting:
    """Sorts a flat note collection by various criteria."""

    def __init__(self, notes: dict) -> None:
        """Initialise with a flat note mapping.

        Args:
            notes: Flat mapping of note_id -> note data dict (not nested by user).
        """
        self.notes = notes

    def sort_date(self, descending: bool) -> dict:
        """Return notes sorted by their timestamp.

        Parses each note's ``timestamp`` field and sorts via Python's
        built-in ``sorted()`` (Timsort — guaranteed O(n log n), stable),
        then reverses if ``descending`` is ``True``.

        Args:
            descending: If ``True``, newest notes appear first; if ``False``,
                oldest notes appear first.

        Returns:
            dict: Notes mapping in sorted order (note_id -> note data).
        """
        date_list = []
        for nid, data in self.notes.items():
            note = Note(**data)
            try:
                # Postgres returns timezone-aware ISO strings (e.g. trailing
                # "-07:00"), which strptime's fixed naive format can't parse.
                dt = datetime.fromisoformat(note.timestamp)
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
            except (ValueError, TypeError):
                dt = datetime.min.replace(tzinfo=timezone.utc)
            date_list.append((nid, dt))

        date_list.sort(key=lambda pair: pair[1], reverse=descending)

        note_sorted = {}
        for nid, _ in date_list:
            note_sorted[nid] = self.notes[nid]
        return note_sorted
