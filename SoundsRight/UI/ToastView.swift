import SwiftUI

/// A transient cursor-anchored capsule ("No text selected", "Copied translation").
/// Shown by `AppState.showToast(_:style:)`; never interactive, never key.
struct ToastView: View {
    enum Style {
        case info
        case notice

        var dotColor: Color {
            switch self {
            case .info: return .accentColor
            case .notice: return Color(red: 0.71, green: 0.25, blue: 0.18)
            }
        }
    }

    let message: String
    var style: Style = .info

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(style.dotColor)
                .frame(width: 6, height: 6)

            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .fixedSize()
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 3)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 12) {
        ToastView(message: "No text selected — select some text, then press the shortcut", style: .notice)
        ToastView(message: "Copied translation")
    }
    .padding()
}
#endif
