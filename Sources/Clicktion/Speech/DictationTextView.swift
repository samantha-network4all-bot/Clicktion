import AppKit
import SwiftUI

/// An editable text view that scrolls to the bottom as text is appended, so the
/// latest dictated words stay visible. SwiftUI's `TextEditor` doesn't follow
/// programmatic text growth, hence this NSTextView wrapper.
struct DictationTextView: NSViewRepresentable {
    @Binding var text: String
    /// When true, growth in `text` scrolls the view to the end (used while dictating).
    var autoScroll: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.string = text
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView, tv.string != text else { return }

        let grew = (text as NSString).length > (tv.string as NSString).length
        let previousSelection = tv.selectedRange()
        tv.string = text

        if autoScroll && grew {
            let end = NSRange(location: (text as NSString).length, length: 0)
            tv.setSelectedRange(end)
            tv.scrollToEndOfDocument(nil)
        } else if previousSelection.location <= (text as NSString).length {
            tv.setSelectedRange(previousSelection)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: DictationTextView
        init(_ parent: DictationTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
