import AppKit

/// Vector status-bar icon — same crosshair-in-circle as the web header logo
/// (see clicktion-service/web/templates/base.html). Rendered programmatically
/// so it scales crisply and respects the system menu-bar tint via isTemplate.
enum StatusBarIcon {
    static func make(filled: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
        let s = size.width / 24.0    // SVG viewBox is 24×24
        let lineWidth: CGFloat = 1.7

        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)

        // Outer circle r=10 at (12,12)
        ctx.strokeEllipse(in: CGRect(x: 2 * s, y: 2 * s, width: 20 * s, height: 20 * s))

        // Inner dot r=3 — filled when active (todo badge state), outlined otherwise
        let inner = CGRect(x: 9 * s, y: 9 * s, width: 6 * s, height: 6 * s)
        if filled {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: inner)
        } else {
            ctx.strokeEllipse(in: inner)
        }

        // Four crosshair ticks at the cardinal points
        let ticks: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 12, y: 2),  CGPoint(x: 12, y: 6)),
            (CGPoint(x: 12, y: 18), CGPoint(x: 12, y: 22)),
            (CGPoint(x: 2,  y: 12), CGPoint(x: 6,  y: 12)),
            (CGPoint(x: 18, y: 12), CGPoint(x: 22, y: 12))
        ]
        for (a, b) in ticks {
            ctx.move(to: CGPoint(x: a.x * s, y: a.y * s))
            ctx.addLine(to: CGPoint(x: b.x * s, y: b.y * s))
        }
        ctx.strokePath()

        image.isTemplate = true   // macOS tints to match the menu bar
        return image
    }
}
