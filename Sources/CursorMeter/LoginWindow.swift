import AppKit
import WebKit

@MainActor
final class LoginWindow: NSObject {
    private enum LoginState { case idle, navigating, completed }

    private var webView: WKWebView?
    private var window: NSWindow?
    private var onComplete: ((String?) -> Void)?
    private var state: LoginState = .idle

    private nonisolated static let allowedDomains: Set<String> = [
        // Cursor
        "cursor.com",
        "www.cursor.com",
        "authenticator.cursor.sh",
        "authenticate.cursor.sh",
        // Auth providers
        "api.workos.com",
        "accounts.google.com",
        "github.com",
        // Enterprise SSO (Azure AD)
        "login.microsoftonline.com",
        // Stripe (Cursor dashboard payment)
        "js.stripe.com",
        "m.stripe.network",
    ]

    nonisolated static func isAllowedHost(_ host: String) -> Bool {
        if allowedDomains.contains(host) { return true }
        if host.hasSuffix(".cursor.com") { return true }
        if host.hasSuffix(".cursor.sh") { return true }
        if host.hasSuffix(".workos.com") { return true }
        if host.hasSuffix(".google.com") { return true }
        if host.hasSuffix(".github.com") { return true }
        if host.hasSuffix(".microsoftonline.com") { return true }
        if host.hasSuffix(".stripe.com") { return true }
        if host.hasSuffix(".stripe.network") { return true }
        return false
    }

    func open(onComplete: @escaping (String?) -> Void) {
        self.onComplete = onComplete
        self.state = .idle

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 640),
            configuration: config)
        webView.navigationDelegate = self
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Cursor Login"
        window.contentView = webView
        window.center()
        window.delegate = self
        // MenuBarExtra apps use .accessory policy — temporarily switch to .regular
        // so the login window can receive keyboard focus
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        let url = URL(string: "https://www.cursor.com/dashboard")!
        webView.load(URLRequest(url: url))
        Log.info("Login window opened")
    }

    private func complete(cookieHeader: String?) {
        guard state != .completed else { return }
        state = .completed
        onComplete?(cookieHeader)
        window?.close()
        webView = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func captureAndComplete(isRetry: Bool = false) {
        guard state != .completed, let webView else { return }
        Task {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let cursorCookies = cookies.filter {
                $0.domain.contains("cursor.com") || $0.domain.contains("cursor.sh")
            }

            guard !cursorCookies.isEmpty else {
                if !isRetry {
                    Log.info("No cursor cookies found, retrying in 1s")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    captureAndComplete(isRetry: true)
                } else {
                    Log.error("No cursor cookies found after retry")
                    complete(cookieHeader: nil)
                }
                return
            }

            let header = cursorCookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            Log.info("Captured \(cursorCookies.count) cookies")
            complete(cookieHeader: header)
        }
    }
}

// MARK: - WKNavigationDelegate

extension LoginWindow: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, let host = url.host else {
            decisionHandler(.cancel)
            return
        }

        if Self.isAllowedHost(host) {
            decisionHandler(.allow)
        } else {
            Log.info("Blocked navigation to: \(host)")
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let urlString = url.absoluteString

        if !urlString.contains("cursor.com/dashboard") {
            state = .navigating
        }

        // After auth redirect back to dashboard, wait briefly for cookies to be written
        if urlString.contains("cursor.com/dashboard"), state == .navigating {
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                captureAndComplete()
            }
        }
    }
}

// MARK: - NSWindowDelegate

extension LoginWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        complete(cookieHeader: nil)
    }
}
