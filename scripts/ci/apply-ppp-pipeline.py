#!/usr/bin/env python3
"""Apply the PinePhone Pro changes (pipeline patch 0060) to a bootstrapped
duranium tree.

Usage:
    apply-ppp-pipeline.py [DURANIUM_DIR] [--check]

DURANIUM_DIR defaults to $MARATHON_BUILD_DIR/duranium, else
~/.cache/marathon-build/duranium. With --check nothing is written: it only
verifies that every anchor is found, so a drifted tree is caught early.

Every edit is anchored on text that patches 0022/0023 leave in the tree.
An edit that is already applied is skipped, so the script is idempotent.
If an anchor is missing or ambiguous the script stops before writing any
file.

The boot partition of this device starts at sector 32768 (16 MiB), after
u-boot.itb at 8 MiB; every other device keeps sector 4096. The script ends
by printing the lines that still mention the old layout, to review by hand.
"""
import os
import re
import sys
from pathlib import Path

args = [a for a in sys.argv[1:] if not a.startswith("--")]
CHECK = "--check" in sys.argv[1:]
base = Path(os.environ.get("MARATHON_BUILD_DIR", Path.home() / ".cache/marathon-build"))
ROOT = Path(args[0]) if args else base / "duranium"


class Anchor(Exception):
    pass


def replace_once(old, new):
    """Replace a unique substring; None means already applied."""
    def run(text):
        if old not in text and new in text:
            return None
        n = text.count(old)
        if n != 1:
            raise Anchor(f"expected exactly 1 match of {old!r}, found {n}")
        return text.replace(old, new)
    return run


def insert_after_line(pattern, block, marker):
    """Insert `block` (lines with their absolute indentation) after the single
    line matching `pattern`. `marker` shows the block is already there."""
    def run(text):
        if marker in text:
            return None
        lines = text.split("\n")
        hits = [i for i, l in enumerate(lines) if re.search(pattern, l)]
        if len(hits) != 1:
            raise Anchor(f"expected exactly 1 line matching {pattern!r}, found {len(hits)}")
        i = hits[0]
        return "\n".join(lines[: i + 1] + block + lines[i + 1:])
    return run


def replace_comment(pattern, template, marker):
    """Replace the single comment line matching `pattern` by `template` lines
    at the same indentation. `marker` shows it is already done."""
    def run(text):
        if marker in text:
            return None
        lines = text.split("\n")
        hits = [i for i, l in enumerate(lines) if re.search(pattern, l)]
        if len(hits) != 1:
            raise Anchor(f"expected exactly 1 line matching {pattern!r}, found {len(hits)}")
        i = hits[0]
        indent = re.match(r"\s*", lines[i]).group(0)
        return "\n".join(lines[:i] + [indent + t for t in template] + lines[i + 1:])
    return run


