<p align="center">
  <img src="Resources/ElegantWhisperLogo.png" width="104" alt="ElegantWhisper icon">
</p>

<h1 align="center">ElegantWhisper</h1>

<p align="center">
  Native voice input for macOS.<br>
  Tap Right Option, speak naturally, and insert polished text anywhere.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6.3-orange" alt="Swift 6.3">
</p>


ElegantWhisper is a macOS 26+ Dock and menu-bar voice input app with a SwiftUI interface and AppKit system integration. It records with a single Right Option tap, transcribes with Apple's Speech framework, optionally applies OpenAI-compatible Style Pack polishing, then inserts the final text into the focused editable field when it is safe to do so.

## Why ElegantWhisper

- **Native macOS experience** - SwiftUI windows and menu-bar controls with AppKit global-hotkey and non-activating-panel behavior.
- **One-key dictation** - Tap Right Option to start, tap Right Option again to stop and transcribe.
- **Automatic insertion** - Inserts into the focused editor when possible; otherwise keeps the result on the clipboard.
- **Personal dictionary** - Correct project names, technical terms, people, and recurring recognition mistakes.
- **Optional polishing** - Use OpenAI-compatible providers and Style Packs for conservative recognition cleanup.
- **Local history** - Completed dictations are saved locally and canceled recordings are ignored.

## How It Works

1. Focus a text field in another app.
2. Tap Right Option to start recording.
3. Speak naturally while the floating bar shows audio level and partial text.
4. Tap Right Option again to stop.
5. ElegantWhisper finalizes the transcript, applies local corrections, optionally runs polishing, and inserts or copies the result.

Command shortcuts such as Cmd+V/C/A/Z and Option combined with other keys keep normal macOS behavior and do not start or stop recording.

## Privacy

- History, dictionary entries, Style Packs, and settings are stored locally.
- API credentials are stored in the macOS Keychain.
- LLM polishing is **disabled by default**.
- Audio is processed through Apple's Speech framework on device.

### What stays on your Mac

When you start dictation, ElegantWhisper may read the **focused editable field** through Accessibility (same permission used for text insertion). It does **not** upload that field's contents. Instead it:

- Extracts up to **12 high-value tokens** (technical words, camelCase identifiers, etc.) from the focused field for local Apple Speech `contextualStrings`.
- Skips secure password fields and filters URLs, emails, and obvious secret-like strings before token extraction.
- Caps selected/visible snippet reads (2k / 4k characters) only to find those tokens; the snippets themselves are not sent to any API.

### What leaves your Mac (only when LLM polishing is enabled)

Each polish request sends to your configured OpenAI-compatible provider:

- The **final recognized transcript** (user message).
- The active **Style Pack** system prompt.
- Optional **local context** appended to the system prompt: foreground **app name** (≤40 characters) and up to **20 vocabulary hints** (AX-focused tokens plus active Style Pack seed terms, deduped)—not the full editor text.

No conversation history from prior dictations is sent. Each refinement is a single independent request.

## Requirements

- macOS 26 or newer
- Xcode 26.6 and Swift 6.3 to build
- Microphone permission
- Speech Recognition permission
- Accessibility permission
- Input Monitoring permission

## Installation For Local Development

Create a local signing config once:

```sh
cp Signing.xcconfig.example Signing.xcconfig
```

Then edit `Signing.xcconfig` and replace `YOUR_TEAM_ID_HERE` with your Team ID from **Xcode -> Settings -> Accounts**. This file is gitignored; certificates and private keys stay in your macOS Keychain.

Build and run from Xcode:

```sh
open ElegantWhisper.xcodeproj
```

Or use SwiftPM:

```sh
make build
make run
```

Create a signed SwiftPM app bundle:

```sh
make install
```

The app bundle is created at:

```text
build/ElegantWhisper.app
```

The Makefile signs with the first available Apple Development identity when possible, and falls back to ad-hoc signing if none is available:

```sh
make sign-info
```

For distribution outside your own machine, use a Developer ID certificate and Apple notarization. See [docs/RELEASE.md](docs/RELEASE.md).

## Permissions

On first launch, ElegantWhisper walks through permissions, a short feature overview, and an optional in-app dictation exercise. The overview and exercise can be skipped and replayed later from About. Global hotkeys do not start until Accessibility and Input Monitoring are granted.

### Microphone

System Settings -> Privacy & Security -> Microphone -> enable ElegantWhisper.

`make install` signs the app with `Resources/ElegantWhisper.entitlements`, including `com.apple.security.device.audio-input`. If you manually re-sign the app, include that entitlements file; otherwise hardened runtime can block microphone access.

### Speech Recognition

