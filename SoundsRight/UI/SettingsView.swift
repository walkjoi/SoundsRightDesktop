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
                    PlaybackSettingsTab(appState: appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 420, height: 300)
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
            SettingsSection(title: "Keyboard Shortcut") {
                SettingsRow(label: "Trigger") {
                    KeyboardShortcuts.Recorder(for: .translateClipboard)
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
    @State private var selectedRate: PlaybackRate = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Voice") {
                SettingsRow(label: "Default Speed") {
                    Picker("", selection: $selectedRate) {
                        ForEach(PlaybackRate.allCases, id: \.self) { rate in
                            Text(rate.displayLabel).tag(rate)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .onChange(of: selectedRate) { newRate in
                        appState.playbackRateRaw = newRate.rawValue
                    }
                }
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
        .onAppear {
            if let rate = PlaybackRate(rawValue: appState.playbackRateRaw) {
                selectedRate = rate
            }
        }
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
