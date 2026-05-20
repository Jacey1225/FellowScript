import logging
from fastapi import APIRouter
from pydantic import BaseModel
from schemas.filter import Filter, Sort
from backend.filters.filter_notes import Filters, Sorting

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
async def filter_notes(req: FilterRequest):
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
async def sort_notes(req: SortRequest):
    sort_manager = Sorting(req.notes)
    if req.to_sort.date is not None:
        new_notes = sort_manager.sort_date(req.to_sort.date)
    else:
        new_notes = req.notes
    return new_notes