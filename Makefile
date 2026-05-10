.PHONY: all all-obf libmihomo libmihomo-obf project version clean build sim help \
        assets geo-assets ui-assets clean-assets \
        mihomo-init mihomo-upgrade mihomo-checkout require-development-team

XCODEGEN ?= xcodegen
XCODEBUILD ?= xcodebuild
GOMOBILE ?= gomobile
CONFIGURATION ?= Debug
SCHEME ?= Pcat
SIM_DESTINATION ?= generic/platform=iOS Simulator
DEVICE_DESTINATION ?= generic/platform=iOS

help:
	@echo "ProxyCat — iOS client for mihomo"
	@echo ""
	@echo "Targets:"
	@echo "  make libmihomo      build Frameworks/Libmihomo.xcframework via gomobile"
	@echo "  make libmihomo-obf  same, but routed through garble (App Store submissions)"
	@echo "                      (extra flags via GARBLE_FLAGS, e.g. GARBLE_FLAGS='-literals -tiny')"
	@echo "  make project        run xcodegen (auto-fills version + XCODE_DEVELOPMENT_TEAM)"
	@echo "  make version        print the marketing version + build number"
	@echo "  make all            libmihomo + project (run after first checkout)"
	@echo "  make all-obf        obfuscated libmihomo + project"
	@echo "  make build          full xcodebuild for the iOS app (needs codesigning)"
	@echo "  make sim            build for iOS Simulator (no codesigning)"
	@echo "  make assets         download geo dbs + metacubexd into BundledAssets/"
	@echo "  make geo-assets     download geoip / geosite / mmdb only"
	@echo "  make ui-assets      download metacubexd only"
	@echo "  make clean-assets   empty BundledAssets/{geo,ui} (keeps .gitkeep)"
	@echo "  make mihomo-init    init/refresh the mihomo submodule (run after clone)"
	@echo "  make mihomo-upgrade pull latest mihomo Meta tip + rebuild xcframework"
	@echo "  make mihomo-checkout REF=<ref>"
	@echo "                      pin mihomo to a tag/commit/branch + rebuild"
	@echo "                      (e.g. REF=v1.19.5, REF=35d5d4e4, REF=Alpha)"
	@echo "  make clean          wipe generated artifacts"
	@echo ""
	@echo "Prereqs:"
	@echo "  brew install xcodegen"
	@echo "  go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init"
	@echo "  go install mvdan.cc/garble@master   # only for libmihomo-obf (need post-v0.16.0 fix)"

all: mihomo-init libmihomo project

all-obf: mihomo-init libmihomo-obf project

mihomo-init:
	@if [ ! -f mihomo/go.mod ]; then \
		echo "==> Initializing mihomo submodule"; \
		git submodule update --init --recursive mihomo; \
	else \
		echo "==> mihomo submodule already initialized ($$(git -C mihomo rev-parse --short=12 HEAD))"; \
	fi

mihomo-upgrade: mihomo-init
	@echo "==> Fetching latest mihomo Meta"
	git -C mihomo fetch --tags --force origin
	git -C mihomo checkout --detach origin/Meta
	@printf "    now at %s (%s)\n" "$$(git -C mihomo rev-parse --short=12 HEAD)" "$$(git -C mihomo log -1 --format=%s)"
	$(MAKE) libmihomo
	@echo ""
	@echo "Mihomo upgraded to origin/Meta. Commit the new pointer with:"
	@echo "  git add mihomo && git commit -m \"Bump mihomo to $$(git -C mihomo rev-parse --short=12 HEAD)\""

