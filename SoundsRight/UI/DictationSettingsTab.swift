import SwiftUI
import KeyboardShortcuts

struct DictationSettingsTab: View {
    @ObservedObject var controller: DictationController

    /// View-local for the same reason as the Playback tab's voice picker: the
    /// AppKit-bridged pickers write their binding during the view-update pass,
    /// and routing that through an ObservableObject publishes mid-update. Same
    /// UserDefaults keys, so the controller still reads the values live.
    @AppStorage("dictationLanguage") private var languageRaw: String = DictationLanguage.auto.rawValue
    @AppStorage("dictationEngine") private var engineRaw: String = DictationEngine.whisper.rawValue
    @AppStorage("whisperModel") private var modelRaw: String = AppConstants.defaultWhisperModel.rawValue

    private var selectedLanguage: DictationLanguage {
        DictationLanguage(rawValue: languageRaw) ?? .auto
    }

    private var selectedEngine: DictationEngine {
        DictationEngine(rawValue: engineRaw) ?? .whisper
    }

    private var selectedModel: WhisperModelVariant {
        WhisperModelVariant(rawValue: modelRaw) ?? AppConstants.defaultWhisperModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Keyboard Shortcuts") {
                SettingsRow(label: "Dictate") {
                    KeyboardShortcuts.Recorder(for: .dictation)
                }
                SettingsRow(label: "Dictate & save recording") {
                    KeyboardShortcuts.Recorder(for: .dictationSaveRecording)
                }

                SettingsNote(
                    icon: "info.circle",
                    text: "Hold to dictate and release to finish, or tap once to start and tap again to stop. Esc discards."
                )
            }

            SettingsSection(title: "Language") {
                SettingsRow(label: "Spoken language") {
                    Picker("", selection: $languageRaw) {
                        ForEach(DictationLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 210)
                }

                SettingsNote(icon: "info.circle", text: selectedLanguage.settingsNote)
            }

            SettingsSection(title: "Engine") {
                SettingsRow(label: "Recognition engine") {
                    Picker("", selection: $engineRaw) {
                        ForEach(DictationEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 210)
                    .onChange(of: engineRaw) { _ in
                        controller.applyEngineChange()
                    }
                }

                SettingsNote(icon: "info.circle", text: selectedEngine.settingsNote)

                if selectedEngine == .whisper {
                    SettingsRow(label: "Model") {
                        Picker("", selection: $modelRaw) {
                            ForEach(WhisperModelVariant.allCases) { variant in
                                Text("\(variant.displayName) · \(variant.downloadSizeDescription)")
                                    .tag(variant.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(width: 180)
                        .onChange(of: modelRaw) { _ in
                            controller.applyModelChange()
                        }
                    }

                    SettingsNote(icon: "info.circle", text: selectedModel.settingsNote)

                    ModelStatusRow(status: controller.modelStatus) {
                        controller.downloadModelNow()
                    }
                }
            }

            SettingsSection(title: "Recordings") {
                SettingsNote(
                    icon: "lock.shield",
                    text: "Dictation audio stays in memory and is discarded after transcription. Only \(AppState.shortcutLabel(for: .dictationSaveRecording)) writes a file."
                )

                SettingsRow(label: "Saved recordings") {
                    Button("Show in Finder") {
                        controller.revealSavedRecordings()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.top, 8)
    }
}

/// Download / load progress for the Whisper model, with the action that starts
/// it so the user does not have to trigger it by dictating.
private struct ModelStatusRow: View {
    let status: WhisperModelStatus
    let onDownload: () -> Void

    var body: some View {
        SettingsRow(label: "Status") {
            switch status {
            case .notDownloaded:
                Button("Download now", action: onDownload)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

            case .downloading(let fraction):
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 100)
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Preparing…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)

            case .failed(let message):
                Button("Retry", action: onDownload)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .help(message)
            }
        }
    }
}

/// The explanatory line under a control, matching the General tab's treatment.
private struct SettingsNote: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

#if DEBUG
#Preview {
    DictationSettingsTab(controller: DictationController())
        .frame(width: 440, height: 600)
}
#endif
