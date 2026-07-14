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
            // The custom template icon lives in the asset catalog, which only
            // Xcode builds compile; SwiftPM/CLT builds fall back to a symbol.
            if NSImage(named: "MenuBarIcon") != nil {
                Image("MenuBarIcon")
            } else {
                Image(systemName: "character.book.closed")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
