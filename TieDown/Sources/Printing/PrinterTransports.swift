@preconcurrency import CoreBluetooth
import Foundation
import Network

enum PrinterError: LocalizedError, Equatable {
    case noPrinter
    case timedOut
    case connectionFailed(String)
    case bluetoothUnavailable
    case bluetoothPrinterNotFound
    case noWritableCharacteristic
    case airPrintFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPrinter: "No printer is set up. Add one in More › App Settings › Printers."
        case .timedOut: "The printer didn't respond. Check it's on and connected to the same network."
        case let .connectionFailed(detail): "Couldn't reach the printer: \(detail)"
        case .bluetoothUnavailable: "Bluetooth is off or not allowed for TieDown. Turn it on in Settings."
        case .bluetoothPrinterNotFound: "The Bluetooth printer isn't in range. Turn it on and try again."
        case .noWritableCharacteristic: "This Bluetooth device doesn't accept print data."
        case let .airPrintFailed(detail): "AirPrint failed: \(detail)"
        }
    }
}

// MARK: - Network (raw TCP / port 9100)

/// Sends a print job to an ESC/POS printer over TCP using Network.framework.
enum NetworkPrinterTransport {
    static func send(_ data: Data, to endpoint: NWEndpoint, timeout: TimeInterval = 10) async throws {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "us.tiedown.printer.network")
        let gate = ResumeOnce()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                @Sendable func finish(_ result: Result<Void, Error>) {
                    guard gate.claim() else { return }
                    connection.cancel()
                    continuation.resume(with: result)
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                            if let error {
                                finish(.failure(PrinterError.connectionFailed(error.localizedDescription)))
                            } else {
                                finish(.success(()))
                            }
                        })
                    case let .failed(error):
                        finish(.failure(PrinterError.connectionFailed(error.localizedDescription)))
                    case let .waiting(error):
                        // Network unreachable / connection refused: fail fast instead of retrying forever.
                        finish(.failure(PrinterError.connectionFailed(error.localizedDescription)))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    finish(.failure(PrinterError.timedOut))
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    static func endpoint(for connection: SavedPrinter.Connection) -> NWEndpoint? {
        switch connection {
        case let .network(host, port):
            guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
            return .hostPort(host: NWEndpoint.Host(host), port: port)
        case let .bonjour(name, type, domain):
            return .service(name: name, type: type, domain: domain, interface: nil)
        default:
            return nil
        }
    }
}

/// Thread-safe "resume a continuation exactly once" flag.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - Network discovery

/// Finds receipt printers that advertise raw printing (`_pdl-datastream._tcp`) on the local network.
@MainActor
final class NetworkPrinterBrowser: ObservableObject {
    struct Found: Identifiable, Hashable {
        let name: String
        let type: String
        let domain: String
        var id: String { "\(name).\(type)\(domain)" }
    }

    static let serviceType = "_pdl-datastream._tcp"

    @Published private(set) var found: [Found] = []
    @Published private(set) var isBrowsing = false
    private var browser: NWBrowser?

    func start() {
        stop()
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Found? in
                if case let .service(name, type, domain, _) = result.endpoint {
                    return Found(name: name, type: type, domain: domain)
                }
                return nil
            }
            Task { @MainActor in self?.found = found.sorted { $0.name < $1.name } }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.isBrowsing = false } }
        }
        browser.start(queue: .main)
        self.browser = browser
        isBrowsing = true
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }
}

// MARK: - Bluetooth LE

/// Scans for and prints to Bluetooth LE receipt printers. Most BLE thermal printers expose one
/// writable characteristic that accepts raw ESC/POS bytes; data is written in MTU-sized chunks.
@MainActor
final class BluetoothPrinterCentral: NSObject, ObservableObject {
    struct Found: Identifiable, Hashable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    @Published private(set) var found: [Found] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isPoweredOn = false

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var poweredOnWaiters: [CheckedContinuation<Bool, Never>] = []
    private var connectContinuation: CheckedContinuation<CBPeripheral, Error>?
    private var characteristicContinuation: CheckedContinuation<CBCharacteristic, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var discoveredCharacteristics: [CBCharacteristic] = []
    private var pendingServices = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    func startScan() async {
        guard await waitForPowerOn() else { return }
        found = []
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        stopScan()
    }

    func stopScan() {
        if central.isScanning { central.stopScan() }
        isScanning = false
    }

