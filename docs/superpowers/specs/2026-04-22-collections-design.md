# Collections — Design

## Goal

Let English learners save any word or phrase they look up, then reopen
that saved list to hear and review pronunciations. Primary use case is
study/review.

## Scope

Single flat list. **No** sub-collections, tags, search, flashcards,
export, or cross-device sync.

## User Flow

1. User selects text on a webpage, triggers the translate hotkey.
2. Floating translation panel appears as today.
3. Panel's playback controls now include a bookmark button. Clicking it
   saves the currently-shown item (word with phonetics and meanings, or
   phrase with translation).
4. User opens the menu bar, clicks `Collection (N)`. A dedicated
   window opens with the full list.
5. In the collection window, the user selects an item to see its detail
   (same visual treatment as the translation panel) and presses Play to
   hear it spoken. Delete via context menu or ⌫.

## Data Model

```swift
struct CollectionItem: Codable, Identifiable, Sendable {
    let id: UUID
    let sourceText: String        // original English, preserved as captured
    let createdAt: Date
    let content: Content
}

enum Content: Codable, Sendable {
    case word(phonetics: [String], meanings: [Meaning])
    case phrase(translation: String)

    struct Meaning: Codable, Sendable {
        let partOfSpeech: String
        let definition: String
        let translatedDefinition: String?
    }
}
```

- `sourceText` is the captured English. A trimmed, case-insensitive
  normalization of `sourceText` is used as the dedup key.
- `.word` mirrors `DictionaryResult` (word + phonetics + meanings with
  optional Chinese translation). `sourceText` is the word itself.
- `.phrase` holds the one-line Chinese translation. `sourceText` is the
  English phrase.

## Storage

- One JSON file at
  `~/Library/Application Support/SoundsRight/collection.json`.
- Entire array read once at app launch. Entire array rewritten on every
  mutation using an atomic write via a temp-file rename.
- Rationale: expected N in the low hundreds over the app's lifetime;
  JSON is trivial to debug, inspect, back up, and version. SwiftData
  would add an order of magnitude more code for no user benefit at this
  size.
- File-not-found on first launch is not an error — treat as empty list.
- Decode error: log, keep in-memory list empty, rename the broken file
  to `collection.corrupt-<timestamp>.json` so data isn't silently lost.

## Components

### `CollectionStore` (`@MainActor`, `ObservableObject`)

Lives in `Features/Collection/CollectionStore.swift`.

- `@Published private(set) var items: [CollectionItem]` — sorted
  newest-first in memory.
- `init()` — synchronously loads from disk. File I/O is a few KB; this
  keeps startup deterministic and avoids a flash-of-empty-list.
- `contains(sourceText:) -> Bool` — dedup check, normalized.
- `add(_ item: CollectionItem)` — inserts at index 0 if the normalized
  `sourceText` isn't already present. Returns silently if duplicate.
- `remove(id:)` — removes by id.
- `removeAll(ids:)` — bulk delete for keyboard multi-select later, but
  used for single delete in v1 for consistency.
- Every mutation enqueues a save on a private serial `Task` chain so
  rapid saves don't race or drop.

### `AppState` additions

- `let collectionStore = CollectionStore()` — created at init.
- `func saveCurrentToCollection()` — builds a `CollectionItem` from
  current `dictionaryResult` or `translation` + `currentText`, hands it
  to the store. No-op if nothing translatable is visible yet.
- `var isCurrentSavedInCollection: Bool` — drives the bookmark icon
  state in `PlaybackControls`.
- `func playCollectionItem(text: String)` — synthesizes via the
  existing `ttsManager` and plays via `audioPlayer`, without touching
  `currentText` / `translation`. Stops any prior playback.
- `func showCollectionWindow()` — mirrors `showSettings()`. Holds an
  `NSWindow` reference on `AppState`.

### `PlaybackControls` change

Add a bookmark icon button to the right of the speed pill. Icon:
`bookmark.fill` when saved, `bookmark` otherwise. Disabled while
`isTranslating` / `isTranslatingDefinitions` is true, or when
`currentText` is empty, or when neither a translation nor a dictionary
result is available yet.

### `MenuBarView` change

Add a row `Collection (N)` above the divider. `N` is
`appState.collectionStore.items.count`. Clicking opens the collection
window.

### `CollectionWindowView`

Lives in `UI/CollectionWindowView.swift`. Two-pane layout using
`NavigationSplitView` (macOS 13+):

- **Sidebar list** — `List(selection:)` of items, newest first. Each
  row shows:
  - SF Symbol: `character.book.closed` for `.word`, `text.bubble` for
    `.phrase`.
  - Source text, one line, truncated.
  - Relative date (`RelativeDateTimeFormatter`) as secondary text.
  - Context menu: Delete. ⌫ on selected rows also deletes.
- **Detail pane** — renders the selected item:
  - `.word` → reuses the same layout as the dictionary branch of
    `TranslationView` (large word, phonetics, meaning list with
    optional Chinese).
  - `.phrase` → source text on top, translation below, same typography
    as the sentence branch.
  - A Play button at the top of the detail area, wired to
    `appState.playCollectionItem(text: item.sourceText)`. It reflects
    loading/playing/error the same way `PlaybackControls` does.
- **Empty state** — centered gray text "Save words and phrases from the
  translation panel to see them here." shown when `items.isEmpty`.

### Extracted view

The detail pane and the current `TranslationView` share rendering for
the `.word` shape. Extract that into a reusable
`DictionaryDetailView(result: DictionaryResult)` and use it from both
sites. This is a targeted cleanup because the collection feature adds a
second consumer.

## Audio Playback in Review

- A single audio stream: `AppState.playCollectionItem` stops any
  in-flight panel playback before starting. The collection window
  shares `AppState`'s `audioPlayer`.
- Playback rate comes from the global `playbackRate` preference —
  reusing existing cache keys means a word already heard in the panel
  plays instantly from the audio LRU cache on review.
- Loop and speed controls are **not** added in v1; a single Play /
  Pause is enough for review.

## Error Handling

- Load failure (decode error): quarantine the file (rename with
  `.corrupt-<timestamp>`), start with an empty list, log via `Logger`.
- Save failure: log, surface nothing to the UI — the next successful
  save will persist the full current state.
- TTS playback errors during review: same `.error(String)` state as
  today; the detail pane's play button shows the same red warning
  affordance as `PlaybackControls` and retries on click.

## Concurrency

- `CollectionStore` is `@MainActor`; mutation and published state stay
  on the main actor.
- Disk writes run off-main by wrapping the serialized write in a
  `Task.detached(priority: .utility)` fed from a serial queue of
  pending writes. A private `private var pendingWrite: Task<Void,
  Never>?` chain suffices — each mutation awaits the prior task before
  writing.
- Codable types are all `Sendable`. Strict concurrency stays clean.

## File Layout

```
SoundsRight/
  Features/
    Collection/
      CollectionStore.swift
      CollectionItem.swift
  UI/
    CollectionWindowView.swift
    DictionaryDetailView.swift   (extracted from TranslationView)
```

After adding files, run `xcodegen generate`.

## Out of Scope

- Search, tags, folders, flashcards/SRS, export, import, iCloud sync.
- Editing saved items.
- Reordering the list manually.
- Showing saved-state on past items across multiple selections in a
  session (bookmark toggle is driven by the *current* selection only).
