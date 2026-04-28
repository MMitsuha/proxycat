#!/usr/bin/env bash
# Builds Libmihomo.xcframework from the Go wrapper using gomobile.
# Output: proxycat/Frameworks/Libmihomo.xcframework
#
# Prereqs (one-time, on a Mac):
#   go install golang.org/x/mobile/cmd/gomobile@latest
#   go install golang.org/x/mobile/cmd/gobind@latest
#   gomobile init
#
# Usage:
#   ./scripts/build-libmihomo.sh           # device + simulator slices
#   ./scripts/build-libmihomo.sh sim       # simulator-only (faster iteration)

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/Frameworks"
mkdir -p "$OUT"

cd "$ROOT/libmihomo"

# Tidy with module replacement to local mihomo. tools.go pins
# golang.org/x/mobile/bind so gobind can resolve it.
go mod tidy

TARGETS="ios,iossimulator"
if [[ "${1-}" == "sim" ]]; then
  TARGETS="iossimulator"
fi

# Tags chosen to keep the binary small for the NE 15MB jetsam ceiling:
#   no_gvisor      — drops gvisor netstack (we use sing-tun's gvisor wrapper instead)
#                    NOTE: do NOT pass this if the user picks gvisor stack at runtime.
#   with_gvisor    — keep gvisor (default)
# Default to "with_gvisor" since iOS users will want it for stack stability.
BUILD_TAGS="with_gvisor"

echo "==> gomobile bind target=$TARGETS tags=$BUILD_TAGS"
gomobile bind \
  -target="$TARGETS" \
  -tags="$BUILD_TAGS" \
  -trimpath \
  -ldflags="-s -w" \
  -o "$OUT/Libmihomo.xcframework" \
  github.com/proxycat/libmihomo

# Strip the xcframework's __TEXT to keep the NE process small. The xcframework
# Info.plist still validates after this; only the binaries are touched.
for slice in "$OUT/Libmihomo.xcframework"/*/Libmihomo.framework/Libmihomo; do
  if [[ -f "$slice" ]]; then
    strip -x "$slice" 2>/dev/null || true
  fi
done

echo "==> Built $OUT/Libmihomo.xcframework"
du -sh "$OUT/Libmihomo.xcframework"
