import AppKit
import SwiftUI
import WiFiPilotCore

// MARK: - Formatting

enum Fmt {
    static func number(_ value: Double?, digits: Int = 0, fallback: String = "—") -> String {
        guard let value, value.isFinite else { return fallback }
        return String(format: "%.\(digits)f", value)
    }

    static func ms(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return number(value, digits: value >= 100 ? 0 : 1)
    }

    static func percent(_ value: Double?) -> String {
        number(value, digits: 1)
    }

    static func mbps(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value >= 100 ? number(value) : number(value, digits: 1)
    }

    /// Throughput is always derived from small controlled downloads, so it is shown
    /// with an approximation marker rather than as an exact link rate.
    static func approxMbps(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "≈" + mbps(value)
    }

    static func rssi(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f", value)
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

func scoreColor(_ score: Double) -> Color {
    switch score {
    case 78...: return .green
    case 60..<78: return .mint
    case 45..<60: return .yellow
    case 30..<45: return .orange
    default: return .red
    }
}

func modeColor(_ mode: AutomationMode) -> Color {
    switch mode {
    case .auto: return .accentColor
    case .observe: return .orange
    case .off: return .secondary
    }
}

// MARK: - Small components

struct SignalBars: View {
    let rssi: Double

    var body: some View {
        let level = SignalQuality.bars(rssi: rssi)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < level ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.22))
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }
        .accessibilityLabel("Signal \(LevelText.text(level: level))")
    }

    private enum LevelText {
        static func text(level: Int) -> String {
            switch level {
            case 4: "excellent"
            case 3: "good"
            case 2: "fair"
            case 1: "weak"
            default: "very weak"
            }
        }
    }
}

struct ScoreRing: View {
    let score: Double
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 6)
            Circle()
                .trim(from: 0, to: min(1, max(0, score / 100)))
                .stroke(scoreColor(score), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(String(format: "%.0f", score))
                    .font(.system(size: size * 0.3, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("score")
                    .font(.system(size: size * 0.13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct ScoreBadge: View {
    let score: Double
    var basis: ScoreBasis?

    var body: some View {
        HStack(spacing: 4) {
            Text(String(format: "%.0f", score))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if let basis, basis != .live {
                Image(systemName: basis == .historical ? "clock.arrow.circlepath" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.8)
            }
        }
        .foregroundStyle(scoreColor(score))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(scoreColor(score).opacity(0.13))
        )
        .help(basis?.displayName ?? "")
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var unit: String?
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let unit, value != "—" {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ModeBadge: View {
    let mode: AutomationMode

    var body: some View {
        Text(mode.displayName.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(modeColor(mode))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(modeColor(mode).opacity(0.14)))
    }
}

struct ScoreComponentBar: View {
    let component: ScoreComponent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(component.kind.displayName)
                    .font(.system(size: 11))
                Spacer()
                Text(component.isMeasured ? "\(Int(component.quality * 100))" : "n/a")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(scoreColor(component.quality * 100))
                        .frame(width: max(2, geometry.size.width * component.quality))
                }
            }
            .frame(height: 4)
            if !component.detail.isEmpty {
                Text(component.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