    /// Connects, finds a writable characteristic, writes the job and disconnects.
    func send(_ data: Data, to peripheralId: UUID) async throws {
        guard await waitForPowerOn() else { throw PrinterError.bluetoothUnavailable }
        guard let peripheral = peripherals[peripheralId]
            ?? central.retrievePeripherals(withIdentifiers: [peripheralId]).first
        else { throw PrinterError.bluetoothPrinterNotFound }
        peripherals[peripheralId] = peripheral
        peripheral.delegate = self
        defer { central.cancelPeripheralConnection(peripheral) }

        let connected: CBPeripheral = try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
            central.connect(peripheral)
            armTimeout(seconds: 10) { $0.failConnect() }
        }
        let characteristic: CBCharacteristic = try await withCheckedThrowingContinuation { continuation in
            characteristicContinuation = continuation
            discoveredCharacteristics = []
            connected.discoverServices(nil)
            armTimeout(seconds: 10) { $0.failCharacteristic() }
        }
        let withResponse = characteristic.properties.contains(.write)
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        let chunkSize = max(20, min(512, connected.maximumWriteValueLength(for: type)))
        var offset = 0
        while offset < data.count {
            let chunk = data.subdata(in: offset ..< min(offset + chunkSize, data.count))
            if withResponse {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    writeContinuation = continuation
                    connected.writeValue(chunk, for: characteristic, type: .withResponse)
                    armTimeout(seconds: 5) { $0.failWrite() }
                }
            } else {
                connected.writeValue(chunk, for: characteristic, type: .withoutResponse)
                // Give cheap printers time to drain their buffer.
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            offset += chunk.count
        }
        // Let the last bytes leave the radio before disconnecting.
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func waitForPowerOn() async -> Bool {
        if central.state == .poweredOn { return true }
        if central.state == .unauthorized || central.state == .unsupported || central.state == .poweredOff {
            return false
        }
        return await withCheckedContinuation { continuation in
            poweredOnWaiters.append(continuation)
        }
    }

    /// Fails whichever wait is still pending after `seconds`. A generation counter makes sure a
    /// late timer never fails a newer wait.
    private var timeoutGeneration = 0

    private func armTimeout(seconds: Double, fail: @escaping @MainActor (BluetoothPrinterCentral) -> Void) {
        timeoutGeneration += 1
        let generation = timeoutGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.timeoutGeneration == generation else { return }
            fail(self)
        }
    }

    private func failConnect() {
        connectContinuation?.resume(throwing: PrinterError.timedOut)
        connectContinuation = nil
    }

    private func failCharacteristic() {
        characteristicContinuation?.resume(throwing: PrinterError.timedOut)
        characteristicContinuation = nil
    }

    private func failWrite() {
        writeContinuation?.resume(throwing: PrinterError.timedOut)
        writeContinuation = nil
    }
}

extension BluetoothPrinterCentral: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated {
            isPoweredOn = state == .poweredOn
            guard state != .unknown, state != .resetting else { return }
            let waiters = poweredOnWaiters
            poweredOnWaiters = []
            waiters.forEach { $0.resume(returning: state == .poweredOn) }
        }
    }

    nonisolated func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name, !name.isEmpty else { return } // unnamed devices are never printers people can pick
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            peripherals[id] = peripheral
            if !found.contains(where: { $0.id == id }) {
                found.append(Found(id: id, name: name, rssi: rssi))
                found.sort { $0.rssi > $1.rssi }
            }
        }
    }

    nonisolated func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            connectContinuation?.resume(returning: peripheral)
            connectContinuation = nil
        }
    }

    nonisolated func centralManager(_: CBCentralManager, didFailToConnect _: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            connectContinuation?.resume(throwing: PrinterError.connectionFailed(error?.localizedDescription ?? "connection failed"))
            connectContinuation = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let services = peripheral.services ?? []
            if error != nil || services.isEmpty {
                characteristicContinuation?.resume(throwing: PrinterError.noWritableCharacteristic)
                characteristicContinuation = nil
                return
            }
            pendingServices = services.count
            services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
        }
    }

    nonisolated func peripheral(_: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error _: Error?) {
        MainActor.assumeIsolated {
            discoveredCharacteristics += service.characteristics ?? []
            pendingServices -= 1
            guard pendingServices <= 0, let continuation = characteristicContinuation else { return }
            characteristicContinuation = nil
            // Prefer a write-without-response characteristic (what most printers use for bulk data).
            let writable = discoveredCharacteristics.first { $0.properties.contains(.writeWithoutResponse) }
                ?? discoveredCharacteristics.first { $0.properties.contains(.write) }
            if let writable {
                continuation.resume(returning: writable)
            } else {
                continuation.resume(throwing: PrinterError.noWritableCharacteristic)
            }
        }
    }

    nonisolated func peripheral(_: CBPeripheral, didWriteValueFor _: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                writeContinuation?.resume(throwing: PrinterError.connectionFailed(error.localizedDescription))
            } else {
                writeContinuation?.resume()
            }
            writeContinuation = nil
        }
    }
}
