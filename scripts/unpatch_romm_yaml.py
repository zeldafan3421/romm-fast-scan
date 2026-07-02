#!/usr/bin/env python3
"""
unpatch_romm_yaml.py  —  romm fast-scan plugin uninstaller
─────────────────────────────────────────────────────────
Reverts the four changes patch_romm_yaml.py made to your romm.yml, restoring
it to stock RomM. Run it next to your patched romm.yml:

    python3 unpatch_romm_yaml.py [romm.yml]

What it does:
  1. Backs up romm.yml → romm.yml.bak.<timestamp> (before touching anything)
  2. Removes the entrypoint override, PYTHONPATH env var, volumeMount, and
     volume definition that patch_romm_yaml.py added
  3. Rolls back automatically if anything goes wrong, or if the result still
     looks patched afterward

This is the exact inverse of patch_romm_yaml.py. It does not touch your
library, RomM's database, or anything outside the pod YAML.
"""

import sys
import os
import re
import shutil
import datetime

# ── Helpers ───────────────────────────────────────────────────────────────────

def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def remove_block(text, block, label, required=True):
    """Remove `block` (an exact string) from text exactly once."""
    count = text.count(block)
    if count == 0:
        if required:
            die(
                f"Unpatch step '{label}' failed — expected text not found.\n"
                "  romm.yml may already be unpatched, or was modified by hand\n"
                "  since the plugin was installed. Check the file manually, or\n"
                "  restore from a romm.yml.bak.* backup instead."
            )
        return text
    if count > 1:
        die(
            f"Unpatch step '{label}' failed — text appears {count} times.\n"
            "  Cannot remove unambiguously. Edit romm.yml manually."
        )
    return text.replace(block, "", 1)


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "romm.yml"

    if not os.path.isfile(target):
        die(f"'{target}' not found. Run from the directory that contains your romm.yml.")

    with open(target, "r") as f:
        original = f.read()

    if "/romm-plugin/start.sh" not in original:
        print(f"'{target}' doesn't contain the fast-scan plugin patch — nothing to do.")
        sys.exit(0)

    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup = f"{target}.bak.{ts}"

    print(f"Backing up {target} → {backup}")
    shutil.copy2(target, backup)

    text = original

    # ── Undo 1: entrypoint override ───────────────────────────────────────────
    text = remove_block(
        text,
        (
            "\n"
            "      # fast-scan plugin: override entrypoint so start.sh can\n"
            "      # compile plugins and patch roms_handler.py before boot.\n"
            "      command: [\"/romm-plugin/start.sh\"]\n"
            "\n"
        ),
        "entrypoint override",
    )

    # ── Undo 2: PYTHONPATH env var ────────────────────────────────────────────
    text = remove_block(
        text,
        (
            "        # fast-scan plugin: makes plugin_manager importable\n"
            "        - name: PYTHONPATH\n"
            "          value: \"/romm-plugin/src:/backend\"\n"
        ),
        "PYTHONPATH env var",
    )

    # ── Undo 3: volumeMount entry ─────────────────────────────────────────────
    text = remove_block(
        text,
        (
            "        # fast-scan plugin volume\n"
            "        - name: romm-fast-scan-plugin\n"
            "          mountPath: \"/romm-plugin\"\n"
        ),
        "volumeMount entry",
    )

    # ── Undo 4: volume definition ─────────────────────────────────────────────
    # The hostPath value is whatever PLUGIN_HOST_PATH was set to at patch time,
    # so match it with a regex instead of an exact string.
    volume_def_re = re.compile(
        r"    # fast-scan plugin volume\n"
        r"    - name: romm-fast-scan-plugin\n"
        r"      hostPath:\n"
        r"        path: .*\n"
        r"        type: Directory\n"
    )
    if volume_def_re.search(text) is None:
        die(
            "Unpatch step 'volume definition' failed — expected text not found.\n"
            "  romm.yml may already be unpatched, or was modified by hand\n"
            "  since the plugin was installed. Check the file manually, or\n"
            "  restore from a romm.yml.bak.* backup instead."
        )
    text, n = volume_def_re.subn("", text, count=1)

    # ── Write unpatched file ──────────────────────────────────────────────────
    try:
        with open(target, "w") as f:
            f.write(text)
    except Exception as e:
        print(f"Write failed ({e}), restoring backup...", file=sys.stderr)
        shutil.copy2(backup, target)
        die("Restored original. No changes applied.")

    # ── Sanity check: verify no plugin markers remain ────────────────────────
    leftover = [
        m
        for m in ("/romm-plugin/start.sh", "PYTHONPATH", "romm-fast-scan-plugin")
        if m in text
    ]
    if leftover:
        print(f"Sanity check failed — still present: {leftover}", file=sys.stderr)
        print("Restoring backup...", file=sys.stderr)
        shutil.copy2(backup, target)
        die("Restored original (still patched). Edit romm.yml manually instead.")

    print()
    print("Unpatched successfully. Removed:")
    print("  - command: [\"/romm-plugin/start.sh\"]       (entrypoint override)")
    print("  - PYTHONPATH=/romm-plugin/src:/backend      (env var)")
    print("  - volumeMount romm-fast-scan-plugin → /romm-plugin")
    print("  - volume hostPath definition")
    print()
    print(f"{target} now matches stock RomM. SCAN_WORKERS and any other")
    print("settings you changed manually were left untouched.")
    print()
    print("To apply:")
    print("  podman pod stop  romm-pod 2>/dev/null || true")
    print("  podman pod rm    romm-pod 2>/dev/null || true")
    print(f"  podman play kube {target}")
    print()
    print(f"Backup: {backup}")


if __name__ == "__main__":
    main()
