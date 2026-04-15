# SoundsRight

A macOS menu bar app that reads selected text aloud with Chinese translation.

Select any text in any app, press the shortcut, and SoundsRight will:
- Pronounce it in American English using high-quality TTS (Edge TTS, with macOS system voice as fallback)
- Translate it to Simplified Chinese (macOS 15+)

## Modes

- **Translation Mode** — floating panel with translation + playback controls
- **Sound Only Mode** — compact HUD near your cursor, audio only, no translation

## Install (pre-built)

1. Download `SoundsRight.zip` from [Releases](../../releases)
2. Unzip and move `SoundsRight.app` to `/Applications`
3. Run this once in Terminal to clear the quarantine flag:
   ```bash
   xattr -cr /Applications/SoundsRight.app
   ```
4. Open the app — it lives in your menu bar

> The quarantine step is required because the app is not signed with an Apple Developer certificate.
> This is safe to do for apps you trust and built yourself or downloaded from a known source.

## Requirements

- macOS 13 (Ventura) or later
- Translation requires macOS 15 (Sequoia)
- Accessibility permission (the app will prompt on first launch)

## Build from source

### Prerequisites

- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

### Steps

```bash
git clone https://github.com/YOUR_USERNAME/SoundsRight.git
cd SoundsRight
xcodegen generate
open SoundsRight.xcodeproj
```

Then press **Cmd+R** in Xcode to build and run.

## Keyboard shortcut

Default: configurable in Settings. The app registers a global hotkey — set it to whatever feels natural (e.g. `Ctrl+Option+S`).

## Architecture

See [CLAUDE.md](CLAUDE.md) for technical architecture notes.
