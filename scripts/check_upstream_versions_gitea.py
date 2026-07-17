#!/usr/bin/env python3
"""
check_upstream_versions_gitea.py  —  Gitea Actions counterpart to
check_upstream_versions.py (see that file's docstring for the full
rationale of what this reports and why it never runs refresh.sh itself)
─────────────────────────────────────────────────────────────────────────────
Same gap computation as check_upstream_versions.py, adapted for a
Gitea-hosted romm-fast-scan repo:

  - Upstream rommapp/romm releases are always fetched from GitHub's public
    REST API directly via urllib (no `gh` CLI dependency -- a self-hosted
    Gitea act_runner has no reason to have it installed, and rommapp/romm
    itself lives on GitHub regardless of where this repo is hosted).
  - The tracking issue lives on *this* Gitea instance instead of GitHub, so
    it's managed via Gitea's REST API (token auth) instead of `gh issue`.

Reads GITHUB_API_URL and GITHUB_REPOSITORY from the environment -- both are
populated automatically by Gitea Actions' GitHub-Actions compatibility
layer, pointing at the Gitea instance running the workflow -- plus a
GITEA_TOKEN (or GITHUB_TOKEN) wired from secrets.GITHUB_TOKEN in
.gitea/workflows/compat-watch.yml.

Run by .gitea/workflows/compat-watch.yml on a weekly schedule (and via
manual workflow_dispatch).

Usage:
    python3 check_upstream_versions_gitea.py              # real run: manages the issue
    python3 check_upstream_versions_gitea.py --dry-run     # print the gap, touch nothing
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
from list_known_versions import parse_known_sha, resolve_known_sha_path  # noqa: E402

UPSTREAM_RELEASES_API = "https://api.github.com/repos/rommapp/romm/releases"
THIS_REPO_VERSION_PREFIX = "5."  # scope of the current commitment
TRACKING_LABEL = "compat-watch"
LABEL_COLOR = "d93f0b"
LABEL_DESCRIPTION = "Tracks RomM upstream releases not yet covered by known_sha256.txt"


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def gitea_env():
    api_url = os.environ.get("GITHUB_API_URL")
    repository = os.environ.get("GITHUB_REPOSITORY")
    token = os.environ.get("GITEA_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not api_url or not repository or not token:
        die(
            "GITHUB_API_URL, GITHUB_REPOSITORY, and GITEA_TOKEN (or GITHUB_TOKEN) "
            "must all be set -- this script expects to run under Gitea Actions."
        )
    owner, repo = repository.split("/", 1)
    return api_url.rstrip("/"), owner, repo, token


def gitea_request(api_url, token, method, path, body=None):
    url = f"{api_url}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"token {token}")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        die(f"{method} {path} failed ({e.code}): {e.read().decode(errors='replace')}")


def known_versions():
    _, entries = parse_known_sha(resolve_known_sha_path(None))
    return {e.version_label for e in entries}


def upstream_5x_versions():
    tags = set()
    page = 1
    while True:
        req = urllib.request.Request(
            f"{UPSTREAM_RELEASES_API}?per_page=100&page={page}",
            headers={"Accept": "application/vnd.github+json"},
        )
        try:
            with urllib.request.urlopen(req) as resp:
                releases = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            die(f"Fetching upstream releases failed ({e.code}): {e.read().decode(errors='replace')}")
        if not releases:
            break
        for r in releases:
            tag = r.get("tag_name", "")
            if tag.startswith(THIS_REPO_VERSION_PREFIX):
                tags.add(tag)
        page += 1
    return tags


def compute_gap():
    known = known_versions()
    upstream = upstream_5x_versions()
    gap = sorted(upstream - known, reverse=True)
    return known, upstream, gap


def issue_body(gap):
    lines = [
        "This issue is managed automatically by `.gitea/workflows/compat-watch.yml`",
        "(`scripts/check_upstream_versions_gitea.py`) — do not edit its body by hand,",
        "it will be overwritten on the next weekly run. Discussion in comments is fine.",
        "",
        "RomM 5.x release(s) not yet covered by `known_sha256.txt`:",
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


def ensure_label(api_url, owner, repo, token):
    labels = gitea_request(api_url, token, "GET", f"/repos/{owner}/{repo}/labels?limit=50") or []
    for label in labels:
        if label["name"] == TRACKING_LABEL:
            return label["id"]
    created = gitea_request(
        api_url, token, "POST", f"/repos/{owner}/{repo}/labels",
        {"name": TRACKING_LABEL, "color": LABEL_COLOR, "description": LABEL_DESCRIPTION},
    )
    return created["id"]


def find_tracking_issue(api_url, owner, repo, token):
    issues = gitea_request(
        api_url, token, "GET", f"/repos/{owner}/{repo}/issues?state=open&type=issues&limit=50",
    ) or []
    for issue in issues:
        if any(label["name"] == TRACKING_LABEL for label in issue.get("labels") or []):
            return issue["number"]
    return None


def manage_issue(gap):
    api_url, owner, repo, token = gitea_env()
    label_id = ensure_label(api_url, owner, repo, token)
    existing = find_tracking_issue(api_url, owner, repo, token)

    if gap:
        body = issue_body(gap)
        if existing is None:
            gitea_request(
                api_url, token, "POST", f"/repos/{owner}/{repo}/issues",
                {
                    "title": f"RomM 5.x compatibility gap: {', '.join(gap)}",
                    "body": body,
                    "labels": [label_id],
                },
            )
            print(f"Opened tracking issue for gap: {gap}")
        else:
            gitea_request(
                api_url, token, "PATCH", f"/repos/{owner}/{repo}/issues/{existing}",
                {"body": body},
            )
            print(f"Refreshed tracking issue #{existing} for gap: {gap}")
    else:
        if existing is not None:
            gitea_request(
                api_url, token, "POST", f"/repos/{owner}/{repo}/issues/{existing}/comments",
                {"body": "known_sha256.txt now covers every published RomM 5.x release. Closing."},
            )
            gitea_request(
                api_url, token, "PATCH", f"/repos/{owner}/{repo}/issues/{existing}",
                {"state": "closed"},
            )
            print(f"Closed tracking issue #{existing} -- gap is now empty.")
        else:
            print("No gap, no open tracking issue -- nothing to do.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="Print the gap, don't touch any Gitea issue")
    args = parser.parse_args()

    known, upstream, gap = compute_gap()
    print(f"Known versions ({len(known)}): {', '.join(sorted(known)) or '(none)'}")
    print(f"Upstream {THIS_REPO_VERSION_PREFIX}* releases ({len(upstream)}): {', '.join(sorted(upstream)) or '(none)'}")
    print(f"Gap ({len(gap)}): {', '.join(gap) or '(none)'}")

    if args.dry_run:
        print("[dry-run] not touching any Gitea issue.")
        return

    manage_issue(gap)


if __name__ == "__main__":
    main()
