from schemas.users import Note, User
from schemas.filter import Sort, Filter
import os
import json
import logging
from datetime import datetime

logger = logging.getLogger(__name__)

class Filters:
    def __init__(self, notes: dict): #takes pre-processed notes with usernames instead of uids
        self.notes = notes
        self.date_format = "%Y-%m-%d %H:%M:%S.%f"

    def filter_note(self):
        
        for uid, n_data in self.notes.items():
            if not isinstance(n_data, dict):
                continue
            for nid, data in n_data.items():
                yield uid, nid, Note(**data), data

    def _collect(self, predicate):
        result = {}
        logger.info("filtering %d uid(s): %s", len(self.notes), list(self.notes.keys()))
        for uid, nid, note, data in self.filter_note():
            logger.info("note title=%r user=%r verses=%s", note.title, note.user, note.verses)
            if not predicate(note):
                logger.info("  -> filtered out")
                continue
            logger.info("  -> matched")
            result.setdefault(uid, {})[nid] = data
        logger.info("filter result: %d notes", sum(len(v) for v in result.values()))
        return result

    def filter_users(self, users: list):
        logger.info("filter_users: %s", users)
        return self._collect(lambda note: note.user in users)

    def filter_date(self, date: str):
        logger.info("filter_date: %s", date)
        target = date[:10]  # compare YYYY-MM-DD only
        return self._collect(
            lambda note: note.timestamp[:10] == target
        )

    def filter_book(self, book: str):
        logger.info("filter_book: %s", book)
        return self._collect(
            lambda note: (
                (bool(note.verses[0]) and book.lower() in note.verses[0][0].lower()) or
                (bool(note.verses[1]) and book.lower() in note.verses[1][0].lower())
            )
        )

    def filter_title(self, title: str):
        logger.info("filter_title: %s", title)
        return self._collect(lambda note: title.lower() in note.title.lower())
            
class Sorting:
    def __init__(self, notes: dict):
        self.notes = notes
        self.date_format = "%Y-%m-%d %H:%M:%S.%f"

    def quicksort(self, notes_arr: list[tuple]) -> list:
        if len(notes_arr) <= 1:
            return notes_arr

        pivot = notes_arr[len(notes_arr) // 2][1]  # compare by datetime, not the whole pair
        left:   list = [[x, y] for x, y in notes_arr if y < pivot]
        middle: list = [[x, y] for x, y in notes_arr if y == pivot]
        right:  list = [[x, y] for x, y in notes_arr if y > pivot]
        return (self.quicksort(left) +
                self.quicksort(middle) +
                self.quicksort(right))

    def sort_date(self, descending: bool):
        date_list = []
        for nid, data in self.notes.items():
            note = Note(**data)
            date_list.append([nid, datetime.strptime(note.timestamp, self.date_format)])

        print(f"sorting list of {len(date_list)} dates: {date_list}")
        sorted_list = self.quicksort(date_list)
        print(f"length of sorted list: {len(sorted_list)}")
        if descending:
            sorted_list = sorted_list[::-1]

        note_sorted = {}
        for nid, _ in sorted_list:
            print(f"note in order: {self.notes[nid].get("title")}, {self.notes[nid].get("timestamp")}")
            note_sorted[nid] = self.notes[nid]
        return note_sorted