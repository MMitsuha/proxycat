.PHONY: all libmihomo libmihomo-obf project version clean build sim help \
        assets geo-assets ui-assets clean-assets \
        mihomo-init mihomo-upgrade

XCODEGEN ?= xcodegen
GOMOBILE ?= gomobile

help:
	@echo "ProxyCat — iOS client for mihomo"
	@echo ""
	@echo "Targets:"
	@echo "  make libmihomo      build Frameworks/Libmihomo.xcframework via gomobile"
	@echo "  make libmihomo-obf  same, but routed through garble (App Store submissions)"
	@echo "  make project        run xcodegen (auto-fills version from VERSION + git)"
	@echo "  make version        print the marketing version + build number"
	@echo "  make all            libmihomo + project (run after first checkout)"
	@echo "  make build          full xcodebuild for the iOS app (needs codesigning)"
	@echo "  make sim            build for iOS Simulator (no codesigning)"
	@echo "  make assets         download geo dbs + metacubexd into BundledAssets/"
	@echo "  make geo-assets     download geoip / geosite / mmdb only"
	@echo "  make ui-assets      download metacubexd only"
	@echo "  make clean-assets   empty BundledAssets/{geo,ui} (keeps .gitkeep)"
	@echo "  make mihomo-init    init/refresh the mihomo submodule (run after clone)"
	@echo "  make mihomo-upgrade pull latest mihomo Alpha tip + rebuild xcframework"
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

mihomo-upgrade:
	@echo "==> Fetching latest mihomo Alpha tip"
	git submodule update --init --remote mihomo
	@printf "    now at %s (%s)\n" "$$(git -C mihomo rev-parse --short=12 HEAD)" "$$(git -C mihomo log -1 --format=%s)"
	@echo "==> Rebuilding xcframework"
	./scripts/build-libmihomo.sh
	@echo ""
	@echo "Mihomo upgraded. Commit the new pointer with:"
	@echo "  git add mihomo && git commit -m \"Bump mihomo to $$(git -C mihomo rev-parse --short=12 HEAD)\""

libmihomo:
	./scripts/build-libmihomo.sh

libmihomo-obf:
	LIBMIHOMO_OBFUSCATE=1 ./scripts/build-libmihomo.sh

project:
	XCODEGEN=$(XCODEGEN) ./scripts/generate-project.sh

version:
	@printf "MARKETING_VERSION  %s\n" "$$(cat VERSION 2>/dev/null || echo 0.1.0)"
	@printf "BUILD_NUMBER       %s\n" "$$(git rev-list --count HEAD 2>/dev/null || echo 1)"
	@printf "GIT_DESCRIBE       %s\n" "$$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"

build:
	xcodebuild -project ProxyCat.xcodeproj \
		-scheme Pcat \
		-configuration Debug \
		-destination 'generic/platform=iOS' \
		build

sim:
	xcodebuild -project ProxyCat.xcodeproj \
		-scheme Pcat \
		-configuration Debug \
		-sdk iphonesimulator \
		-destination 'generic/platform=iOS Simulator' \
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
	cd libmihomo && go clean -cache -modcache 2>/dev/null || true
