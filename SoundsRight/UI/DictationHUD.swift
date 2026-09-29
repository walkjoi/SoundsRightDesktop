import SwiftUI

/// Compact indicator shown next to the caret while dictating. Non-interactive
/// by design (the panel ignores mouse events): the hands are on the keyboard.
struct DictationHUD: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(spacing: 10) {
            switch controller.phase {
            case .recording:
                recordingContent
            case .transcribing:
                transcribingContent
            case .idle, .failed:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    controller.isSavingRecording ? Color.accentColor.opacity(0.45) : Color.clear,
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
    }

    // MARK: - Recording

    private var recordingContent: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.isSavingRecording ? "recordingtape" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .help(controller.isSavingRecording ? "Recording will be saved" : "Recording")

            LevelMeter(level: controller.level)

            Text(Self.timeLabel(controller.elapsed))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Divider().frame(height: 14)

            Text("Esc")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    // MARK: - Transcribing

    private var transcribingContent: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 14, height: 14)

            Text(transcribingLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var transcribingLabel: String {
        if case .downloading(let fraction) = controller.modelStatus,
           controller.preferredEngine == .whisper {
            return "Transcribing — Whisper model \(Int(fraction * 100))%"
        }
        return "Transcribing…"
    }

    private static func timeLabel(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Five bars that rise with the input level, so the user can see the mic is
/// live before they finish the first word.
private struct LevelMeter: View {
    let level: Float

    private static let barCount = 5

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(color(for: index))
                    .frame(width: 2.5, height: height(for: index))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    /// Each bar lights at its own threshold, so the meter reads as a level
    /// rather than five copies of the same value.
    private func fill(for index: Int) -> Double {
        let threshold = Double(index) / Double(Self.barCount)
        let span = 1.0 / Double(Self.barCount)
        return min(1, max(0, (Double(level) - threshold) / span))
    }

    private func height(for index: Int) -> CGFloat {
        // Taller in the middle even at rest, so an idle meter still looks like a meter.
        let base: CGFloat = index == 2 ? 6 : (index == 1 || index == 3 ? 5 : 4)
        return base + 10 * fill(for: index)
    }

    private func color(for index: Int) -> Color {
        fill(for: index) > 0.05 ? Color.accentColor : Color.secondary.opacity(0.28)
    }
}

#if DEBUG
#Preview {
    let controller = DictationController()
    return DictationHUD(controller: controller)
        .padding(40)
}
#endif
