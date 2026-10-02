"""Flag operations without a deploy: run inside the API container.

    docker exec fellowscript-api python -m backend.admin_flags list
    docker exec fellowscript-api python -m backend.admin_flags set <name> <off|canary|on> [--canary id,id]

Changes land within the 10 s flag cache TTL (this separate process cannot
invalidate the server's cache). Prints names, states and counts only.
"""
from __future__ import annotations

import argparse
import sys

from backend.interactions import flags


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m backend.admin_flags")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="show every registered flag")
    p_set = sub.add_parser("set", help="set a flag state")
    p_set.add_argument("name")
    p_set.add_argument("state", choices=flags.STATES)
    p_set.add_argument("--canary", default=None,
                       help="comma-separated user ids (replaces the stored list)")
    args = parser.parse_args(argv)

    if args.cmd == "list":
        for row in flags.list_flags():
            print(f"{row['name']}\t{row['state']}\tcanary={row['canary_count']}")
        return 0

    ids = None
    if args.canary is not None:
        ids = [i.strip() for i in args.canary.split(",") if i.strip()]
    try:
        res = flags.set_flag(args.name, args.state, ids, actor="cli")
    except flags.FlagError as e:
        print(f"refused: {e}", file=sys.stderr)
        return 2
    print(f"{res['name']}\t{res['state']}\tcanary={res['canary_count']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
