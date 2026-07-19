import SwiftUI
import WebKit

/// Wraps a WKWebView and exposes the primitives the browser agent drives:
/// navigate, extract interactable elements, fill fields, click.
@MainActor
final class WebViewController: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView

    @Published var currentURL: String = ""
    @Published var isLoading = false

    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: - Actions

    func navigate(to urlString: String) {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { return }
        webView.load(URLRequest(url: url))
    }

    @discardableResult
    func run(_ js: String) async -> Any? {
        try? await webView.evaluateJavaScript(js)
    }

    /// Tags visible interactable elements with a stable ref and returns them as JSON.
    func interactables() async -> String {
        (await run(Self.extractJS) as? String) ?? "[]"
    }

    /// A short excerpt of the page's visible text for context.
    func pageText() async -> String {
        let js = "document.body ? document.body.innerText.slice(0, 3000) : ''"
        return (await run(js) as? String) ?? ""
    }

    func click(ref: String) async -> Bool {
        let js = "var e=document.querySelector('[data-clik-ref=\(ref)]'); if(e){e.click(); 'ok'}else{'missing'}"
        return (await run(js) as? String) == "ok"
    }

    func fill(ref: String, text: String) async -> Bool {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let js = """
            var e=document.querySelector('[data-clik-ref=\(ref)]');
            if(e){e.focus();e.value='\(escaped)';\
            e.dispatchEvent(new Event('input',{bubbles:true}));\
            e.dispatchEvent(new Event('change',{bubbles:true}));'ok'}else{'missing'}
            """
        return (await run(js) as? String) == "ok"
    }

    /// Waits until the page finishes loading (bounded).
    func waitUntilIdle(timeout: TimeInterval = 8) async {
        try? await Task.sleep(nanoseconds: 300_000_000)   // let navigation begin
        let deadline = Date().addingTimeInterval(timeout)
        while isLoading && Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURL = webView.url?.absoluteString ?? ""
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    // MARK: - JS

    private static let extractJS = """
        (function() {
          const sel = 'a,button,input,textarea,select,[role=button],[onclick]';
          const els = document.querySelectorAll(sel);
          const out = [];
          let i = 0;
          els.forEach(el => {
            const r = el.getBoundingClientRect();
            if (r.width === 0 || r.height === 0) return;
            const ref = 'clik' + (i++);
            el.setAttribute('data-clik-ref', ref);
            const label = (el.getAttribute('aria-label') || el.placeholder ||
              el.name || el.id || (el.innerText || '').trim() || el.value || '')
              .toString().slice(0, 80);
            out.push({ ref, tag: el.tagName.toLowerCase(), type: el.type || '', label });
          });
          return JSON.stringify(out.slice(0, 80));
        })();
        """
}

struct WebViewRepresentable: NSViewRepresentable {
    let controller: WebViewController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
