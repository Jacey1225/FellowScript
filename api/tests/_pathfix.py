"""Import this first, before any top-level api/ module (db, main, routes.*,
backend.*), in every file under api/tests/. Test scripts run as plain files
(``python tests/test_x.py``), not via pytest, so there's no conftest.py-style
auto-path-setup — Python only puts this script's own directory (tests/) on
sys.path, not api/ itself, which breaks every ``from db import ...``-style
import. Adding api/ to sys.path here, once, keeps that fix in one place
instead of repeated boilerplate in every test file.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
