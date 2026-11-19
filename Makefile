APPLE_PROJECT := Apple/ProxyGauge.xcodeproj
APPLE_DERIVED := .build/xcode
XCODEBUILD_UNSIGNED := -derivedDataPath $(APPLE_DERIVED) CODE_SIGNING_ALLOWED=NO
XCODEBUILD_SIMULATOR_ADHOC := -derivedDataPath $(APPLE_DERIVED) CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- PROVISIONING_PROFILE_SPECIFIER=
ASC_ENV ?= $(HOME)/.appstoreconnect/asc.env
PLATFORM ?= all
BUMP ?= patch
RENDER_DIR ?= .build/renders

.PHONY: build test generate build-ios build-mac strings integration icon renders testflight testflight-confirm bump

build:
	swift build

test:
	swift test
	bun test scripts
	bun scripts/check-strings.ts

generate:
	bash scripts/apple-generate.sh

build-ios: generate
	xcodebuild -project $(APPLE_PROJECT) -scheme PhoneApp -configuration Debug -destination 'generic/platform=iOS Simulator' $(XCODEBUILD_SIMULATOR_ADHOC) build
	bun scripts/check-strings.ts --extracted $(APPLE_DERIVED) --targets PhoneApp,PhoneWidgets

build-mac: generate
	xcodebuild -project $(APPLE_PROJECT) -scheme MacApp -configuration Debug -destination 'generic/platform=macOS' $(XCODEBUILD_UNSIGNED) build
	bun scripts/check-strings.ts --extracted $(APPLE_DERIVED) --targets MacApp

strings:
	bun scripts/check-strings.ts --sync $(APPLE_DERIVED)

integration:
	bash scripts/integration.sh

renders: generate
	xcodebuild -project $(APPLE_PROJECT) -scheme MacApp -configuration Debug -destination 'generic/platform=macOS' $(XCODEBUILD_UNSIGNED) build
	rm -rf $(APPLE_DERIVED)/Build/Products/Debug/*.lproj
	cp -R $(APPLE_DERIVED)/Build/Products/Debug/*.app/Contents/Resources/*.lproj $(APPLE_DERIVED)/Build/Products/Debug/
	xcodebuild -project $(APPLE_PROJECT) -scheme RenderTool -configuration Debug -destination 'platform=macOS' $(XCODEBUILD_UNSIGNED) build
	$(APPLE_DERIVED)/Build/Products/Debug/RenderTool "$(RENDER_DIR)" -AppleLanguages '(en)' -AppleLocale en_US
	$(APPLE_DERIVED)/Build/Products/Debug/RenderTool "$(RENDER_DIR)" --polish -AppleLanguages '(pl)' -AppleLocale pl_PL

icon:
	swift scripts/render-icon.swift Apple/Assets.xcassets/AppIcon.appiconset

testflight-confirm:
	@test -n "$(CONFIRM)" || { echo "Refusing to upload: run make testflight CONFIRM=<bundle id> after checking the build." >&2; exit 2; }; test -f "$(ASC_ENV)" || { echo "Missing $(ASC_ENV)" >&2; exit 2; }

testflight: testflight-confirm
	$(MAKE) test
	$(MAKE) build-ios
	$(MAKE) build-mac
	@set -eu; set -a; . "$(ASC_ENV)"; set +a; bash scripts/appstore-upload.sh --confirm "$(CONFIRM)" --platform "$(PLATFORM)"

bump:
	bash scripts/bump-version.sh $(BUMP)
