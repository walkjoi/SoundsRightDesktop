---
paths:
  - "SoundsRight/UI/**/*.swift"
---

# SwiftUI Patterns

- Views receive `AppState` as an `@ObservedObject` parameter, not via `@EnvironmentObject`. This keeps dependencies explicit.
- The floating panel is an `NSPanel` subclass (`FloatingPanel`), not a SwiftUI `Window`. Its content is an `NSHostingController` created once and reused, so the resident translation session survives across lookups; the HUDs, toasts and other windows use `NSHostingView`.
- Settings window is managed by `AppState.showSettings()` using `NSWindow` directly. Do not create a separate SwiftUI `Settings` scene.
- Use `@AppStorage` for user preferences that need persistence. Store new preference keys in `AppState` alongside existing ones (`autoPlay`, `playbackRate`); dictation keys live on `DictationController`.
- The menu bar entry uses `MenuBarExtra` with `.menuBarExtraStyle(.window)`. Keep menu items in `MenuBarView`.
