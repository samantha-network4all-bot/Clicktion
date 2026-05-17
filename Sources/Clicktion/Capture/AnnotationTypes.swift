import SwiftUI

enum AnnotationTool: Equatable {
    case none, rectangle, freedraw
}

// All geometry is stored in unit coordinates (0–1) relative to the
// displayed image rectangle so it scales correctly if the view resizes.
struct Annotation: Identifiable {
    let id = UUID()
    var kind: Kind

    enum Kind {
        case rectangle(CGRect)
        case freedraw([CGPoint])   // unit-coordinate point sequence
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
            }
        }
        result.unlockFocus()
        return result
    }

    /// Crops to a unit-coordinate rect. Returns nil if rect is degenerate.
    func cropping(to unitRect: CGRect) -> NSImage? {
        guard unitRect.width > 0.01, unitRect.height > 0.01 else { return nil }
        guard let cgSrc = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let cgW = CGFloat(cgSrc.width)
        let cgH = CGFloat(cgSrc.height)
        let scaleX = size.width > 0 ? cgW / size.width : 1

        // Convert unit coords (top-left origin) to CGImage pixel coords (bottom-left origin)
        let pixelRect = CGRect(
            x: unitRect.minX * cgW,
            y: (1 - unitRect.maxY) * cgH,
            width: unitRect.width * cgW,
            height: unitRect.height * cgH
        )

        // Draw into a new CGContext — avoids the lazy-reference memory leak from CGImage.cropping
        let w = Int(pixelRect.width.rounded())
        let h = Int(pixelRect.height.rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil,
                                  width: w, height: h,
                                  bitsPerComponent: cgSrc.bitsPerComponent,
                                  bytesPerRow: 0,
                                  space: cgSrc.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: cgSrc.bitmapInfo.rawValue) else { return nil }

        ctx.draw(cgSrc, in: CGRect(x: -pixelRect.minX,
                                   y: -pixelRect.minY,
                                   width: cgW, height: cgH))
        guard let newCG = ctx.makeImage() else { return nil }

        let logicalSize = CGSize(width: CGFloat(w) / scaleX, height: CGFloat(h) / scaleX)
        return NSImage(cgImage: newCG, size: logicalSize)
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

