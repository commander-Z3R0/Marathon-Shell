#!/usr/bin/env bash
# Flash a Marathon image to the PINE64 PinePhone Pro (pine64-pinephonepro),
# either to a microSD card or to the internal eMMC.
#
# The image from scripts/build-pinephonepro-image.sh is the whole disk: a
# GPT, the Rockchip U-Boot (idbloader at sector 64 = 32 KiB, u-boot.itb at
# sector 16384 = 8 MiB), the boot partition from sector 32768 (16 MiB) and
# the root. Writing it with dd is the entire install, as on pmOS.
#
# Targets:
#   microSD  insert the card in a USB reader and pass its block device.
#   eMMC     boot JumpDrive for the PinePhone Pro from a microSD card
#            (https://github.com/dreemurrs-embedded/Jumpdrive), plug the
#            phone into the host by USB-C, and pass the eMMC block device it
#            exposes. Then power off, remove the JumpDrive card and boot.
#
# Which medium the phone boots first depends on the firmware in its SPI
# flash and on what the eMMC holds; this has not been verified on hardware.
# If the phone ignores the microSD, check the PINE64 wiki for the boot order
# of your firmware before assuming the image is bad.
#
# Before writing, the image is checked for the PinePhone Pro layout (a GPT,
# a Rockchip idbloader "RK33" at 32 KiB and a FIT image at 8 MiB), so an
# image built before pipeline patch 0060 (or for another device) is refused.
# SKIP_SIGNATURE_CHECK=1 skips the two U-Boot signature checks only, for
# when the layout was verified by hand.
set -euo pipefail

CACHE="${MARATHON_BUILD_DIR:-$HOME/.cache/marathon-build}/duranium/mkosi.output/pine64-pinephonepro_marathon_edge"
DEFAULT_IMG=""
for f in "$CACHE"/pine64-pinephonepro_marathon_edge_*.raw; do
    [[ "$(basename "$f")" =~ ^pine64-pinephonepro_marathon_edge_[0-9]+\.raw$ ]] || continue
    { [ -z "$DEFAULT_IMG" ] || [ "$f" -nt "$DEFAULT_IMG" ]; } && DEFAULT_IMG="$f"
done

usage() {
    cat <<USAGE
Usage: flash-pinephonepro.sh /dev/sdX [/path/to/image.raw[.xz|.gz|.zst]]

  /dev/sdX        the microSD card, or the eMMC JumpDrive exposes (lsblk).
  image           default: the newest build,
                    ${DEFAULT_IMG:-$CACHE/pine64-pinephonepro_marathon_edge_<N>.raw}
USAGE
    exit 64
}

[ -z "${1:-}" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage

DEV="$1"
IMG="${2:-$DEFAULT_IMG}"
[ -n "$IMG" ] || { echo "error: no image under $CACHE; run ./scripts/build-pinephonepro-image.sh first" >&2; exit 1; }
[ -f "$IMG" ] || { echo "missing $IMG" >&2; exit 1; }

decompress() {
    case "$IMG" in
        *.xz)  xz -dc "$IMG" ;;
        *.gz)  gzip -dc "$IMG" ;;
        *.zst) zstd -dc "$IMG" ;;
        *.raw|*.img) cat "$IMG" ;;
        *) echo "unrecognized image format: $IMG" >&2; return 1 ;;
    esac
}

# The first 8 MiB + 16 bytes hold everything the boot ROM and U-Boot look at.
HEAD=$(mktemp)
trap 'rm -f "$HEAD"' EXIT
decompress | head -c 8388624 > "$HEAD" || true
at() { dd if="$HEAD" bs=1 skip="$1" count="$2" status=none | tr -d '\000'; }
hex() { od -An -tx1 | tr -d ' \n'; }
[ "$(at 510 2 | hex)" = "55aa" ] \
    || { echo "refusing: $IMG has no (protective) MBR boot signature" >&2; exit 1; }
[ "$(at 512 8)" = "EFI PART" ] \
    || { echo "refusing: $IMG has no GPT (built for another device, or before pipeline patch 0060?)" >&2; exit 1; }
if [ "${SKIP_SIGNATURE_CHECK:-0}" != "1" ]; then
    [ "$(at 32768 4)" = "RK33" ] \
        || { echo "refusing: $IMG has no Rockchip idbloader (RK33) at 32 KiB" >&2; exit 1; }
    [ "$(at 8388608 4 | hex)" = "d00dfeed" ] \
        || { echo "refusing: $IMG has no FIT image (u-boot.itb) at 8 MiB" >&2; exit 1; }
fi

[ -b "$DEV" ] || { echo "$DEV is not a block device" >&2; exit 1; }

# Never the disk the host runs from; ask before a non-removable one
# (JumpDrive's eMMC may report removable=0).
target_basename=$(basename "$DEV")
DEV_DISK=$(lsblk -no PKNAME "$DEV" 2>/dev/null | head -1)
[ -z "$DEV_DISK" ] && DEV_DISK="$target_basename"
ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null | sed 's|\[.*\]||')
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)
[ -z "$ROOT_DISK" ] && ROOT_DISK=$(basename "$ROOT_SRC")
if [ "$DEV_DISK" = "$ROOT_DISK" ] || [ "$target_basename" = "$ROOT_DISK" ]; then
    echo "refusing: $DEV is on the same disk as the host root ($ROOT_SRC)" >&2
    exit 1
fi
if [ "$(cat /sys/block/"$DEV_DISK"/removable 2>/dev/null || echo 0)" != "1" ]; then
    echo "warning: $DEV is not marked removable (fine for JumpDrive's eMMC)." >&2
    read -r -p "type FORCE to continue: " override
    [ "$override" = "FORCE" ] || { echo "aborted"; exit 1; }
fi

echo "==> about to overwrite $DEV with $IMG"
lsblk "$DEV" 2>/dev/null || true
read -r -p "type YES to confirm: " confirm
[ "$confirm" = "YES" ] || { echo "aborted"; exit 1; }

for m in $(lsblk -nrpo MOUNTPOINT "$DEV" 2>/dev/null | grep -v '^$'); do
    echo "==> unmounting $m"
    sudo umount "$m"
done

echo "==> writing image"
decompress | sudo dd of="$DEV" bs=4M conv=fsync status=progress
sudo sync

cat <<DONE

==> done.
microSD: put the card in the phone and power on.
eMMC:    power off, take out the JumpDrive card, power on.

Debug console: UART2 at 115200 baud on the 3.5 mm jack, enabled by the
DIP switch under the back cover. Boot progress shows on the RGB LED:
green = U-Boot started, yellow = kernel loaded, white = booting.

First boot takes a minute (the root partition grows to fill the disk).
DONE
