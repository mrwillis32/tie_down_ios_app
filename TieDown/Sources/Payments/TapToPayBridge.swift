import Foundation
import WebKit

/// Web ↔ native contract for Tap to Pay (used by apps/app/src/routes/(shell)/pos/orders.new._index.tsx).
///
/// Web → native:
///   window.webkit.messageHandlers.tapToPay.postMessage({
///     action: "collectPayment", amount: 1500, currency: "usd", orderId?: "...", requestId?: "..."
///   })
///   window.webkit.messageHandlers.tapToPay.postMessage({ action: "cancelCollect" })
///   window.webkit.messageHandlers.tapToPay.postMessage({ action: "prepare" })   // warm up the reader
///
/// Native → web:
///   window.onTapToPayResult({ success, paymentIntentId?, last4?, brand?, error?, canceled?, requestId? })
@MainActor
final class TapToPayBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "tapToPay"

    weak var webView: WKWebView?
    private let terminal: TerminalManager

    init(terminal: TerminalManager) {
        self.terminal = terminal
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only our own top-level page may start a charge — never an iframe or another site.
        guard message.frameInfo.isMainFrame,
              AppEnvironment.current.isAppHost(message.frameInfo.securityOrigin.host),
              message.frameInfo.securityOrigin.protocol == (AppEnvironment.current.usesHTTPS ? "https" : "http"),
              let body = message.body as? [String: Any],
              let action = body["action"] as? String
        else { return }

        let requestId = body["requestId"] as? String
        switch action {
        case "collectPayment":
            collect(body, requestId: requestId)
        case "cancelCollect":
            terminal.cancelCollect()
        case "prepare":
            Task { _ = try? await terminal.prepare() }
        default:
            send(["success": false, "error": "Unknown action: \(action)"], requestId: requestId)
        }
    }

    private func collect(_ body: [String: Any], requestId: String?) {
        guard let amount = (body["amount"] as? NSNumber)?.intValue, amount > 0 else {
            send(["success": false, "error": "Missing or invalid amount"], requestId: requestId)
            return
        }
        guard !terminal.isCollecting else {
            send(["success": false, "error": TerminalError.busy.localizedDescription, "busy": true], requestId: requestId)
            return
        }
        let currency = body["currency"] as? String ?? "usd"
        let orderId = body["orderId"] as? String

        Task {
            let result = await terminal.collectPayment(amountCents: amount, currency: currency, orderId: orderId)
            var payload: [String: Any] = ["success": result.paymentIntentId != nil]
            if let id = result.paymentIntentId { payload["paymentIntentId"] = id }
            if let last4 = result.last4 { payload["last4"] = last4 }
            if let brand = result.brand { payload["brand"] = brand }
            if let error = result.error { payload["error"] = error }
            if result.canceled { payload["canceled"] = true }
            send(payload, requestId: requestId)
        }
    }

    private func send(_ payload: [String: Any], requestId: String?) {
        var payload = payload
        if let requestId { payload["requestId"] = requestId }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        webView?.evaluateJavaScript("window.onTapToPayResult && window.onTapToPayResult(\(json));")
    }
}
