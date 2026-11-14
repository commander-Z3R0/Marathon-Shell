#!/usr/bin/env bash
# Build a Marathon image for the PINE64 PinePhone Pro (pine64-pinephonepro,
# Rockchip RK3399S). Bring-up: not validated on hardware.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/build-image.sh" pine64-pinephonepro "$@"
