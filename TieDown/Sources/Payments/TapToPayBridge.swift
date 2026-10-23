import Foundation
import WebKit

extension Notification.Name {
    /// Posted by web bridges to open a native settings screen (`object` is a `NativeSettingsScreen`).
    static let tdOpenNativeSettings = Notification.Name("tdOpenNativeSettings")
}

/// Native settings screens a web page can ask to open.
enum NativeSettingsScreen: String, Identifiable, Sendable {
    case cardReaders
    case printers

    var id: String { rawValue }
}

/// Web ↔ native contract for in-person card payments
/// (used by apps/app/src/routes/(shell)/pos/orders.new._index.tsx).
///
/// Web → native:
///   window.webkit.messageHandlers.tapToPay.postMessage({
///     action: "collectPayment", amount: 1500, currency: "usd",
///     reader?: "tapToPay" | "bluetooth", orderId?: "...", requestId?: "..."
///   })
///   …postMessage({ action: "cancelCollect" })
///   …postMessage({ action: "prepare" })               // warm up Tap to Pay
///   …postMessage({ action: "getReaderStatus" })       // → window.onNativeReaderStatus(status)
///   …postMessage({ action: "openReaderSettings" })    // opens More › App Settings › Card Readers
///
/// Native → web:
///   window.onTapToPayResult({ success, paymentIntentId?, last4?, brand?, error?, canceled?, requestId? })
///   window.onNativeReaderStatus({ connected, kind?, name?, batteryPercent?, preferred, tapToPay, bluetooth })
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
        case "getReaderStatus":
            sendStatus()
        case "openReaderSettings":
            NotificationCenter.default.post(name: .tdOpenNativeSettings, object: NativeSettingsScreen.cardReaders)
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
        let reader = (body["reader"] as? String).flatMap(ReaderKind.init(rawValue:))

        Task {
            let result = await terminal.collectPayment(
                amountCents: amount,
                currency: currency,
                orderId: orderId,
                reader: reader
            )
            var payload: [String: Any] = ["success": result.paymentIntentId != nil]
            if let id = result.paymentIntentId { payload["paymentIntentId"] = id }
            if let last4 = result.last4 { payload["last4"] = last4 }
            if let brand = result.brand { payload["brand"] = brand }
            if let error = result.error { payload["error"] = error }
            if result.canceled { payload["canceled"] = true }
            send(payload, requestId: requestId)
        }
    }

    private func sendStatus() {
        var status: [String: Any] = [
            "connected": terminal.connectedReader != nil,
            "preferred": terminal.preferredKind.rawValue,
            "tapToPay": true,
            "bluetooth": true,
        ]
        if let kind = terminal.connectedKind { status["kind"] = kind.rawValue }
        if let name = terminal.connectedReaderName { status["name"] = name }
        if let battery = terminal.batteryPercent { status["batteryPercent"] = battery }
        evaluate(callback: "onNativeReaderStatus", payload: status)
    }

    private func send(_ payload: [String: Any], requestId: String?) {
        var payload = payload
        if let requestId { payload["requestId"] = requestId }
        evaluate(callback: "onTapToPayResult", payload: payload)
    }

    private func evaluate(callback: String, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        webView?.evaluateJavaScript("window.\(callback) && window.\(callback)(\(json));")
    }
}
