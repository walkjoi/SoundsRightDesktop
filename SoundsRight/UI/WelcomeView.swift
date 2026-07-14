import SwiftUI
import KeyboardShortcuts

/// First-run guide: teaches the two hotkeys, walks through the Accessibility
/// grant *before* the first failed activation, and offers a sentence to try.
/// Reachable later from Settings → General → "Show Welcome Guide".
struct WelcomeView: View {
    @ObservedObject var appState: AppState

    @State private var isAccessibilityGranted = SelectionReader.isAccessibilityGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 20)

            stepRow(number: "1", title: "Allow Accessibility access") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SoundsRight reads your selection by simulating ⌘C, which needs one permission.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(isAccessibilityGranted ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(isAccessibilityGranted ? "Access granted" : "Not granted yet")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isAccessibilityGranted ? .secondary : .primary)

                        if !isAccessibilityGranted {
                            Button("Open System Settings") {
                                appState.requestAccessibilityAccess()
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                        }
                    }

                    if !isAccessibilityGranted {
                        Text("Already enabled in the list? Toggle it off and back on — the grant is tied to the exact build of the app.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            stepRow(number: "2", title: "Select text anywhere, press a shortcut") {
                VStack(alignment: .leading, spacing: 6) {
                    shortcutLine(
                        label: "Hear it spoken",
                        shortcut: AppState.shortcutLabel(for: .soundOnlyClipboard)
                    )
                    shortcutLine(
                        label: "Hear it + see the Chinese translation",
                        shortcut: AppState.shortcutLabel(for: .translateClipboard)
                    )
                }
            }

            stepRow(number: "3", title: "Try it on this sentence", isLast: true) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Serendipity means finding something good without looking for it.")
                        .font(.system(size: 13, weight: .medium))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

                    Text("Select the sentence above, then press \(AppState.shortcutLabel(for: .translateClipboard)).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 16)

            HStack {
                Spacer()
                Button("Get Started") {
                    appState.finishWelcome()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 512)
        .background(.background)
        // Re-check the grant whenever the user returns from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isAccessibilityGranted = SelectionReader.isAccessibilityGranted
        }
        // Live update: tccd broadcasts this when the trust table changes, so the
        // status flips the moment the user toggles the switch in System Settings —
        // without them having to click back on this window. Re-check after a short
        // delay because the notification can precede the table commit.
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: Notification.Name(AppConstants.accessibilityTrustChangedNotification)
            )
        ) { _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                isAccessibilityGranted = SelectionReader.isAccessibilityGranted
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppMark(size: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to SoundsRight")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                Text("Hear any English on your Mac — with Chinese alongside.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stepRow(
        number: String,
        title: String,
        isLast: Bool = false,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, isLast ? 0 : 18)
    }

    private func shortcutLine(label: String, shortcut: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(shortcut)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

/// The app's mark, drawn in SwiftUI so it renders identically in Xcode and
/// SwiftPM builds (the asset catalog is not compiled under Command Line Tools).
/// Mirrors the app icon: a cinnabar seal with 声 ("sound").
struct AppMark: View {
    let size: CGFloat

    var body: some View {
        Text("声")
            .font(.system(size: size * 0.56, weight: .semibold, design: .serif))
            .foregroundStyle(Color(red: 0.98, green: 0.96, blue: 0.93))
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.76, green: 0.30, blue: 0.22),
                        Color(red: 0.64, green: 0.22, blue: 0.15)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            )
    }
}

#if DEBUG
#Preview {
    WelcomeView(appState: AppState())
}
#endif
