APP_NAME := ElegantWhisper
BUILD_ROOT := build
BUNDLE := $(BUILD_ROOT)/$(APP_NAME).app
XCODE_DERIVED_DATA := $(BUILD_ROOT)/XcodeDerivedData
XCODE_APP := $(XCODE_DERIVED_DATA)/Build/Products/Debug/$(APP_NAME).app
CONTENTS := $(BUNDLE)/Contents
MACOS := $(CONTENTS)/MacOS
RESOURCES := $(CONTENTS)/Resources
ENTITLEMENTS := Resources/ElegantWhisper.entitlements
XCODE_PROJECT := $(APP_NAME).xcodeproj
XCODE_SCHEME := $(APP_NAME)

# Prefer a stable Apple Development identity so macOS privacy permissions survive rebuilds.
# Override manually: make install SIGN_IDENTITY='Apple Development: Your Name (TEAMID)'
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $$2; exit }')

.PHONY: build run install clean sign-info xcode-build xcode-run xcode-clean

build:
	swift build -c release --product $(APP_NAME)

sign-info:
	@echo "Available signing identities:"
	@security find-identity -v -p codesigning || true
	@echo ""
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		echo "Will sign with: $(SIGN_IDENTITY)"; \
	else \
		echo "No Apple Development identity found. Will use ad-hoc signing (permissions reset each rebuild)."; \
		echo "Open Xcode → Settings → Accounts → your Apple ID → Manage Certificates → + → Apple Development"; \
	fi

install: build
	rm -rf "$(BUNDLE)"
	mkdir -p "$(MACOS)" "$(RESOURCES)"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	cp Resources/AppIcon.icns "$(RESOURCES)/AppIcon.icns"
	cp Resources/ElegantWhisperLogo.png "$(RESOURCES)/ElegantWhisperLogo.png"
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" "$(MACOS)/$(APP_NAME)"
	chmod +x "$(MACOS)/$(APP_NAME)"
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		echo "Signing with: $(SIGN_IDENTITY)"; \
		codesign --force --deep --sign "$(SIGN_IDENTITY)" --options runtime --entitlements "$(ENTITLEMENTS)" "$(BUNDLE)"; \
	else \
		echo "Signing ad-hoc (permissions will reset after each rebuild)"; \
		codesign --force --deep --sign - --entitlements "$(ENTITLEMENTS)" "$(BUNDLE)"; \
	fi
	@codesign --verify --deep --strict "$(BUNDLE)"
	@codesign -dv "$(BUNDLE)" 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|Signature'
	@codesign -d --entitlements - "$(BUNDLE)" 2>/dev/null | grep -q 'com.apple.security.device.audio-input'

run: install
	open "$(BUNDLE)"

xcode-build:
	@test -f Signing.xcconfig || (echo "Missing Signing.xcconfig. Run: cp Signing.xcconfig.example Signing.xcconfig" && exit 1)
	xcodebuild -project "$(XCODE_PROJECT)" -scheme "$(XCODE_SCHEME)" -configuration Debug -derivedDataPath "$(XCODE_DERIVED_DATA)" build

xcode-run: xcode-build
	open "$(XCODE_APP)"

xcode-clean:
	xcodebuild -project "$(XCODE_PROJECT)" -scheme "$(XCODE_SCHEME)" -configuration Debug -derivedDataPath "$(XCODE_DERIVED_DATA)" clean

clean:
	rm -rf .build "$(BUILD_ROOT)"
