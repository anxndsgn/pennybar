import AppKit

/// The menu bar mark: a solid disc inside a thin outer ring, with the glyph cut out of the disc.
/// Drawn as vectors so the proportions and stroke weights can be tuned independently.
enum MenuBarIcon {
    enum Glyph {
        case dollar
        case exclamation
    }

    /// Warning amber: deep enough that a white "$" stays readable, unlike on system yellow.
    static let warningFill = NSColor(srgbRed: 0xE8 / 255, green: 0xA1 / 255, blue: 0x00 / 255, alpha: 1)

    struct Metrics {
        /// Side of the square canvas, in points.
        var size: CGFloat = 16
        var ringWidth: CGFloat = 1.1
        /// Space between the outer ring and the disc.
        var gap: CGFloat = 1.1
        /// Stroke width of the glyph inside the disc.
        var glyphWidth: CGFloat = 1.5
    }

    /// The normal mark as a template image, so it follows the menu bar's appearance.
    /// The glyph is punched out of the disc, letting the menu bar show through.
    static func template(_ metrics: Metrics = Metrics()) -> NSImage {
        draw(.dollar, ink: .black, glyphColor: nil, metrics: metrics, isTemplate: true)
    }

    /// A colored mark for budget alerts. The glyph color is chosen per fill for contrast:
    /// white reads on red, but on yellow only a dark glyph stays legible.
    static func colored(_ glyph: Glyph, color: NSColor, glyphColor: NSColor = .white, metrics: Metrics = Metrics()) -> NSImage {
        draw(glyph, ink: color, glyphColor: glyphColor, metrics: metrics, isTemplate: false)
    }

    private static func draw(_ glyph: Glyph, ink: NSColor, glyphColor: NSColor?, metrics: Metrics, isTemplate: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: metrics.size, height: metrics.size), flipped: false) { rect in
            ink.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: metrics.ringWidth / 2, dy: metrics.ringWidth / 2))
            ring.lineWidth = metrics.ringWidth
            ring.stroke()

            ink.setFill()
            let inset = metrics.ringWidth + metrics.gap
            NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset)).fill()

            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.saveGState()
            if let glyphColor {
                glyphColor.setStroke()
                glyphColor.setFill()
            } else {
                // Erase the glyph from the disc instead of painting it.
                context.setBlendMode(.destinationOut)
                NSColor.black.setStroke()
                NSColor.black.setFill()
            }
            stroke(glyph, in: rect, metrics: metrics)
            context.restoreGState()
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    /// Strokes the glyph centered in `rect` with the current colors.
    private static func stroke(_ glyph: Glyph, in rect: NSRect, metrics: Metrics) {
        let unit = rect.width / 16
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let width = metrics.glyphWidth

        switch glyph {
        case .dollar:
            // An "S" from two stacked elliptical bowls (wider than tall, so it doesn't look thin),
            // plus short stems above and below.
            let radiusX = 2.0 * unit
            let radiusY = 1.4 * unit
            let s = NSBezierPath()
            s.append(arc(center: NSPoint(x: center.x, y: center.y + radiusY), radiusX: radiusX, radiusY: radiusY,
                         from: 25, to: 270, clockwise: false))
            s.append(arc(center: NSPoint(x: center.x, y: center.y - radiusY), radiusX: radiusX, radiusY: radiusY,
                         from: 90, to: 205, clockwise: true))
            s.lineWidth = width
            s.lineCapStyle = .round
            s.lineJoinStyle = .round
            s.stroke()

            let stemLength = 1.1 * unit
            for (start, direction) in [(center.y + 2 * radiusY, 1.0), (center.y - 2 * radiusY, -1.0)] {
                let stem = NSBezierPath()
                stem.move(to: NSPoint(x: center.x, y: start))
                stem.line(to: NSPoint(x: center.x, y: start + direction * stemLength))
                stem.lineWidth = width
                stem.lineCapStyle = .round
                stem.stroke()
            }

        case .exclamation:
            let bar = NSBezierPath()
            bar.move(to: NSPoint(x: center.x, y: center.y + 3.0 * unit))
            bar.line(to: NSPoint(x: center.x, y: center.y - 0.7 * unit))
            bar.lineWidth = width * 1.15
            bar.lineCapStyle = .round
            bar.stroke()
            let dot = width * 0.72
            NSBezierPath(ovalIn: NSRect(x: center.x - dot, y: center.y - 3.0 * unit - dot, width: dot * 2, height: dot * 2)).fill()
        }
    }

    /// An arc of an axis-aligned ellipse, built on the unit circle and scaled, so the stroke stays uniform.
    private static func arc(center: NSPoint, radiusX: CGFloat, radiusY: CGFloat, from start: CGFloat, to end: CGFloat, clockwise: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        path.appendArc(withCenter: .zero, radius: 1, startAngle: start, endAngle: end, clockwise: clockwise)
        path.transform(using: AffineTransform(m11: radiusX, m12: 0, m21: 0, m22: radiusY, tX: center.x, tY: center.y))
        return path
    }
}
