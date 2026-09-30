# SoundsRight

A macOS menu bar app that reads selected text aloud with Chinese translation, and types what you say.

Select any text in any app, press the shortcut, and SoundsRight will:

- Pronounce it in American English using high-quality TTS (Edge TTS, with macOS system voice as fallback)
- Translate it to Simplified Chinese (macOS 15+) — full sentences via Apple Translation, single words via dictionary lookup with translated definitions
- Let you save results to Collections for later review

Or press the dictation shortcut and speak — in Mandarin, English, or both in the same sentence — and the text appears wherever your cursor is.

## Modes

- **Translation Mode** (default: `⌘⌥X`) — floating panel with translation + playback controls
- **Sound Only Mode** (default: `⌘⌥Z`) — compact HUD near your cursor, audio only, no translation
- **Dictation** (default: `` ⌃` ``) — speak, and the transcript is pasted at your cursor
- **Dictation + save recording** (default: `` ⌃⇧` ``) — the same, but the audio is also written to disk

All shortcuts are rebindable in Settings.

## Dictation

Hold `` ⌃` `` while you speak and release to finish, or tap it once to start and again to stop. `Esc` throws the recording away.

**Two languages, deliberately.** SoundsRight only ever considers Mandarin and English, which is what makes it accurate for mixed speech. Say *"帮我把这个 function 改成 async"* and the English words stay English. General-purpose dictation tools guess from 99 languages and routinely transcribe Mandarin as Cantonese, Japanese, or Korean; SoundsRight reads only the Chinese and English scores off the same detection pass and picks between those two. You can also pin the language outright in Settings → Dictation, which skips detection entirely and is a little faster.

**Recordings are not saved.** Audio stays in memory for the few seconds it takes to transcribe, then it is gone. Only `` ⌃⇧` `` writes a file, to `~/Library/Application Support/SoundsRight/Dictation/`, alongside a small JSON file with the transcript. Settings → Dictation → Show in Finder opens that folder.

**Engines.** The default is Whisper large-v3-turbo running locally on the Neural Engine — nothing is uploaded, and it is the only option that handles a sentence mixing both languages. It needs a one-time 632 MB download, which starts in the background on first launch; until it finishes, dictation quietly uses the macOS built-in recognizer so the shortcut works right away. Settings → Dictation shows download progress and offers a larger, slightly more accurate model or a smaller, faster one.

## Install on any Mac (recommended: build from source)

This is the most reliable way to run SoundsRight on each of your devices.
It needs **no Apple Developer account and no Gatekeeper workarounds** —
macOS automatically trusts apps built on the same machine.

```bash
# 1. One-time: install Xcode from the App Store (see the note below)

# 2. Get the source and build (~1 minute)
git clone https://github.com/walkjoi/SoundsRightDesktop.git
cd SoundsRightDesktop
./Scripts/build-app.sh

# 3. Install and launch
cp -R build.noindex/SoundsRight.app /Applications/
open /Applications/SoundsRight.app
```

> Xcode is required because SwiftUI's `@State` became a compiler macro in SDK 27
> and the macro plugin ships only inside Xcode. It does **not** have to be your
> active toolchain — `build-app.sh` finds `/Applications/Xcode.app` on its own,
> so `xcode-select` can stay pointed at the Command Line Tools.

Then, on first launch (required on every Mac):

1. **Grant Accessibility permission** when prompted — System Settings →
   Privacy & Security → Accessibility. Without it the hotkeys silently do nothing.
2. Select text anywhere and press `⌘⌥X` (translation) or `⌘⌥Z` (sound only).
3. Press `` ⌃` `` and speak to try dictation — macOS will ask for **Microphone**
   access the first time.
4. On macOS 15+, accept the one-time translation language model download when offered.

**Updating later** on that device:

```bash
cd SoundsRightDesktop
git pull
./Scripts/build-app.sh
cp -R build.noindex/SoundsRight.app /Applications/
```

> After each rebuild the ad-hoc code signature changes, so macOS silently
> invalidates the Accessibility and Microphone grants — if the hotkeys or
> dictation stop working, toggle SoundsRight off and on in System Settings →
> Privacy & Security. "Launch at Login" registrations are tied to the signature
> the same way and may need re-enabling after a rebuild.

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
- Microphone permission for dictation
- Internet connection for high-quality TTS and dictionary lookups (offline, playback falls back to the macOS system voice), and once for the Whisper model download
- About 700 MB of disk for the Whisper model, stored outside the app bundle

## Privacy

**Lookups.** When you press a lookup hotkey, the selected text is sent to Microsoft's
Edge TTS endpoint (`speech.platform.bing.com`) for speech synthesis, and single words
are also sent to the free `api.dictionaryapi.dev` dictionary API. Nothing is sent
unless you trigger the shortcut. Sentence translation uses Apple's on-device
Translation framework. The app briefly copies your selection through the clipboard
and restores the previous clipboard contents afterwards.

**Dictation.** Your voice never leaves the machine. Transcription runs locally, either
through the bundled Whisper model or macOS's built-in recognizer; the only network
request dictation ever makes is the one-time model download from Hugging Face. Audio
is held in memory and discarded once the text is produced — nothing is written to disk
unless you use `` ⌃⇧` ``. To paste the result, the transcript goes onto the clipboard
for about 1.5 seconds and your previous clipboard contents are then restored.

## Architecture

See [CLAUDE.md](CLAUDE.md) for technical architecture notes.
