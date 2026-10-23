import SwiftUI

/// Jogga visual language: one accent, rounded numerals, grouped surfaces,
/// continuous corners, springs, numeric transitions.
enum Jogga {
    static let cardRadius: CGFloat = 26
    static let cardPadding: CGFloat = 20
    static let cardSpacing: CGFloat = 14
    static let pagePadding: CGFloat = 16

    static func numerals(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }

    /// Rounded navigation titles, like Fitness.
    static func configureAppearance() {
        let appearance = UINavigationBar.appearance()
        for (style, weight) in [(UIFont.TextStyle.largeTitle, UIFont.Weight.bold),
                                (.headline, .semibold)] {
            let base = UIFont.systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: weight
            )
            let font = base.fontDescriptor.withDesign(.rounded)
                .map { UIFont(descriptor: $0, size: 0) } ?? base
            let scaled = UIFontMetrics(forTextStyle: style).scaledFont(for: font)
            if style == .largeTitle {
                appearance.largeTitleTextAttributes = [.font: scaled]
            } else {
                appearance.titleTextAttributes = [.font: scaled]
            }
        }
    }
}

/// Value/unit pairs for the "big number, small unit" style.
enum Fmt {
    static func km(_ metres: Double) -> String {
        String(format: "%.2f", metres / 1000)
    }

    static func kmShort(_ km: Double) -> String {
        km.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", km)
            : String(format: "%.1f", km)
    }

    static func pace(_ sPerKm: Double) -> String {
        guard sPerKm.isFinite, sPerKm > 0 else { return "–:––" }
        let s = Int(sPerKm.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func distanceName(_ key: String) -> String {
        switch key {
        case "5k": "5K"
        case "10k": "10K"
        case "half": "Half"
        case "marathon": "Marathon"
        default: key
        }
    }

    static func runTitle(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let part = switch hour {
        case 5..<12: "Morning"
        case 12..<17: "Afternoon"
        case 17..<22: "Evening"
        default: "Night"
        }
        return "\(part) Run"
    }
}

extension View {
    /// Small uppercase secondary label used above stats.
    func statLabel() -> some View {
        font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    /// Standard card: secondary grouped background, continuous corners.
    func card(padding: CGFloat = Jogga.cardPadding) -> some View {
        self.padding(padding)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: Jogga.cardRadius, style: .continuous)
            )
    }
}

struct Card<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing, content: { content })
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
    }
}

/// Screen chrome: grouped background page.
struct JoggaScreen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: Jogga.cardSpacing, content: { content })
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Jogga.pagePadding)
                .padding(.top, 4)
                .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground))
    }
}

/// Big rounded value with a smaller unit, e.g. `5.02 km`.
struct Metric: View {
    var value: String
    var unit: String? = nil
    var size: CGFloat = 34
    var weight: Font.Weight = .semibold

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(Jogga.numerals(size, weight: weight))
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(Jogga.numerals(max(size * 0.42, 13), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
}

/// Labelled metric used in stat rows and grids.
struct StatCell: View {
    var label: String
    var value: String
    var unit: String? = nil
    var size: CGFloat = 26
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(label).statLabel()
            Metric(value: value, unit: unit, size: size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value) \(unit ?? "")")
    }
}

/// Tinted capsule tag, e.g. "Tempo".
struct Chip: View {
    var text: String
    var prominent = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(prominent ? Color.white : Color.brand)
            .background(
                prominent ? Color.brand : Color.brand.opacity(0.14),
                in: Capsule()
            )
    }
}

/// Thin capsule progress bar in the accent colour.
struct Bar: View {
    var fraction: Double
    var height: CGFloat = 6
    var tint: Color = .brand

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color(.tertiarySystemFill))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(geo.size.width * min(max(fraction, 0), 1), height))
                }
        }
        .frame(height: height)
        .animation(.smooth, value: fraction)
    }
}

/// Full-width filled accent button with a gentle press state.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                Color.brand.opacity(isEnabled ? 1 : 0.4),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// Soft press feedback for tappable cards and round controls.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

extension Color {
    /// Brand blue from the asset catalog (light #0E71FE, dark #3D8BFF), matching the logo.
    static let brand = Color("AccentColor")
}

extension ShapeStyle where Self == Color {
    static var brand: Color { Color.brand }
}
