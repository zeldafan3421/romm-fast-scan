#!/usr/bin/env python3
"""
patch_romm_yaml.py  —  romm fast-scan plugin installer (volume-mount method)
──────────────────────────────────────────────────────────────────────────
DEPRECATED for RomM versions that already have a published fast-scan image
(see SUPPORTED_IMAGE_VERSIONS below) -- use the one-line image swap in
README.md instead. This script remains the recommended path for RomM
versions that don't have a published image yet, e.g. right after a new
RomM release before this repo has caught up; for those it runs normally
with no warning.

Drop this file next to your romm.yml and run it once:

    python3 patch_romm_yaml.py [romm.yml]

What it does:
  1. Backs up romm.yml → romm.yml.bak.<timestamp>
  2. Applies four targeted patches to wire in the fast-scan plugin
  3. Rolls back automatically if anything goes wrong

The plugin must already be deployed to a directory on the host.
Set PLUGIN_HOST_PATH below (or pass it as a second argument) to match
wherever you copied the plugin files.
"""

import sys
import os
import re
import shutil
import datetime

# ── Deprecation guard ─────────────────────────────────────────────────────────
# Strip --allow-deprecated out before any positional argv parsing below, so
# it can appear anywhere on the command line.
ALLOW_DEPRECATED = "--allow-deprecated" in sys.argv
if ALLOW_DEPRECATED:
    sys.argv = [a for a in sys.argv if a != "--allow-deprecated"]

# RomM versions with a published ghcr.io/zeldafan3421/romm-fast-scan image.
# Deliberately separate from known_sha256.txt (which tracks versions with
# prepatched *source*, a broader set) -- keep this in sync with the tags
# .github/workflows/build-container.yml actually publishes.
SUPPORTED_IMAGE_VERSIONS = {"4.9.2"}

# ── Config ────────────────────────────────────────────────────────────────────

# Path on the HOST where you deployed the plugin files.
# Override via second argument: python3 patch_romm_yaml.py romm.yml /my/path
PLUGIN_HOST_PATH = sys.argv[2] if len(sys.argv) > 2 else "/opt/romm/fast-scan-plugin"

# ── Helpers ───────────────────────────────────────────────────────────────────

def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)

def detect_romm_version(text):
    """Best-effort extraction of the romm-app container's image tag.
    Returns None if it can't be determined unambiguously -- e.g. the image
    was already swapped to something custom, or is tracking :latest, which
    we deliberately don't try to resolve to a concrete version."""
    m = re.search(r"image:\s*(?:docker\.io/)?rommapp/romm:(\S+)", text)
    if not m or m.group(1) == "latest":
        return None
    return m.group(1)

def warn_if_deprecated(text):
    version = detect_romm_version(text)
    if version not in SUPPORTED_IMAGE_VERSIONS:
        return  # unknown/new version -- this script is still the right tool
    if ALLOW_DEPRECATED:
        print(f"NOTE: RomM {version} has a published fast-scan image, but "
              f"--allow-deprecated was given -- proceeding with the "
              f"volume-mount install anyway.\n")
        return
    print(
        f"RomM {version} already has a published fast-scan image. The "
        "volume-mount install\n"
        "is deprecated for versions that do -- use the one-line image swap "
        "instead\n"
        "(see README.md):\n\n"
        f"    image: ghcr.io/zeldafan3421/romm-fast-scan:{version}-fast-scan\n\n"
        "This script remains fully supported for RomM versions that don't "
        "have a\n"
        "published image yet -- for those it runs normally, no warning.\n\n"
        "To keep the stock rommapp/romm image anyway (policy, tracking "
        ":latest,\n"
        "etc.), rerun with --allow-deprecated.",
        file=sys.stderr,
    )
    sys.exit(1)

