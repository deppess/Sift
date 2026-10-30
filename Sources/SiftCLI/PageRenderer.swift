import AppKit
import Foundation
import SiftCore
import WebKit

/// `sift __render <url>`: loads a page in WebKit, lets its scripts build it, and writes the
/// resulting HTML to standard output. It runs in its own process (see `renderPage`) so a page
/// that hangs or crashes WebKit can only time out that process. The page gets no persistent
/// storage, no downloads, and no navigation away from HTTPS; the user agent is WebKit's own with
/// Sift's name added, never another browser's.
@MainActor
final class PageRenderer: NSObject, WKNavigationDelegate {
    private var finished = false
    private var failed = false

    nonisolated static func main(url: URL, timeout: TimeInterval) -> Int32 {
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.prohibited)
            guard let html = PageRenderer().render(url, timeout: timeout) else { return EXIT_FAILURE }
            FileHandle.standardOutput.write(Data(html.utf8))
            return EXIT_SUCCESS
        }
    }

    func render(_ url: URL, timeout: TimeInterval) -> String? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.applicationNameForUserAgent = "sift/\(SiftVersion.current)"
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 2000), configuration: configuration)
        view.navigationDelegate = self
        if url.host == "sift-render-selftest.invalid" {
            view.loadHTMLString("<html><body><div id=a></div><script>document.getElementById('a').innerText='rendered by script';</script></body></html>", baseURL: nil)
        } else {
            view.load(URLRequest(url: url, timeoutInterval: timeout))
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished, !failed, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        guard finished else { return nil }
        // Scripts keep filling the page after the load event; wait until its text stops growing.
        var lastLength = -1
        var stableRounds = 0
        while Date() < deadline, stableRounds < 3 {
            let length = (evaluate("document.body ? document.body.innerText.length : 0", in: view, until: deadline) as? Int) ?? 0
            stableRounds = length == lastLength && length > 0 ? stableRounds + 1 : 0
            lastLength = length
            let pause = Date().addingTimeInterval(0.4)
            while Date() < pause { RunLoop.main.run(mode: .default, before: pause) }
        }
        return evaluate("document.documentElement.outerHTML", in: view, until: deadline) as? String
    }

    private func evaluate(_ script: String, in view: WKWebView, until deadline: Date) -> Any? {
        var result: Any?
        var done = false
        view.evaluateJavaScript(script) { value, _ in
            result = value
            done = true
        }
        while !done, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return result
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(scheme == "https" || scheme == "about" || scheme == "data" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error); failed = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error); failed = true }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { report(nil); failed = true }

    private func report(_ error: Error?) {
        FileHandle.standardError.write(Data("sift: rendering failed: \(error?.localizedDescription ?? "the page's process ended")\n".utf8))
    }
}

/// Renders a page through `sift __render` in a child process, for the changelog resolver.
func renderPage(_ url: URL) -> String? {
    guard url.scheme?.lowercased() == "https", let executable = Bundle.main.executableURL else { return nil }
    guard let result = try? CommandRunner().run(executable: executable, arguments: ["__render", url.absoluteString], environment: ProcessInfo.processInfo.environment, timeout: 30, outputLimit: 16 * 1_048_576),
          result.status == 0 else { return nil }
    return String(data: result.stdout, encoding: .utf8)
}
