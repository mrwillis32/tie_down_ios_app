import Foundation
import WebKit

/// One receipt line from `receiptLinesFromHtml()` (apps/app/src/lib/native-print.ts).
struct WebReceiptLine: Decodable, Equatable, Sendable {
    var text: String?
    var left: String?
    var right: String?
    var align: String?
    var bold: Bool?
    var large: Bool?
    var divider: String?
}

/// A print request from a web page, parsed from the bridge message (pure; unit tested).
enum PrintCommand: Equatable {
    /// POS receipt: structured data for receipt printers plus HTML for AirPrint.
    case receipt(ReceiptPayload, html: String?)
    /// A receipt the page laid out itself (order reprints): ready-made lines plus HTML for AirPrint.
    case receiptLines([WebReceiptLine], html: String?, title: String)
    /// Any HTML document (print windows, iframes, reports).
    case html(String, title: String)
    /// The page itself (`window.print()` in the top-level page).
    case page(title: String)
    case openCashDrawer
    case status
    case openSettings

    static func parse(_ body: Any) -> PrintCommand? {
        guard let body = body as? [String: Any], let action = body["action"] as? String else { return nil }
        let title = (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "TieDown"
        switch action {
        case "printReceipt":
            guard let json = try? JSONSerialization.data(withJSONObject: body),
                  let receipt = try? JSONDecoder().decode(ReceiptPayload.self, from: json)
            else { return nil }
            return .receipt(receipt, html: body["html"] as? String)
        case "printReceiptLines":
            guard let raw = body["lines"],
                  let json = try? JSONSerialization.data(withJSONObject: raw),
                  let lines = try? JSONDecoder().decode([WebReceiptLine].self, from: json),
                  !lines.isEmpty
            else { return nil }
            return .receiptLines(lines, html: body["html"] as? String, title: title)
        case "printHTML":
            guard let html = body["html"] as? String, !html.isEmpty else { return nil }
            return .html(html, title: title)
        case "printPage":
            return .page(title: title)
        case "openCashDrawer":
            return .openCashDrawer
        case "getStatus":
            return .status
        case "openSettings":
            return .openSettings
        default:
            return nil
        }
    }
}

/// Web ↔ native printing.
///
/// Web → native (`window.webkit.messageHandlers.printer.postMessage(...)`):
///   { action: "printReceipt", receipt, config, org, html }   // from useReceiptPrinter()
///   { action: "printReceiptLines", lines, html, title }       // from printReceiptHtmlNatively()
///   { action: "printHTML", html, title }                      // window.print() in iframes / print windows
///   { action: "printPage", title }                            // window.print() on the page itself
///   { action: "openCashDrawer" } | { action: "getStatus" } | { action: "openSettings" }
///
/// Native → web:
///   window.onNativePrintResult({ success, error? })
///   window.onNativePrinterStatus({ hasPrinter, name?, kind? })
@MainActor
final class PrintBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "printer"

    weak var webView: WKWebView?
    /// Told which web view sent a print request (lets print windows avoid printing twice).
    var onPrintRequest: ((WKWebView?) -> Void)?
    private let printers: PrinterManager

    init(printers: PrinterManager) {
        self.printers = printers
    }

    /// Replaces `window.print()` in every frame (WKWebView on iOS ignores it otherwise).
    static let printOverrideScript = """
    (function () {
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.printer;
      if (!handler) return;
      window.print = function () {
        try {
          if (window === window.top && !window.opener) {
            handler.postMessage({ action: "printPage", title: document.title });
          } else {
            handler.postMessage({
              action: "printHTML",
              title: document.title,
              html: "<!doctype html>" + document.documentElement.outerHTML
            });
          }
        } catch (e) {}
      };
    })();
    """

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        // Our own pages only. Print windows and srcdoc/about:blank iframes inherit our origin.
        guard AppEnvironment.current.isAppHost(message.frameInfo.securityOrigin.host),
              let command = PrintCommand.parse(message.body)
        else { return }
        let source = message.webView
        switch command {
        case .receipt, .receiptLines, .html, .page: onPrintRequest?(source)
        default: break
        }

        Task {
            do {
                switch command {
                case let .receipt(receipt, html):
                    try await printers.printReceipt(receipt, html: html)
                case let .receiptLines(lines, html, title):
                    try await printers.printReceiptLines(lines, html: html, jobName: title)
                case let .html(html, title):
                    try await printers.printHTML(html, jobName: title)
                case let .page(title):
                    guard let page = source ?? webView else { return }
                    try await printers.printWebView(page, jobName: title)
                case .openCashDrawer:
                    try await printers.openCashDrawer()
                case .status:
                    sendStatus(to: source)
                    return
                case .openSettings:
                    NotificationCenter.default.post(name: .tdOpenNativeSettings, object: NativeSettingsScreen.printers)
                    return
                }
                send(["success": true], to: source)
            } catch {
                send(["success": false, "error": error.localizedDescription], to: source)
            }
        }
    }

    private func sendStatus(to target: WKWebView?) {
        var status: [String: Any] = ["hasPrinter": printers.defaultPrinter != nil]
        if let printer = printers.defaultPrinter {
            status["name"] = printer.name
            status["kind"] = printer.connection.isReceiptPrinter ? "receipt" : "airprint"
        }
        evaluate("onNativePrinterStatus", status, in: target)
    }

    private func send(_ payload: [String: Any], to target: WKWebView?) {
        evaluate("onNativePrintResult", payload, in: target)
    }

    private func evaluate(_ callback: String, _ payload: [String: Any], in target: WKWebView?) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        (target ?? webView)?.evaluateJavaScript("window.\(callback) && window.\(callback)(\(json));")
    }
}
