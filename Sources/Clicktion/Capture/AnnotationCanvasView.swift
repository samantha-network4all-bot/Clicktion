import SwiftUI

/// Overlays on top of the thumbnail image and handles drawing gestures.
struct AnnotationCanvasView: View {
    let imageSize: CGSize            // actual NSImage pixel dimensions
    @Binding var activeTool: AnnotationTool
    @Binding var annotations: [Annotation]

    @State private var dragStart: CGPoint = .zero
    @State private var dragCurrent: CGPoint = .zero
    @State private var isDragging = false
    @State private var freedrawPoints: [CGPoint] = []

    // Callback: rectangle was finalized → ViewModel can re-crop + re-OCR
    var onRectFinalized: ((CGRect) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let displayRect = fittedImageRect(imageSize: imageSize, containerSize: geo.size)

            ZStack(alignment: .topLeading) {
                // Invisible hit-test layer
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(toolGesture(displayRect: displayRect))

                // Committed annotations
                Canvas { ctx, size in
                    let rect = fittedImageRect(imageSize: imageSize, containerSize: size)
                    for annotation in annotations {
                        drawAnnotation(annotation, ctx: &ctx, displayRect: rect)
                    }
                }

                // Live preview while dragging
                if isDragging {
                    Canvas { ctx, size in
                        let rect = fittedImageRect(imageSize: imageSize, containerSize: size)
                        switch activeTool {
                        case .rectangle:
                            let liveRect = rectFromPoints(dragStart, dragCurrent,
                                                          in: rect)
                            var path = Path(liveRect)
                            ctx.stroke(path, with: .color(.red.opacity(0.85)),
                                       style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                            ctx.fill(Path(liveRect), with: .color(.red.opacity(0.08)))
                        case .freedraw:
                            if freedrawPoints.count > 1 {
                                var path = Path()
                                let first = denorm(freedrawPoints[0], in: rect)
                                path.move(to: first)
                                for pt in freedrawPoints.dropFirst() {
                                    path.addLine(to: denorm(pt, in: rect))
                                }
                                ctx.stroke(path, with: .color(.red.opacity(0.9)),
                                           style: StrokeStyle(lineWidth: 3,
                                                              lineCap: .round,
                                                              lineJoin: .round))
                            }
                        default: break
                        }
                    }
                }
            }
        }
    }

    // MARK: - Gesture

    private func toolGesture(displayRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if !isDragging {
                    dragStart = value.startLocation
                    isDragging = true
                    freedrawPoints = []
                }
                dragCurrent = value.location
                if activeTool == .freedraw {
                    let unit = normalize(value.location, in: displayRect)
                    freedrawPoints.append(unit)
                }
            }
            .onEnded { value in
                isDragging = false
                let end = value.location
                switch activeTool {
                case .rectangle:
                    let unitRect = unitRectFromPoints(dragStart, end, in: displayRect)
                    if unitRect.width > 0.01 && unitRect.height > 0.01 {
                        annotations.append(Annotation(kind: .rectangle(unitRect)))
                        onRectFinalized?(unitRect)
                    }
                case .freedraw:
                    if freedrawPoints.count > 2 {
                        annotations.append(Annotation(kind: .freedraw(freedrawPoints)))
                    }
                    freedrawPoints = []
                default: break
                }
            }
    }

    // MARK: - Canvas rendering

    private func drawAnnotation(_ annotation: Annotation, ctx: inout GraphicsContext,
                                 displayRect: CGRect) {
        switch annotation.kind {
        case .rectangle(let unit):
            let r = denormRect(unit, in: displayRect)
            var path = Path(r)
            ctx.stroke(path, with: .color(.red.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
            ctx.fill(Path(r), with: .color(.red.opacity(0.08)))

        case .freedraw(let points):
            guard points.count > 1 else { return }
            var path = Path()
            path.move(to: denorm(points[0], in: displayRect))
            for pt in points.dropFirst() {
                path.addLine(to: denorm(pt, in: displayRect))
            }
            ctx.stroke(path, with: .color(.red.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

        case .text(let content, let anchor):
            let pt = denorm(anchor, in: displayRect)
            let resolved = ctx.resolve(Text(content)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white))
            ctx.draw(resolved, at: pt, anchor: .bottomLeading)
        }
    }

    // MARK: - Coordinate helpers

    /// The rect the image actually occupies within the container (aspect-fit).
    func fittedImageRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width,
                        containerSize.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (containerSize.width - w) / 2,
                      y: (containerSize.height - h) / 2,
                      width: w, height: h)
    }

    /// View point → unit coordinate within the image rect.
    private func normalize(_ pt: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: (pt.x - rect.minX) / rect.width,
                y: (pt.y - rect.minY) / rect.height)
    }

    /// Unit coordinate → view point.
    private func denorm(_ unit: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + unit.x * rect.width,
                y: rect.minY + unit.y * rect.height)
    }

    private func denormRect(_ unit: CGRect, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + unit.minX * rect.width,
               y: rect.minY + unit.minY * rect.height,
               width: unit.width * rect.width,
               height: unit.height * rect.height)
    }

    private func rectFromPoints(_ a: CGPoint, _ b: CGPoint, in rect: CGRect) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func unitRectFromPoints(_ a: CGPoint, _ b: CGPoint, in displayRect: CGRect) -> CGRect {
        let ua = normalize(a, in: displayRect)
        let ub = normalize(b, in: displayRect)
        return CGRect(x: min(ua.x, ub.x), y: min(ua.y, ub.y),
                      width: abs(ua.x - ub.x), height: abs(ua.y - ub.y))
    }
}
