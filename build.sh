#!/usr/bin/env bash
# Local build helper. Needs Theos installed and $THEOS set.
# macOS or Linux/WSL only -- not Windows.
#
#   ./build.sh            # rootful .deb
#   ./build.sh rootless   # rootless .deb (Dopamine / palera1n-rootless)
set -euo pipefail

if [ "${THEOS:-}" = "" ]; then
  echo "THEOS is not set. Install Theos first: https://theos.dev" >&2
  exit 1
fi

if [ "${1:-rootful}" = "rootless" ]; then
  export THEOS_PACKAGE_SCHEME=rootless
  echo ">> Building ROOTLESS package"
else
  echo ">> Building ROOTFUL package"
fi

make clean || true
make package FINALPACKAGE=1

echo
echo ">> Done. .deb is in ./packages/"
ls -1 packages/*.deb
