"""Copy the affiliate resource files named in config/affiliates.json from the
repo ``data/`` directory into ``api/assets/affiliates/<key><ext>`` (the Docker
image ships only ``api/``). Idempotent; run from ``api/``:

    ../.venv/bin/python scripts/sync_affiliate_assets.py
"""
import shutil
import sys
from pathlib import Path

API = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API))

from backend.subscription.affiliates_config import ASSETS_DIR, get_affiliates_config  # noqa: E402

DATA = API.parent / "data"


def main() -> int:
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    missing = 0
    for r in get_affiliates_config().resources:
        src = (DATA / r.file).resolve()
        if DATA.resolve() not in src.parents or not src.is_file():
            print(f"MISSING {r.key}: data/{r.file}")
            missing += 1
            continue
        shutil.copyfile(src, ASSETS_DIR / r.asset_name)
        print(f"ok {r.key}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
