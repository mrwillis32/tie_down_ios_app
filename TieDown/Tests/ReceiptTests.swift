@testable import TieDown
import XCTest

final class ReceiptPayloadTests: XCTestCase {
    /// The exact shape `useReceiptPrinter()` posts (apps/app/src/hooks/use-receipt-printer.ts).
    nonisolated(unsafe) static let webMessage: [String: Any] = [
        "action": "printReceipt",
        "receipt": [
            "orderNumber": "1042",
            "orderId": "ord_8f2c1d9e",
            "items": [
                ["id": "1", "name": "Avgas 100LL (gal)", "sku": "FUEL", "price": 6.25, "quantity": 40],
                ["id": "2", "name": "Tie-down overnight", "sku": "TD", "price": "15", "quantity": 1],
            ],
            "customer": ["id": "cus_1", "name": "Test Pilot", "email": NSNull()],
            "subtotal": 265,
            "taxAmount": 21.2,
            "taxLabel": "Sales Tax (8%)",
            "includedTaxAmount": 0,
            "includedTaxLabel": "",
            "subtotalAfterTax": 286.2,
            "discountAmount": 0,
            "discountName": "",
            "afterDiscount": 286.2,
            "serviceFeeAmount": 0,
            "serviceFeeName": "",
            "grandTotal": 286.2,
            "paymentMethod": "Card",
            "amountPaid": 300,
            "date": "2026-10-22T14:05:00.000Z",
        ],
        "config": [
            "showLogo": true,
            "showBarcode": false,
            "headerText": "Welcome to Red Bird",
            "footerText": "Thank you for flying with us!",
            "paperWidth": "58",
            "fields": [["field_name": "customer_name", "label": "Customer", "enabled": false, "order": 1]],
        ],
        "org": ["name": "Red Bird Skyport", "phone": "555-0100"],
        "html": "<html><body>receipt</body></html>",
    ]

    func testParsesWebReceiptMessage() throws {
        guard case let .receipt(receipt, html) = PrintCommand.parse(Self.webMessage) else {
            return XCTFail("expected a receipt command")
        }
        XCTAssertEqual(html, "<html><body>receipt</body></html>")
        XCTAssertEqual(receipt.orderNumber, "1042")
        XCTAssertEqual(receipt.items.count, 2)
        XCTAssertEqual(receipt.items[1].price, 15) // string number accepted
        XCTAssertEqual(receipt.customerName, "Test Pilot")
        XCTAssertEqual(receipt.grandTotal, 286.2, accuracy: 0.001)
        XCTAssertEqual(receipt.changeDue, 13.8, accuracy: 0.001)
        XCTAssertEqual(receipt.config.paperWidth, "58")
        XCTAssertFalse(receipt.isOn("customer_name"))
        XCTAssertTrue(receipt.isOn("subtotal")) // not listed → on
        XCTAssertEqual(receipt.org.name, "Red Bird Skyport")
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: receipt.date)
        XCTAssertEqual(parts.hour, 14)
    }

    func testMissingFieldsGetDefaults() throws {
        guard case let .receipt(receipt, html) = PrintCommand.parse(["action": "printReceipt", "receipt": [:]]) else {
            return XCTFail("expected a receipt command")
        }
        XCTAssertNil(html)
        XCTAssertEqual(receipt.items, [])
        XCTAssertEqual(receipt.customerId, "walk-in")
        XCTAssertEqual(receipt.taxLabel, "Tax")
    }

    func testOtherCommands() {
        XCTAssertEqual(PrintCommand.parse(["action": "printHTML", "html": "<p>x</p>", "title": "Report"]), .html("<p>x</p>", title: "Report"))
        XCTAssertEqual(PrintCommand.parse(["action": "printPage", "title": ""]), .page(title: "TieDown"))
        XCTAssertEqual(PrintCommand.parse(["action": "openCashDrawer"]), .openCashDrawer)
        XCTAssertEqual(PrintCommand.parse(["action": "getStatus"]), .status)
        XCTAssertEqual(PrintCommand.parse(["action": "openSettings"]), .openSettings)
        XCTAssertNil(PrintCommand.parse(["action": "printHTML", "html": ""]))
        XCTAssertNil(PrintCommand.parse(["action": "printReceipt"])) // no receipt
        XCTAssertNil(PrintCommand.parse(["action": "explode"]))
        XCTAssertNil(PrintCommand.parse("not a dictionary"))
    }
}

