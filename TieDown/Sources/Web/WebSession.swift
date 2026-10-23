import Foundation
import WebKit

/// Shared web state for every tab: one cookie store, so signing in natively
/// signs in every web screen, and signing out clears them all.
@MainActor
final class WebSession {
    static let shared = WebSession()

    let dataStore = WKWebsiteDataStore.default()

    private init() {}

    /// Writes the `tiedown_session` cookie the web app's server reads (HttpOnly, Secure, host-only).
    func installSessionCookie(token: String) {
        let env = AppEnvironment.current
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: AppEnvironment.sessionCookieName,
            .value: token,
            .domain: env.appHost,
            .path: "/",
            .secure: env.usesHTTPS ? "TRUE" : "FALSE",
            .expires: Date().addingTimeInterval(7 * 24 * 3600),
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax.rawValue,
        ]
        guard let cookie = HTTPCookie(properties: properties) else { return }
        dataStore.httpCookieStore.setCookie(cookie)
    }

    /// Removes cookies, local storage and caches for every site.
    func clearWebsiteData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await dataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    func makeConfiguration(messageHandlers: [String: WKScriptMessageHandler]) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = UserAgent.webSuffix
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = config.userContentController
        controller.addUserScript(WKUserScript(
            source: """
            window.__TIEDOWN_NATIVE__ = true;
            window.__TIEDOWN_PLATFORM__ = 'ios';
            window.__TIEDOWN_NATIVE_FEATURES__ = { tapToPay: true, bluetoothReaders: true, printing: true, push: true, share: true, haptics: true };
            document.documentElement.classList.add('tiedown-native', 'tiedown-ios');
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // window.print() does nothing in an iOS web view; route it to the native printer bridge
        // in every frame (the receipt iframe, print windows, and the page itself).
        controller.addUserScript(WKUserScript(
            source: PrintBridge.printOverrideScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        for (name, handler) in messageHandlers {
            // Page content world + weak proxy: only the page's own scripts can call us,
            // and the controller doesn't retain the coordinator.
            controller.add(WeakScriptMessageHandler(handler), contentWorld: .page, name: name)
        }
        return config
    }
}

/// Breaks the retain cycle `WKUserContentController` → handler.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
