#!/usr/bin/env bash
# Populates BundledAssets/ with the canonical mihomo geo databases and
# the metacubexd external UI so the next build embeds them. Idempotent.
#
# Usage:
#   ./scripts/fetch-bundled-assets.sh         # geo + ui
#   ./scripts/fetch-bundled-assets.sh geo     # geo only
#   ./scripts/fetch-bundled-assets.sh ui      # external UI only
#
# Override the source URLs via env if you need a mirror:
#   GEO_BASE=...          base URL of the meta-rules-dat release
#   UI_TARBALL=...        full URL of the metacubexd compressed-dist tarball

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
GEO_DIR="$ROOT/BundledAssets/geo"
UI_DIR="$ROOT/BundledAssets/ui"

GEO_BASE="${GEO_BASE:-https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/release}"
# `<remote>[:<local>]` — when the remote name on the release branch
# differs from what mihomo expects on disk, list both sides separated
# by a colon. The release branch ships GeoLite2-ASN.mmdb; mihomo's
# default geox-url config points at ASN.mmdb in the home directory.
GEO_FILES=(
    geoip.dat
    geosite.dat
    country.mmdb
    GeoLite2-ASN.mmdb:ASN.mmdb
)
UI_TARBALL="${UI_TARBALL:-https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz}"

require() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }
}
require curl
require tar

# Replace contents of $1 with everything in $2, preserving the .gitkeep
# marker so git keeps tracking the directory after a clean.
sync_dir() {
    local dest="$1" src="$2"
    find "$dest" -mindepth 1 ! -name .gitkeep -delete
    # /. preserves dotfiles in the source (BSD + GNU cp).
    cp -R "$src"/. "$dest"/
}

fetch_geo() {
    mkdir -p "$GEO_DIR"
    for entry in "${GEO_FILES[@]}"; do
        # ${entry%%:*} → remote name, ${entry##*:} → local name. With
        # no colon both expansions return the whole string, so a plain
        # "geoip.dat" still works as a 1:1 mapping.
        local remote="${entry%%:*}"
        local local_name="${entry##*:}"
        if [ "$remote" = "$local_name" ]; then
            echo "  ↓ $local_name"
        else
            echo "  ↓ $local_name (from $remote)"
        fi
        # Stage to .tmp and rename so an interrupted curl never leaves
        # a half-written file mihomo would mmap as a corrupt database.
        curl -fL --progress-bar -o "$GEO_DIR/$local_name.tmp" "$GEO_BASE/$remote"
        mv "$GEO_DIR/$local_name.tmp" "$GEO_DIR/$local_name"
    done
    echo "  ✓ geo databases → $GEO_DIR"
}

fetch_ui() {
    mkdir -p "$UI_DIR"
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    echo "  ↓ metacubexd"
    curl -fL --progress-bar -o "$tmp/ui.tgz" "$UI_TARBALL"

    mkdir -p "$tmp/extracted"
    tar -xzf "$tmp/ui.tgz" -C "$tmp/extracted"

    # Some upstream tarballs wrap the bundle in a single top-level
    # directory (e.g. dist/), others lay files at the root. Detect.
    local entries=("$tmp/extracted"/*)
    local src
    if [ ${#entries[@]} -eq 1 ] && [ -d "${entries[0]}" ]; then
        src="${entries[0]}"
    else
        src="$tmp/extracted"
    fi
    sync_dir "$UI_DIR" "$src"
    echo "  ✓ external UI → $UI_DIR"
}

what="${1:-all}"
case "$what" in
    geo) fetch_geo ;;
    ui)  fetch_ui ;;
    all) fetch_geo; fetch_ui ;;
    *) echo "usage: $0 [geo|ui|all]" >&2; exit 2 ;;
esac
