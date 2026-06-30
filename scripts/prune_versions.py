#!/usr/bin/env python3
"""
prune_versions.py  —  romm fast-scan plugin version cleanup
─────────────────────────────────────────────────────────────
Every time refresh.sh runs against a new RomM version, it appends an entry
to known_sha256.txt and a pre-patched handler to overrides/prepatched/, so
the tier-1 exact-match fast path keeps working for every version you've ever
refreshed against. That list only ever grows. This tool removes entries you
no longer need — e.g. RomM versions you've since upgraded past.

Removing a version does not break anything: start.sh just falls back to
tier-2 (the unified diff patch) for that version's SHA, same as it would for
a version that was never recorded. Nothing is lost except the slightly
faster exact-match boot for that specific old version.

Usage:
    python3 prune_versions.py [--dir PATH] list
    python3 prune_versions.py [--dir PATH] remove VERSION [VERSION ...] [--purge] [--dry-run]
    python3 prune_versions.py [--dir PATH] keep-latest N [--purge] [--dry-run]

--dir PATH   Directory containing known_sha256.txt and overrides/prepatched/.
             Defaults to the repo root (works on a checkout) or a deployed
             plugin directory, e.g. /opt/romm/fast-scan-plugin.

By default, removed .py files are moved to overrides/prepatched/.removed/
(quarantined, not deleted) and known_sha256.txt is backed up first. Pass
--purge to delete them outright instead of quarantining.
"""

import argparse
import datetime
import os
import shutil
import sys

KNOWN_SHA_FILENAME = "known_sha256.txt"
PREPATCHED_DIRNAME = os.path.join("overrides", "prepatched")
QUARANTINE_DIRNAME = ".removed"


class Entry:
    def __init__(self, raw_line, sha, filename, comment, index):
        self.raw_line = raw_line
        self.sha = sha
        self.filename = filename
        self.comment = comment  # everything after '#', stripped (may be "")
        self.index = index  # original order in the file (append order ~= recency)

    @property
    def version_label(self):
        # Comments are written as "RomM <version>" by refresh.sh; fall back
        # to the filename (sans .py) if the comment doesn't follow that shape.
        c = self.comment.strip()
        if c.lower().startswith("romm "):
            return c[5:].strip()
        return c or self.filename[:-3] if self.filename.endswith(".py") else self.filename


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def resolve_dir(arg_dir):
    if arg_dir:
        d = os.path.abspath(arg_dir)
    else:
        # Default to the repo root (parent of this script's scripts/ dir).
        d = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    known_sha = os.path.join(d, KNOWN_SHA_FILENAME)
    prepatched = os.path.join(d, PREPATCHED_DIRNAME)
    if not os.path.isfile(known_sha):
        die(f"'{known_sha}' not found. Pass --dir to point at a plugin directory.")
    if not os.path.isdir(prepatched):
        die(f"'{prepatched}' not found. Pass --dir to point at a plugin directory.")
    return d, known_sha, prepatched


def parse_known_sha(path):
    """Returns (header_lines, entries). header_lines are comment/blank lines
    that precede the first data line, preserved verbatim on rewrite."""
    header_lines = []
    entries = []
    seen_data = False
    with open(path) as f:
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                if not seen_data:
                    header_lines.append(line.rstrip("\n"))
                continue
            seen_data = True
            # "<sha>  <filename>    # comment"
            if "#" in line:
                data_part, _, comment_part = line.partition("#")
                comment = comment_part.strip()
            else:
                data_part = line
                comment = ""
            parts = data_part.split()
            if len(parts) < 2:
                continue  # malformed line; skip rather than crash
            sha, filename = parts[0], parts[1]
            entries.append(Entry(line.rstrip("\n"), sha, filename, comment, len(entries)))
    return header_lines, entries


def write_known_sha(path, header_lines, entries):
    with open(path, "w") as f:
        for h in header_lines:
            f.write(h + "\n")
        for e in entries:
            comment = f"    # RomM {e.version_label}" if e.comment else ""
            # Preserve original spacing/comment exactly when unchanged; only
            # entries we kept are written, so this is just a clean re-render.
            f.write(f"{e.sha}  {e.filename}")
            if e.comment:
                f.write(f"    # {e.comment}")
            f.write("\n")


def fmt_size(num_bytes):
    for unit in ("B", "KB", "MB"):
        if num_bytes < 1024:
            return f"{num_bytes:.0f}{unit}"
        num_bytes /= 1024
    return f"{num_bytes:.1f}GB"


def cmd_list(plugin_dir, known_sha_path, prepatched_dir, args):
    header_lines, entries = parse_known_sha(known_sha_path)
    if not entries:
        print("No recorded versions.")
        return
    print(f"{len(entries)} recorded version(s) in {known_sha_path}:")
    print()
    for e in entries:
        py_path = os.path.join(prepatched_dir, e.filename)
        if os.path.isfile(py_path):
            size = fmt_size(os.path.getsize(py_path))
            mtime = datetime.datetime.fromtimestamp(os.path.getmtime(py_path)).strftime("%Y-%m-%d")
            status = f"{size}, added {mtime}"
        else:
            status = "WARNING: file missing from overrides/prepatched/"
        marker = " (most recent)" if e.index == len(entries) - 1 else ""
        print(f"  {e.version_label:<20} sha={e.sha[:12]}...  file={e.filename:<24} {status}{marker}")


