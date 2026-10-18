import AppKit

/// Provider marks that SF Symbols has no stand-in for, drawn as template images.
/// A descriptor opts in with a `symbolName` of the form "custom.<name>".
enum ProviderMarks {
    static func image(for symbolName: String) -> NSImage? {
        switch symbolName {
        case "custom.planetscale": planetScale
        default: nil
        }
    }

    /// PlanetScale's mark with softened corners: a disc split by a diagonal gap into a body and a
    /// small crescent, with a shorter parallel slot from the lower-left edge to the center.
    /// Geometry follows the official 16×16 favicon, where every cut runs along a line x + y = c.
    static let planetScale: NSImage = {
        let shape = roundedPlanetScalePath(cornerRadius: 0.45)
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(shape)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// Builds each piece shrunk by `cornerRadius`, then grows it back with a round stroke, which
    /// rounds every convex corner by that radius while keeping the outer size and the cuts in place.
    static func roundedPlanetScalePath(cornerRadius r: CGFloat) -> CGPath {
        // Shifting a line x + y = c by distance d moves c by d·√2.
        let shift = r * 2.squareRoot()
        let disc = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 16, height: 16).insetBy(dx: r, dy: r), transform: nil)

        // Body: x + y < 20, minus a slot between x + y = 16 and 18 that ends at the center line.
        // The band between the slot and the gap stays joined to the body above the slot's end.
        let slotWidth: CGFloat = 2.squareRoot()
        let slot = CGMutablePath()
        slot.move(to: CGPoint(x: -2, y: 19))
        slot.addLine(to: CGPoint(x: 8.5, y: 8.5))
        let widenedSlot = slot.copy(strokingWithWidth: slotWidth + 2 * r, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let body = disc
            .subtracting(halfPlane(beyond: 20 - shift))
            .subtracting(widenedSlot)

        // Crescent: x + y > 24.
        let crescent = disc.intersection(halfPlane(beyond: 24 + shift))

        let core = body.union(crescent)
        return core.union(core.copy(strokingWithWidth: 2 * r, lineCap: .round, lineJoin: .round, miterLimit: 10))
    }

    /// The region x + y > c, as a large quadrilateral covering the 16×16 canvas.
    private static func halfPlane(beyond c: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: c + 40, y: -40),
            CGPoint(x: -40, y: c + 40),
            CGPoint(x: 40, y: c + 120),
            CGPoint(x: c + 120, y: 40),
        ])
        path.closeSubpath()
        return path
    }
}
