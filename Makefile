APPLE_PROJECT := Apple/ProxyGauge.xcodeproj
APPLE_DERIVED := .build/xcode
XCODEBUILD_UNSIGNED := -derivedDataPath $(APPLE_DERIVED) CODE_SIGNING_ALLOWED=NO
XCODEBUILD_SIMULATOR_ADHOC := -derivedDataPath $(APPLE_DERIVED) CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- PROVISIONING_PROFILE_SPECIFIER=
ASC_ENV ?= $(HOME)/.appstoreconnect/asc.env
PLATFORM ?= all
BUMP ?= patch

.PHONY: build test generate build-ios build-mac strings integration icon testflight bump

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

icon:
	swift scripts/render-icon.swift Apple/Assets.xcassets/AppIcon.appiconset

testflight:
	@set -eu; test -n "$(CONFIRM)" || { echo "Refusing to upload: run make testflight CONFIRM=<bundle id> after checking the build." >&2; exit 2; }; test -f "$(ASC_ENV)" || { echo "Missing $(ASC_ENV)" >&2; exit 2; }; set -a; . "$(ASC_ENV)"; set +a; bash scripts/appstore-upload.sh --confirm "$(CONFIRM)" --platform "$(PLATFORM)"

bump:
	bash scripts/bump-version.sh $(BUMP)
