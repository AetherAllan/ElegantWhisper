# Release Guide

ElegantWhisper does not enable release CD yet. CI proves that the code builds and tests; public distribution needs Developer ID signing and Apple notarization, which require private credentials.

## Recommended First Release

- Tag: `v0.1.0-alpha.1`
- Title: `ElegantWhisper 0.1 Alpha`
- GitHub Release: mark as pre-release
- Asset: `ElegantWhisper-v0.1.0-alpha.1-macOS.zip`
- Checksum: `ElegantWhisper-v0.1.0-alpha.1-macOS.zip.sha256`

## Required Secrets For Future CD

Do not commit these values. Store them as GitHub Actions secrets only when release automation is ready.

```text
DEVELOPER_ID_CERTIFICATE_P12_BASE64
DEVELOPER_ID_CERTIFICATE_PASSWORD
TEMP_KEYCHAIN_PASSWORD
APP_STORE_CONNECT_API_KEY_P8_BASE64
APP_STORE_CONNECT_KEY_ID
APP_STORE_CONNECT_ISSUER_ID
```

## Release Flow

1. Import the Developer ID Application certificate into a temporary keychain.
2. Build `ElegantWhisper.app` in Release configuration.
3. Sign with hardened runtime and `Resources/ElegantWhisper.entitlements`.
4. Verify the signature:

   ```sh
   codesign --verify --deep --strict --verbose=2 ElegantWhisper.app
   ```

5. Zip the app for notarization:

   ```sh
   ditto -c -k --keepParent ElegantWhisper.app ElegantWhisper.zip
   ```

6. Submit notarization with `notarytool` using an App Store Connect API key.
7. Wait for notarization to finish.
8. Staple the ticket:

   ```sh
   xcrun stapler staple ElegantWhisper.app
   ```

9. Recreate the final zip and checksum:

   ```sh
   ditto -c -k --keepParent ElegantWhisper.app ElegantWhisper-v0.1.0-alpha.1-macOS.zip
   shasum -a 256 ElegantWhisper-v0.1.0-alpha.1-macOS.zip > ElegantWhisper-v0.1.0-alpha.1-macOS.zip.sha256
   ```

10. Create the GitHub Release and upload both files.

## Release Notes Template

```markdown
## ElegantWhisper 0.1 Alpha

The first public preview of ElegantWhisper, a native voice input app for macOS.

### Highlights

- Right Option global dictation shortcut
- Floating transcription bar
- Personal dictionary and conservative corrections
- Optional OpenAI-compatible polishing
- Local transcription history
- Automatic insertion and clipboard fallback

### Requirements

- macOS 26 or later
- Microphone, Speech Recognition, Accessibility, and Input Monitoring permissions

### Installation

1. Download `ElegantWhisper-v0.1.0-alpha.1-macOS.zip`.
2. Extract the archive.
3. Move `ElegantWhisper.app` to Applications.
4. Open it and complete the permissions guide.

### Known limitations

- Apple Speech recognition quality varies by language and environment.
- Free LLM providers may be rate-limited or temporarily unavailable.
- Some applications expose editable fields inconsistently through Accessibility APIs.

### Integrity

SHA-256 checksums are attached to this release.
```
