# ElegantWhisper

ElegantWhisper is a macOS 14+ menu-bar voice input app built with Swift Package Manager and AppKit.

It records with a single Option key tap, streams Apple Speech Recognition partial results, optionally applies conservative OpenAI-compatible correction, then inserts the final text into the focused editable field when it is safe to do so.

## Requirements

- macOS 14 or newer
- Swift toolchain / Xcode Command Line Tools
- Microphone permission
- Speech Recognition permission
- Accessibility permission

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

The app runs as `LSUIElement`, so it only appears in the menu bar and does not show a Dock icon.

## Stable Identifiers

- Product name: `ElegantWhisper`
- Executable name: `ElegantWhisper`
- App bundle: `ElegantWhisper.app`
- Bundle identifier: `com.aetherallan.ElegantWhisper`
- Application Support: `~/Library/Application Support/ElegantWhisper/`
- Models: `~/Library/Application Support/ElegantWhisper/Models/`
- UserDefaults suite: `com.aetherallan.ElegantWhisper`
- Keychain service: `com.aetherallan.ElegantWhisper`

## Permissions

Open the app once, then grant these permissions when prompted or from System Settings.

### Microphone

System Settings -> Privacy & Security -> Microphone -> enable ElegantWhisper.

### Speech Recognition

System Settings -> Privacy & Security -> Speech Recognition -> enable ElegantWhisper.

### Accessibility

System Settings -> Privacy & Security -> Accessibility -> enable ElegantWhisper.

Accessibility is required for the global Option key event tap and simulated Cmd+V insertion.

The menu bar includes `Permissions Status` with shortcuts to the relevant System Settings panes.

## Usage

- Tap left or right Command/Option once to start recording.
- Tap Command/Option again to stop recording and transcribe.
- Command/Option combined with other keys keeps normal macOS behavior and does not start or stop recording.
- Use `Cancel Recording` from the menu bar to cancel the current recording without transcription.
- If a valid editable field is focused, ElegantWhisper inserts the final text automatically.
- If no safe editable field is available, ElegantWhisper keeps the final text on the clipboard and shows `Text copied to clipboard`.

## Settings

Open `Settings` from the menu bar to configure:

- API Base URL
- API Key
- Model
- Request timeout
- Whether to keep text on the clipboard when no editable field is available

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
- LLM failures fall back to the raw Apple Speech result.
