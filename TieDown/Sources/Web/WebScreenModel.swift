import SafariServices
import UIKit
import WebKit

/// One persistent web view (per tab / pushed screen) plus its navigation rules.
@MainActor
final class WebScreenModel: NSObject, ObservableObject {
    enum LoadError: Equatable {
        case offline
        case unreachable(String)
        case failed(String)
    }

    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var loadError: LoadError?
    @Published private(set) var canGoBack = false
    @Published private(set) var title: String = ""

    let rootPath: String
    private(set) var webView: WKWebView!
    private let auth: AuthService
    private let tapToPay: TapToPayBridge
    private var observations: [NSKeyValueObservation] = []
    private var hasLoaded = false
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    init(rootPath: String, auth: AuthService, terminal: TerminalManager) {
        self.rootPath = rootPath
        self.auth = auth
        tapToPay = TapToPayBridge(terminal: terminal)
        super.init()

        let native = NativeBridge()
        let config = WebSession.shared.makeConfiguration(messageHandlers: [
            TapToPayBridge.handlerName: tapToPay,
            NativeBridge.handlerName: native,
        ])
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.isInspectable = AppEnvironment.current != .production
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.keyboardDismissMode = .interactive

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            self?.reload()
            refresh?.endRefreshing()
        }, for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        self.webView = webView
        tapToPay.webView = webView
        native.webView = webView

        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.progress = view.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.isLoading = view.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.title = view.title ?? "" }
            },
        ]
    }

    // MARK: - Loading

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        load(path: rootPath)
    }

    func load(path: String) {
        guard let url = URL(string: path, relativeTo: AppEnvironment.current.appBaseURL) else { return }
        loadError = nil
        hasLoaded = true
        webView.load(URLRequest(url: url))
    }

    func reload() {
        loadError = nil
        if webView.url == nil {
            load(path: rootPath)
        } else {
            webView.reload()
        }
    }

    func goHome() {
        load(path: rootPath)
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    // MARK: - Routing helpers

    private func handleAppPath(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path == "/logout" {
            Task { await auth.signOut() }
            return true
        }
        if path == "/login" {
            // The web app bounced us to its login page: the session cookie is missing or expired.
            Task { await auth.handleWebSessionExpired() }
            return true
        }
        return false
    }

    private func openExternally(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            let safari = SFSafariViewController(url: url)
            safari.dismissButtonStyle = .close
            Presenter.present(safari)
        } else {
            UIApplication.shared.open(url)
        }
    }

    private static let allowedPaymentHosts = [
        "stripe.com", "stripe.network", "hyperswitch.io", "paypal.com", "plaid.com",
    ]

    private static func isPaymentHost(_ host: String) -> Bool {
        allowedPaymentHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}

// MARK: - WKNavigationDelegate

extension WebScreenModel: WKNavigationDelegate {
    func webView(
        _: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = action.request.url else { return (.cancel, preferences) }
        let scheme = url.scheme?.lowercased() ?? ""

        if action.shouldPerformDownload { return (.download, preferences) }

        switch scheme {
        case "about", "blob", "data", "javascript":
            return (.allow, preferences)
        case "http", "https":
            break
        default:
            // tel:, mailto:, sms:, maps:, itms-apps:, etc.
            openExternally(url)
            return (.cancel, preferences)
        }

        // Embedded frames (payment fields, Plaid, maps) load whatever they need.
        if action.targetFrame?.isMainFrame == false {
            return (.allow, preferences)
        }

        let host = url.host?.lowercased() ?? ""
        if AppEnvironment.current.isAppHost(host) {
            return handleAppPath(url) ? (.cancel, preferences) : (.allow, preferences)
        }
        // 3-D Secure / payment redirects return to the app, so keep them in place.
        if Self.isPaymentHost(host) || AppEnvironment.isFirstPartyHost(host) {
            return (.allow, preferences)
        }
        openExternally(url)
        return (.cancel, preferences)
    }

    func webView(
        _: WKWebView,
        decidePolicyFor response: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if !response.canShowMIMEType { return .download }
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment")
        {
            return .download
        }
        return .allow
    }

    func webView(_: WKWebView, navigationAction _: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_: WKWebView, navigationResponse _: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        loadError = nil
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func handle(_ error: Error) {
        let nsError = error as NSError
        // Cancelled navigations (e.g. ones we intercepted) and frame-load interruptions from downloads.
        if nsError.code == NSURLErrorCancelled || nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
            return
        }
        let offlineCodes = [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff,
        ]
        let unreachableCodes = [NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorTimedOut]
        if offlineCodes.contains(nsError.code) {
            loadError = .offline
        } else if unreachableCodes.contains(nsError.code) {
            let host = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host
                ?? AppEnvironment.current.appHost
            loadError = .unreachable(host)
        } else {
            loadError = .failed(nsError.localizedDescription)
        }
    }
}

// MARK: - WKUIDelegate

extension WebScreenModel: WKUIDelegate {
    /// `target="_blank"` and `window.open`: same-site links open here, everything else in Safari.
    func webView(
        _ webView: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        if AppEnvironment.current.isAppHost(url.host) {
            webView.load(action.request)
        } else if url.scheme == "blob" || url.scheme == "data" {
            webView.load(action.request)
        } else {
            openExternally(url)
        }
        return nil
    }

    func webView(
        _: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame _: WKFrameInfo
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation.resume() })
            Presenter.present(alert, onFailure: { continuation.resume() })
        }
    }

    func webView(
        _: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame _: WKFrameInfo
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation.resume(returning: true) })
            Presenter.present(alert, onFailure: { continuation.resume(returning: false) })
        }
    }

    func webView(
        _: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame _: WKFrameInfo
    ) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                continuation.resume(returning: alert?.textFields?.first?.text)
            })
            Presenter.present(alert, onFailure: { continuation.resume(returning: nil) })
        }
    }

    /// Camera/microphone for the barcode scanner and voice features: allow for our own site only;
    /// iOS still shows its system permission prompt the first time.
    func webView(
        _: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy _: WKFrameInfo,
        type _: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        AppEnvironment.current.isAppHost(origin.host) ? .grant : .deny
    }
}

// MARK: - WKDownloadDelegate

extension WebScreenModel: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing _: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = suggestedFilename.replacingOccurrences(of: "/", with: "-")
        let destination = folder.appendingPathComponent(safeName.isEmpty ? "download" : safeName)
        downloadDestinations[ObjectIdentifier(download)] = destination
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        Presenter.present(share)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData _: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        let alert = UIAlertController(
            title: "Download failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        Presenter.present(alert)
    }
}

/// Presents UIKit controllers (alerts, Safari, share sheets) over whatever is on screen.
@MainActor
enum Presenter {
    static func present(_ controller: UIViewController, onFailure: (() -> Void)? = nil) {
        guard let top = topViewController() else {
            onFailure?()
            return
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
