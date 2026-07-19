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

    /// An excerpt of the page's main content, preferring the article/main region
    /// so navigation chrome doesn't crowd out the actual text.
    func pageText() async -> String {
        let js = """
            (function(){
              var m = document.querySelector('main, article, [role="main"], #mw-content-text, #content');
              var t = m || document.body;
              return t ? t.innerText.slice(0, 6000) : '';
            })();
            """
        return (await run(js) as? String) ?? ""
    }

    func click(ref: String) async -> Bool {
        let js = "var e=document.querySelector('[data-clik-ref=\(ref)]'); if(e){e.click(); 'ok'}else{'missing'}"
        return (await run(js) as? String) == "ok"
    }

    func fill(ref: String, text: String, submit: Bool = false) async -> Bool {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        // Submit: prefer the containing form (classic + JS forms with validation);
        // otherwise dispatch Enter key events for JS-driven search boxes.
        let submitJS = submit ? """
            if(e.form&&e.form.requestSubmit){e.form.requestSubmit();}\
            else{['keydown','keypress','keyup'].forEach(function(t){\
            e.dispatchEvent(new KeyboardEvent(t,{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));});}
            """ : ""
        let js = """
            var e=document.querySelector('[data-clik-ref=\(ref)]');
            if(e){e.focus();e.value='\(escaped)';\
            e.dispatchEvent(new Event('input',{bubbles:true}));\
            e.dispatchEvent(new Event('change',{bubbles:true}));\
            \(submitJS)'ok'}else{'missing'}
            """
        return (await run(js) as? String) == "ok"
    }

    /// Captures the current view as a base64-encoded PNG for the vision model.
    func snapshot() async -> String? {
        let config = WKSnapshotConfiguration()
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, _ in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: png.base64EncodedString())
            }
        }
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
        if AppState.shared.browserAutoAcceptCookies {
            // Banners often render slightly after load, so give it a moment.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                _ = await run(Self.acceptCookiesJS)
            }
        }
    }

    /// Best-effort auto-accept of cookie-consent banners.
    func acceptCookies() async {
        _ = await run(Self.acceptCookiesJS)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    // MARK: - JS

    // Clicks a cookie-consent "accept" button: known CMP selectors first, then a
    // conservative text match on visible buttons/links.
    private static let acceptCookiesJS = """
        (function() {
          const sels = [
            '#onetrust-accept-btn-handler',
            '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll',
            '#CybotCookiebotDialogBodyButtonAccept',
            '.fc-cta-consent', '.fc-button.fc-cta-consent',
            'button[aria-label*="accept" i]',
            '[data-testid*="accept-all" i]', '[data-testid*="accept" i]'
          ];
          for (const s of sels) {
            const el = document.querySelector(s);
            if (el) { el.click(); return 'cmp'; }
          }
          const exact = ['accept','agree','i agree','ok','allow all','akkoord',
            'accepteren','alles toestaan','got it','ik ga akkoord','allow cookies'];
          const contains = ['accept all','accept cookies','alles accepteren',
            'allow all cookies','agree and close','accepteer alles'];
          const nodes = document.querySelectorAll(
            'button, a, [role=button], input[type=button], input[type=submit]');
          for (const n of nodes) {
            const t = ((n.innerText || n.value || '') + '').trim().toLowerCase();
            if (!t || t.length > 40) continue;
            const r = n.getBoundingClientRect();
            if (r.width === 0 || r.height === 0) continue;
            if (exact.includes(t) || contains.some(c => t.includes(c))) {
              n.click();
              return 'text:' + t;
            }
          }
          return 'none';
        })();
        """

    private static let extractJS = """
        (function() {
          const sel = 'a,button,input,textarea,select,[role=button],[onclick]';
          const els = document.querySelectorAll(sel);
          const out = [];
          let i = 0;
          els.forEach(el => {
            const r = el.getBoundingClientRect();
            if (r.width === 0 || r.height === 0) return;
            const img = el.querySelector ? el.querySelector('img') : null;
            const label = (el.getAttribute('aria-label') || el.getAttribute('title') ||
              el.placeholder || el.name || (el.innerText || '').trim() ||
              (img && img.getAttribute('alt')) || el.id || el.value || '')
              .toString().trim().slice(0, 80);
            if (!label) return;   // skip elements the model can't meaningfully reference
            const ref = 'clik' + (i++);
            el.setAttribute('data-clik-ref', ref);
            out.push({ ref, tag: el.tagName.toLowerCase(), type: el.type || '', label });
          });
          return JSON.stringify(out.slice(0, 150));
        })();
        """
}

struct WebViewRepresentable: NSViewRepresentable {
    let controller: WebViewController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
