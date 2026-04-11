---
paths:
  - "SoundsRight/UI/**/*.swift"
---

# SwiftUI Patterns

- Views receive `AppState` as an `@ObservedObject` parameter, not via `@EnvironmentObject`. This keeps dependencies explicit.
- The floating panel is an `NSPanel` subclass (`FloatingPanel`), not a SwiftUI `Window`. Content is hosted via `NSHostingView`.
- Settings window is managed by `AppState.showSettings()` using `NSWindow` directly. Do not create a separate SwiftUI `Settings` scene.
- Use `@AppStorage` for user preferences that need persistence. Store new preference keys in `AppState` alongside existing ones (`autoPlay`, `playbackRate`).
- The menu bar entry uses `MenuBarExtra` with `.menuBarExtraStyle(.window)`. Keep menu items in `MenuBarView`.
