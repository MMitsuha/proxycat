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

# Tags chosen to keep the binary small for the NE jetsam ceiling
# (~15MB historical, ~50MB on recent iOS):
#   with_gvisor      — keep the gvisor netstack. Required: iOS NE can't use
#                      sing-tun's "system" stack (sandbox blocks the kernel
#                      socket calls), see binding.go.
#   with_low_memory  — halve mihomo's per-connection relay buffers
#                      (TCP 32→16KB, UDP 16→8KB) and flip
#                      features.WithLowMemory true. Matches sing-box-for-apple's
#                      iOS build. Saves ~24KB per active connection
#                      (≈2.4MB at 100 concurrent connections).
BUILD_TAGS="with_gvisor with_low_memory"

# Inject mihomo + wrapper build identifiers so the iOS Settings →
# Diagnostics screen can show real values instead of "unknown time".
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MIHOMO_VERSION="$(grep -E '^\s*Version\s*=' "$ROOT/../mihomo/constant/version.go" | sed -E 's/.*"([^"]+)".*/\1/' | head -1)"
MIHOMO_COMMIT="$(git -C "$ROOT/../mihomo" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
LDFLAGS="-s -w"
LDFLAGS+=" -X 'github.com/metacubex/mihomo/constant.Version=$MIHOMO_VERSION'"
LDFLAGS+=" -X 'github.com/metacubex/mihomo/constant.BuildTime=$BUILD_TIME'"
LDFLAGS+=" -X 'github.com/proxycat/libmihomo.wrapperBuildTime=$BUILD_TIME'"
LDFLAGS+=" -X 'github.com/proxycat/libmihomo.wrapperBuildTag=$BUILD_TAGS'"
LDFLAGS+=" -X 'github.com/proxycat/libmihomo.mihomoCommit=$MIHOMO_COMMIT'"

echo "==> gomobile bind target=$TARGETS tags=$BUILD_TAGS"
echo "    mihomo $MIHOMO_VERSION ($MIHOMO_COMMIT) built $BUILD_TIME"
gomobile bind \
  -target="$TARGETS" \
  -tags="$BUILD_TAGS" \
  -trimpath \
  -ldflags="$LDFLAGS" \
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
