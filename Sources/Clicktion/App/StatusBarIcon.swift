import AppKit

/// Vector status-bar icon — same crosshair-in-circle as the web header logo
/// (see clicktion-service/web/templates/base.html). Rendered programmatically
/// so it scales crisply and respects the system menu-bar tint via isTemplate.
enum StatusBarIcon {
    static func make(filled: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let s = size.width / 24.0    // SVG viewBox is 24×24
            let lineWidth: CGFloat = 1.8

            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Outer circle r=10 at (12,12)
            let outer = NSBezierPath(ovalIn: NSRect(x: 2 * s, y: 2 * s, width: 20 * s, height: 20 * s))
            outer.lineWidth = lineWidth
            outer.stroke()

            // Inner dot r=3 — filled when active, outlined otherwise
            let inner = NSBezierPath(ovalIn: NSRect(x: 9 * s, y: 9 * s, width: 6 * s, height: 6 * s))
            inner.lineWidth = lineWidth
            if filled {
                inner.fill()
            } else {
                inner.stroke()
            }

            // Four crosshair ticks
            let ticks: [(NSPoint, NSPoint)] = [
                (NSPoint(x: 12, y: 2),  NSPoint(x: 12, y: 6)),
                (NSPoint(x: 12, y: 18), NSPoint(x: 12, y: 22)),
                (NSPoint(x: 2,  y: 12), NSPoint(x: 6,  y: 12)),
                (NSPoint(x: 18, y: 12), NSPoint(x: 22, y: 12))
            ]
            for (a, b) in ticks {
                let path = NSBezierPath()
                path.lineWidth = lineWidth
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: a.x * s, y: a.y * s))
                path.line(to: NSPoint(x: b.x * s, y: b.y * s))
                path.stroke()
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}
