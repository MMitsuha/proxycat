#!/usr/bin/env bash
# Generates ProxyCat.xcodeproj via xcodegen.
#
# Resolves marketing version (from VERSION) and build number
# (from `git rev-list --count HEAD`) and exports them as the env vars
# that project.yml interpolates via ${PROXYCAT_MARKETING_VERSION} and
# ${PROXYCAT_BUILD_NUMBER}. Override either by exporting it before
# invoking the script.
#
# Usage:
#   ./scripts/generate-project.sh                   # normal
#   PROXYCAT_BUILD_NUMBER=1000 ./scripts/...        # pin build number
#   make project                                    # canonical entry point

set -euo pipefail

cd "$(dirname "$0")/.."

: "${PROXYCAT_MARKETING_VERSION:=$(cat VERSION 2>/dev/null || echo 0.1.0)}"
: "${PROXYCAT_BUILD_NUMBER:=$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
export PROXYCAT_MARKETING_VERSION PROXYCAT_BUILD_NUMBER

echo "==> xcodegen (v${PROXYCAT_MARKETING_VERSION} build ${PROXYCAT_BUILD_NUMBER})"
exec "${XCODEGEN:-xcodegen}" generate "$@"
