# ElegantWhisper

ElegantWhisper is a macOS 14+ Dock and menu-bar voice input app built with AppKit.

It records with a single left/right Command or Option key tap, streams Apple Speech Recognition partial results, optionally applies conservative OpenAI-compatible correction, then inserts the final text into the focused editable field when it is safe to do so.

## Requirements

- macOS 14 or newer
- Xcode 26 or newer, or a Swift toolchain with Xcode Command Line Tools
- Microphone permission
- Speech Recognition permission
- Accessibility permission
- Input Monitoring permission

## Local Signing

The Xcode project reads your Apple Development Team from a local `Signing.xcconfig` file. This file is gitignored and is never committed.

After cloning the repository, create your local signing config once:

```sh
cp Signing.xcconfig.example Signing.xcconfig
```

Then edit `Signing.xcconfig` and replace `YOUR_TEAM_ID_HERE` with your Team ID from **Xcode → Settings → Accounts**.

The committed `Signing.xcconfig.example` contains only a placeholder. Certificates and private keys stay in your macOS Keychain and are not stored in the repository.

## Build With Xcode

Open the project directly:

```sh
open ElegantWhisper.xcodeproj
```

Then select the `ElegantWhisper` scheme and run it from Xcode. The Xcode target uses the same bundle identifier, app name, Info.plist, icon, and entitlements as the command-line build:

- Bundle identifier: `com.aetherallan.ElegantWhisper`
- Entitlements: `Resources/ElegantWhisper.entitlements`
- Info.plist: `Resources/Info.plist`

You can also build the Xcode project from Terminal:

```sh
make xcode-build
```

The Xcode-built app is created at:

```text
build/XcodeDerivedData/Build/Products/Debug/ElegantWhisper.app
```

Run the Xcode-built app with:

```sh
make xcode-run
```

## Build With SwiftPM

The Swift Package Manager path is still available for fast command-line builds:

```sh
make build
```

## Create the SwiftPM App Bundle

```sh
make install
```

The signed app bundle is created at:

```text
build/ElegantWhisper.app
```

The Makefile signs with the first available Apple Development identity when possible, and falls back to ad-hoc signing if none is available:

```sh
make sign-info
```

For distribution outside your machine, use a Developer ID certificate and a notarization flow.

## Run The SwiftPM Bundle

```sh
make run
```

The app runs as a regular Dock app and also keeps a menu-bar status item for quick controls.

## Stable Identifiers

- Product name: `ElegantWhisper`
- Executable name: `ElegantWhisper`
- App bundle: `ElegantWhisper.app`
- Bundle identifier: `com.aetherallan.ElegantWhisper`
- Application Support: `~/Library/Application Support/ElegantWhisper/`
- Models: `~/Library/Application Support/ElegantWhisper/Models/`
- History: `~/Library/Application Support/ElegantWhisper/history.json`
- UserDefaults suite: `com.aetherallan.ElegantWhisper`
- Keychain service: `com.aetherallan.ElegantWhisper`

## Permissions

On first launch, ElegantWhisper shows a permissions window. Grant each required permission from that window. Global hotkeys do not start until Accessibility and Input Monitoring are granted.

### Microphone

System Settings -> Privacy & Security -> Microphone -> enable ElegantWhisper.

`make install` signs the app with `Resources/ElegantWhisper.entitlements`, including `com.apple.security.device.audio-input`. If you manually re-sign the app, include that entitlements file; otherwise hardened runtime can block microphone access.

### Speech Recognition

System Settings -> Privacy & Security -> Speech Recognition -> enable ElegantWhisper.

### Accessibility

System Settings -> Privacy & Security -> Accessibility -> enable ElegantWhisper.

Accessibility is required to find the focused editable field and perform simulated Cmd+V insertion.

### Input Monitoring

System Settings -> Privacy & Security -> Input Monitoring -> enable ElegantWhisper.

Input Monitoring is required for Command/Option detection while ElegantWhisper is in the background or while another app is focused. ElegantWhisper treats successful creation of its listen-only keyboard event tap as the operational permission check, and also shows `CGPreflightListenEventAccess()` / `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` diagnostics when that probe fails.

The menu bar includes `Permissions Status` with shortcuts to the relevant System Settings panes.

## Usage

- Tap left or right Command/Option once to start recording.
- Tap Command/Option again to stop recording and transcribe.
- Command/Option combined with other keys keeps normal macOS behavior and does not start or stop recording.
- Use `Cancel Recording` from the menu bar to cancel the current recording without transcription.
- If a valid editable field is focused, ElegantWhisper inserts the final text automatically.
- If no safe editable field is available, ElegantWhisper keeps the final text on the clipboard and shows `Text copied to clipboard`.

## Settings

Open `Open ElegantWhisper` from the menu bar to configure:

- API Base URL
- API Key
- Model
- Request timeout
- Whether to keep text on the clipboard when no editable field is available
- Whether to save local transcription history

The History section stores completed dictations locally. Canceled recordings are not saved.

`LLM Refinement` is disabled by default. When enabled, it sends only the final recognized text to an OpenAI-compatible `/chat/completions` endpoint and asks the model to fix obvious speech recognition errors without rewriting the text.

## Languages

The `Language` menu supports:

- English
- 简体中文
- 繁體中文
- 日本語
- 한국어

The selected language is saved in the `com.aetherallan.ElegantWhisper` UserDefaults suite. The API key is stored in the macOS Keychain under the same stable service name.

## Manual Verification

After building, manually verify:

- Command/Option alone starts and stops recording.
- Command/Option with other keys still works normally.
- The floating recording panel does not steal focus from the original app.
- Text inserts into TextEdit, browser address fields, web inputs, and chat inputs.
- Switching to another editable field during transcription inserts into the current field.
- With no editable field, the result stays on the clipboard.
- Completed dictations appear in History; canceled dictations do not.
- LLM failures fall back to the raw Apple Speech result.
