# SoundsRight Desktop

macOS menu bar app (Swift 5.9, SwiftUI, macOS 13+) that reads the currently selected text aloud with Chinese translation. Two activation modes, each with a global hotkey: Translation (⌘⌥X, floating panel at a fixed user-controlled position persisted via frame autosave, transient unless pinned) and Sound Only (⌘⌥Z, compact HUD at the cursor, promotable to the full panel via its expand button). Both are also reachable from the menu bar dropdown, which additionally lists recent lookups. Uses XcodeGen (`project.yml`) to generate the Xcode project; a SwiftPM-based build path exists for machines without Xcode.

## Build & Run

### With Xcode (canonical)

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
# Generate Xcode project (after changing project.yml or adding files)
xcodegen generate

# Build from command line
xcodebuild -scheme SoundsRight -configuration Debug build
```

### Without Xcode (Command Line Tools only, no developer account)

```bash
./Scripts/build-app.sh   # release only — debug does not compile under CLT (see below)
```

Builds via SwiftPM (root `Package.swift`), assembles `build.noindex/SoundsRight.app` by hand, and ad-hoc signs it (the `.noindex` directory name keeps Spotlight/Launchpad from listing the artifact as a duplicate of the installed app). Notes:

- KeyboardShortcuts is vendored at `Vendor/KeyboardShortcuts` with its `#Preview` blocks stripped, because the SwiftUI previews macro plugin ships only with full Xcode. Xcode builds still pull upstream via `project.yml`.
- Keep `#Preview` blocks in app sources wrapped in `#if DEBUG` so the release CLT build compiles them out. The debug configuration still cannot build under CLT — SwiftPM defines `DEBUG` there, so the previews compile and hit the missing Xcode-only macro plugin. Previews still work in Xcode's canvas.
- Ad-hoc signatures change on every rebuild, so macOS revokes the Accessibility grant each time. If hotkeys go dead after a rebuild, re-grant in System Settings → Privacy & Security → Accessibility.

### Tests

`SoundsRightTests/` contains a smoke test target (XCTest). Running it requires full Xcode (`xcodebuild -scheme SoundsRight test`); it is not part of the SwiftPM package. Place new tests in `SoundsRightTests/`.

## Architecture

Single-target app with a `@main` SwiftUI entry point (`SoundsRightApp`) that lives entirely in the menu bar (`MenuBarExtra`). Core state is centralized in `AppState` (an `@MainActor ObservableObject`).

