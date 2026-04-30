#!/usr/bin/env bash
# Builds Libmihomo.xcframework from the Go wrapper using gomobile.
# Output: proxycat/Frameworks/Libmihomo.xcframework
#
# Prereqs (one-time, on a Mac):
#   go install golang.org/x/mobile/cmd/gomobile@latest
#   go install golang.org/x/mobile/cmd/gobind@latest
#   gomobile init
#   # only for LIBMIHOMO_OBFUSCATE=1:
#   go install mvdan.cc/garble@master  # v0.16.0 panics on Go 1.26 generics; PR #1028 (post-tag) fixes it
#
# Usage:
#   ./scripts/build-libmihomo.sh           # device + simulator slices
#   ./scripts/build-libmihomo.sh sim       # simulator-only (faster iteration)
#
# Env:
#   LIBMIHOMO_OBFUSCATE=1   build through garble (see `make libmihomo-obf`)

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

# Optional garble obfuscation. App Store "Design - Spam" rejections happen
# when the binary similarity hash matches other apps embedding mihomo; garble
# renames symbols/packages and (with -literals) scrambles string literals so
# the binary diverges from every other mihomo-based shipper. gomobile bind
# itself has no obfuscation hook, so we substitute a `go` shim into PATH that
# routes `go build`/`go install` through garble while letting `go env`,
# `go list`, `go mod`, etc. fall through to the real toolchain. Garble
# itself spawns `go` via PATH lookup — see the SHIM heredoc for the loop
# break.
OBFUSCATE="${LIBMIHOMO_OBFUSCATE:-0}"
if [[ "$OBFUSCATE" == "1" ]]; then
  if ! command -v garble >/dev/null 2>&1; then
    echo "error: LIBMIHOMO_OBFUSCATE=1 but 'garble' is not on PATH" >&2
    echo "       install: go install mvdan.cc/garble@master" >&2
    exit 1
  fi
  LIBMIHOMO_REAL_GO="$(command -v go)"
  LIBMIHOMO_GARBLE_BIN="$(command -v garble)"
  LIBMIHOMO_SHIM_DIR="$(mktemp -d -t libmihomo-shim-XXXXXX)"
  trap 'rm -rf "$LIBMIHOMO_SHIM_DIR"' EXIT
  cat >"$LIBMIHOMO_SHIM_DIR/go" <<'SHIM'
#!/usr/bin/env bash
# Installed by scripts/build-libmihomo.sh when LIBMIHOMO_OBFUSCATE=1.
# Forward only build/install through garble; the rest stay on real go so
# gomobile's `go env`, `go list`, `go mod tidy`, `go version`, etc. behave
# normally. Garble's own internal `go` invocations resolve via PATH, so we
# must drop the shim dir from PATH before exec'ing garble — otherwise we
# loop (gomobile → shim → garble → shim → garble → …, growing -toolexec).
case "${1-}" in
  build|install)
    PATH="$LIBMIHOMO_REAL_PATH" exec "$LIBMIHOMO_GARBLE_BIN" $LIBMIHOMO_GARBLE_FLAGS "$@"
    ;;
  *)
    exec "$LIBMIHOMO_REAL_GO" "$@"
    ;;
esac
SHIM
  chmod +x "$LIBMIHOMO_SHIM_DIR/go"
  export LIBMIHOMO_REAL_GO LIBMIHOMO_GARBLE_BIN
  # -literals obfuscates strings/numbers — biggest contributor to binary
  # diversity vs other mihomo apps. Skip -tiny so log[level=warning]
  # stack frames stay readable (runtime.Caller would otherwise return
  # zero PCs, making field bug reports useless).
  export LIBMIHOMO_GARBLE_FLAGS="-literals"
  export LIBMIHOMO_REAL_PATH="$PATH"
  export PATH="$LIBMIHOMO_SHIM_DIR:$PATH"
  echo "==> Obfuscated build via $("$LIBMIHOMO_GARBLE_BIN" version | head -1)"
  echo "    GARBLE_FLAGS=$LIBMIHOMO_GARBLE_FLAGS"
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
MIHOMO_VERSION="$(grep -E '^\s*Version\s*=' "$ROOT/mihomo/constant/version.go" | sed -E 's/.*"([^"]+)".*/\1/' | head -1)"
MIHOMO_COMMIT="$(git -C "$ROOT/mihomo" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
LDFLAGS="-s -w"
LDFLAGS+=" -X 'github.com/metacubex/mihomo/constant.Version=$MIHOMO_VERSION'"
LDFLAGS+=" -X 'github.com/metacubex/mihomo/constant.BuildTime=$BUILD_TIME'"
LDFLAGS+=" -X 'github.com/proxycat/libmihomo.wrapperBuildTime=$BUILD_TIME'"
WRAPPER_TAG="$BUILD_TAGS"
[[ "$OBFUSCATE" == "1" ]] && WRAPPER_TAG="$WRAPPER_TAG +obfuscated"
LDFLAGS+=" -X 'github.com/proxycat/libmihomo.wrapperBuildTag=$WRAPPER_TAG'"
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
