import AppKit
import SwiftUI

/// NSTextView wrapper that fills its parent's width and grows in height to fit content.
/// Bypasses SwiftUI's text layout entirely — reliable on macOS where SwiftUI Text
/// width propagation through ScrollView can silently collapse.
struct FlowingTextView: NSViewRepresentable {
    let text: String
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width]

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        tv.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        scrollView.documentView = tv
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
        }
        // Recalculate height after layout
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let h = tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 20
        DispatchQueue.main.async {
            if abs(self.height - h) > 1 { self.height = max(h, 20) }
        }
    }
}
