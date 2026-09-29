import AppKit
import SwiftUI

@main
struct SoundsRightApp: App {
    @StateObject private var appState: AppState

    init() {
        let appState = AppState()
        _appState = StateObject(wrappedValue: appState)

        Task { @MainActor in
            await appState.initialize()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    /// Xcode serves `MenuBarIcon` from the compiled asset catalog; `build-app.sh`
    /// drops the same PNGs in `Contents/Resources`. `NSImage(named:)` finds either,
    /// but SwiftUI's `Image("MenuBarIcon")` only resolves catalog names — using it
    /// after a successful `NSImage(named:)` check produces a blank status item on
    /// the SwiftPM path. Always drive the label from the `NSImage` itself.
    @ViewBuilder
    private var menuBarLabel: some View {
        if let image = Self.menuBarTemplateImage {
            Image(nsImage: image)
        } else {
            Image(systemName: "character.book.closed")
        }
    }

    private static let menuBarTemplateImage: NSImage? = {
        guard let image = NSImage(named: "MenuBarIcon") else { return nil }
        // Catalog builds already mark the imageset as template; loose PNGs do not.
        image.isTemplate = true
        // Status items render at 18×18 pt; pin the size so a 36px @2x PNG isn't
        // treated as a 36pt image and clipped to nothing in the menu bar.
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
