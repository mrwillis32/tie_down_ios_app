import Foundation

/// Lays out a `ReceiptPayload` for a thermal printer, following the same rules as the web
/// receipt (apps/app/src/lib/receipt-printer.ts `formatReceiptHtml`).
struct ReceiptFormatter {
    /// One printed line plus its styling.
    struct Line: Equatable {
        enum Style: Equatable {
            case normal
            case bold
            case large
        }

        var text: String
        var alignment: EscPos.Alignment = .left
        var style: Style = .normal
    }

    /// Characters per line: 32 on 58 mm paper, 48 on 80 mm paper (Font A).
    let columns: Int

    init(paperWidthMM: Int) {
        columns = paperWidthMM <= 58 ? 32 : 48
    }

    init(columns: Int) {
        self.columns = max(16, columns)
    }

    // MARK: - Layout

    func lines(for receipt: ReceiptPayload) -> [Line] {
        var out: [Line] = []
        let org = receipt.org

        if receipt.isOn("company_name"), let name = org.name, !name.isEmpty {
            out.append(Line(text: name, alignment: .center, style: .large))
        }
        if receipt.isOn("company_address"), let address = org.address, !address.isEmpty {
            out += wrap(address).map { Line(text: $0, alignment: .center) }
        }
        if receipt.isOn("company_phone"), let phone = org.phone, !phone.isEmpty {
            out.append(Line(text: phone, alignment: .center))
        }
        if receipt.isOn("company_email"), let email = org.email, !email.isEmpty {
            out.append(Line(text: email, alignment: .center))
        }
        if !receipt.config.headerText.isEmpty {
            out += wrap(receipt.config.headerText).map { Line(text: $0, alignment: .center) }
        }
        out.append(divider("-"))

        if receipt.isOn("order_number") {
            let number = receipt.orderNumber.isEmpty ? String(receipt.orderId.prefix(8)) : receipt.orderNumber
            out.append(Line(text: row("Invoice No:", "#\(number)")))
        }
        if receipt.isOn("order_date") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_GB")
            formatter.dateFormat = receipt.isOn("order_time") ? "dd/MM/yyyy HH:mm" : "dd/MM/yyyy"
            out.append(Line(text: row("Date:", formatter.string(from: receipt.date))))
        }
        if receipt.isOn("payment_method"), !receipt.paymentMethod.isEmpty {
            out.append(Line(text: row("Payment:", receipt.paymentMethod)))
        }
        if receipt.isOn("customer_name"), receipt.customerId != "walk-in", !receipt.customerName.isEmpty {
            out.append(Line(text: row("Customer:", receipt.customerName)))
        }

        if receipt.isOn("item_name"), !receipt.items.isEmpty {
            out.append(divider("="))
            for item in receipt.items {
                let total = (item.price * item.quantity * 10000).rounded() / 10000
                let quantity = Self.quantity(item.quantity)
                let showDetail = receipt.isOn("item_quantity") || receipt.isOn("item_price")
                // Name on its own line(s) when there's a detail line underneath; otherwise name + total.
                if showDetail {
                    out += wrap(item.name).map { Line(text: $0) }
                    var detail = "  "
                    if receipt.isOn("item_quantity") { detail += "\(quantity) x " }
                    if receipt.isOn("item_price") { detail += "$\(Self.price(item.price))" }
                    out.append(Line(text: row(detail, "$\(Self.price(total))")))
                } else {
                    out.append(Line(text: row(item.name, "$\(Self.price(total))")))
                }
            }
        }

        out.append(divider("-"))
        if receipt.isOn("subtotal") {
            out.append(Line(text: row("Subtotal", Self.money(receipt.subtotal))))
        }
        if receipt.isOn("tax_amount"), receipt.taxAmount > 0 {
            out.append(Line(text: row(receipt.taxLabel, Self.money(receipt.taxAmount))))
        }
        if receipt.isOn("tax_amount"), receipt.includedTaxAmount > 0 {
            out.append(Line(text: row(receipt.includedTaxLabel, Self.money(receipt.includedTaxAmount))))
        }
        if receipt.discountAmount > 0 || receipt.serviceFeeAmount > 0, receipt.taxAmount > 0 {
            out.append(Line(text: row("Subtotal + Tax", Self.money(receipt.subtotalAfterTax)), style: .bold))
        }
        if receipt.isOn("discount_total"), receipt.discountAmount > 0 {
            let name = receipt.discountName.isEmpty ? "Discount" : receipt.discountName
            out.append(Line(text: row(name, "-" + Self.money(receipt.discountAmount))))
        }
        if receipt.discountAmount > 0, receipt.serviceFeeAmount > 0 {
            out.append(Line(text: row("After Discount", Self.money(receipt.afterDiscount)), style: .bold))
        }
        if receipt.isOn("service_fee"), receipt.serviceFeeAmount > 0 {
            let name = receipt.serviceFeeName.isEmpty ? "Service Fee" : receipt.serviceFeeName
            out.append(Line(text: row(name, Self.money(receipt.serviceFeeAmount))))
        }
        if receipt.isOn("grand_total") {
            out.append(divider("="))
            out.append(Line(text: row("GRAND TOTAL", Self.money(receipt.grandTotal)), style: .bold))
        }
        if receipt.isOn("amount_paid") {
            out.append(Line(text: row("Amount Paid", Self.money(receipt.amountPaid))))
        }
        if receipt.isOn("balance_due"), receipt.changeDue > 0 {
            out.append(Line(text: row("Change Due", Self.money(receipt.changeDue)), style: .bold))
        }
        if receipt.isOn("balance_due"), receipt.balanceDue > 0 {
            out.append(Line(text: row("Balance Due", Self.money(receipt.balanceDue)), style: .bold))
        }

