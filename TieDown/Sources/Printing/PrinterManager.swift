import Foundation
import UIKit
import WebKit

/// Owns the printers set up on this device and sends jobs to them.
///
/// - Receipt printers (network or Bluetooth) get ESC/POS built from the structured receipt.
/// - AirPrint printers get the HTML/page; with a default AirPrint printer the job prints
///   straight away, otherwise iOS shows its print sheet.
@MainActor
final class PrinterManager: ObservableObject {
    @Published private(set) var printers: [SavedPrinter] = []
    @Published private(set) var defaultPrinterId: UUID?
    @Published private(set) var isPrinting = false
    @Published private(set) var lastResult: String?

    let bluetooth = BluetoothPrinterCentral()
    let networkBrowser = NetworkPrinterBrowser()
    private let store: PrinterStore

    init(store: PrinterStore = PrinterStore()) {
        self.store = store
        let loaded = store.load()
        printers = loaded.printers
        defaultPrinterId = loaded.defaultId
    }

    var defaultPrinter: SavedPrinter? {
        printers.first { $0.id == defaultPrinterId } ?? printers.first
    }

    // MARK: - Managing printers

    func add(_ printer: SavedPrinter, makeDefault: Bool = false) {
        printers.append(printer)
        if makeDefault || defaultPrinterId == nil { defaultPrinterId = printer.id }
        persist()
    }

    func update(_ printer: SavedPrinter) {
        guard let index = printers.firstIndex(where: { $0.id == printer.id }) else { return }
        printers[index] = printer
        persist()
    }

    func remove(_ id: UUID) {
        printers.removeAll { $0.id == id }
        if defaultPrinterId == id { defaultPrinterId = printers.first?.id }
        persist()
    }

    func setDefault(_ id: UUID) {
        defaultPrinterId = id
        persist()
    }

    private func persist() {
        store.save(printers: printers, defaultId: defaultPrinterId)
    }

    // MARK: - Printing

    /// Prints a POS receipt on the default printer.
    func printReceipt(_ receipt: ReceiptPayload, html: String?) async throws {
        guard let printer = defaultPrinter else {
            // No printer set up yet: fall back to the AirPrint sheet so the receipt still prints.
            guard let html else { throw PrinterError.noPrinter }
            try await airPrint(html: html, jobName: "Receipt \(receipt.orderNumber)", to: nil)
            return
        }
        if printer.connection.isReceiptPrinter {
            let width = Int(receipt.config.paperWidth ?? "") ?? printer.paperWidthMM
            let formatter = ReceiptFormatter(paperWidthMM: width)
            let data = formatter.escPos(for: receipt, cut: printer.autoCut, openDrawer: printer.openCashDrawer)
            try await sendRaw(data, to: printer)
        } else if let html {
            try await airPrint(html: html, jobName: "Receipt \(receipt.orderNumber)", to: printer)
        } else {
            let text = ReceiptFormatter(columns: 48).lines(for: receipt).map(\.text).joined(separator: "\n")
            try await airPrint(html: "<pre style=\"font: 11pt Menlo\">\(Self.escape(text))</pre>", jobName: "Receipt", to: printer)
        }
    }

    /// Prints a receipt the web page laid out itself (e.g. reprinting an order).
    func printReceiptLines(_ lines: [WebReceiptLine], html: String?, jobName: String) async throws {
        if let printer = defaultPrinter, printer.connection.isReceiptPrinter {
            let formatter = ReceiptFormatter(paperWidthMM: printer.paperWidthMM)
            let data = formatter.render(formatter.lines(from: lines), cut: printer.autoCut, openDrawer: false)
            try await sendRaw(data, to: printer)
        } else if let html {
            try await airPrint(html: html, jobName: jobName, to: defaultPrinter)
        } else {
            let text = ReceiptFormatter(columns: 48).lines(from: lines).map(\.text).joined(separator: "\n")
            try await airPrint(html: "<pre style=\"font: 11pt Menlo\">\(Self.escape(text))</pre>", jobName: jobName, to: defaultPrinter)
        }
    }

