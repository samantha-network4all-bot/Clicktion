import SwiftUI

enum AnnotationTool: Equatable {
    case none, rectangle, freedraw, text
}

// All geometry is stored in unit coordinates (0–1) relative to the
// displayed image rectangle so it scales correctly if the view resizes.
struct Annotation: Identifiable {
    let id = UUID()
    var kind: Kind

    enum Kind {
        case rectangle(CGRect)
        case freedraw([CGPoint])   // unit-coordinate point sequence
        case text(String, CGPoint) // content + unit-coordinate anchor
    }
}

// MARK: - Image compositing

extension NSImage {
    /// Composites annotations onto a copy of the image and returns the result.
    func compositing(_ annotations: [Annotation]) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        draw(in: NSRect(origin: .zero, size: size))

        for annotation in annotations {
            switch annotation.kind {
            case .rectangle(let rect):
                drawRect(rect, in: size)
            case .freedraw(let points):
                drawFreedraw(points, in: size)
            case .text(let content, let anchor):
                drawText(content, at: anchor, in: size)
            }
        }
        result.unlockFocus()
        return result
    }

    /// Crops to a unit-coordinate rect. Returns nil if rect is degenerate.
    func cropping(to unitRect: CGRect) -> NSImage? {
        guard unitRect.width > 0.01, unitRect.height > 0.01 else { return nil }
        // NSImage has bottom-left origin; flip Y
        let pixelRect = CGRect(
            x: unitRect.minX * size.width,
            y: (1 - unitRect.maxY) * size.height,
            width: unitRect.width * size.width,
            height: unitRect.height * size.height
        )
        guard let cgSrc = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = cgSrc.cropping(to: pixelRect) else { return nil }
        return NSImage(cgImage: cropped,
                       size: CGSize(width: pixelRect.width, height: pixelRect.height))
    }
}

// MARK: - Core Graphics drawing helpers (called inside lockFocus)

private func drawRect(_ unit: CGRect, in imageSize: CGSize) {
    let px = CGRect(
        x: unit.minX * imageSize.width,
        y: (1 - unit.maxY) * imageSize.height,
        width: unit.width * imageSize.width,
        height: unit.height * imageSize.height
    )
    NSColor.red.withAlphaComponent(0.8).setStroke()
    let path = NSBezierPath(rect: px)
    path.lineWidth = max(2, imageSize.width / 300)
    let dash: [CGFloat] = [8, 4]
    path.setLineDash(dash, count: 2, phase: 0)
    path.stroke()
}

private func drawFreedraw(_ points: [CGPoint], in imageSize: CGSize) {
    guard points.count > 1 else { return }
    NSColor.red.withAlphaComponent(0.9).setStroke()
    let path = NSBezierPath()
    path.lineWidth = max(2, imageSize.width / 250)
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    let first = CGPoint(x: points[0].x * imageSize.width,
                        y: (1 - points[0].y) * imageSize.height)
    path.move(to: first)
    for pt in points.dropFirst() {
        path.line(to: CGPoint(x: pt.x * imageSize.width,
                              y: (1 - pt.y) * imageSize.height))
    }
    path.stroke()
}

private func drawText(_ content: String, at anchor: CGPoint, in imageSize: CGSize) {
    let px = CGPoint(x: anchor.x * imageSize.width,
                     y: (1 - anchor.y) * imageSize.height)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: max(14, imageSize.width / 40), weight: .semibold),
        .foregroundColor: NSColor.white,
        .backgroundColor: NSColor.black.withAlphaComponent(0.55)
    ]
    let str = NSAttributedString(string: content, attributes: attrs)
    str.draw(at: px)
}
