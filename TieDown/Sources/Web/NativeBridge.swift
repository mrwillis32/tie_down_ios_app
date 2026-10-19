import UIKit
import WebKit

/// Small general-purpose bridge for web pages:
/// `window.webkit.messageHandlers.native.postMessage({ action: "haptic", style: "success" })`
/// `window.webkit.messageHandlers.native.postMessage({ action: "share", url, text })`
@MainActor
final class NativeBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "native"
    weak var webView: WKWebView?

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              AppEnvironment.current.isAppHost(message.frameInfo.securityOrigin.host),
              let body = message.body as? [String: Any],
              let action = body["action"] as? String
        else { return }

        switch action {
        case "haptic":
            haptic(body["style"] as? String)
        case "share":
            var items: [Any] = []
            if let text = body["text"] as? String { items.append(text) }
            if let link = body["url"] as? String, let url = URL(string: link) { items.append(url) }
            guard !items.isEmpty else { return }
            Presenter.present(UIActivityViewController(activityItems: items, applicationActivities: nil))
        default:
            break
        }
    }

    private func haptic(_ style: String?) {
        switch style {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}
