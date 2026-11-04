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
- **Dictate** - Optional LLM cleanup that writes what you meant: removes fillers and repetitions, applies self-corrections, turns spoken lists into lists, and matches the tone of the app you are in.
- **Optional polishing** - Use OpenAI-compatible providers and Style Packs for conservative recognition cleanup.
- **Local history** - Completed dictations are saved locally and canceled recordings are ignored.

## How It Works

1. Focus a text field in another app.
2. Tap Right Option to start recording.
3. Speak naturally while the floating bar shows your voice level. Click its ✓ to finish or ✕ to cancel; keyboard focus stays in your app.
4. Tap Right Option again to stop.
5. ElegantWhisper finalizes the transcript, applies local corrections, optionally runs polishing, and inserts or copies the result.

Command shortcuts such as Cmd+V/C/A/Z and Option combined with other keys keep normal macOS behavior and do not start or stop recording.

## Privacy

- History, dictionary entries, Style Packs, and settings are stored locally.
- API credentials are stored in the macOS Keychain.
- Dictate and LLM polishing are **disabled by default**.
- Audio is processed through Apple's Speech framework on device.

### What stays on your Mac

When you start dictation, ElegantWhisper may read the **focused editable field** through Accessibility (same permission used for text insertion). It does **not** upload that field's contents unless you turn on the opt-in described in [Optional: text around the cursor](#optional-text-around-the-cursor). Instead it:

- Extracts up to **12 high-value tokens** (technical words, camelCase identifiers, etc.) from the focused field for local Apple Speech `contextualStrings`.
- Skips secure password fields and filters URLs, emails, and obvious secret-like strings before token extraction.
- Caps selected/visible snippet reads (2k / 4k characters) only to find those tokens; the snippets themselves are not sent to any API.
- With **Settings → General → Use words from the front window** (on by default), it also reads text from the window you are dictating into (for example a chat thread or web page) in the background while you speak. Only technical words and capitalized names (up to 200) are kept, and they are used solely to fix the spelling of the transcript on this Mac. Password fields, toolbars, and menus are skipped, and the read is capped at 2,500 elements, 60,000 characters, and 0.3 seconds.
- After recognition, a local spelling pass fixes near-misses of your Dictionary, on-screen, and Style Pack terms (for example "redisk" → "Redis", or a name split in two such as "Elegan的 Visper" → "ElegantWhisper"). It only changes Latin-script words that are a close match and are not ordinary English words; the one exception is casing for terms you added to your Dictionary ("slack" → "Slack").

### What leaves your Mac with online recognition

**Settings → Recognition → Provider** chooses who transcribes: **This Mac** (Apple, the default), **OpenAI**, or **OpenRouter**. Each online provider uses its own API key, stored in the Keychain; **Check Key** verifies it (and, for OpenRouter, that the chosen model exists) without uploading audio. With an online provider, each dictation's audio is uploaded once when you stop:

- **OpenAI** (`gpt-transcribe`): compressed M4A to OpenAI's `/v1/audio/transcriptions`, with language hints for the selected language plus English (for example `zh-cn` and `en`, so mixed Chinese and English is expected), up to **50 keyword hints**, and a one-line prompt naming the app you are dictating into.
- **OpenRouter** (pick a model, or type any OpenRouter speech-to-text model ID): base64 WAV to OpenRouter's `/api/v1/audio/transcriptions`, with one language code (for example `zh`) and the same keyword hints as `keyterms`. OpenRouter has no prompt field. If a model rejects the hints, the request is retried once without them and that model gets audio only for the next 7 days. Presets include OpenAI GPT Transcribe, Qwen3 ASR, Microsoft MAI-Transcribe 2, Meta Muse Voice Transcribe, Mistral Voxtral, and Whisper Large v3 Turbo, with OpenRouter's listed per-minute prices.
- Keyword hints are your Dictionary terms first, then technical words from the focused field and the front window, then Style Pack terms. Links, emails, and secret-like strings are never extracted as terms.

Apple's on-device model still runs during recording for the live preview, and its text is inserted if the request fails or takes longer than 15 seconds. Recordings shorter than 0.3 seconds are not uploaded. OpenAI and OpenRouter both list `gpt-transcribe` at about $0.0045 per minute of audio; other OpenRouter models range from about $0.0002 to $0.004 per minute.

### What leaves your Mac with Dictate or polishing

**Settings → Dictate → After recognition** chooses **As spoken** (the default: no language model), **Dictate**, or **Style pack**. With Dictate, the recognized text is rewritten by the model you pick under *Language model*: fillers (嗯, 呃, um) and repetitions are removed, self-corrections keep only the final wording, spoken lists become numbered lists, and punctuation is added. It is told never to answer, carry out, or translate what you said, and its output is checked before insertion: a reply ("Sure, here is…"), many words that were never spoken, a much longer text, or a dropped vocabulary term is rejected and the recognized text is inserted instead. Phrases of three words or fewer skip the model, and Dictate waits at most 5 seconds. With **Match the tone to the app** on, only the kind of app (chat, email, code editor or terminal, document, AI assistant), decided locally from its bundle identifier, is added to the prompt. History keeps the recognized text next to the rewrite (**Cleaned up** badge, **Copy as Recognized**).

The **OpenRouter** language-model provider lists fast models suited to Dictate and, with its key left empty, uses your OpenRouter key from **Recognition**. Reasoning is turned off for these requests and OpenRouter is asked to route them to the provider with the lowest recent latency. **Compare Models…** sends eight built-in test sentences (no dictation of yours) to each suggested model with your saved key, times every answer, checks it against Dictate's rules, and lets you switch to the fastest correct one; a full run costs about two cents.

If Dictate or polishing cannot run because of the key, credits, or model, the floating bar says why after inserting the recognized text.

Each Dictate or polish request sends to your configured OpenAI-compatible provider:

- The **final recognized transcript** (user message).
- The active **Style Pack** system prompt.
- Optional **local context** appended to the system prompt: foreground **app name** (≤40 characters) and up to **20 vocabulary hints** (AX-focused tokens plus active Style Pack seed terms, deduped)—not the full editor text.

No conversation history from prior dictations is sent. Each refinement is a single independent request.

### Optional: text around the cursor

**Settings → AI Provider → Send text around the cursor** is off by default. When you turn it on (and polishing is enabled), each polish request also includes up to **400 characters before and 120 after** the insertion point, so the model can match names, terms, and spelling already in your document. Secure password fields are skipped, and links, emails, and secret-like strings are replaced with `[redacted]` before sending. Fields that do not support range reads are only read in full when they hold 20,000 characters or fewer.

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

The Settings page has General, Recognition, Polishing, and Permissions tabs. Use it to configure:

- Appearance: **Standard** or **Prism** (black, with light split into a spectrum by a prism, for the main window and the floating bar)
- Recognition: provider (This Mac, OpenAI, or OpenRouter), model, per-provider API keys, language, and whether to use words from the front window. On this Mac you can pick Apple Speech (newer `SpeechTranscriber`, default) or Apple Dictation (classic `DictationTranscriber`); see **Privacy** for the online providers
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
