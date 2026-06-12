# SoundsRight

A macOS menu bar app that reads selected text aloud with Chinese translation.

Select any text in any app, press the shortcut, and SoundsRight will:

- Pronounce it in American English using high-quality TTS (Edge TTS, with macOS system voice as fallback)
- Translate it to Simplified Chinese (macOS 15+) — full sentences via Apple Translation, single words via dictionary lookup with translated definitions
- Let you save results to Collections for later review

## Modes

- **Translation Mode** (default: `⌘⌥X`) — floating panel with translation + playback controls
- **Sound Only Mode** (default: `⌘⌥Z`) — compact HUD near your cursor, audio only, no translation

Both shortcuts are rebindable in Settings.

## Install on any Mac (recommended: build from source)

This is the most reliable way to run SoundsRight on each of your devices.
It needs **no Xcode, no Apple Developer account, and no Gatekeeper workarounds** —
macOS automatically trusts apps built on the same machine.

```bash
# 1. One-time: install Apple's Command Line Tools (skip if already installed)
xcode-select --install

# 2. Get the source and build (~1 minute)
git clone https://github.com/walkjoi/SoundsRightDesktop.git
cd SoundsRightDesktop
./Scripts/build-app.sh

# 3. Install and launch
cp -R build.noindex/SoundsRight.app /Applications/
open /Applications/SoundsRight.app
```

Then, on first launch (required on every Mac):

1. **Grant Accessibility permission** when prompted — System Settings →
   Privacy & Security → Accessibility. Without it the hotkeys silently do nothing.
2. Select text anywhere and press `⌘⌥X` (translation) or `⌘⌥Z` (sound only).
3. On macOS 15+, accept the one-time translation language model download when offered.

**Updating later** on that device:

```bash
cd SoundsRightDesktop
git pull
./Scripts/build-app.sh
cp -R build.noindex/SoundsRight.app /Applications/
```

> After each rebuild the ad-hoc code signature changes, so macOS silently
> invalidates the Accessibility grant — if the hotkeys stop working, toggle
> SoundsRight off and on in System Settings → Privacy & Security → Accessibility.
> "Launch at Login" registrations are tied to the signature the same way and may
> need re-enabling after a rebuild.

Builds are native to the Mac that builds them (Apple Silicon or Intel), so
building on each device — as above — also takes care of CPU architecture.

## Other ways to install

### Pre-built app (from Releases)

1. Download `SoundsRight.zip` from [Releases](../../releases)
2. Unzip and move `SoundsRight.app` to `/Applications`
3. Run this once in Terminal to clear the quarantine flag:
   ```bash
   xattr -cr /Applications/SoundsRight.app
   ```
4. Open the app — it lives in your menu bar

> The quarantine step is required because the app is not signed with an Apple
> Developer certificate. This is safe to do for apps you trust and built yourself
> or downloaded from a known source. Pre-built binaries are Apple Silicon only.

### Build with Xcode

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), plus a free Apple ID signed into Xcode (personal team)
for automatic signing — no paid Developer Program membership.

```bash
git clone https://github.com/walkjoi/SoundsRightDesktop.git
cd SoundsRightDesktop
xcodegen generate
open SoundsRight.xcodeproj
```

Then press **Cmd+R** in Xcode to build and run.

## Requirements

- macOS 13 (Ventura) or later
- Translation requires macOS 15 (Sequoia)
- Accessibility permission (the app will prompt on first launch)
- Internet connection for high-quality TTS and dictionary lookups (offline, playback falls back to the macOS system voice)

## Privacy

When you press a hotkey, the selected text is sent to Microsoft's Edge TTS endpoint
(`speech.platform.bing.com`) for speech synthesis, and single words are also sent to
the free `api.dictionaryapi.dev` dictionary API. Nothing is sent unless you trigger
the shortcut. Sentence translation uses Apple's on-device Translation framework.
The app briefly copies your selection through the clipboard and restores the previous
clipboard contents afterwards.

## Architecture

See [CLAUDE.md](CLAUDE.md) for technical architecture notes.