edits = [
    # ---- mkosi.finalize ----------------------------------------------------
    ("mkosi.finalize", "PinePhone Pro joins the U-Boot boot-script path",
     replace_once("pine64-pinephone) UBOOT_SCRIPT_BOOT=1 ;;",
                  "pine64-pinephone|pine64-pinephonepro) UBOOT_SCRIPT_BOOT=1 ;;")),
    ("mkosi.finalize", "mkimage name within the 32-byte header field",
     replace_once('-n "Marathon $PMOS_DEVICE boot" \\',
                  '-n "Marathon ${PMOS_DEVICE#pine64-} boot" \\')),
    ("mkosi.finalize", "explain the dropped pine64- prefix",
     replace_comment(r"^\s*# The image name is the legacy header's, capped at 32 bytes\.$",
                     ["# The image name is the legacy header's, capped at 32 bytes: the",
                      "# pine64- prefix is dropped (\"Marathon pine64-pinephonepro boot\" is 33)."],
                     "pine64- prefix is dropped")),
    # ---- scripts/mkosi-configure.py ---------------------------------------
    ("scripts/mkosi-configure.py", "Bootloader=uki for the PinePhone Pro",
     replace_once('if device == "pine64-pinephone":',
                  'if device in ("pine64-pinephone", "pine64-pinephonepro"):')),
    ("scripts/mkosi-configure.py", "update the exact-match comment",
     replace_comment(r"^\s*# Exact match: pine64-pinephonepro boots differently\.$",
                     ["# Exact matches: pine64-pinephone (A64, U-Boot at 8 KiB) and",
                      "# pine64-pinephonepro (RK3399, U-Boot at 32 KiB)."],
                     "pine64-pinephonepro (RK3399, U-Boot at 32 KiB)")),
    # ---- scripts/build-image.py -------------------------------------------
    ("scripts/build-image.py", "U-Boot blob, offset and table for the PinePhone Pro",
     insert_after_line(
         r'^\s+8, "mbr"\)$',
         ['        elif device_name == "pine64-pinephonepro":',
          "            # The RK3399 BootROM reads the idbloader at sector 64 (32 KiB), which",
          "            # a GPT's partition-entry array (LBA 2..33) does not reach, so the",
          "            # disk stays GPT. pmaports' deviceinfo_sd_embed_firmware names this",
          "            # blob (idbloader + u-boot.itb, ~9 MiB) and its offset.",
          '            uboot_boot = ("usr/share/u-boot/pinephone-pro-rk3399/u-boot-rockchip.bin",',
          '                          32, "gpt")'],
         'elif device_name == "pine64-pinephonepro":')),
    ("scripts/build-image.py", "stage the board DTBs under rockchip/",
     insert_after_line(
         r"board DTBs staged under allwinner/ on the boot partition",
         ['                if device_name == "pine64-pinephonepro":',
          "                    import shutil",
          '                    dtbs_src = os.path.join(boot_stage, "dtbs", "rockchip")',
          "                    if os.path.isdir(dtbs_src):",
          "                        shutil.copytree(dtbs_src, os.path.join(boot_stage, \"rockchip\"),",
          "                                        dirs_exist_ok=True)",
          '                        print(f"{device_name}: board DTBs staged under rockchip/ on the boot partition")',
          "                    else:",
          '                        print(f"warning: {device_name}: no dtbs/rockchip in the boot staging dir")'],
         'dtbs_src = os.path.join(boot_stage, "dtbs", "rockchip")')),
    ("scripts/build-image.py", "boot partition start per device",
     insert_after_line(
         r"^\s+blob_rel, blob_kib, table = uboot_boot$",
         ["            # The Rockchip u-boot.itb sits at 8 MiB, so this device's boot",
          "            # partition starts at 16 MiB (pmaports deviceinfo_boot_part_start).",
          '            boot_start = 32768 if device_name == "pine64-pinephonepro" else 4096'],
         "boot_start = 32768 if device_name")),
    ("scripts/build-image.py", "sgdisk creates the boot partition at boot_start",
     replace_once('"-n", "1:4096:1052671",',
                  '"-n", f"1:{boot_start}:{boot_start + 1048576 - 1}",')),
    ("scripts/build-image.py", "log the real boot start",
     replace_once('print(f"Librem 5: rebuilding disk layout (boot ext4 at sector 4096)")',
                  'print(f"{device_name}: rebuilding disk layout (boot ext4 at sector {boot_start})")')),
]

# Dry run first: compute every result before writing anything.
results = {}
errors = []
for rel, label, fn in edits:
    path = ROOT / rel
    if not path.is_file():
        errors.append(f"{rel}: file not found under {ROOT}")
        continue
    text = results.get(rel, path.read_text())
    try:
        new = fn(text)
    except Anchor as e:
        errors.append(f"{rel}: {label}: {e}")
        continue
    if new is None:
        print(f"skip   {rel}: {label} (already applied)")
    else:
        results[rel] = new
        print(f"ok     {rel}: {label}")

if errors:
    print("\nNothing written. Problems:", file=sys.stderr)
    for e in errors:
        print("  - " + e, file=sys.stderr)
    sys.exit(1)

if CHECK:
    print("\n--check: nothing written.")
else:
    for rel, text in results.items():
        (ROOT / rel).write_text(text)
    print(f"\nwrote {len(results)} file(s) under {ROOT}")

print("\nReview by hand: lines in build-image.py that still mention the old")
print("layout (comments are fine; anything functional needs the same treatment):\n")
bi = (ROOT / "scripts/build-image.py")
if bi.is_file():
    for n, line in enumerate(bi.read_text().split("\n"), 1):
        if re.search(r"4096|1052671|528384|2099200|boot_start", line):
            print(f"  {n:5d}: {line.rstrip()}")
