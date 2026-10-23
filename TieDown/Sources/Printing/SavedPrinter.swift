import Foundation

/// A printer the user has set up on this device.
struct SavedPrinter: Codable, Identifiable, Equatable, Sendable {
    enum Connection: Codable, Equatable, Sendable {
        /// Any AirPrint printer; `url` comes from `UIPrinter.url`.
        case airPrint(url: URL)
        /// ESC/POS receipt printer reached over TCP (raw "JetDirect" port, usually 9100).
        case network(host: String, port: UInt16)
        /// ESC/POS receipt printer advertised on the network via Bonjour (`_pdl-datastream._tcp`).
        case bonjour(name: String, type: String, domain: String)
        /// ESC/POS receipt printer over Bluetooth Low Energy; `peripheralId` is the CoreBluetooth identifier.
        case bluetooth(peripheralId: UUID)

        /// True for printers that take raw ESC/POS receipt commands (everything except AirPrint).
        var isReceiptPrinter: Bool {
            if case .airPrint = self { return false }
            return true
        }

        var summary: String {
            switch self {
            case .airPrint: "AirPrint"
            case let .network(host, port): "Network · \(host):\(port)"
            case .bonjour: "Network · found automatically"
            case .bluetooth: "Bluetooth"
            }
        }
    }

    var id: UUID = .init()
    var name: String
    var connection: Connection
    /// 58 or 80 (mm). Only used by receipt printers.
    var paperWidthMM: Int = 80
    var autoCut: Bool = true
    var openCashDrawer: Bool = false
}

/// Persists printers and the default choice in `UserDefaults` (pure logic; unit tested).
struct PrinterStore {
    private let defaults: UserDefaults
    private static let printersKey = "printers.saved.v1"
    private static let defaultKey = "printers.default.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> (printers: [SavedPrinter], defaultId: UUID?) {
        let printers = defaults.data(forKey: Self.printersKey)
            .flatMap { try? JSONDecoder().decode([SavedPrinter].self, from: $0) } ?? []
        var defaultId = defaults.string(forKey: Self.defaultKey).flatMap(UUID.init(uuidString:))
        if let id = defaultId, !printers.contains(where: { $0.id == id }) { defaultId = nil }
        return (printers, defaultId ?? printers.first?.id)
    }

    func save(printers: [SavedPrinter], defaultId: UUID?) {
        if let data = try? JSONEncoder().encode(printers) {
            defaults.set(data, forKey: Self.printersKey)
        }
        defaults.set(defaultId?.uuidString, forKey: Self.defaultKey)
    }
}
