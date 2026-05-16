import SwiftUI
import AppKit

/// Native AppKit drawing surface with NSPanGestureRecognizer.
/// Works correctly with both trackpad and mouse on macOS.
struct AnnotationCanvasView: NSViewRepresentable {
    let imageSize: CGSize
    @Binding var activeTool: AnnotationTool
    @Binding var annotations: [Annotation]
    var onRectFinalized: ((CGRect) -> Void)?

    func makeNSView(context: Context) -> DrawingNSView {
        let view = DrawingNSView()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: DrawingNSView, context: Context) {
        context.coordinator.imageSize = imageSize
        context.coordinator.activeTool = activeTool
        context.coordinator.annotations = annotations
        nsView.annotations = annotations
        nsView.imageSize = imageSize
        nsView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(activeTool: activeTool,
                    annotations: annotations,
                    onRectFinalized: onRectFinalized,
                    bindingTool: $activeTool,
                    bindingAnnotations: $annotations)
    }

    // MARK: - Coordinator

    final class Coordinator: DrawingNSViewDelegate {
        var imageSize: CGSize
        var activeTool: AnnotationTool
        var annotations: [Annotation]
        let onRectFinalized: ((CGRect) -> Void)?
        @Binding var bindingTool: AnnotationTool
        @Binding var bindingAnnotations: [Annotation]

        private var dragStart: CGPoint = .zero
        private var currentPoints: [CGPoint] = []

        init(activeTool: AnnotationTool,
             annotations: [Annotation],
             onRectFinalized: ((CGRect) -> Void)?,
             bindingTool: Binding<AnnotationTool>,
             bindingAnnotations: Binding<[Annotation]>) {
            self.activeTool = activeTool
            self.annotations = annotations
            self.onRectFinalized = onRectFinalized
            self._bindingTool = bindingTool
            self._bindingAnnotations = bindingAnnotations
            self.imageSize = .zero
        }

        func panBegan(_ point: CGPoint, in view: DrawingNSView) {
            dragStart = point
            currentPoints = [normalize(point, in: view)]
            view.livePoints = currentPoints
            view.liveStart = point
            view.needsDisplay = true
        }

        func panChanged(_ point: CGPoint, in view: DrawingNSView) {
            let unit = normalize(point, in: view)
            if activeTool == .freedraw {
                currentPoints.append(unit)
            } else {
                currentPoints = [normalize(dragStart, in: view), unit]
            }
            view.livePoints = currentPoints
            view.liveCurrent = point
            view.needsDisplay = true
        }

        func panEnded(_ point: CGPoint, in view: DrawingNSView) {
            defer {
                view.livePoints = []
                view.needsDisplay = true
            }
            switch activeTool {
            case .rectangle:
                let start = normalize(dragStart, in: view)
                let end   = normalize(point, in: view)
                let unitRect = CGRect(
                    x: min(start.x, end.x), y: min(start.y, end.y),
                    width: abs(start.x - end.x), height: abs(start.y - end.y)
                )
                guard unitRect.width > 0.01 && unitRect.height > 0.01 else { return }
                bindingAnnotations.append(Annotation(kind: .rectangle(unitRect)))
                onRectFinalized?(unitRect)

            case .freedraw:
                guard currentPoints.count > 2 else { return }
                bindingAnnotations.append(Annotation(kind: .freedraw(currentPoints)))

            default: break
            }
            currentPoints = []
        }

        /// Convert a point in the NSView's flipped coordinate system to
        /// unit coordinates (0–1) relative to the displayed image rect.
        private func normalize(_ pt: CGPoint, in view: DrawingNSView) -> CGPoint {
            let rect = view.imageDisplayRect()
            guard rect.width > 0, rect.height > 0 else { return .zero }
            return CGPoint(
                x: (pt.x - rect.minX) / rect.width,
                y: (pt.y - rect.minY) / rect.height
            )
        }
    }
}

// MARK: - Delegate protocol

protocol DrawingNSViewDelegate: AnyObject {
    var activeTool: AnnotationTool { get }
    func panBegan(_ point: CGPoint, in view: DrawingNSView)
    func panChanged(_ point: CGPoint, in view: DrawingNSView)
    func panEnded(_ point: CGPoint, in view: DrawingNSView)
}

// MARK: - Native NSView

final class DrawingNSView: NSView {
    weak var delegate: DrawingNSViewDelegate?

    var imageSize: CGSize = .zero
    var annotations: [Annotation] = []

    // Live gesture state (drawn during drag, not yet committed)
    var livePoints: [CGPoint] = []
    var liveStart: CGPoint = .zero
    var liveCurrent: CGPoint = .zero

    override var isFlipped: Bool { true }           // top-left origin to match SwiftUI
    override var mouseDownCanMoveWindow: Bool { false } // prevent window drag on canvas

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.buttonMask = 0x1   // primary button / one-finger trackpad
        addGestureRecognizer(pan)
    }

    @objc private func handlePan(_ rec: NSPanGestureRecognizer) {
        // NSView is flipped, so y is already top-down
        let pt = rec.location(in: self)
        switch rec.state {
        case .began:    delegate?.panBegan(pt, in: self)
        case .changed:  delegate?.panChanged(pt, in: self)
        case .ended, .cancelled: delegate?.panEnded(pt, in: self)
        default: break
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageDisplayRect()

        // Committed annotations
        for annotation in annotations {
            drawAnnotation(annotation, ctx: ctx, displayRect: rect)
        }

        // Live preview
        guard !livePoints.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch delegate?.activeTool {
        case .rectangle:
            let r = CGRect(
                x: min(liveStart.x, liveCurrent.x),
                y: min(liveStart.y, liveCurrent.y),
                width: abs(liveStart.x - liveCurrent.x),
                height: abs(liveStart.y - liveCurrent.y)
            )
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.08).cgColor)
            ctx.fill(r)
            let dash: [CGFloat] = [6, 3]
            ctx.setLineDash(phase: 0, lengths: dash)
            ctx.stroke(r)

        case .freedraw where livePoints.count > 1:
            ctx.beginPath()
            let first = denorm(livePoints[0], in: rect)
            ctx.move(to: first)
            for pt in livePoints.dropFirst() {
                ctx.addLine(to: denorm(pt, in: rect))
            }
            ctx.strokePath()

        default: break
        }
        ctx.restoreGState()
    }

    private func drawAnnotation(_ annotation: Annotation, ctx: CGContext, displayRect: CGRect) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(2.5)

        switch annotation.kind {
        case .rectangle(let unit):
            let r = denormRect(unit, in: displayRect)
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.08).cgColor)
            ctx.fill(r)
            let dash: [CGFloat] = [6, 3]
            ctx.setLineDash(phase: 0, lengths: dash)
            ctx.stroke(r)

        case .freedraw(let points) where points.count > 1:
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.beginPath()
            ctx.move(to: denorm(points[0], in: displayRect))
            for pt in points.dropFirst() {
                ctx.addLine(to: denorm(pt, in: displayRect))
            }
            ctx.strokePath()

        case .text(let content, let anchor):
            let pt = denorm(anchor, in: displayRect)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.55)
            ]
            NSAttributedString(string: content, attributes: attrs).draw(at: pt)

        default: break
        }
        ctx.restoreGState()
    }

    // MARK: - Coordinate helpers

    /// The rect the image occupies inside this view (aspect-fit, top-left origin).
    func imageDisplayRect() -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: bounds.size)
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (bounds.width - w) / 2,
                      y: (bounds.height - h) / 2,
                      width: w, height: h)
    }

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
}
