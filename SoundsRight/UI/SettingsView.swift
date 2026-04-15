import SwiftUI
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Custom tab bar
            HStack(spacing: 0) {
                SettingsTab(title: "General", icon: "gear", isSelected: selectedTab == 0) {
                    selectedTab = 0
                }
                SettingsTab(title: "Playback", icon: "speaker.wave.2", isSelected: selectedTab == 1) {
                    selectedTab = 1
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Content
            Group {
                if selectedTab == 0 {
                    GeneralSettingsTab(appState: appState)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        PlaybackSettingsTab(appState: appState)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 420, height: 420)
        .background(.background)
    }
}

private struct SettingsTab: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct GeneralSettingsTab: View {
    @ObservedObject var appState: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Keyboard Shortcuts") {
                SettingsRow(label: "Translation") {
                    KeyboardShortcuts.Recorder(for: .translateClipboard)
                }
                SettingsRow(label: "Sound Only") {
                    KeyboardShortcuts.Recorder(for: .soundOnlyClipboard)
                }
            }

            SettingsSection(title: "Preferences") {
                SettingsRow(label: "Auto-play pronunciation") {
                    Toggle("", isOn: $appState.autoPlay)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SettingsRow(label: "Launch at Login") {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: launchAtLogin) { newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                launchAtLogin = !newValue
                            }
                        }
                }
            }
        }
        .padding(.top, 8)
    }
}

struct PlaybackSettingsTab: View {
    @ObservedObject var appState: AppState
    private let defaultColumns = [
        GridItem(.adaptive(minimum: 88, maximum: 120), spacing: 8, alignment: .leading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Playback") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Speed Preferences")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)

                            Text("Choose the default speed, then decide which speeds appear when you cycle during playback.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Button("Reset") {
                            appState.resetPlaybackRateOptions()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default Speed")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: defaultColumns, alignment: .leading, spacing: 8) {
                            ForEach(appState.availablePlaybackRates) { rate in
                                DefaultSpeedChip(
                                    rate: rate,
                                    isSelected: appState.playbackRate == rate,
                                    onSelect: { appState.setPlaybackRate(rate) }
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Included When Cycling")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 8) {
                            ForEach(PlaybackRate.allCases) { rate in
                                SpeedOptionRow(
                                    rate: rate,
                                    isEnabled: appState.isPlaybackRateEnabled(rate),
                                    isSelected: appState.playbackRate == rate,
                                    canDisable: canDisable(rate),
                                    onToggle: { toggleRate(rate) },
                                    onSelectDefault: { selectRate(rate) }
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Cycle range: 0.5x to 1.5x")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            }

            SettingsSection(title: "Test") {
                SettingsRow(label: "Preview voice") {
                    Button {
                        appState.currentText = "Hello, I am SoundsRight."
                        Task { await appState.playTTS() }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.ttsState.isPlayingOrLoading)
                }
            }
        }
        .padding(.top, 8)
    }

    private func selectRate(_ rate: PlaybackRate) {
        var updatedRates = appState.availablePlaybackRates

        if !updatedRates.contains(rate) {
            updatedRates.append(rate)
            appState.setPlaybackRateOptions(updatedRates)
        }

        appState.setPlaybackRate(rate)
    }

    private func toggleRate(_ rate: PlaybackRate) {
        var updatedRates = appState.availablePlaybackRates

        if let index = updatedRates.firstIndex(of: rate) {
            guard !isOnlyEnabledRate(rate) else { return }
            updatedRates.remove(at: index)
        } else {
            updatedRates.append(rate)
        }

        appState.setPlaybackRateOptions(updatedRates)
    }

    private func isOnlyEnabledRate(_ rate: PlaybackRate) -> Bool {
        appState.availablePlaybackRates.count == 1 && appState.isPlaybackRateEnabled(rate)
    }

    private func canDisable(_ rate: PlaybackRate) -> Bool {
        appState.isPlaybackRateEnabled(rate) && !isOnlyEnabledRate(rate)
    }
}

private struct DefaultSpeedChip: View {
    let rate: PlaybackRate
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(rate.displayLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(borderStyle, lineWidth: isSelected ? 1.4 : 1)
                )
        }
        .buttonStyle(.plain)
        .help("Set \(rate.displayLabel) as the default speed")
    }

    private var backgroundStyle: Color {
        isSelected ? Color.accentColor.opacity(0.14) : Color.white.opacity(0.001)
    }

    private var borderStyle: Color {
        isSelected ? .accentColor : Color.primary.opacity(0.10)
    }
}

private struct SpeedOptionRow: View {
    let rate: PlaybackRate
    let isEnabled: Bool
    let isSelected: Bool
    let canDisable: Bool
    let onToggle: () -> Void
    let onSelectDefault: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)

                    Text(rate.displayLabel)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)

                    if isSelected {
                        Text("Default")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
            }
            .buttonStyle(.plain)
            .help(isEnabled ? "Remove \(rate.displayLabel) from cycling" : "Include \(rate.displayLabel) when cycling")

            Spacer()

            if isEnabled && !isSelected {
                Button("Make Default") {
                    onSelectDefault()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.10), in: Capsule())
            }

            if !canDisable {
                Text("Required")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.20) : Color.clear, lineWidth: 1)
        )
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 2)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            Spacer()
            control
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 4)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(appState: AppState())
    }
}
