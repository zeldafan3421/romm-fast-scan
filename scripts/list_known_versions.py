#!/usr/bin/env python3
"""
list_known_versions.py  —  single source of truth for "which RomM versions
does this repo support"
─────────────────────────────────────────────────────────────────────────────
known_sha256.txt is the ledger refresh.sh/prune_versions.py already maintain
(every version anyone has ever run refresh.sh against, appended, never
silently dropped). This script just reads that ledger and prints the version
list in whatever shape a consumer needs, so nothing else has to hardcode a
second copy of "which versions are supported":

  - .github/workflows/build-container.yml's build matrix (--json)
  - a manual single-version workflow_dispatch (--only VERSION)
  - scripts/check_upstream_versions.py's upstream-gap diff (--json)

Reuses prune_versions.py's Entry/parse_known_sha/version_label parsing
convention directly (same directory, safe to import: prune_versions.py's
own CLI is guarded by `if __name__ == "__main__"`) rather than keeping a
second copy of that parsing logic in sync.

Usage:
    python3 list_known_versions.py [--dir PATH]              # one per line
    python3 list_known_versions.py [--dir PATH] --json        # JSON array
    python3 list_known_versions.py [--dir PATH] --only 4.9.2  # validate one
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from prune_versions import KNOWN_SHA_FILENAME, parse_known_sha  # noqa: E402


def resolve_known_sha_path(arg_dir):
    """Only requires known_sha256.txt to exist -- unlike prune_versions.py's
    resolve_dir(), this script has no reason to also require
    overrides/prepatched/ to be present."""
    if arg_dir:
        d = os.path.abspath(arg_dir)
    else:
        d = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(d, KNOWN_SHA_FILENAME)
    if not os.path.isfile(path):
        print(f"ERROR: '{path}' not found. Pass --dir to point at a plugin directory.", file=sys.stderr)
        sys.exit(1)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", help="Plugin directory containing known_sha256.txt (default: repo root)")
    parser.add_argument("--json", action="store_true", help="Print as a JSON array instead of one per line")
    parser.add_argument("--only", metavar="VERSION", help="Exit 0 and print VERSION if it's known, else exit 1")
    args = parser.parse_args()

    known_sha_path = resolve_known_sha_path(args.dir)
    _, entries = parse_known_sha(known_sha_path)
    versions = [e.version_label for e in entries]

    if args.only:
        if args.only in versions:
            print(args.only)
            sys.exit(0)
        print(f"ERROR: '{args.only}' is not a known version. Known: {', '.join(versions) or '(none)'}", file=sys.stderr)
        sys.exit(1)

    if args.json:
        print(json.dumps(versions))
    else:
        for v in versions:
            print(v)


if __name__ == "__main__":
    main()