mihomo-checkout:
	@if [ -z "$(REF)" ]; then \
		echo "error: REF is required" >&2; \
		echo "  usage: make mihomo-checkout REF=<commit|tag|branch>" >&2; \
		echo "  examples:" >&2; \
		echo "    make mihomo-checkout REF=v1.19.5" >&2; \
		echo "    make mihomo-checkout REF=35d5d4e44d7a" >&2; \
		echo "    make mihomo-checkout REF=Alpha" >&2; \
		exit 2; \
	fi
	@if [ ! -f mihomo/go.mod ]; then \
		echo "==> Initializing mihomo submodule"; \
		git submodule update --init --recursive mihomo; \
	fi
	@echo "==> Fetching mihomo refs from origin"
	git -C mihomo fetch --tags --force origin
	@echo "==> Checking out $(REF)"
	@git -C mihomo rev-parse --verify --quiet "$(REF)^{commit}" >/dev/null \
		|| git -C mihomo rev-parse --verify --quiet "origin/$(REF)^{commit}" >/dev/null \
		|| { echo "error: '$(REF)' does not resolve to a commit in mihomo/" >&2; exit 1; }
	@if git -C mihomo rev-parse --verify --quiet "refs/remotes/origin/$(REF)" >/dev/null \
			&& ! git -C mihomo rev-parse --verify --quiet "refs/tags/$(REF)" >/dev/null; then \
		git -C mihomo checkout --detach "origin/$(REF)"; \
	else \
		git -C mihomo checkout --detach "$(REF)"; \
	fi
	@printf "    now at %s (%s)\n" "$$(git -C mihomo rev-parse --short=12 HEAD)" "$$(git -C mihomo log -1 --format=%s)"
	$(MAKE) libmihomo
	@echo ""
	@echo "Mihomo pinned to $(REF). Commit the new pointer with:"
	@echo "  git add mihomo && git commit -m \"Pin mihomo to $$(git -C mihomo rev-parse --short=12 HEAD) ($(REF))\""

libmihomo:
	GOMOBILE="$(GOMOBILE)" ./scripts/build-libmihomo.sh

libmihomo-obf:
	GOMOBILE="$(GOMOBILE)" LIBMIHOMO_OBFUSCATE=1 LIBMIHOMO_GARBLE_FLAGS="$(GARBLE_FLAGS)" ./scripts/build-libmihomo.sh

project:
	XCODEGEN="$(XCODEGEN)" XCODE_DEVELOPMENT_TEAM="$(XCODE_DEVELOPMENT_TEAM)" ./scripts/generate-project.sh

version:
	@printf "MARKETING_VERSION  %s\n" "$$(cat VERSION 2>/dev/null || echo 0.1.0)"
	@printf "BUILD_NUMBER       %s\n" "$$(git rev-list --count HEAD 2>/dev/null || echo 1)"
	@printf "GIT_DESCRIBE       %s\n" "$$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
	@team="$(XCODE_DEVELOPMENT_TEAM)"; printf "DEVELOPMENT_TEAM   %s\n" "$${team:-<unset>}"

require-development-team:
	@if [ -z "$(XCODE_DEVELOPMENT_TEAM)" ]; then \
		echo "error: XCODE_DEVELOPMENT_TEAM is required for make build" >&2; \
		echo "       usage: XCODE_DEVELOPMENT_TEAM=ABCDE12345 make build" >&2; \
		exit 2; \
	fi

build: require-development-team project
	$(XCODEBUILD) -project ProxyCat.xcodeproj \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination '$(DEVICE_DESTINATION)' \
		build

sim: project
	$(XCODEBUILD) -project ProxyCat.xcodeproj \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-sdk iphonesimulator \
		-destination '$(SIM_DESTINATION)' \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		build

assets:
	./scripts/fetch-bundled-assets.sh all

geo-assets:
	./scripts/fetch-bundled-assets.sh geo

ui-assets:
	./scripts/fetch-bundled-assets.sh ui

clean-assets:
	@find BundledAssets/geo -mindepth 1 ! -name .gitkeep -delete 2>/dev/null || true
	@find BundledAssets/ui  -mindepth 1 ! -name .gitkeep -delete 2>/dev/null || true
	@echo "✓ BundledAssets/{geo,ui} cleared"

clean:
	rm -rf Frameworks/Libmihomo.xcframework
	rm -rf ProxyCat.xcodeproj
	rm -rf build
	cd libmihomo && go clean -cache 2>/dev/null || true
