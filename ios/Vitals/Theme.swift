import SwiftUI

/// Same visual language as the web dashboard: near-black grounds, chart cyan for
/// the ordinary case, marigold for anything that needs a second look.
enum Palette {
    static let accent = Color(red: 0.37, green: 0.84, blue: 0.82)   // #5FD6D2
    static let warm = Color(red: 0.94, green: 0.66, blue: 0.24)     // #F0A93E
    static let rose = Color(red: 0.89, green: 0.47, blue: 0.60)     // #E4779A
    static let good = Color(red: 0.37, green: 0.84, blue: 0.63)     // #5FD6A0

    static let ground = Color(uiColor: .systemBackground)
    static let card = Color(uiColor: .secondarySystemBackground)
    static let raised = Color(uiColor: .tertiarySystemBackground)
    static let hairline = Color.primary.opacity(0.09)

    /// One scale for every "percentage of something finite" reading.
    static func level(_ percent: Double, warn: Double = 80, crit: Double = 92) -> Color {
        percent >= crit ? rose : percent >= warn ? warm : accent
    }
}

extension Font {
    /// Rounded tabular figures. Every number in the app uses this.
    static func figure(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// The app's only container.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.hairline))
    }
}

struct SectionLabel: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(.secondary)
            if let trailing {
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.figure(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A magnitude bar. Three points tall, and it does more for readability than
/// any number next to it.
struct MeterBar: View {
    let fraction: Double
    var tint: Color = Palette.accent
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline)
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
                    .animation(.easeOut(duration: 0.45), value: fraction)
            }
        }
        .frame(height: height)
    }
}

/// A filled area chart of a short rolling window, with the newest point marked.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = Palette.accent
    /// Percentages pass 100 so a flat line sits low instead of pinning to the top.
    var ceiling: Double?

    var body: some View {
        GeometryReader { geo in
            let top = ceiling ?? max(values.max() ?? 1, 1)
            let points = positions(in: geo.size, top: max(top, 0.001))
            ZStack {
                if points.count > 1 {
                    area(points, in: geo.size).fill(tint.opacity(0.14))
                    line(points).stroke(tint, style: .init(lineWidth: 1.6,
                                                           lineCap: .round,
                                                           lineJoin: .round))
                    if let last = points.last {
                        Circle().fill(tint)
                            .frame(width: 4.5, height: 4.5)
                            .position(last)
                    }
                }
            }
        }
        .frame(height: 34)
    }

    private func positions(in size: CGSize, top: Double) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        return values.enumerated().map { index, value in
            let x = size.width * Double(index) / Double(values.count - 1)
            let y = size.height - (min(value, top) / top) * (size.height - 4) - 2
            return CGPoint(x: x, y: y)
        }
    }

    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        return path
    }

    private func area(_ points: [CGPoint], in size: CGSize) -> Path {
        var path = Path()
        path.addLines(points)
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}

/// One headline reading.
struct StatTile: View {
    let label: String
    let value: String
    var unit: String?
    var detail: String?
    var fraction: Double?
    var tint: Color = Palette.accent
    var series: [Double]?
    var ceiling: Double?

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: label)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.figure(27))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    if let unit {
                        Text(unit)
                            .font(.figure(13, .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if let fraction {
                    MeterBar(fraction: fraction, tint: tint).padding(.top, 2)
                }
                if let series, series.count > 1 {
                    Sparkline(values: series, tint: tint, ceiling: ceiling)
                }
            }
        }
    }
}
