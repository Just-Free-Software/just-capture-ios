import SwiftUI

/// Shared look for the whole app: one dark palette, one card style, one set
/// of status colours. Screens should reach for these instead of ad-hoc
/// opacities so spacing and contrast stay consistent.
enum Theme {
    static let background = Color(red: 0.04, green: 0.04, blue: 0.06)
    static let surface = Color.white.opacity(0.06)
    static let surfaceRaised = Color.white.opacity(0.10)
    static let stroke = Color.white.opacity(0.08)
    static let secondaryText = Color.white.opacity(0.6)
    static let tertiaryText = Color.white.opacity(0.4)

    static let accent = Color(red: 0.36, green: 0.55, blue: 1.0)
    static let record = Color(red: 1.0, green: 0.27, blue: 0.27)
    static let success = Color(red: 0.25, green: 0.84, blue: 0.53)
    static let warning = Color(red: 1.0, green: 0.68, blue: 0.2)

    static let cornerRadius: CGFloat = 18
    static let spacing: CGFloat = 16

    static let brandGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.35, blue: 0.35), Color(red: 0.62, green: 0.33, blue: 1.0)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension View {
    /// Standard content card used on Dashboard and detail screens.
    func card(padding: CGFloat = Theme.spacing) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
    }

    /// Translucent pill used for overlays on top of the camera preview.
    func overlayPill() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
    }
}

/// Small coloured capsule with an icon and label, e.g. "Uploaded".
struct StatusBadge: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Full-width banner for problems the user should know about right now.
struct NoticeBanner: View {
    enum Style {
        case error, warning, info

        var color: Color {
            switch self {
            case .error: return Theme.record
            case .warning: return Theme.warning
            case .info: return Theme.accent
            }
        }
    }

    let style: Style
    let systemImage: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(style.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(style.color)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(4)
                }
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(style.color.opacity(0.25)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Big number with a caption, used for session stats.
struct StatView: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum Formatters {
    static func duration(_ time: TimeInterval) -> String {
        let total = Int(time.rounded())
        let hours = total / 3600
        let minutes = total / 60 % 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension RecordingSession {
    var totalDuration: TimeInterval {
        chunks.reduce(0) { $0 + $1.duration }
    }

    var totalBytes: Int64 {
        chunks.reduce(0) { $0 + $1.fileSize }
    }

    var queuedCount: Int {
        chunks.filter { $0.status == .pending || $0.status == .uploading }.count
    }

    var uploadFraction: Double {
        totalCount == 0 ? 0 : Double(uploadedCount) / Double(totalCount)
    }

    /// One-word summary used by list rows and badges.
    var statusSummary: (text: String, icon: String, color: Color) {
        if isActive { return ("Live", "record.circle", Theme.record) }
        if totalCount == 0 { return ("Empty", "tray", Theme.tertiaryText) }
        if failedCount > 0 { return ("\(failedCount) failed", "exclamationmark.triangle.fill", Theme.warning) }
        if queuedCount > 0 { return ("Uploading", "arrow.up.circle.fill", Theme.accent) }
        return ("Backed up", "checkmark.icloud.fill", Theme.success)
    }
}