def patch(text, old, new, label):
    """Replace old→new exactly once; abort if not found or found >1 time."""
    count = text.count(old)
    if count == 0:
        die(
            f"Patch '{label}' failed — anchor text not found.\n"
            "  Your romm.yml may have already been patched, or its structure\n"
            "  differs from what was expected. Check the file and re-run, or\n"
            "  restore from backup and apply changes manually."
        )
    if count > 1:
        die(
            f"Patch '{label}' failed — anchor text appears {count} times.\n"
            "  Cannot apply patch unambiguously. Edit romm.yml manually."
        )
    return text.replace(old, new, 1)

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "romm.yml"

    if not os.path.isfile(target):
        die(f"'{target}' not found. Run from the directory that contains your romm.yml.")

    with open(target, "r") as f:
        original = f.read()

    # Guard against double-patching
    if "/romm-plugin/start.sh" in original:
        print("romm.yml already contains the fast-scan plugin patch — nothing to do.")
        sys.exit(0)

    warn_if_deprecated(original)

    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup = f"{target}.bak.{ts}"

    print(f"Backing up {target} → {backup}")
    shutil.copy2(target, backup)

    text = original

    # ── Patch 1: inject entrypoint override ──────────────────────────────────
    # Insert `command:` after `restartPolicy: Always` and before `ports:`
    text = patch(
        text,
        "      restartPolicy: Always\n      ports:",
        (
            "      restartPolicy: Always\n"
            "\n"
            "      # fast-scan plugin: override entrypoint so start.sh can\n"
            "      # compile plugins and patch roms_handler.py before boot.\n"
            "      command: [\"/romm-plugin/start.sh\"]\n"
            "\n"
            "      ports:"
        ),
        "entrypoint override",
    )

    # ── Patch 2: inject PYTHONPATH env var ───────────────────────────────────
    # Find the last env entry (ROMM_AUTH_SECRET_KEY) and append PYTHONPATH after it.
    # We match the auth key name line + value line + the closing volumeMounts line
    # so the insertion point is unambiguous.
    text = patch(
        text,
        "        - name: ROMM_AUTH_SECRET_KEY\n          value:",
        (
            "        # fast-scan plugin: makes plugin_manager importable\n"
            "        - name: PYTHONPATH\n"
            "          value: \"/romm-plugin/src:/backend\"\n"
            "        - name: ROMM_AUTH_SECRET_KEY\n"
            "          value:"
        ),
        "PYTHONPATH env var",
    )

    # ── Patch 3: inject volumeMount for the plugin dir ───────────────────────
    # After the last existing mount (romm-config) and before the romm-db container.
    text = patch(
        text,
        (
            "        - name: romm-config\n"
            "          mountPath: \"/romm/config\"\n"
            "    - name: romm-db"
        ),
        (
            "        - name: romm-config\n"
            "          mountPath: \"/romm/config\"\n"
            "        # fast-scan plugin volume\n"
            "        - name: romm-fast-scan-plugin\n"
            "          mountPath: \"/romm-plugin\"\n"
            "    - name: romm-db"
        ),
        "volumeMount entry",
    )

    # ── Patch 4: inject volume definition at end of volumes list ─────────────
    text = patch(
        text,
        (
            "    - name: mysql_data\n"
            "      persistentVolumeClaim:\n"
            "        claimName: rommdb-data\n"
        ),
        (
            "    - name: mysql_data\n"
            "      persistentVolumeClaim:\n"
            "        claimName: rommdb-data\n"
            "    # fast-scan plugin volume\n"
            "    - name: romm-fast-scan-plugin\n"
            "      hostPath:\n"
            f"        path: {PLUGIN_HOST_PATH}\n"
            "        type: Directory\n"
        ),
        "volume definition",
    )

    # ── Write patched file ────────────────────────────────────────────────────
    try:
        with open(target, "w") as f:
            f.write(text)
    except Exception as e:
        print(f"Write failed ({e}), restoring backup...", file=sys.stderr)
        shutil.copy2(backup, target)
        die("Restored original. No changes applied.")

    # ── Sanity check: verify all anchors are present ─────────────────────────
    checks = [
        "/romm-plugin/start.sh",
        "PYTHONPATH",
        "romm-fast-scan-plugin",
        PLUGIN_HOST_PATH,
    ]
    missing = [c for c in checks if c not in text]
    if missing:
        print(f"Sanity check failed — missing: {missing}", file=sys.stderr)
        print("Restoring backup...", file=sys.stderr)
        shutil.copy2(backup, target)
        die("Restored original.")

    print()
    print("Patched successfully. Summary of changes:")
    print("  + command: [\"/romm-plugin/start.sh\"]       (entrypoint wrapper)")
    print("  + PYTHONPATH=/romm-plugin/src:/backend      (makes .so importable)")
    print("  + volumeMount romm-fast-scan-plugin → /romm-plugin")
    print(f"  + volume hostPath {PLUGIN_HOST_PATH}")
    print()
    print("Note: SCAN_WORKERS is unchanged. With the GIL-released C extension")
    print("you can safely raise it (e.g. value: \"4\") for more parallel hashing.")
    print()
    print("To apply:")
    print("  podman pod stop  romm-pod 2>/dev/null || true")
    print("  podman pod rm    romm-pod 2>/dev/null || true")
    print(f"  podman play kube {target}")
    print()
    print(f"Backup: {backup}")

if __name__ == "__main__":
    main()
