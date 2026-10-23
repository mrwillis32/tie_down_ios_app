import Network
@testable import TieDown
import XCTest

final class PrinterStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "PrinterStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testEmptyByDefault() {
        let loaded = PrinterStore(defaults: defaults).load()
        XCTAssertTrue(loaded.printers.isEmpty)
        XCTAssertNil(loaded.defaultId)
    }

    func testRoundTripsEveryConnectionType() {
        let printers = [
            SavedPrinter(name: "Office", connection: .airPrint(url: URL(string: "ipps://office.local:631/ipp/print")!)),
            SavedPrinter(name: "Counter", connection: .network(host: "192.168.1.50", port: 9100), paperWidthMM: 80, openCashDrawer: true),
            SavedPrinter(name: "Bar", connection: .bonjour(name: "TM-m30", type: "_pdl-datastream._tcp", domain: "local.")),
            SavedPrinter(name: "Portable", connection: .bluetooth(peripheralId: UUID()), paperWidthMM: 58, autoCut: false),
        ]
        let store = PrinterStore(defaults: defaults)
        store.save(printers: printers, defaultId: printers[1].id)
        let loaded = store.load()
        XCTAssertEqual(loaded.printers, printers)
        XCTAssertEqual(loaded.defaultId, printers[1].id)
    }

    func testDefaultFallsBackToFirstWhenMissing() {
        let printers = [SavedPrinter(name: "A", connection: .network(host: "10.0.0.2", port: 9100))]
        let store = PrinterStore(defaults: defaults)
        store.save(printers: printers, defaultId: UUID()) // id that doesn't exist
        XCTAssertEqual(store.load().defaultId, printers[0].id)
    }

    func testReceiptPrinterClassification() {
        XCTAssertFalse(SavedPrinter.Connection.airPrint(url: URL(string: "ipp://x")!).isReceiptPrinter)
        XCTAssertTrue(SavedPrinter.Connection.network(host: "h", port: 9100).isReceiptPrinter)
        XCTAssertTrue(SavedPrinter.Connection.bluetooth(peripheralId: UUID()).isReceiptPrinter)
    }

    @MainActor
    func testManagerAddRemoveAndDefault() {
        let manager = PrinterManager(store: PrinterStore(defaults: defaults))
        let a = SavedPrinter(name: "A", connection: .network(host: "10.0.0.2", port: 9100))
        let b = SavedPrinter(name: "B", connection: .network(host: "10.0.0.3", port: 9100))
        manager.add(a)
        manager.add(b)
        XCTAssertEqual(manager.defaultPrinter?.id, a.id, "first printer becomes the default")
        manager.setDefault(b.id)
        XCTAssertEqual(manager.defaultPrinter?.id, b.id)
        manager.remove(b.id)
        XCTAssertEqual(manager.defaultPrinter?.id, a.id)
        // Persisted
        XCTAssertEqual(PrinterManager(store: PrinterStore(defaults: defaults)).printers.map(\.name), ["A"])
    }
}

/// Sends a real print job over TCP to a fake printer (an NWListener on localhost) and checks the bytes.
final class NetworkPrinterTransportTests: XCTestCase {
    func testSendsBytesToRawPort() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let received = ReceivedBytes()
        let gotData = expectation(description: "printer received the job")
        let ready = expectation(description: "listener ready")

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            @Sendable func readMore() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, _ in
                    if let data { received.append(data) }
                    if isComplete {
                        gotData.fulfill()
                        connection.cancel()
                    } else {
                        readMore()
                    }
                }
            }
            readMore()
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let job = ReceiptFormatter(paperWidthMM: 80).testPage(printerName: "Unit Test")
        let endpoint = try XCTUnwrap(NetworkPrinterTransport.endpoint(for: .network(host: "127.0.0.1", port: port)))
        try await NetworkPrinterTransport.send(job, to: endpoint, timeout: 5)

        await fulfillment(of: [gotData], timeout: 5)
        XCTAssertEqual(received.data, job)
        listener.cancel()
    }

    func testFailsFastWhenNothingIsListening() async throws {
        // Port 9 (discard) on localhost is closed on CI/dev machines: connection is refused.
        let endpoint = try XCTUnwrap(NetworkPrinterTransport.endpoint(for: .network(host: "127.0.0.1", port: 9)))
        let started = Date()
        do {
            try await NetworkPrinterTransport.send(Data([0x1B, 0x40]), to: endpoint, timeout: 3)
            XCTFail("expected a connection error")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        }
    }

    func testEndpointMapping() {
        XCTAssertNil(NetworkPrinterTransport.endpoint(for: .airPrint(url: URL(string: "ipp://x")!)))
        XCTAssertNil(NetworkPrinterTransport.endpoint(for: .bluetooth(peripheralId: UUID())))
        XCTAssertNotNil(NetworkPrinterTransport.endpoint(for: .bonjour(name: "P", type: "_pdl-datastream._tcp", domain: "local.")))
    }
}

private final class ReceivedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

final class ReaderKindTests: XCTestCase {
    func testPaymentReaderSelection() {
        XCTAssertEqual(ReaderKind.forPayment(requested: .bluetooth, connected: .tapToPay, preferred: .tapToPay), .bluetooth)
        XCTAssertEqual(ReaderKind.forPayment(requested: nil, connected: .bluetooth, preferred: .tapToPay), .bluetooth)
        XCTAssertEqual(ReaderKind.forPayment(requested: nil, connected: nil, preferred: .bluetooth), .bluetooth)
        XCTAssertEqual(ReaderKind.forPayment(requested: nil, connected: nil, preferred: .tapToPay), .tapToPay)
    }

    @MainActor
    func testPreferencesPersist() {
        let suite = "ReaderKindTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = TerminalManager(defaults: defaults)
        XCTAssertEqual(first.preferredKind, .tapToPay)
        first.preferredKind = .bluetooth
        XCTAssertEqual(TerminalManager(defaults: defaults).preferredKind, .bluetooth)
    }

    @MainActor
    func testBluetoothPaymentWithoutReaderFailsClearly() async {
        let terminal = TerminalManager(defaults: UserDefaults(suiteName: "ReaderKindTests.pay")!)
        terminal.configure(api: APIClient(baseURL: URL(string: "http://127.0.0.1:9")!))
        let result = await terminal.collectPayment(amountCents: 500, currency: "usd", orderId: nil, reader: .bluetooth)
        XCTAssertNil(result.paymentIntentId)
        XCTAssertEqual(result.error, TerminalError.noBluetoothReader.localizedDescription)
    }
}
