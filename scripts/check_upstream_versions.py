#!/usr/bin/env python3
"""
check_upstream_versions.py  —  operationalizes the "5.*.* indefinitely"
compatibility commitment (see CLAUDE.md's Roadmap section)
─────────────────────────────────────────────────────────────────────────────
Compares this repo's known-supported versions (scripts/list_known_versions.py,
backed by known_sha256.txt) against rommapp/romm's published GitHub releases,
restricted to the 5.* line (the scope of the current commitment — revisit
this filter once a 6.x line exists). If upstream has released a 5.x version
this repo hasn't run refresh.sh against yet, that's a gap.

This script only *surfaces* a gap (via a single persistent GitHub issue,
labeled compat-watch, created/refreshed/closed as the gap changes) — it
deliberately does NOT run refresh.sh or commit anything itself. refresh.sh
has to run inside a live container of the new version and its diff should
get a human's eyes before anyone trusts it; this script's job ends at
"someone should look at this."

Run by .github/workflows/compat-watch.yml on a weekly schedule (and via
manual workflow_dispatch). Requires `gh` authenticated with repo + issues
scope (the Actions-provided GITHUB_TOKEN covers this; see GH_TOKEN in the
workflow's env).

Usage:
    python3 check_upstream_versions.py              # real run: manages the issue
    python3 check_upstream_versions.py --dry-run     # print the gap, touch nothing
"""

import argparse
import json
import subprocess
import sys

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
from list_known_versions import parse_known_sha, resolve_known_sha_path  # noqa: E402

UPSTREAM_REPO = "rommapp/romm"
THIS_REPO_VERSION_PREFIX = "5."  # scope of the current commitment
TRACKING_LABEL = "compat-watch"
LABEL_COLOR = "d93f0b"
LABEL_DESCRIPTION = "Tracks RomM upstream releases not yet covered by known_sha256.txt"


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def run_gh(args, input_text=None):
    try:
        return subprocess.run(
            ["gh"] + args,
            capture_output=True,
            text=True,
            input=input_text,
            check=True,
        )
    except FileNotFoundError:
        die("gh CLI not found on PATH.")
    except subprocess.CalledProcessError as e:
        die(f"`gh {' '.join(args)}` failed (exit {e.returncode}):\n{e.stderr.strip()}")


def known_versions():
    _, entries = parse_known_sha(resolve_known_sha_path(None))
    return {e.version_label for e in entries}


def upstream_5x_versions():
    result = run_gh([
        "api", f"repos/{UPSTREAM_REPO}/releases", "--paginate",
        "--jq", ".[].tag_name",
    ])
    tags = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return {t for t in tags if t.startswith(THIS_REPO_VERSION_PREFIX)}


def compute_gap():
    known = known_versions()
    upstream = upstream_5x_versions()
    gap = sorted(upstream - known, reverse=True)
    return known, upstream, gap


def issue_body(gap):
    lines = [
        "This issue is managed automatically by `.github/workflows/compat-watch.yml`",
        "(`scripts/check_upstream_versions.py`) — do not edit its body by hand, it will",
        "be overwritten on the next weekly run. Discussion in comments is fine.",
        "",
        f"RomM 5.x release(s) not yet covered by `known_sha256.txt`:",
        "",
    ]
    lines += [f"- `{v}`" for v in gap]
    lines += [
        "",
        "To close the gap for a version above: run `scripts/refresh.sh` inside a live",
        "container of that RomM version, review the generated diff, then commit the",
        "updated `known_sha256.txt` and `overrides/prepatched/<version>.py`. This issue",
        "will auto-close once the next scheduled run sees the gap is empty.",
    ]
    return "\n".join(lines)


def find_tracking_issue():
    result = run_gh([
        "issue", "list", "--label", TRACKING_LABEL, "--state", "open",
        "--json", "number", "--limit", "1",
    ])
    issues = json.loads(result.stdout)
    return issues[0]["number"] if issues else None


def manage_issue(gap):
    run_gh([
        "label", "create", TRACKING_LABEL,
        "--color", LABEL_COLOR, "--description", LABEL_DESCRIPTION, "--force",
    ])
    existing = find_tracking_issue()

    if gap:
        body = issue_body(gap)
        if existing is None:
            run_gh([
                "issue", "create",
                "--title", f"RomM 5.x compatibility gap: {', '.join(gap)}",
                "--body", body,
                "--label", TRACKING_LABEL,
            ])
            print(f"Opened tracking issue for gap: {gap}")
        else:
            run_gh(["issue", "edit", str(existing), "--body", body])
            print(f"Refreshed tracking issue #{existing} for gap: {gap}")
    else:
        if existing is not None:
            run_gh([
                "issue", "close", str(existing),
                "--comment", "known_sha256.txt now covers every published RomM 5.x release. Closing.",
            ])
            print(f"Closed tracking issue #{existing} -- gap is now empty.")
        else:
            print("No gap, no open tracking issue -- nothing to do.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="Print the gap, don't touch any GitHub issue")
    args = parser.parse_args()

    known, upstream, gap = compute_gap()
    print(f"Known versions ({len(known)}): {', '.join(sorted(known)) or '(none)'}")
    print(f"Upstream {THIS_REPO_VERSION_PREFIX}* releases ({len(upstream)}): {', '.join(sorted(upstream)) or '(none)'}")
    print(f"Gap ({len(gap)}): {', '.join(gap) or '(none)'}")

    if args.dry_run:
        print("[dry-run] not touching any GitHub issue.")
        return

    manage_issue(gap)


if __name__ == "__main__":
    main()
