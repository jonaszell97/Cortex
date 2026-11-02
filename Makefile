.PHONY: bootstrap project open build build-ios check install install-ios migrate test test-app screenshots clean

# First checkout: fetch the vendored GRDB sources, create Local.xcconfig and
# generate the Xcode project.
bootstrap:
	git submodule update --init --recursive
	@test -f Config/Local.xcconfig || { cp Config/Local.xcconfig.example Config/Local.xcconfig; \
		echo "Created Config/Local.xcconfig: fill in DEVELOPMENT_TEAM and BUNDLE_ID_PREFIX."; }
	$(MAKE) project

# Regenerate Cortex.xcodeproj from project.yml (needs `brew install xcodegen`).
project:
	xcodegen generate --quiet

open: project
	open Cortex.xcworkspace

build: project
	xcodebuild -workspace Cortex.xcworkspace -scheme Cortex -configuration Debug \
		-destination 'platform=macOS' -allowProvisioningUpdates build

build-ios: project
	xcodebuild -workspace Cortex.xcworkspace -scheme CortexMobile -configuration Debug \
		-destination 'generic/platform=iOS Simulator' build

INSTALLED_APP = /Applications/Cortex.app
RELEASE_APP = build/install/Build/Products/Release/Cortex.app

# Release build, signed with the Apple Development certificate, copied to
# /Applications and restarted. Over SSH the login Keychain is locked for
# codesign, so it asks for your login password first (handed straight to
# `security`, never stored). If signing fails, the running app is left alone.
# A copy rather than a symlink, so cleaning build/ or moving the repository
# never breaks the installed app.
install: project
	@if [ -d "$$HOME/Library/Application Support/the-mind" ]; then \
		echo "error: the database of the-mind (the app's old name) has not moved yet. Run make migrate first."; \
		exit 1; \
	fi
	@if [ -n "$$SSH_CONNECTION" ]; then \
		echo "Over SSH: unlocking the login Keychain so codesign can use the signing key."; \
		security unlock-keychain ~/Library/Keychains/login.keychain-db; \
	fi
	xcodebuild -workspace Cortex.xcworkspace -scheme Cortex -configuration Release \
		-destination 'platform=macOS' -derivedDataPath build/install -allowProvisioningUpdates build
	@# The Accessibility permission belongs to the certificate; an ad-hoc or
	@# unsigned app would silently lose it (see docs/MANUAL_TESTS.md).
	@codesign -dv "$(RELEASE_APP)" 2>&1 | grep -q '^TeamIdentifier=[A-Z0-9]' || \
		{ echo "error: $(RELEASE_APP) is not signed with a team certificate; not installing."; exit 1; }
	@pkill -x Cortex && echo "Quit the running Cortex." || true
	@for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Cortex >/dev/null || break; sleep 0.5; done
	rm -rf "$(INSTALLED_APP)"
	ditto "$(RELEASE_APP)" "$(INSTALLED_APP)"
	open "$(INSTALLED_APP)"

IOS_APP = build/install-ios/Build/Products/Release-iphoneos/Cortex.app

# Release build of the iOS app, installed on an iPhone over the cable or the
# network. The device is DEVICE=<name or UDID>, else IOS_DEVICE from
# Config/Local.xcconfig; `xcrun devicectl list devices` lists them. The first
# build registers the App Group with your team (automatic signing).
install-ios: project
	@device="$(DEVICE)"; \
	if [ -z "$$device" ]; then device=$$(sed -n 's/^[[:space:]]*IOS_DEVICE[[:space:]]*=[[:space:]]*//p' Config/Local.xcconfig 2>/dev/null | tail -n 1); fi; \
	if [ -z "$$device" ]; then \
		echo "error: no device. Use make install-ios DEVICE=<name or UDID>, or set IOS_DEVICE in Config/Local.xcconfig:"; \
		xcrun devicectl list devices; exit 1; \
	fi; \
	xcodebuild -workspace Cortex.xcworkspace -scheme CortexMobile -configuration Release \
		-destination 'generic/platform=iOS' -derivedDataPath build/install-ios -allowProvisioningUpdates build && \
	xcrun devicectl device install app --device "$$device" "$(IOS_APP)"

# One-off after the rename from "the-mind": quits it, moves its database,
# quick action files and settings to Cortex's places and trashes
# /Applications/the-mind.app. Does nothing if there is nothing left to move.
# The bundle ID prefix comes from Config/Local.xcconfig, like in the builds.
migrate:
	@prefix=$$(sed -n 's/^[[:space:]]*BUNDLE_ID_PREFIX[[:space:]]*=[[:space:]]*//p' Config/Local.xcconfig 2>/dev/null \
		| tail -n 1 | tr -d '[:space:]'); \
		test -n "$$prefix" || { echo "error: no BUNDLE_ID_PREFIX in Config/Local.xcconfig (see make bootstrap)."; exit 1; }; \
		scripts/migrate-from-the-mind.sh "$$prefix"

# Compile both apps without signing (works over SSH). Builds into build/check:
# an unsigned app in Xcode's DerivedData could get launched by mistake, and a
# permission granted to it is pinned to that one build.
check: project
	xcodebuild -workspace Cortex.xcworkspace -scheme Cortex -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath build/check CODE_SIGNING_ALLOWED=NO build
	xcodebuild -workspace Cortex.xcworkspace -scheme CortexMobile -configuration Debug \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath build/check build

# Core package tests (storage, search, importers).
test:
	swift test --package-path CortexCore

# macOS app tests (pasteboard reading, paste write-back, monitor, palette keys
# and state), after checking the module boundaries (docs/ARCHITECTURE.md,
# "Repository layout"). Signed ad hoc so they also run over SSH, where the
# Keychain blocks the development certificate. Builds into build/test so the
# ad-hoc app never replaces the properly signed one in Xcode's DerivedData.
test-app: project
	scripts/check-modules.sh
	xcodebuild -workspace Cortex.xcworkspace -scheme Cortex -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath build/test \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test

# The README's screenshots and demo GIF (docs/images), drawn from the real
# palette on demo data by CortexTests/Screenshots and put on wallpapers by
# scripts/screenshots/compose.sh (docs/DEVELOPMENT.md, "Screenshots"). Needs ImageMagick and ffmpeg.
SCREENSHOTS = build/screenshots
screenshots: project
	rm -rf $(SCREENSHOTS)
	TEST_RUNNER_CORTEX_SCREENSHOTS="$(CURDIR)/$(SCREENSHOTS)" xcodebuild -workspace Cortex.xcworkspace -scheme Cortex \
		-configuration Debug -destination 'platform=macOS' -derivedDataPath build/test \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
		-testLanguage en -testRegion en_US -only-testing:CortexTests/ReadmeScreenshots test
	scripts/screenshots/compose.sh $(SCREENSHOTS)/raw docs/images

clean:
	rm -rf CortexCore/.build build

# Optional extra targets of your own, kept out of this file.
-include local.mk