    /// Prints arbitrary HTML (reports, print previews). Always AirPrint, since receipt printers can't render HTML.
    func printHTML(_ html: String, jobName: String) async throws {
        let airPrinter = printers.first { $0.id == defaultPrinterId && !$0.connection.isReceiptPrinter }
        try await airPrint(html: html, jobName: jobName, to: airPrinter)
    }

    /// Prints the page currently shown in a web view (what `window.print()` means on the web).
    func printWebView(_ webView: WKWebView, jobName: String) async throws {
        let airPrinter = printers.first { $0.id == defaultPrinterId && !$0.connection.isReceiptPrinter }
        try await present(formatter: webView.viewPrintFormatter(), jobName: jobName, to: airPrinter, showSheet: true)
    }

    func printTestPage(_ printer: SavedPrinter) async throws {
        if printer.connection.isReceiptPrinter {
            let data = ReceiptFormatter(paperWidthMM: printer.paperWidthMM).testPage(printerName: printer.name)
            try await sendRaw(data, to: printer)
        } else {
            let html = """
            <div style="font-family:-apple-system;text-align:center;padding:24px">
            <h1>TieDown</h1><p>Printer test for <b>\(Self.escape(printer.name))</b></p>
            <p>\(Date().formatted(date: .abbreviated, time: .shortened))</p>
            <p>If you can read this, AirPrint is working.</p></div>
            """
            try await airPrint(html: html, jobName: "TieDown test page", to: printer)
        }
    }

    /// Kicks the cash drawer attached to the default receipt printer.
    func openCashDrawer() async throws {
        guard let printer = printers.first(where: { $0.id == defaultPrinterId && $0.connection.isReceiptPrinter })
            ?? printers.first(where: { $0.connection.isReceiptPrinter })
        else { throw PrinterError.noPrinter }
        var commands = EscPos()
        commands.openCashDrawer()
        try await sendRaw(commands.data, to: printer)
    }

    func sendRaw(_ data: Data, to printer: SavedPrinter) async throws {
        isPrinting = true
        defer { isPrinting = false }
        do {
            switch printer.connection {
            case let .bluetooth(peripheralId):
                try await bluetooth.send(data, to: peripheralId)
            case .network, .bonjour:
                guard let endpoint = NetworkPrinterTransport.endpoint(for: printer.connection) else {
                    throw PrinterError.connectionFailed("Invalid printer address")
                }
                try await NetworkPrinterTransport.send(data, to: endpoint)
            case .airPrint:
                throw PrinterError.airPrintFailed("AirPrint printers can't take receipt printer commands")
            }
            lastResult = "Sent to \(printer.name)"
        } catch {
            lastResult = error.localizedDescription
            throw error
        }
    }

    // MARK: - AirPrint

    private func airPrint(html: String, jobName: String, to printer: SavedPrinter?) async throws {
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        formatter.perPageContentInsets = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        try await present(formatter: formatter, jobName: jobName, to: printer, showSheet: printer == nil)
    }

    private func present(
        formatter: UIPrintFormatter,
        jobName: String,
        to printer: SavedPrinter?,
        showSheet: Bool
    ) async throws {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = jobName
        controller.printInfo = info
        controller.printFormatter = formatter

        isPrinting = true
        defer { isPrinting = false }

        if !showSheet, case let .airPrint(url)? = printer?.connection {
            // Default AirPrint printer: print without asking.
            let ok: Bool = await withCheckedContinuation { continuation in
                controller.print(to: UIPrinter(url: url)) { _, completed, error in
                    continuation.resume(returning: completed && error == nil)
                }
            }
            if ok {
                lastResult = "Sent to \(printer?.name ?? "printer")"
                return
            }
            // Printer asleep or moved: fall through to the sheet so the user can pick another.
        }

        let completed: Bool = await withCheckedContinuation { continuation in
            let handler: UIPrintInteractionController.CompletionHandler = { _, completed, _ in
                continuation.resume(returning: completed)
            }
            if UIDevice.current.userInterfaceIdiom == .pad, let view = Presenter.topViewController()?.view {
                let rect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
                controller.present(from: rect, in: view, animated: true, completionHandler: handler)
            } else {
                controller.present(animated: true, completionHandler: handler)
            }
        }
        lastResult = completed ? "Sent to printer" : "Printing canceled"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
