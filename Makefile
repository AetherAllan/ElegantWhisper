APP_NAME := ElegantWhisper
BUILD_ROOT := build
BUNDLE := $(BUILD_ROOT)/$(APP_NAME).app
CONTENTS := $(BUNDLE)/Contents
MACOS := $(CONTENTS)/MacOS
RESOURCES := $(CONTENTS)/Resources

.PHONY: build run install clean

build:
	swift build -c release --product $(APP_NAME)

install: build
	rm -rf "$(BUNDLE)"
	mkdir -p "$(MACOS)" "$(RESOURCES)"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	cp Resources/AppIcon.icns "$(RESOURCES)/AppIcon.icns"
	cp Resources/ElegantWhisperLogo.png "$(RESOURCES)/ElegantWhisperLogo.png"
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" "$(MACOS)/$(APP_NAME)"
	chmod +x "$(MACOS)/$(APP_NAME)"
	# Ad-hoc signing changes the binary hash on every rebuild, so macOS treats each
	# install as a new app and privacy permissions must be re-granted in System Settings.
	codesign --force --deep --sign - "$(BUNDLE)"

run: install
	open "$(BUNDLE)"

clean:
	rm -rf .build "$(BUILD_ROOT)"
