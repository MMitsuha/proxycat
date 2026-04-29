.PHONY: all libmihomo project version clean build sim help \
        assets geo-assets ui-assets clean-assets

XCODEGEN ?= xcodegen
GOMOBILE ?= gomobile

help:
	@echo "ProxyCat — iOS client for mihomo"
	@echo ""
	@echo "Targets:"
	@echo "  make libmihomo     build Frameworks/Libmihomo.xcframework via gomobile"
	@echo "  make project       run xcodegen (auto-fills version from VERSION + git)"
	@echo "  make version       print the marketing version + build number"
	@echo "  make all           libmihomo + project (run after first checkout)"
	@echo "  make build         full xcodebuild for the iOS app (needs codesigning)"
	@echo "  make sim           build for iOS Simulator (no codesigning)"
	@echo "  make assets        download geo dbs + metacubexd into BundledAssets/"
	@echo "  make geo-assets    download geoip / geosite / mmdb only"
	@echo "  make ui-assets     download metacubexd only"
	@echo "  make clean-assets  empty BundledAssets/{geo,ui} (keeps .gitkeep)"
	@echo "  make clean         wipe generated artifacts"
	@echo ""
	@echo "Prereqs:"
	@echo "  brew install xcodegen"
	@echo "  go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init"

all: libmihomo project

libmihomo:
	./scripts/build-libmihomo.sh

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