        if receipt.isOn("thank_you_message"), !receipt.config.footerText.isEmpty {
            out.append(Line(text: ""))
            out += wrap(receipt.config.footerText).map { Line(text: $0, alignment: .center) }
        }
        return out
    }

    /// Full ESC/POS job: header-to-footer, then feed and cut (and optionally kick the drawer).
    func escPos(for receipt: ReceiptPayload, cut: Bool = true, openDrawer: Bool = false) -> Data {
        render(lines(for: receipt), cut: cut, openDrawer: openDrawer)
    }

    /// A short page that proves the printer, paper width and cutter work.
    func testPage(printerName: String, date: Date = Date()) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let lines: [Line] = [
            Line(text: "TieDown", alignment: .center, style: .large),
            Line(text: "Printer test", alignment: .center, style: .bold),
            divider("-"),
            Line(text: row("Printer:", printerName)),
            Line(text: row("Paper:", "\(columns) characters wide")),
            Line(text: row("Printed:", formatter.string(from: date))),
            divider("-"),
            Line(text: String(repeating: "1234567890", count: columns / 10 + 1).prefix(columns).description),
            Line(text: "If this page looks right, you're ready to print receipts.", alignment: .center),
        ]
        return render(lines.flatMap { line in
            line.text.count > columns ? wrap(line.text).map { Line(text: $0, alignment: line.alignment, style: line.style) } : [line]
        }, cut: true, openDrawer: false)
    }

    /// Converts lines a web page laid out itself (label/amount rows, text, dividers).
    func lines(from webLines: [WebReceiptLine]) -> [Line] {
        webLines.flatMap { web -> [Line] in
            if let divider = web.divider {
                return [self.divider(divider == "=" ? "=" : "-")]
            }
            let style: Line.Style = web.large == true ? .large : web.bold == true ? .bold : .normal
            if web.left != nil || web.right != nil {
                return [Line(text: row(web.left ?? "", web.right ?? ""), style: style)]
            }
            let alignment: EscPos.Alignment = switch web.align {
            case "center": .center
            case "right": .right
            default: .left
            }
            // Large text is double width, so it gets half the columns.
            let wrapper = style == .large ? ReceiptFormatter(columns: columns / 2) : self
            return wrapper.wrap(web.text ?? "").map { Line(text: $0, alignment: alignment, style: style) }
        }
    }

    func render(_ lines: [Line], cut: Bool, openDrawer: Bool) -> Data {
        var printer = EscPos()
        for line in lines {
            printer.align(line.alignment)
            switch line.style {
            case .normal: break
            case .bold: printer.bold(true)
            case .large:
                printer.bold(true)
                printer.size(doubleWidth: true, doubleHeight: true)
            }
            printer.line(line.text)
            if line.style != .normal {
                printer.bold(false)
                printer.size(doubleWidth: false, doubleHeight: false)
            }
        }
        printer.align(.left)
        if cut {
            printer.feed(3)
            printer.cut()
        } else {
            printer.feed(4)
        }
        if openDrawer { printer.openCashDrawer() }
        return printer.data
    }

    // MARK: - Text layout

    /// Left text and right text on one line, padded to the full width (left side truncated if needed).
    func row(_ left: String, _ right: String) -> String {
        let right = String(right.prefix(columns))
        let room = columns - right.count - 1
        guard room > 0 else { return right }
        let leftPart = left.count > room ? String(left.prefix(max(0, room - 1))) + "." : left
        return leftPart + String(repeating: " ", count: columns - leftPart.count - right.count) + right
    }

    func divider(_ character: Character) -> Line {
        Line(text: String(repeating: character, count: columns))
    }

    /// Word-wraps to the line width, hard-breaking words longer than a line.
    func wrap(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            var word = word
            while word.count > columns {
                if !current.isEmpty {
                    lines.append(current)
                    current = ""
                }
                lines.append(String(word.prefix(columns)))
                word = String(word.dropFirst(columns))
            }
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= columns {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    // MARK: - Numbers (same rules as the web receipt)

    static func money(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// Up to 4 decimals for unit prices, but never fewer than 2 ("$1.50", "$0.0125").
    static func price(_ value: Double) -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0"), let dot = text.firstIndex(of: "."), text.distance(from: dot, to: text.endIndex) > 3 {
            text.removeLast()
        }
        return text
    }

    static func quantity(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}
