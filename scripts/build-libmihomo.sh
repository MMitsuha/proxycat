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
#   GOMOBILE                 gomobile binary or path; defaults to `gomobile`
#   LIBMIHOMO_OBFUSCATE=1     build through garble (see `make libmihomo-obf`)
#   LIBMIHOMO_GARBLE_FLAGS    extra garble flags (e.g. "-literals -tiny");
#                             empty by default. Only consulted when
#                             LIBMIHOMO_OBFUSCATE=1. The Makefile forwards
#                             `make libmihomo-obf GARBLE_FLAGS=…` here.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/Frameworks"
mkdir -p "$OUT"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing tool: $1" >&2; exit 127; }
}

GOMOBILE_BIN="${GOMOBILE:-gomobile}"
require go
require git
require "$GOMOBILE_BIN"
require strip

if [[ ! -f "$ROOT/mihomo/go.mod" ]]; then
  echo "error: mihomo submodule is not initialized" >&2
  echo "       run: make mihomo-init" >&2
  exit 2
fi

cd "$ROOT/libmihomo"

# Tidy with module replacement to local mihomo. tools.go pins
# golang.org/x/mobile/bind so gobind can resolve it.
go mod tidy

MODE="${1:-all}"
case "$MODE" in
  all) TARGETS="ios,iossimulator" ;;
  device) TARGETS="ios" ;;
  sim) TARGETS="iossimulator" ;;
  *)
    echo "usage: $0 [all|device|sim]" >&2
    exit 2
    ;;
esac

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
  # Default: empty — garble alone (symbol/package rename) is enough to
  # break binary-similarity hashes vs other mihomo apps. Override with
  # `make libmihomo-obf GARBLE_FLAGS=…` to add e.g. -literals (scramble
  # strings, biggest diversity gain) or -tiny (strip line/file info,
  # at the cost of zeroing runtime.Caller PCs in field stack traces).
  export LIBMIHOMO_GARBLE_FLAGS="${LIBMIHOMO_GARBLE_FLAGS:-}"
  # Allowlist of modules to obfuscate. GOGARBLE is *includes only* —
  # `module.MatchPrefixPatterns` has no `!` exclusion syntax (see
  # x/mod/module.go), so we have to enumerate what we want obfuscated
  # rather than excluding what breaks.
  #
  # We obfuscate the proxycat wrapper and mihomo core, since those are
  # the App Store binary-similarity concern (every other mihomo client
  # ships the same wrapper-shaped Go bridge over the same core). Lower-
  # level deps stay un-obfuscated:
  #   * gvisor — tcpip.InitStatCounters walks Stats with reflection and
  #     does `v.Addr().Interface().(**StatCounter|**IntegralStatCounterMap)`
  #     type assertions; under garble's name obfuscation those assertions
  #     misfire on the *IntegralStatCounterMap fields and the recursive
  #     fallback calls v.NumField() on a Ptr Value, panicking the NE at
  #     startTunnel. (Reproduced 2026-05-09 with garble v0.16.1-master.)
  #   * grpc/protobuf, crypto, net/http etc. — shared with every other
  #     mihomo app, so obfuscating them adds little binary diversity
  #     while extending the bug surface.
  # Override by setting GOGARBLE in the environment if you want to
  # widen or narrow this set.
  export GOGARBLE="${GOGARBLE:-github.com/proxycat,github.com/metacubex/mihomo,github.com/metacubex/sing*}"
  export LIBMIHOMO_REAL_PATH="$PATH"
  export PATH="$LIBMIHOMO_SHIM_DIR:$PATH"
  echo "==> Obfuscated build via $("$LIBMIHOMO_GARBLE_BIN" version | head -1)"
  echo "    GARBLE_FLAGS=$LIBMIHOMO_GARBLE_FLAGS"
  echo "    GOGARBLE=$GOGARBLE"
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
# mihomo/constant/version.go pins "1.10.0" as a placeholder that the
# upstream project never bumps — they always override via ldflags at
# build time (see mihomo/Makefile). We mirror their convention so the
# iOS app reports the same string `mihomo -v` would on a server: an
# exact tag for tagged commits, "alpha-<short>" / "beta-<short>" for
# pre-release channel tips, and `git describe --tags --always` as a
# last-resort fallback. Submodule is always in detached HEAD after
# `git submodule update`, so we probe ref reachability instead of
# `git branch --show-current`.
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MIHOMO_GIT="$ROOT/mihomo"
MIHOMO_SHORT="$(git -C "$MIHOMO_GIT" rev-parse --short HEAD 2>/dev/null || true)"
MIHOMO_COMMIT="$(git -C "$MIHOMO_GIT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
WRAPPER_COMMIT="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
if [[ -z "$MIHOMO_SHORT" ]]; then
  MIHOMO_VERSION="unknown"
elif EXACT_TAG="$(git -C "$MIHOMO_GIT" describe --tags --exact-match HEAD 2>/dev/null)"; then
  MIHOMO_VERSION="$EXACT_TAG"
elif git -C "$MIHOMO_GIT" merge-base --is-ancestor HEAD origin/Meta 2>/dev/null; then
  MIHOMO_VERSION="meta-$MIHOMO_SHORT"
elif git -C "$MIHOMO_GIT" merge-base --is-ancestor HEAD origin/Alpha 2>/dev/null; then
  MIHOMO_VERSION="alpha-$MIHOMO_SHORT"
else
  MIHOMO_VERSION="$(git -C "$MIHOMO_GIT" describe --tags --always 2>/dev/null || echo "$MIHOMO_SHORT")"
fi
LDFLAGS="-s -w"
LDFLAGS+=" -X 'github.com/metacubex/mihomo/constant.Version=$MIHOMO_VERSION'"
LDFLAGS+=" -X 'github.com/metacubex/mihomo/constant.BuildTime=$BUILD_TIME'"
LDFLAGS+=" -X 'github.com/proxycat/libmihomo.wrapperBuildTime=$BUILD_TIME'"
WRAPPER_TAG="$BUILD_TAGS"
[[ "$OBFUSCATE" == "1" ]] && WRAPPER_TAG="$WRAPPER_TAG +public"
LDFLAGS+=" -X 'github.com/proxycat/libmihomo.wrapperBuildTag=$WRAPPER_TAG'"
LDFLAGS+=" -X 'github.com/proxycat/libmihomo.mihomoCommit=$MIHOMO_COMMIT'"
LDFLAGS+=" -X 'github.com/proxycat/libmihomo.wrapperCommit=$WRAPPER_COMMIT'"

echo "==> gomobile bind target=$TARGETS tags=$BUILD_TAGS"
echo "    mihomo $MIHOMO_VERSION ($MIHOMO_COMMIT) built $BUILD_TIME"
"$GOMOBILE_BIN" bind \
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
