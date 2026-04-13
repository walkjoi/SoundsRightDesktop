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
        MenuBarExtra("SoundsRight", systemImage: "character.book.closed") {
            MenuBarView(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}
