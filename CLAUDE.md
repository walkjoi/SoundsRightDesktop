# SoundsRight Desktop

macOS menu bar app (Swift 5.9, SwiftUI, macOS 13+) that reads clipboard text aloud with translation. Uses XcodeGen (`project.yml`) to generate the Xcode project.

## Build & Run

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
# Generate Xcode project (after changing project.yml or adding files)
xcodegen generate

# Build from command line
xcodebuild -scheme SoundsRight -configuration Debug build
```

No test suite exists yet. When adding tests, use XCTest and place them in a `SoundsRightTests/` target.

## Architecture

Single-target app with a `@main` SwiftUI entry point (`SoundsRightApp`) that lives entirely in the menu bar (`MenuBarExtra`). Core state is centralized in `AppState` (an `@MainActor ObservableObject`).

Key data flow: clipboard text -> Apple Translation (macOS 15+) -> TTS synthesis -> audio playback.

### TTS Fallback Chain

`TTSManager` (an actor) tries providers in order:
1. **AudioCache** -- returns cached audio if available
2. **EdgeTTSService** -- Microsoft Edge TTS over WebSocket (American English, `avaNeural` voice)
3. **FallbackTTSService** -- macOS `AVSpeechSynthesizer` with `en-US` voice (no audio data returned, plays directly)

## Project Structure

```
SoundsRight/
  App/           -- AppState, SoundsRightApp entry point
  Features/
    Translation/ -- Apple Translation integration
    TTS/         -- TTSManager and all TTS service implementations
    Audio/       -- AudioPlayer
    Shortcuts/   -- Global keyboard shortcut handling
  UI/            -- SwiftUI views (TranslationView, MenuBarView, SettingsView, FloatingPanel, PlaybackControls)
  Utilities/     -- Constants, KeychainHelper, ClipboardMonitor, AudioCache
Scripts/         -- Python Kokoro TTS server and setup script
```

## Code Style

- Mark actors and `@MainActor` classes explicitly. Use `actor` for service types that manage mutable state across async boundaries.
- Use structured concurrency (`async let`, `TaskGroup`) over callbacks or Combine.
- Group code with `// MARK: -` sections in the order: Published State, Services, Lifecycle, Core Actions, then helpers.
- Errors: define domain-specific error enums conforming to `LocalizedError` inside their owning type.
- Logging: use `os.Logger` with subsystem `"com.soundsright.desktop"` and a per-type category.
- Keep constants in `AppConstants` enum (no stored instances).
- Prefer `guard let` for early exits; prefer `switch` exhaustiveness over default cases.

## Concurrency

Strict concurrency is enabled (`SWIFT_STRICT_CONCURRENCY: complete`). All new code must compile without concurrency warnings. `AppState` is `@MainActor`; TTS services are `actor` types.

## Dependencies

- **KeyboardShortcuts** (SPM) -- global hotkey registration
- **Kokoro Python server** -- Flask + kokoro + soundfile + numpy (see `Scripts/requirements.txt`)

## When Making Changes

- After adding or removing Swift files, run `xcodegen generate` to regenerate the Xcode project.
- Keep `AppConstants` as the single source of truth for URLs, limits, and keys.
- If modifying the TTS fallback chain, preserve the cache-first lookup and the Kokoro -> Edge -> AVSpeech ordering.
- New UI views go in `UI/`; new feature domains get their own subdirectory under `Features/`.
