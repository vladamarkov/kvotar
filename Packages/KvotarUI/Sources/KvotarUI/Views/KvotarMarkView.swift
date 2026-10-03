import SwiftUI

/// The Kvotar headroom mark: a clear K inside a mostly complete operating envelope. The short
/// sage segment is the capacity still available; the template form is one colour so the same
/// silhouette remains crisp in the macOS menu bar at 14 pt.
struct KvotarMarkView: View {
    enum Style {
        case brand
        case template(Color)
    }

    let style: Style

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 100
            let origin = CGPoint(x: (size.width - 100 * scale) / 2,
                                 y: (size.height - 100 * scale) / 2)

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
            }

            func stroke(_ path: Path, width: CGFloat, color: Color) {
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: width * scale,
                                                  lineCap: .round,
                                                  lineJoin: .round))
            }

            func arc(from start: Double, to end: Double) -> Path {
                var path = Path()
                path.addArc(center: point(50, 50), radius: 35.5 * scale,
                            startAngle: .degrees(start), endAngle: .degrees(end),
                            clockwise: false)
                return path
            }

            let primary: Color
            let remaining: Color
            switch style {
            case .brand:
                primary = Brand.graphite
                remaining = Brand.sage
            case .template(let color):
                primary = color
                remaining = color
            }

            // The selected top-left geometry: a 238-degree main arc, a short separated
            // lower-right segment, and enough open space below to keep the mark from reading Q.
            stroke(arc(from: 122, to: 360), width: 6, color: primary)
            stroke(arc(from: 13, to: 56), width: 6, color: remaining)

            var stem = Path()
            stem.move(to: point(40, 32))
            stem.addLine(to: point(40, 68))
            stroke(stem, width: 6, color: primary)

            var arms = Path()
            arms.move(to: point(44, 50))
            arms.addLine(to: point(63, 33))
            arms.move(to: point(44, 50))
            arms.addLine(to: point(63, 67))
            stroke(arms, width: 5.5, color: primary)
        }
        .accessibilityHidden(true)
    }
}

private enum Brand {
    static let graphite = Color(red: 37 / 255, green: 40 / 255, blue: 45 / 255)
    static let sage = Color(red: 120 / 255, green: 150 / 255, blue: 129 / 255)
}

#Preview("Kvotar mark") {
    HStack(spacing: 24) {
        KvotarMarkView(style: .brand)
            .frame(width: 64, height: 64)
        KvotarMarkView(style: .template(.primary))
            .frame(width: 14, height: 14)
    }
    .padding(24)
}