Key data flow: on hotkey press, `SelectionReader` captures the current selection by synthesizing ⌘C and reading the pasteboard (requires Accessibility permission; input is truncated to `maxInputLength` with a `wasTruncated` flag surfaced in the UI; the user's previous clipboard contents are restored afterwards, and the ⌘C keycode is resolved against the active keyboard layout). Failed activations always produce visible feedback (a cursor-anchored toast via `AppState.showToast`, or the Accessibility alert). Successful lookups are also recorded in `RecentLookupStore` (in-memory, surfaced in the menu bar dropdown). Then:

- **Single word** -> dictionary lookup via `api.dictionaryapi.dev`; on macOS 15+ the definitions are then translated to Chinese in the background (English-only result on older macOS)
- **Multiple words** -> Apple Translation, en -> zh-Hans (macOS 15+ only; runs inside `.translationTask` modifiers on `TranslationView`, so the panel must be visible)

Either path feeds TTS synthesis -> audio playback. Results can be saved to Collections, persisted as JSON in `~/Library/Application Support/SoundsRight/`.

### TTS Fallback Chain

`TTSManager` (an actor) tries providers in order:
1. **AudioCache** -- in-memory LRU (`audioCacheMaxEntries`), empty on each launch
2. **EdgeTTSService** -- Microsoft Edge TTS over WebSocket (American English; the voice is user-selectable in Settings → Playback between `avaNeural` and `emmaMultilingualNeural`, stored in `@AppStorage("ttsVoice")`). Unofficial endpoint; requires network and a reasonably accurate system clock (auth token is time-derived). Bounded by a 10s idle timeout and a 30s overall synthesis deadline
3. **FallbackTTSService** -- macOS `AVSpeechSynthesizer` with `en-US` voice (no audio data returned, plays directly). `.fallbackUsed(generation)` means speech *started*; completion arrives via the handler registered with `TTSManager.setFallbackFinishedHandler`, tagged with the utterance generation so stale events are ignored. Pause/resume/stop are supported through `TTSManager`; loop and replay are not (no audio data)

`TTSResult.failed` is returned when Edge fails and fallback speech cannot start; callers must handle all three cases.

## Project Structure

```
SoundsRight/
  App/           -- AppState, SoundsRightApp entry point
  Features/
    Translation/ -- dictionary lookup service and translation/dictionary models
                    (Apple Translation calls live in UI/TranslationView's
                    .translationTask modifiers)
    TTS/         -- TTSManager and all TTS service implementations
    Audio/       -- AudioPlayer
    Shortcuts/   -- Global keyboard shortcut handling
    Collection/  -- Saved-items store and models (JSON persistence)
    History/     -- RecentLookupStore (automatic in-memory recents, menu bar)
  UI/            -- SwiftUI views (TranslationView, MenuBarView, SettingsView,
                    FloatingPanel, PlaybackControls, SoundOnlyHUD, ToastView,
                    WelcomeView, CollectionWindowView, DictionaryDetailView)
  Utilities/     -- Constants, AudioCache, SelectionReader
  Resources/     -- Assets.xcassets (app + menu bar icons); Info.plist and
                    SoundsRight.entitlements live at SoundsRight/ root
SoundsRightTests/ -- XCTest smoke test
Scripts/         -- build-app.sh (SwiftPM build for machines without Xcode);
                    generate-icons.swift (renders all icon PNGs from code)
Vendor/          -- vendored KeyboardShortcuts (see Build & Run)
docs/            -- design specs
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

Strict concurrency is enabled (`SWIFT_STRICT_CONCURRENCY: complete`). All new code must compile without concurrency warnings. `AppState` is `@MainActor`; `TTSManager` and `EdgeTTSService` are `actor` types. `FallbackTTSService` and `AudioPlayer` are `@MainActor` NSObject subclasses (they must conform to AVFoundation delegate protocols, which actors cannot); their `nonisolated` delegate callbacks hop back onto the main actor before touching state.

## Dependencies

- **KeyboardShortcuts** (SPM) -- global hotkey registration. Xcode builds resolve it from GitHub (`project.yml`); SwiftPM builds use the vendored copy in `Vendor/`.

## When Making Changes

- After adding or removing Swift files, run `xcodegen generate` to regenerate the Xcode project. The SwiftPM build picks up new files automatically (sources are globbed from `SoundsRight/`).
- Keep `AppConstants` as the single source of truth for URLs, limits, and keys.
- If modifying the TTS fallback chain, preserve the cache-first lookup and the Edge -> AVSpeech ordering.
- New UI views go in `UI/`; new feature domains get their own subdirectory under `Features/`.
- `project.yml` resolves KeyboardShortcuts as `from: "2.0.0"` (floating), so Xcode may pick up a newer 2.x than the vendored 2.4.0 on its own. Either pin an exact version in `project.yml`, or re-vendor `Vendor/KeyboardShortcuts` (and re-strip its `#Preview` blocks) whenever the resolved version changes.
- Icons are code-generated: edit `Scripts/generate-icons.swift` and run `swift Scripts/generate-icons.swift` from the repo root, then commit the regenerated PNGs. Xcode builds compile them from `Assets.xcassets` (`ASSETCATALOG_COMPILER_APPICON_NAME`); `build-app.sh` packs the same PNGs into an `.icns` with `iconutil` (SwiftPM cannot compile asset catalogs). The menu bar icon is a template image with an SF Symbol fallback in `SoundsRightApp` for CLT builds, where the asset catalog is absent at runtime.
