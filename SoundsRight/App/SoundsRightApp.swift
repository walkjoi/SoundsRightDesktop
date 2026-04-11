import SwiftUI

@main
struct SoundsRightApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("SoundsRight", systemImage: "character.book.closed") {
            MenuBarView(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}
