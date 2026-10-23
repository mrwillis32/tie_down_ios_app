import Foundation

/// A receipt sent from the web app (`ReceiptData`, `ReceiptConfig`, `OrgInfo` in
/// apps/app/src/lib/receipt-printer.ts). Decoding is lenient: missing fields get defaults and
/// numbers may arrive as numbers or strings.
struct ReceiptPayload: Decodable, Equatable, Sendable {
    struct Item: Decodable, Equatable, Sendable {
        var name: String
        var sku: String
        var price: Double
        var quantity: Double

        init(name: String, sku: String = "", price: Double, quantity: Double) {
            self.name = name
            self.sku = sku
            self.price = price
            self.quantity = quantity
        }

        enum CodingKeys: String, CodingKey { case name, sku, price, quantity }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Item"
            sku = try c.decodeIfPresent(String.self, forKey: .sku) ?? ""
            price = c.lenientDouble(.price)
            quantity = c.lenientDouble(.quantity, default: 1)
        }
    }

    struct Field: Decodable, Equatable, Sendable {
        var fieldName: String
        var enabled: Bool

        enum CodingKeys: String, CodingKey {
            case fieldName = "field_name"
            case enabled
        }
    }

    struct Config: Decodable, Equatable, Sendable {
        var headerText: String = ""
        var footerText: String = ""
        var paperWidth: String?
        var fields: [Field] = []

        enum CodingKeys: String, CodingKey { case headerText, footerText, paperWidth, fields }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            headerText = try c.decodeIfPresent(String.self, forKey: .headerText) ?? ""
            footerText = try c.decodeIfPresent(String.self, forKey: .footerText) ?? ""
            paperWidth = try? c.decodeIfPresent(String.self, forKey: .paperWidth)
            fields = (try? c.decodeIfPresent([Field].self, forKey: .fields)) ?? []
        }
    }

    struct Org: Decodable, Equatable, Sendable {
        var name: String?
        var address: String?
        var phone: String?
        var email: String?
    }

    var orderNumber: String = ""
    var orderId: String = ""
    var items: [Item] = []
    var customerId: String = "walk-in"
    var customerName: String = ""
    var subtotal: Double = 0
    var taxAmount: Double = 0
    var taxLabel: String = "Tax"
    var includedTaxAmount: Double = 0
    var includedTaxLabel: String = "Included tax"
    var subtotalAfterTax: Double = 0
    var discountAmount: Double = 0
    var discountName: String = ""
    var afterDiscount: Double = 0
    var serviceFeeAmount: Double = 0
    var serviceFeeName: String = ""
    var grandTotal: Double = 0
    var paymentMethod: String = ""
    var amountPaid: Double = 0
    var date: Date = .init()
    var config = Config()
    var org = Org()

    init() {}

    /// True unless the business turned this receipt field off in Settings › Receipts.
    func isOn(_ field: String) -> Bool {
        guard !config.fields.isEmpty else { return true }
        return config.fields.first { $0.fieldName == field }?.enabled ?? true
    }

    var changeDue: Double { max(0, amountPaid - grandTotal) }
    var balanceDue: Double { max(0, grandTotal - amountPaid) }

    // MARK: - Decoding

    /// The bridge message is `{ receipt: ReceiptData, config: ReceiptConfig|null, org: OrgInfo }`.
    private enum Envelope: String, CodingKey { case receipt, config, org }

    private enum DataKeys: String, CodingKey {
        case orderNumber, orderId, items, customer, subtotal, taxAmount, taxLabel, includedTaxAmount,
             includedTaxLabel, subtotalAfterTax, discountAmount, discountName, afterDiscount,
             serviceFeeAmount, serviceFeeName, grandTotal, paymentMethod, amountPaid, date
    }

    private struct Customer: Decodable {
        var id: String?
        var name: String?
    }

    init(from decoder: Decoder) throws {
        let envelope = try decoder.container(keyedBy: Envelope.self)
        let c = try envelope.nestedContainer(keyedBy: DataKeys.self, forKey: .receipt)
        orderNumber = c.lenientString(.orderNumber)
        orderId = c.lenientString(.orderId)
        items = (try? c.decodeIfPresent([Item].self, forKey: .items)) ?? []
        let customer = try? c.decodeIfPresent(Customer.self, forKey: .customer)
        customerId = customer?.id ?? "walk-in"
        customerName = customer?.name ?? ""
        subtotal = c.lenientDouble(.subtotal)
        taxAmount = c.lenientDouble(.taxAmount)
        taxLabel = c.lenientString(.taxLabel, default: "Tax")
        includedTaxAmount = c.lenientDouble(.includedTaxAmount)
        includedTaxLabel = c.lenientString(.includedTaxLabel, default: "Included tax")
        subtotalAfterTax = c.lenientDouble(.subtotalAfterTax)
        discountAmount = c.lenientDouble(.discountAmount)
        discountName = c.lenientString(.discountName)
        afterDiscount = c.lenientDouble(.afterDiscount)
        serviceFeeAmount = c.lenientDouble(.serviceFeeAmount)
        serviceFeeName = c.lenientString(.serviceFeeName)
        grandTotal = c.lenientDouble(.grandTotal)
        paymentMethod = c.lenientString(.paymentMethod)
        amountPaid = c.lenientDouble(.amountPaid)
        date = Self.parseDate(c.lenientString(.date)) ?? Date()
        config = (try? envelope.decodeIfPresent(Config.self, forKey: .config)) ?? Config()
        org = (try? envelope.decodeIfPresent(Org.self, forKey: .org)) ?? Org()
    }

    static func parseDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

private extension KeyedDecodingContainer {
    func lenientDouble(_ key: Key, default fallback: Double = 0) -> Double {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key), let value = Double(text) { return value }
        return fallback
    }

    func lenientString(_ key: Key, default fallback: String = "") -> String {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let number = try? decodeIfPresent(Double.self, forKey: key) {
            return number.rounded() == number ? String(Int(number)) : String(number)
        }
        return fallback
    }
}
