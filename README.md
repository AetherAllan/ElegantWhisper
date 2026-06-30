# ElegantWhisper

ElegantWhisper is a macOS 14+ Dock and menu-bar voice input app built with Swift Package Manager and AppKit.

It records with a single left/right Command or Option key tap, streams Apple Speech Recognition partial results, optionally applies conservative OpenAI-compatible correction, then inserts the final text into the focused editable field when it is safe to do so.

## Requirements

- macOS 14 or newer
- Swift toolchain / Xcode Command Line Tools
- Microphone permission
- Speech Recognition permission
- Accessibility permission
- Input Monitoring permission

## Build

```sh
make build
```

## Create the App Bundle

```sh
make install
```

The signed app bundle is created at:

```text
build/ElegantWhisper.app
```

The Makefile uses ad-hoc signing:

```sh
codesign --force --deep --sign - build/ElegantWhisper.app
```

For distribution outside your machine, replace ad-hoc signing with a Developer ID certificate.

## Run

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
