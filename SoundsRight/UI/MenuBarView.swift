import SwiftUI
import KeyboardShortcuts

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var collectionStore: CollectionStore
    @ObservedObject var recentLookupStore: RecentLookupStore

    @Environment(\.dismiss) private var dismiss

    init(appState: AppState) {
        self.appState = appState
        self.collectionStore = appState.collectionStore
        self.recentLookupStore = appState.recentLookupStore
    }

    var body: some View {
        VStack(spacing: 0) {
            // The product's two gestures, named and labeled with their hotkeys —
            // the menu is where a new user learns the app exists beyond an icon.
            MenuRow(
                icon: "play.circle",
                label: "Speak Selection",
                detail: AppState.shortcutLabel(for: .soundOnlyClipboard)
            ) {
                activateFromMenu(.soundOnly)
            }

            MenuRow(
                icon: "character.book.closed",
                label: "Translate Selection",
                detail: AppState.shortcutLabel(for: .translateClipboard)
            ) {
                activateFromMenu(.translation)
            }

            if !recentLookupStore.items.isEmpty {
                MenuDivider()
                MenuSectionLabel(title: "Recent")

                ForEach(recentLookupStore.items.prefix(AppConstants.recentLookupsMenuLimit)) { lookup in
                    MenuRow(
                        icon: "clock.arrow.circlepath",
                        label: lookup.text,
                        detail: lookup.summary
                    ) {
                        dismiss()
                        appState.presentRecentLookup(lookup)
                    }
                }
            }

            MenuDivider()

            MenuRow(
                icon: "speaker.wave.2",
                label: "Auto-play: \(appState.autoPlay ? "On" : "Off")"
            ) {
                appState.autoPlay.toggle()
            }

            MenuRow(
                icon: "gauge.with.dots.needle.33percent",
                label: "Speed: \(appState.playbackRate.displayLabel)"
            ) {
                appState.cycleSpeed()
            }

            MenuDivider()

            MenuRow(
                icon: "bookmark",
                label: "Collection (\(collectionStore.items.count))"
            ) {
                appState.showCollectionWindow()
            }

            MenuRow(icon: "gear", label: "Settings") {
                appState.showSettings()
            }

            MenuRow(icon: "power", label: "Quit SoundsRight") {
                quit()
            }
        }
        .padding(.vertical, 4)
        .frame(width: 248)
    }

    /// Close the menu window first so key focus returns to the user's app
    /// before the synthetic ⌘C fires (AppState adds the settling delay).
    private func activateFromMenu(_ mode: ActivationMode) {
        dismiss()
        appState.activateFromMenu(mode: mode)
    }

    private func quit() {
        // terminate(nil) never returns to the run loop, so shutdown must complete first.
        Task { @MainActor in
            await appState.shutdown()
            NSApplication.shared.terminate(nil)
        }
    }
}

private struct MenuRow: View {
    let icon: String
    let label: String
    var detail: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundColor(Color(NSColor.secondaryLabelColor))

                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(Color(NSColor.labelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 110, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isHovered ? Color(NSColor.labelColor).opacity(0.07) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { isHovered = $0 }
    }
}

private struct MenuDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
    }
}

private struct MenuSectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(Color(NSColor.tertiaryLabelColor))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}
