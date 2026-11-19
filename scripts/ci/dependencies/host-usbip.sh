#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
: "${PLANK_SOURCE_ROOT:?}" "${PLANK_DEP_ROOT:?}"
python3 "$PLANK_SOURCE_ROOT/scripts/package/stage-tangent-usbip.py" \
  --prepare --cache "$PLANK_DEP_ROOT/usbip"