System Settings -> Privacy & Security -> Speech Recognition -> enable ElegantWhisper.

ElegantWhisper uses Apple's Speech framework for transcription, and this permission makes that privacy boundary explicit.

### Accessibility

System Settings -> Privacy & Security -> Accessibility -> enable ElegantWhisper.

Accessibility is required to find the focused editable field and perform simulated Cmd+V insertion.

The Accessibility prompt is asynchronous. Return to ElegantWhisper after enabling it in System Settings; the onboarding window refreshes automatically. If macOS still reports the current process as untrusted, use **Restart & Continue**. During local development, avoid launching differently signed copies from several build directories because each copy can create a separate privacy entry.

### Input Monitoring

System Settings -> Privacy & Security -> Input Monitoring -> enable ElegantWhisper.

Input Monitoring is required for Right Option detection while ElegantWhisper is in the background or while another app is focused. ElegantWhisper checks Apple's ListenEvent permission with `CGPreflightListenEventAccess()` and `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`, then starts a listen-only `CGEventTap`. If that tap cannot be created on a developer build, it falls back to an `IOHIDManager` keyboard listener that uses the same Input Monitoring permission.

After enabling Input Monitoring, quit and reopen ElegantWhisper. macOS often requires a relaunch before a newly granted ListenEvent permission is visible to the running process.

The menu bar uses a compact native macOS menu for current state, language, microphone, LLM polishing, Settings, About, and app-window controls.

## Settings

Open Settings from the main window's `Application` sidebar section. The same section also contains About, including version, privacy summary, project link, and tutorial replay. `Settings…` in the menu bar and `Cmd+,` both reopen the same main window and select that page; Settings does not create a separate window.

The Settings page keeps its existing General, AI Provider, and Permissions tabs. Use it to configure:

- API Base URL, API Key, Model, and request timeout
- Whether to keep text on the clipboard when no editable field is available
- Whether to save local transcription history
- macOS permission shortcuts

Use the main window's Dictionary and Styles pages for personal terms, learning suggestions, and Style Pack prompt templates.

Learning suggestions are intentionally conservative. ElegantWhisper records only small, word-bounded corrections and shows a suggestion after the same correction is observed twice. One-off observations remain local so a later repeat can merge without interrupting the user.

History is stored at:

```text
~/Library/Application Support/ElegantWhisper/history.json
```

Dictionary entries are stored at:

```text
~/Library/Application Support/ElegantWhisper/dictionary.json
```

Style Packs are stored at:

```text
~/Library/Application Support/ElegantWhisper/style-packs.json
```

`LLM Refinement` is disabled by default. When enabled, each request sends the recognized transcript plus the active Style Pack prompt to an OpenAI-compatible `/chat/completions` endpoint. It may also include a short local-context block (foreground app name and up to 20 vocabulary hints: AX-focused tokens plus Style Pack seed terms—see **Privacy**).

## Languages

The `Language` menu supports:

- English
- 简体中文
- 繁體中文
- 日本語
- 한국어

The selected language is saved in the `com.aetherallan.ElegantWhisper` UserDefaults suite. The API key is stored in the macOS Keychain under the same stable service name.

## CI/CD

CI runs on GitHub Actions for every push to `main` and every pull request. It verifies:

- `swift test`
- `swift build -c release --product ElegantWhisper`
- unsigned Xcode Release build

Release CD is intentionally not enabled yet. Public distribution requires Developer ID signing, Apple notarization, and GitHub Secrets. See [docs/RELEASE.md](docs/RELEASE.md) for the release checklist.

## Stable Identifiers

- Product name: `ElegantWhisper`
- Executable name: `ElegantWhisper`
- App bundle: `ElegantWhisper.app`
- Bundle identifier: `com.aetherallan.ElegantWhisper`
- Application Support: `~/Library/Application Support/ElegantWhisper/`
- Transcription: Apple Speech framework
- UserDefaults suite: `com.aetherallan.ElegantWhisper`
- Keychain service: `com.aetherallan.ElegantWhisper`

## Manual Verification

After building, manually verify:

- Right Option alone starts and stops recording.
- Cmd+V/C/A/Z and Option with other keys still work normally.
- The floating recording panel does not steal focus from the original app.
- Text inserts into TextEdit, browser address fields, web inputs, and chat inputs.
- Switching to another editable field during transcription inserts into the current field.
- With no editable field, the result stays on the clipboard.
- Completed dictations appear in History; canceled dictations do not.
- Dictionary entries replace configured wrong forms after the final transcript.
- LLM failures fall back to the raw Apple Speech result.
- Style Pack prompt edits persist after relaunch, and Reset restores built-in prompts.
