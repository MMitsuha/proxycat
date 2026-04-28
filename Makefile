.PHONY: all libmihomo project clean build sim help

XCODEGEN ?= xcodegen
GOMOBILE ?= gomobile

help:
	@echo "ProxyCat — iOS client for mihomo"
	@echo ""
	@echo "Targets:"
	@echo "  make libmihomo   build Frameworks/Libmihomo.xcframework via gomobile"
	@echo "  make project     run xcodegen to (re)generate ProxyCat.xcodeproj"
	@echo "  make all         libmihomo + project (run after first checkout)"
	@echo "  make build       full xcodebuild for the iOS app (needs codesigning)"
	@echo "  make sim         build for iOS Simulator (no codesigning)"
	@echo "  make clean       wipe generated artifacts"
	@echo ""
	@echo "Prereqs:"
	@echo "  brew install xcodegen"
	@echo "  go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init"

all: libmihomo project

libmihomo:
	./scripts/build-libmihomo.sh

project:
	$(XCODEGEN) generate

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
		-destination 'platform=iOS Simulator,name=iPhone 15' \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		build

clean:
	rm -rf Frameworks/Libmihomo.xcframework
	rm -rf ProxyCat.xcodeproj
	rm -rf build
	cd libmihomo && go clean -cache -modcache 2>/dev/null || true