final class ReceiptFormatterTests: XCTestCase {
    private func receipt() throws -> ReceiptPayload {
        guard case let .receipt(receipt, _) = PrintCommand.parse(ReceiptPayloadTests.webMessage) else {
            throw XCTSkip("parse failed")
        }
        return receipt
    }

    func testColumnsFollowPaperWidth() {
        XCTAssertEqual(ReceiptFormatter(paperWidthMM: 58).columns, 32)
        XCTAssertEqual(ReceiptFormatter(paperWidthMM: 80).columns, 48)
    }

    func testEveryLineFitsThePaper() throws {
        for width in [58, 80] {
            let formatter = ReceiptFormatter(paperWidthMM: width)
            for line in formatter.lines(for: try receipt()) {
                XCTAssertLessThanOrEqual(line.text.count, formatter.columns, "too wide at \(width)mm: \(line.text)")
            }
        }
    }

    func testLayoutMatchesWebReceipt() throws {
        let formatter = ReceiptFormatter(paperWidthMM: 58)
        let lines = formatter.lines(for: try receipt())
        let text = lines.map(\.text)

        XCTAssertEqual(lines.first, ReceiptFormatter.Line(text: "Red Bird Skyport", alignment: .center, style: .large))
        XCTAssertTrue(text.contains("Welcome to Red Bird"))
        XCTAssertTrue(text.contains(formatter.row("Invoice No:", "#1042")))
        XCTAssertTrue(text.contains(formatter.row("Payment:", "Card")))
        XCTAssertFalse(text.contains { $0.contains("Test Pilot") }, "customer name is turned off in config")
        XCTAssertTrue(text.contains("Avgas 100LL (gal)"))
        XCTAssertTrue(text.contains(formatter.row("  40 x $6.25", "$250.00")))
        XCTAssertTrue(text.contains(formatter.row("Sales Tax (8%)", "$21.20")))
        XCTAssertTrue(lines.contains(ReceiptFormatter.Line(text: formatter.row("GRAND TOTAL", "$286.20"), style: .bold)))
        XCTAssertTrue(lines.contains(ReceiptFormatter.Line(text: formatter.row("Change Due", "$13.80"), style: .bold)))
        XCTAssertFalse(text.contains { $0.hasPrefix("Balance Due") })
        XCTAssertEqual(text.last, "Thank you for flying with us!")
    }

    func testRowPadsAndTruncates() {
        let formatter = ReceiptFormatter(columns: 20)
        XCTAssertEqual(formatter.row("Total", "$5.00"), "Total          $5.00")
        let long = formatter.row("A very long product name", "$5.00")
        XCTAssertEqual(long.count, 20)
        XCTAssertTrue(long.hasSuffix(" $5.00"))
        XCTAssertEqual(long, "A very long p. $5.00", "long names are cut with a trailing dot")
    }

