# SoundsRight Desktop

macOS menu bar app (Swift 5.9, SwiftUI, macOS 13+) that reads the currently selected text aloud with Chinese translation, and dictates speech into any app. Three activation flows, each with a global hotkey: Translation (⌘⌥X, floating panel fixed at screen center, transient unless pinned), Sound Only (⌘⌥Z, compact HUD at the cursor, promotable to the full panel via its expand button), and Dictation (⌃\`, HUD at the caret, text pasted where the cursor is). All are also reachable from the menu bar dropdown, which additionally lists recent lookups. An optional hover trigger (Settings → General → Activation, default off) fires the Translation flow automatically after text is selected with the mouse and the pointer briefly rests (`HoverTriggerMonitor`); keyboard shortcuts stay active either way, and hover-trigger failures are silent instead of toasting. Uses XcodeGen (`project.yml`) to generate the Xcode project; a SwiftPM path (`Scripts/build-app.sh`) builds the app bundle without an Apple Developer account.

## Build & Run

### With Xcode (canonical)

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
# Generate Xcode project (after changing project.yml or adding files)
xcodegen generate

# Build from command line
xcodebuild -scheme SoundsRight -configuration Debug build
```

### Without an Apple Developer account (SwiftPM)

```bash
./Scripts/build-app.sh   # release only — debug does not compile (see below)
```

Builds via SwiftPM, assembles `build.noindex/SoundsRight.app` by hand, and ad-hoc signs it (the `.noindex` directory name keeps Spotlight/Launchpad from listing the artifact as a duplicate of the installed app). To avoid mutating the canonical tree, it does not `swift build` the root package directly: it mirrors the sources into `build.noindex/src/` (via `rsync`, `.build` preserved for incremental builds), rewrites them for CLT (see the `@State` note below), copies `Package.swift` with the vendored-package path made absolute, and builds that copy with `--package-path`. Notes:

- `@State` does not compile under CLT on the macOS 27 SDK: the SDK ships it as a `State()` macro (in SwiftUICore) whose `SwiftUIMacros` compiler plugin is bundled only with full Xcode, so `swift build` fails with "external macro implementation type 'SwiftUIMacros.StateMacro' could not be found". A same-name local property wrapper can't win over the macro in attribute resolution. The workaround: `build-app.sh` rewrites every `@State` attribute (and bare `State(...)`/`State<...>` storage inits) to `@CLTState` in the build copy, where `SoundsRight/Utilities/StateMacroShim.swift` defines a `CLTState` property wrapper that forwards to `SwiftUI.State` (gated on `SWIFT_PACKAGE`, so Xcode keeps the real macro and compiles the shim to nothing). If you add a `@State`-adjacent form the rewrite doesn't recognize, extend the `perl` substitution in `build-app.sh`. `@StateObject`/`@Environment`/`@AppStorage`/`@ObservedObject` are unaffected — they remain plain property wrappers.
- KeyboardShortcuts is vendored at `Vendor/KeyboardShortcuts` with its `#Preview` blocks stripped, because the SwiftUI previews macro plugin ships only with full Xcode. Its upstream `globalKeyboardShortcut(_:)` view modifier is also stripped (unused by the app) — it uses `@State` and hits the same missing-plugin wall. Xcode builds still pull upstream via `project.yml`.
- Keep `#Preview` blocks in app sources wrapped in `#if DEBUG` so the release CLT build compiles them out. The debug configuration still cannot build under CLT — SwiftPM defines `DEBUG` there, so the previews compile and hit the missing Xcode-only macro plugin. Previews still work in Xcode's canvas.
- Ad-hoc signatures change on every rebuild, so macOS revokes the Accessibility grant each time. If hotkeys go dead after a rebuild, re-grant in System Settings → Privacy & Security → Accessibility.

### Tests

`SoundsRightTests/` is an XCTest target covering the pure logic (transcript cleanup, two-language arbitration, WAV encoding). Running it needs Xcode and, without a signing team, ad-hoc flags:

```bash
xcodebuild -scheme SoundsRight -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO test
```

It is not part of the SwiftPM package. Place new tests in `SoundsRightTests/`.

## Architecture

Single-target app with a `@main` SwiftUI entry point (`SoundsRightApp`) that lives entirely in the menu bar (`MenuBarExtra`). Core state is centralized in `AppState` (an `@MainActor ObservableObject`).

Key data flow: on hotkey press, `SelectionReader` captures the current selection by synthesizing ⌘C and reading the pasteboard (requires Accessibility permission; input is truncated to `maxInputLength` with a `wasTruncated` flag surfaced in the UI; the user's previous clipboard contents are restored afterwards, and the ⌘C keycode is resolved against the active keyboard layout). Failed activations always produce visible feedback (a cursor-anchored toast via `AppState.showToast`, or the Accessibility alert). Successful lookups are also recorded in `RecentLookupStore` (in-memory, surfaced in the menu bar dropdown). Then:

- **Single word** -> dictionary lookup via `api.dictionaryapi.dev`, raced against a plain Apple Translation of the word so unknown words aren't stuck behind a failed lookup (the richer dictionary result supersedes the translation in the UI when it lands); on macOS 15+ the definitions are then translated to Chinese in one batched `translations(from:)` call (English-only result on older macOS)
- **Multiple words** -> Apple Translation, en -> zh-Hans (macOS 15+ only)

Apple Translation runs in a single resident session for both paths (same en → zh-Hans pair): `TranslationSessionModifier` on `TranslationView` keeps its `.translationTask` closure looping over `AppState.beginTranslationWorkStream()`, so the session — and its loaded language models — survives across lookups, and the panel's `NSHostingController` is created once and reused for the same reason. Work is handed to the live loop through the stream's continuation, or parked in `pendingTranslationWork` and re-armed via `translationWorkTrigger` + configuration invalidation when no loop is running. Translation errors finish the stream so the next lookup starts a fresh session. Completed sentence translations and fully-translated dictionary entries are kept in in-memory LRU caches (`AppConstants.lookupCacheMaxEntries`), so repeat lookups render instantly; per-lookup latency is logged by `AppState.logLookupLatency`.

Either path feeds TTS synthesis -> audio playback. Results can be saved to Collections, persisted as JSON in `~/Library/Application Support/SoundsRight/`.

### TTS Fallback Chain

`TTSManager` (an actor) tries providers in order:
1. **AudioCache** -- two-tier LRU: in-memory (`audioCacheMaxEntries`) backed by JSON files in `~/Library/Application Support/SoundsRight/AudioCache/` (SHA-256 of text|voice|rate, `audioCacheDiskMaxBytes` cap, oldest-modification-first eviction). Cached entries carry word-boundary timings, so replays still drive read-along highlighting
2. **EdgeTTSService** -- Microsoft Edge TTS over WebSocket (American English; the voice is user-selectable in Settings → Playback between `avaNeural` and `emmaMultilingualNeural`, stored in `@AppStorage("ttsVoice")`). Returns `SynthesizedAudio` (audio bytes + `WordBoundary` timings parsed from `Path:audio.metadata` messages, which power read-along highlighting in the panel). Unofficial endpoint; requires network and a reasonably accurate system clock (auth token is time-derived). Bounded by a 10s idle timeout and a 30s overall synthesis deadline
3. **FallbackTTSService** -- macOS `AVSpeechSynthesizer` with `en-US` voice (no audio data returned, plays directly). `.fallbackUsed(generation)` means speech *started*; completion arrives via the handler registered with `TTSManager.setFallbackFinishedHandler`, tagged with the utterance generation so stale events are ignored. Pause/resume/stop are supported through `TTSManager`; loop and replay are not (no audio data)

`TTSResult.failed` is returned when Edge fails and fallback speech cannot start; callers must handle all three cases.

### Dictation

⌃\` records from the microphone and pastes the transcript at the caret; ⌃⇧\` does the same and additionally writes the audio to disk. Esc discards an in-flight dictation (`ShortcutManager.setDictationCancelEnabled` claims Esc only while recording, so it keeps its normal meaning otherwise). One hotkey serves both gestures: holding it past `dictationHoldThreshold` is push-to-talk, a quicker tap latches recording until the shortcut is pressed again.

`DictationController` (`@MainActor`) owns the flow; it is deliberately outside `AppState`, which is already the largest type in the app and shares nothing with dictation but the toast surface. `DictationRecorder` captures through `AVAudioEngine` into mono 16 kHz Float32 held in memory by a lock-guarded `SampleSink` (the tap runs on a real-time audio thread and cannot hop actors).

**Recordings are not saved by default.** Samples live in memory for one transcription and are then dropped; `DictationRecordingStore` writes a WAV plus a JSON sidecar to `~/Library/Application Support/SoundsRight/Dictation/` only when ⌃⇧\` fired. A saved recording is kept even if transcription failed.

`DictationManager` (an actor) routes the clip, mirroring the shape of `TTSManager`:

1. **WhisperKit** — Whisper large-v3-turbo via Core ML, downloaded from `argmaxinc/whisperkit-coreml` on first use (632 MB default). The only engine that keeps English words intact inside a Chinese sentence.
2. **AppleSpeechTranscriber** — `SpeechAnalyzer`/`SpeechTranscriber` on macOS 26+, `SFSpeechRecognizer` below. No download, so it transcribes clips recorded while the Whisper model is still installing, and catches any Whisper failure.

Clips are rejected before either engine sees them when they fall under `dictationMinDuration` or `dictationSilencePeakThreshold` — Whisper invents a fluent sentence out of room tone.

**Only two languages exist here (Mandarin and English), and both engines exploit that:**

- `WhisperKitTranscriber.resolveLanguage` runs Whisper's language detection, then reads *only* the `zh`/`yue`/`cmn` and `en` probabilities off the posterior. Whisper's unconstrained 99-way guess regularly lands on Japanese, Korean or Cantonese for Mandarin, and it then transcribes in that wrong language; clamping removes the whole failure class for one encoder pass. A near-tie (within `dictationLanguageConfidenceMargin`) resolves to Mandarin, because Whisper keeps embedded English verbatim inside a Chinese transcription but renders Chinese as pinyin under `en`.
- `AppleSpeechTranscriber` runs zh-CN and en-US concurrently over the same clip and keeps the better hypothesis (`bestHypothesis`). This is only affordable because the candidate set is two. Script purity cannot decide it — each recognizer emits its own script regardless of what it understood — so the score is carried by output *rate* plausibility (≈4 Han chars/sec, ≈2.5 English words/sec), adjusted by engine confidence and a purity sanity-check.

`DictationTextCleaner` normalizes every transcript: it strips non-speech annotations (`(music)`, `[BLANK_AUDIO]`, `♪`), and for Mandarin converts Traditional to Simplified via ICU's `Hant-Hans` transform and removes the spaces Whisper leaves between Han characters, while keeping the spaces around embedded Latin words.

`TextInserter` pastes at the caret: pasteboard snapshot → set text → synthesized ⌘V (keycode resolved against the active layout by `KeyboardLayout`, shared with `SelectionReader`) → restore after `dictationClipboardRestoreDelay`, and only if the change count still matches. Without the Accessibility grant it degrades to leaving the text on the clipboard and says so. `CaretLocator` anchors the HUD at the caret via the Accessibility API, falling back to the pointer.

## Project Structure

```
SoundsRight/
  App/           -- AppState, SoundsRightApp entry point
  Features/
    Translation/ -- dictionary lookup service and translation/dictionary models
                    (Apple Translation calls live in UI/TranslationView's
                    .translationTask modifiers)
    TTS/         -- TTSManager and all TTS service implementations
    Dictation/   -- DictationController (flow owner), DictationManager (engine
                    chain), WhisperKitTranscriber, AppleSpeechTranscriber,
                    DictationRecorder, DictationRecordingStore, models
    Audio/       -- AudioPlayer
    Shortcuts/   -- Global activation triggers: keyboard shortcuts and the
                    hover-selection monitor
    Collection/  -- Saved-items store and models (JSON persistence)
    History/     -- RecentLookupStore (automatic recents, JSON-persisted,
                    surfaced in the menu bar)
  UI/            -- SwiftUI views (TranslationView, MenuBarView, SettingsView,
                    DictationSettingsTab, FloatingPanel, PlaybackControls,
                    SoundOnlyHUD, DictationHUD, ToastView, WelcomeView,
                    CollectionWindowView, ReviewSessionView,
                    DictionaryDetailView)
  Utilities/     -- Constants, AudioCache, SelectionReader, TextInserter,
                    KeyboardLayout, CaretLocator
  Resources/     -- Assets.xcassets (app + menu bar icons); Info.plist and
                    SoundsRight.entitlements live at SoundsRight/ root
SoundsRightTests/ -- XCTest: smoke test plus dictation logic tests
Scripts/         -- build-app.sh (SwiftPM app-bundle build, no developer
                    account); generate-icons.swift (renders icon PNGs from code)
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

Strict concurrency is enabled (`SWIFT_STRICT_CONCURRENCY: complete`). All new code must compile without concurrency warnings. `AppState` and `DictationController` are `@MainActor`; `TTSManager`, `EdgeTTSService`, `DictationManager`, `WhisperKitTranscriber` and `AppleSpeechTranscriber` are `actor` types. `FallbackTTSService` and `AudioPlayer` are `@MainActor` NSObject subclasses (they must conform to AVFoundation delegate protocols, which actors cannot); their `nonisolated` delegate callbacks hop back onto the main actor before touching state.

Two patterns worth knowing before touching dictation:

- The `AVAudioEngine` tap runs on a real-time audio thread that must never await, so `DictationRecorder` writes into a lock-guarded `SampleSink: @unchecked Sendable` rather than an actor. That `@unchecked` is deliberate, not an escape hatch.
- `WhisperKit` is a non-Sendable class. It is stored inside `WhisperKitTranscriber` and never crosses out: the shared load task is `Task<Void, Never>` and hands the pipeline over through the actor's own `pipe` property. `@preconcurrency import WhisperKit` covers the rest.
- Reading `AttributedString` attributes uses the type subscript (`run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]`), not dynamic member lookup — the key-path form captures a non-Sendable `KeyPath` and warns.

## Dependencies

- **KeyboardShortcuts** (SPM) -- global hotkey registration. Xcode builds resolve it from GitHub (`project.yml`); SwiftPM builds use the vendored copy in `Vendor/`.
- **WhisperKit** (SPM, `argmaxinc/WhisperKit` from 0.18.0) -- pure-Swift Core ML runtime for Whisper. Chosen over whisper.cpp (OpenSuperWhisper's engine) because it needs no C++ toolchain, CMake submodule or Metal compiler, and therefore leaves the SwiftPM build path intact. Models are downloaded at runtime, so nothing is vendored.

## When Making Changes

- After adding or removing Swift files, run `xcodegen generate` to regenerate the Xcode project. The SwiftPM build picks up new files automatically (sources are globbed from `SoundsRight/`).
- Keep `AppConstants` as the single source of truth for URLs, limits, and keys.
- If modifying the TTS fallback chain, preserve the cache-first lookup and the Edge -> AVSpeech ordering.
- If modifying dictation, preserve three invariants: audio never touches disk unless the save shortcut fired; silent and too-short clips are rejected before any engine runs (Whisper hallucinates on room tone); and language detection stays clamped to Mandarin/English rather than trusting an engine's open-set guess.
- New UI views go in `UI/`; new feature domains get their own subdirectory under `Features/`.
- `project.yml` resolves KeyboardShortcuts as `from: "2.0.0"` (floating), so Xcode may pick up a newer 2.x than the vendored 2.4.0 on its own. Either pin an exact version in `project.yml`, or re-vendor `Vendor/KeyboardShortcuts` (and re-strip its `#Preview` blocks) whenever the resolved version changes.
- Icons are code-generated: edit `Scripts/generate-icons.swift` and run `swift Scripts/generate-icons.swift` from the repo root, then commit the regenerated PNGs. Xcode builds compile them from `Assets.xcassets` (`ASSETCATALOG_COMPILER_APPICON_NAME`). `build-app.sh` cannot run `actool`, so it packs the same PNGs by hand: App Icon → `.icns` via `iconutil`, menu bar → `MenuBarIcon{,@2x}.png` in `Contents/Resources`. The status-item label loads that image via `NSImage(named:)` + `Image(nsImage:)` (with `isTemplate` and an 18pt size), not SwiftUI's `Image("MenuBarIcon")` — the string form only resolves asset-catalog names, so using it after a successful `NSImage` check left a blank menu bar icon on the SwiftPM path. The SF Symbol fallback only fires if both paths omit the icon.
