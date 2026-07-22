import logging
from fastapi import APIRouter, Depends
from pydantic import BaseModel
from schemas.filter import Filter, Sort
from backend.filters.filter_notes import Filters, Sorting
from backend.auth.dependencies import get_current_user

logger = logging.getLogger(__name__)

filter_router  = APIRouter(prefix="/filter")
sorting_router = APIRouter(prefix="/sort")


class FilterRequest(BaseModel):
    notes:     dict
    to_filter: Filter


class SortRequest(BaseModel):
    notes:   dict
    to_sort: Sort


@filter_router.post("/")
async def filter_notes(req: FilterRequest, _: str = Depends(get_current_user)) -> dict:
    """Apply a filter to a collection of notes.

    Exactly one filter criterion from ``req.to_filter`` is applied (book,
    date, users, or title). If none is set, the original notes are returned
    unchanged.

    Args:
        req: Request body containing the flat notes dict and a ``Filter``
            specifying which criterion to apply.

    Returns:
        dict: Filtered subset of notes in the same structure as the input.
    """
    logger.info("POST /filter/ — %d uid(s), filter=%s", len(req.notes), req.to_filter)
    filter_manager = Filters(req.notes)
    if req.to_filter.book:
        return filter_manager.filter_book(req.to_filter.book)
    elif req.to_filter.date:
        return filter_manager.filter_date(req.to_filter.date)
    elif req.to_filter.users:
        return filter_manager.filter_users(req.to_filter.users)
    elif req.to_filter.title:
        return filter_manager.filter_title(req.to_filter.title)
    else:
        logger.info("no filter set, returning original notes")
        return req.notes


@sorting_router.post("/")
async def sort_notes(req: SortRequest, _: str = Depends(get_current_user)) -> dict:
    """Sort a flat collection of notes by the specified criterion.

    Currently supports date-based sorting. If no sort criterion is provided
    the notes are returned in their original insertion order.

    Args:
        req: Request body containing the flat notes dict (note_id -> note
            data) and a ``Sort`` specifying the sort direction.

    Returns:
        dict: Notes dict in sorted order.
    """
    sort_manager = Sorting(req.notes)
    if req.to_sort.date is not None:
        new_notes = sort_manager.sort_date(req.to_sort.date)
    else:
        new_notes = req.notes
    return new_notes