    func testWrapBreaksWordsAndLongTokens() {
        let formatter = ReceiptFormatter(columns: 16)
        XCTAssertEqual(formatter.wrap("Thank you for flying with us"), ["Thank you for", "flying with us"])
        XCTAssertEqual(formatter.wrap("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), ["ABCDEFGHIJKLMNOP", "QRSTUVWXYZ"])
        XCTAssertEqual(formatter.wrap(""), [""])
    }

    func testNumberFormattingMatchesWeb() {
        XCTAssertEqual(ReceiptFormatter.price(1.5), "1.50")
        XCTAssertEqual(ReceiptFormatter.price(0.0125), "0.0125")
        XCTAssertEqual(ReceiptFormatter.price(2), "2.00")
        XCTAssertEqual(ReceiptFormatter.quantity(3), "3")
        XCTAssertEqual(ReceiptFormatter.quantity(2.5), "2.5")
        XCTAssertEqual(ReceiptFormatter.money(286.2), "$286.20")
    }

    func testEscPosJobCutsAndOptionallyKicksDrawer() throws {
        let formatter = ReceiptFormatter(paperWidthMM: 80)
        let plain = try formatter.escPos(for: receipt(), cut: true, openDrawer: false)
        XCTAssertEqual(Array(plain.prefix(2)), [0x1B, 0x40])
        XCTAssertEqual(Array(plain.suffix(4)), [0x1D, 0x56, 0x42, 0x03])
        let withDrawer = try formatter.escPos(for: receipt(), cut: true, openDrawer: true)
        XCTAssertEqual(Array(withDrawer.suffix(5)), [0x1B, 0x70, 0x00, 0x19, 0xFA])
        XCTAssertNotNil(String(data: plain, encoding: .ascii), "job must be pure ASCII")
    }

    func testFieldsTurnedOffAreOmitted() throws {
        var receipt = try receipt()
        receipt.config.fields = [
            .init(fieldName: "item_name", enabled: false),
            .init(fieldName: "grand_total", enabled: false),
        ]
        let text = ReceiptFormatter(paperWidthMM: 80).lines(for: receipt).map(\.text)
        XCTAssertFalse(text.contains("Avgas 100LL (gal)"))
        XCTAssertFalse(text.contains { $0.hasPrefix("GRAND TOTAL") })
    }

    func testTestPageFitsAndCuts() {
        let formatter = ReceiptFormatter(paperWidthMM: 58)
        let page = formatter.testPage(printerName: "Front Desk", date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(Array(page.suffix(4)), [0x1D, 0x56, 0x42, 0x03])
        let text = String(decoding: page, as: UTF8.self)
        XCTAssertTrue(text.contains("Front Desk"))
    }
}

final class WebReceiptLinesTests: XCTestCase {
    func testParsesAndFormatsWebLines() throws {
        let message: [String: Any] = [
            "action": "printReceiptLines",
            "title": "Receipt #1042",
            "html": "<html></html>",
            "lines": [
                ["text": "Red Bird Skyport", "align": "center", "bold": true],
                ["divider": "-"],
                ["left": "Invoice No:", "right": "#1042"],
                ["text": "Avgas 100LL"],
                ["left": "  40 x $6.25", "right": "$250.00"],
                ["divider": "="],
                ["left": "TOTAL", "right": "$270.00", "bold": true],
            ],
        ]
        guard case let .receiptLines(lines, html, title) = PrintCommand.parse(message) else {
            return XCTFail("expected receipt lines")
        }
        XCTAssertEqual(lines.count, 7)
        XCTAssertEqual(html, "<html></html>")
        XCTAssertEqual(title, "Receipt #1042")

        let formatter = ReceiptFormatter(paperWidthMM: 58)
        let printed = formatter.lines(from: lines)
        XCTAssertEqual(printed[0], ReceiptFormatter.Line(text: "Red Bird Skyport", alignment: .center, style: .bold))
        XCTAssertEqual(printed[1].text, String(repeating: "-", count: 32))
        XCTAssertEqual(printed[2].text, formatter.row("Invoice No:", "#1042"))
        XCTAssertEqual(printed.last, ReceiptFormatter.Line(text: formatter.row("TOTAL", "$270.00"), style: .bold))
        XCTAssertTrue(printed.allSatisfy { $0.text.count <= 32 })
    }

    func testRejectsEmptyLines() {
        XCTAssertNil(PrintCommand.parse(["action": "printReceiptLines", "lines": []]))
        XCTAssertNil(PrintCommand.parse(["action": "printReceiptLines"]))
    }
}
