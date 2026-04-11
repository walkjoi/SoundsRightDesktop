import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            MenuRow(icon: "text.quote", label: "Translate Clipboard") {
                Task { await appState.activate() }
            }

            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 2)

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

            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 2)

            MenuRow(icon: "gear", label: "Settings") {
                appState.showSettings()
            }

            MenuRow(icon: "power", label: "Quit SoundsRight") {
                quit()
            }
        }
        .padding(.vertical, 4)
        .frame(width: 220)
        .task {
            await appState.initialize()
        }
    }

    private func quit() {
        Task { await appState.shutdown() }
        NSApplication.shared.terminate(nil)
    }
}

private struct MenuRow: View {
    let icon: String
    let label: String
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
