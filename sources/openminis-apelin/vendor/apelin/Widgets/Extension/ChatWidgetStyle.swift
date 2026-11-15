import SwiftUI

/// The widgets' colours: the leaf's green, iGhostVT's amber and red, and a
/// plain white or black ground, each with a variant for light and for dark.
struct WidgetTheme {
    let isDark: Bool

    init(_ colorScheme: ColorScheme) {
        isDark = colorScheme == .dark
    }

    /// The island is black in both appearances.
    static let island = WidgetTheme(.dark)

    var ground: Color {
        isDark ? .black : .white
    }

    var ink: Color {
        isDark ? .white : Color(hex: 0x111111)
    }

    var braces: Color {
        isDark ? Color(hex: 0xF4F6FA) : Color(hex: 0x1F242E)
    }

    var green: Color {
        isDark ? Color(hex: 0x2BD17E) : Color(hex: 0x12945A)
    }

    var amber: Color {
        isDark ? Color(hex: 0xFFB833) : Color(hex: 0xD08200)
    }

    var red: Color {
        isDark ? Color(hex: 0xFF6161) : Color(hex: 0xD03A33)
    }

    var idle: Color {
        isDark ? Color.white.opacity(0.32) : Color.black.opacity(0.24)
    }

    func color(for status: ChatWidgetSnapshot.Chat.Status) -> Color {
        switch status {
        case .working: green
        case .waiting: amber
        case .done: idle
        case .failed: red
        }
    }
}

/// The three gaps the widgets use, iGhostVT's: between rows, between lines
/// and a row's parts, and the card's padding.
enum WidgetSpacing {
    static let row: CGFloat = 4
    static let line: CGFloat = 8
    static let card: CGFloat = 16
    /// The dot and its gap, so a "more" line starts where titles do.
    static let dotColumn: CGFloat = 8 + line
}

extension Color {
    init(hex: Int) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1,
        )
    }
}

extension Font {
    /// SF Pro Rounded at a text style, so the widgets follow Dynamic Type;
    /// Han characters fall back to the system's own.
    static func rounded(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded).weight(weight)
    }
}

extension View {
    /// The widget's ground. From iOS 17 the system draws it and keeps the
    /// content margins; before, the content pads itself as the system would.
    @ViewBuilder
    func widgetGround(_ color: Color) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { color }
        } else {
            padding(WidgetSpacing.card).background(color)
        }
    }
}

// MARK: - The mark: the icon's braces and leaf, with no plate

/// The braces, in the icon's 1024-unit space.
private struct BracesShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 326, y: 300))
        path.addCurve(to: CGPoint(x: 262, y: 380), control1: CGPoint(x: 272, y: 300), control2: CGPoint(x: 262, y: 330))
        path.addLine(to: CGPoint(x: 262, y: 456))
        path.addCurve(to: CGPoint(x: 210, y: 512), control1: CGPoint(x: 262, y: 494), control2: CGPoint(x: 248, y: 512))
        path.addCurve(to: CGPoint(x: 262, y: 568), control1: CGPoint(x: 248, y: 512), control2: CGPoint(x: 262, y: 530))
        path.addLine(to: CGPoint(x: 262, y: 644))
        path.addCurve(to: CGPoint(x: 326, y: 724), control1: CGPoint(x: 262, y: 694), control2: CGPoint(x: 272, y: 724))
        path.move(to: CGPoint(x: 698, y: 300))
        path.addCurve(to: CGPoint(x: 762, y: 380), control1: CGPoint(x: 752, y: 300), control2: CGPoint(x: 762, y: 330))
        path.addLine(to: CGPoint(x: 762, y: 456))
        path.addCurve(to: CGPoint(x: 814, y: 512), control1: CGPoint(x: 762, y: 494), control2: CGPoint(x: 776, y: 512))
        path.addCurve(to: CGPoint(x: 762, y: 568), control1: CGPoint(x: 776, y: 512), control2: CGPoint(x: 762, y: 530))
        path.addLine(to: CGPoint(x: 762, y: 644))
        path.addCurve(to: CGPoint(x: 698, y: 724), control1: CGPoint(x: 762, y: 694), control2: CGPoint(x: 752, y: 724))
        return path.applying(MarkView.transform(rect))
    }
}

/// The leaf and its vein, filled even-odd.
private struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 388, y: 636))
        path.addCurve(to: CGPoint(x: 636, y: 388), control1: CGPoint(x: 388, y: 466), control2: CGPoint(x: 466, y: 388))
        path.addCurve(to: CGPoint(x: 388, y: 636), control1: CGPoint(x: 636, y: 558), control2: CGPoint(x: 558, y: 636))
        path.closeSubpath()
        path.move(to: CGPoint(x: 430, y: 594))
        path.addCurve(to: CGPoint(x: 590, y: 434), control1: CGPoint(x: 478, y: 556), control2: CGPoint(x: 548, y: 490))
        path.addCurve(to: CGPoint(x: 430, y: 594), control1: CGPoint(x: 556, y: 500), control2: CGPoint(x: 486, y: 566))
        path.closeSubpath()
        return path.applying(MarkView.transform(rect))
    }
}

/// Apelin's mark, drawn rather than looked up: the widgets carry no image,
/// and the braces stay crisp at every size. Decorative to VoiceOver.
struct MarkView: View {
    let size: CGFloat
    let braces: Color

    /// The leaf's green, the same in both appearances.
    private static let leaf = Color(hex: 0x2BD17E)
    /// The square around the icon's centre that holds the braces' stroke.
    private static let crop: CGFloat = 660

    var body: some View {
        ZStack {
            BracesShape().stroke(
                braces,
                style: StrokeStyle(lineWidth: max(1.5, 62 * size / Self.crop), lineCap: .round, lineJoin: .round),
            )
            LeafShape().fill(Self.leaf, style: FillStyle(eoFill: true))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    fileprivate static func transform(_ rect: CGRect) -> CGAffineTransform {
        let scale = rect.width / crop
        return CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -(512 - crop / 2), y: -(512 - crop / 2))
    }
}

/// A status dot, decorative: the row says the status in words to VoiceOver.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}