def _quarantine_or_purge(prepatched_dir, filename, purge, dry_run):
    src = os.path.join(prepatched_dir, filename)
    if not os.path.isfile(src):
        print(f"  (file {filename} already missing, nothing to remove on disk)")
        return
    if dry_run:
        action = "delete" if purge else "quarantine"
        print(f"  [dry-run] would {action}: {src}")
        return
    if purge:
        os.remove(src)
        print(f"  Deleted: {src}")
    else:
        qdir = os.path.join(prepatched_dir, QUARANTINE_DIRNAME)
        os.makedirs(qdir, exist_ok=True)
        dest = os.path.join(qdir, filename)
        if os.path.exists(dest):
            ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            dest = os.path.join(qdir, f"{ts}_{filename}")
        shutil.move(src, dest)
        print(f"  Quarantined: {src} -> {dest}")


def _apply_removal(plugin_dir, known_sha_path, prepatched_dir, entries_to_remove, all_entries, header_lines, purge, dry_run):
    if not entries_to_remove:
        print("Nothing to remove.")
        return

    remaining = [e for e in all_entries if e not in entries_to_remove]

    print(f"Removing {len(entries_to_remove)} version(s):")
    for e in entries_to_remove:
        print(f"  - {e.version_label} (sha={e.sha[:12]}..., file={e.filename})")
    print()

    if len(remaining) == 0:
        print("Note: this removes every recorded version. Tier-1 exact-match")
        print("won't apply to any RomM version until refresh.sh runs again;")
        print("the plugin still works via tier-2 (diff patch) or tier-3 fallback.")
        print()

    if dry_run:
        print("[dry-run] no files changed.")
        for e in entries_to_remove:
            _quarantine_or_purge(prepatched_dir, e.filename, purge, dry_run=True)
        return

    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup = f"{known_sha_path}.bak.{ts}"
    shutil.copy2(known_sha_path, backup)
    print(f"Backed up {known_sha_path} -> {backup}")

    write_known_sha(known_sha_path, header_lines, remaining)
    print(f"Updated {known_sha_path} ({len(remaining)} version(s) remain)")

    for e in entries_to_remove:
        _quarantine_or_purge(prepatched_dir, e.filename, purge, dry_run=False)

    print()
    print("Done. No running container is affected until you redeploy this")
    print("directory (or rebuild your container image) and restart the pod.")


def match_entries(entries, queries):
    """Match each query string against version_label, filename (with/without
    .py), or a unique SHA prefix (>=8 hex chars). Errors on no-match or
    ambiguous match rather than guessing."""
    matched = []
    for q in queries:
        q_norm = q.strip()
        candidates = []
        for e in entries:
            name_no_ext = e.filename[:-3] if e.filename.endswith(".py") else e.filename
            if q_norm == e.version_label or q_norm == e.filename or q_norm == name_no_ext:
                candidates.append(e)
            elif len(q_norm) >= 8 and e.sha.startswith(q_norm.lower()):
                candidates.append(e)
        if not candidates:
            available = ", ".join(e.version_label for e in entries)
            die(f"No recorded version matches '{q}'. Available: {available}")
        if len(candidates) > 1:
            die(f"'{q}' matches multiple entries ambiguously: "
                f"{[c.version_label for c in candidates]}")
        matched.append(candidates[0])
    return matched


def cmd_remove(plugin_dir, known_sha_path, prepatched_dir, args):
    header_lines, entries = parse_known_sha(known_sha_path)
    to_remove = match_entries(entries, args.versions)
    _apply_removal(plugin_dir, known_sha_path, prepatched_dir, to_remove, entries, header_lines, args.purge, args.dry_run)


def cmd_keep_latest(plugin_dir, known_sha_path, prepatched_dir, args):
    header_lines, entries = parse_known_sha(known_sha_path)
    if args.n < 0:
        die("N must be >= 0")
    if args.n >= len(entries):
        print(f"Already at or below {args.n} version(s) ({len(entries)} recorded) — nothing to do.")
        return
    # append order in the file ~= recency, since record_version() removes any
    # stale line for a SHA and re-appends fresh on every refresh
    ordered = sorted(entries, key=lambda e: e.index)
    to_remove = ordered[: len(ordered) - args.n]
    _apply_removal(plugin_dir, known_sha_path, prepatched_dir, to_remove, entries, header_lines, args.purge, args.dry_run)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", help="Plugin directory (default: repo root)")
    sub = parser.add_subparsers(dest="command", required=True)

    p_list = sub.add_parser("list", help="List recorded versions")
    p_list.set_defaults(func=cmd_list)

    p_remove = sub.add_parser("remove", help="Remove one or more versions by name, filename, or SHA prefix")
    p_remove.add_argument("versions", nargs="+", help="Version label(s) to remove, e.g. 4.9.2")
    p_remove.add_argument("--purge", action="store_true", help="Delete files instead of quarantining them")
    p_remove.add_argument("--dry-run", action="store_true", help="Show what would happen without changing anything")
    p_remove.set_defaults(func=cmd_remove)

    p_keep = sub.add_parser("keep-latest", help="Keep only the N most recently recorded versions")
    p_keep.add_argument("n", type=int, help="Number of most-recent versions to keep")
    p_keep.add_argument("--purge", action="store_true", help="Delete files instead of quarantining them")
    p_keep.add_argument("--dry-run", action="store_true", help="Show what would happen without changing anything")
    p_keep.set_defaults(func=cmd_keep_latest)

    args = parser.parse_args()
    plugin_dir, known_sha_path, prepatched_dir = resolve_dir(args.dir)
    args.func(plugin_dir, known_sha_path, prepatched_dir, args)


if __name__ == "__main__":
    main()
