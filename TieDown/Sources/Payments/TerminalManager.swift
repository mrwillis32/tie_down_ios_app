import CoreLocation
import Foundation
@preconcurrency import StripeTerminal

// Stripe Terminal hands out `Reader` objects and calls its delegates on the main queue, and this
// app only touches them from the main actor, so passing one between main-actor code is safe.
extension Reader: @retroactive @unchecked Sendable {}

struct PaymentResult: Sendable {
    let paymentIntentId: String?
    let last4: String?
    let brand: String?
    let error: String?
    let canceled: Bool

    static func failure(_ message: String, canceled: Bool = false) -> PaymentResult {
        PaymentResult(paymentIntentId: nil, last4: nil, brand: nil, error: message, canceled: canceled)
    }
}

/// The two ways this app takes a card in person.
enum ReaderKind: String, Codable, Sendable, CaseIterable {
    /// The iPhone itself (Tap to Pay on iPhone).
    case tapToPay
    /// A paired Bluetooth reader: Stripe M2, BBPOS WisePad 3 or Chipper 2X BT.
    case bluetooth

    var displayName: String {
        switch self {
        case .tapToPay: "Tap to Pay on iPhone"
        case .bluetooth: "Bluetooth card reader"
        }
    }

    /// Which reader a payment should use: the one the page asked for, else whatever is connected,
    /// else the one the user last chose.
    static func forPayment(requested: ReaderKind?, connected: ReaderKind?, preferred: ReaderKind) -> ReaderKind {
        requested ?? connected ?? preferred
    }
}

/// A Bluetooth reader found while scanning (value type so SwiftUI can list it).
struct DiscoveredReader: Identifiable, Equatable, Sendable {
    let id: String // serial number
    let label: String
    let model: String
    let batteryPercent: Int?
    let simulated: Bool
}

enum TerminalError: LocalizedError, Equatable {
    case busy
    case notConfigured
    case locationDenied
    case noReaderFound
    case missingLocation
    case noBluetoothReader
    case readerNotFound
    case sdk(String)

    var errorDescription: String? {
        switch self {
        case .busy: "A payment is already in progress."
        case .notConfigured: "Card payments aren't set up yet. Please sign in again."
        case .locationDenied: "Card readers need location access. Turn it on in Settings › TieDown › Location."
        case .noReaderFound: "This iPhone doesn't support Tap to Pay (iPhone XS or later on iOS 16.7+ required)."
        case .missingLocation: "No Stripe Terminal location is configured for this business."
        case .noBluetoothReader:
            "No Bluetooth card reader is connected. Connect one in More › App Settings › Card Readers."
        case .readerNotFound: "That reader is no longer in range. Turn it on and scan again."
        case let .sdk(message): message
        }
    }
}

/// Stripe Terminal lifecycle for Tap to Pay on iPhone and Bluetooth readers (StripeTerminal 5.8.x):
/// SDK init, location permission, discovery, one connection at a time, and payment collection.
@MainActor
final class TerminalManager: NSObject, ObservableObject {
    @Published private(set) var statusMessage: String?
    @Published private(set) var connectedReader: Reader?
    @Published private(set) var connectedKind: ReaderKind?
    @Published private(set) var isCollecting = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isScanning = false
    @Published private(set) var discoveredReaders: [DiscoveredReader] = []
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var updateAvailable = false
    @Published private(set) var lastError: String?

    /// The reader type used when a page doesn't ask for one. Remembered across launches.
    @Published var preferredKind: ReaderKind {
        didSet { defaults.set(preferredKind.rawValue, forKey: Keys.preferredKind) }
    }

    /// Serial number of the Bluetooth reader to reconnect to automatically.
    @Published private(set) var savedBluetoothSerial: String? {
        didSet { defaults.set(savedBluetoothSerial, forKey: Keys.savedSerial) }
    }

    private enum Keys {
        static let preferredKind = "terminal.preferredKind"
        static let savedSerial = "terminal.bluetoothSerial"
    }

    private let defaults: UserDefaults
    private var api: APIClient?
    private let tokenProvider = TerminalTokenProvider()
    private let locationPermission = LocationPermission()

    private enum DiscoveryMode {
        case none
        case tapToPay
        case bluetooth
    }

    private var discoveryMode: DiscoveryMode = .none
    private var discoverCancelable: Cancelable?
    private var collectCancelable: Cancelable?
    private var connectTask: Task<Reader, Error>?
    private var tapToPayContinuation: CheckedContinuation<Reader, Error>?
    private var bluetoothReaders: [String: Reader] = [:]
    /// When set, connect to this serial as soon as a scan finds it (auto-reconnect).
    private var autoConnectSerial: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferredKind = defaults.string(forKey: Keys.preferredKind).flatMap(ReaderKind.init(rawValue:)) ?? .tapToPay
        savedBluetoothSerial = defaults.string(forKey: Keys.savedSerial)
        super.init()
    }

    /// Called once at launch/sign-in. Initialising early means `Terminal.shared` is always safe to touch.
    func configure(api: APIClient) {
        self.api = api
        tokenProvider.api = api
        if !Terminal.isInitialized() {
            Terminal.initWithTokenProvider(tokenProvider)
        }
    }

    var connectedReaderName: String? {
        guard let reader = connectedReader else { return nil }
        if connectedKind == .tapToPay { return "This iPhone (Tap to Pay)" }
        return reader.label ?? "\(Terminal.stringFromDeviceType(reader.deviceType)) \(reader.serialNumber)"
    }

    // MARK: - Tap to Pay

    /// Connects the built-in Tap to Pay reader (disconnecting a Bluetooth reader first).
    /// Safe to call repeatedly; concurrent callers share one attempt.
    @discardableResult
    func prepare() async throws -> Reader {
        if let reader = connectedReader, connectedKind == .tapToPay { return reader }
        if let connectTask { return try await connectTask.value }
        guard let api else { throw TerminalError.notConfigured }

        let task = Task<Reader, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            if self.connectedKind == .bluetooth { await self.disconnect() }
            return try await self.connectTapToPay(api: api)
        }
        connectTask = task
        isConnecting = true
        defer {
            connectTask = nil
            isConnecting = false
        }
        return try await task.value
    }

    private func connectTapToPay(api: APIClient) async throws -> Reader {
        guard await locationPermission.request() else { throw TerminalError.locationDenied }

        statusMessage = "Preparing Tap to Pay…"
        let locationId = try await fetchLocationId(api: api)
        let reader = try await discoverTapToPayReader()

        statusMessage = "Connecting…"
        let connectionConfig = try TapToPayConnectionConfigurationBuilder(delegate: self, locationId: locationId)
            .setMerchantDisplayName("TieDown")
            .setTosAcceptancePermitted(true)
            .setAutoReconnectOnUnexpectedDisconnect(true)
            .build()

        let connected = try await connect(reader, config: connectionConfig)
        didConnect(connected, kind: .tapToPay)
        statusMessage = "Tap to Pay ready"
        return connected
    }

    private func discoverTapToPayReader() async throws -> Reader {
        stopScan()
        let builder = TapToPayDiscoveryConfigurationBuilder()
        #if targetEnvironment(simulator)
            builder.setSimulated(true)
        #endif
        let config = try builder.build()
        statusMessage = "Starting Tap to Pay…"

        return try await withCheckedThrowingContinuation { continuation in
            tapToPayContinuation = continuation
            discoveryMode = .tapToPay
            discoverCancelable = Terminal.shared.discoverReaders(config, delegate: self) { [weak self] error in
                Task { @MainActor in self?.discoveryEnded(error: error) }
            }
        }
    }

    // MARK: - Bluetooth readers

    /// Scans for nearby Bluetooth readers; results appear in `discoveredReaders`.
    func startBluetoothScan() async {
        lastError = nil
        guard api != nil else {
            lastError = TerminalError.notConfigured.localizedDescription
            return
        }
        guard await locationPermission.request() else {
            lastError = TerminalError.locationDenied.localizedDescription
            return
        }
        stopScan()
        do {
            let builder = BluetoothScanDiscoveryConfigurationBuilder().setTimeout(30)
            #if targetEnvironment(simulator)
                builder.setSimulated(true)
            #endif
            let config = try builder.build()
            discoveredReaders = []
            bluetoothReaders = [:]
            isScanning = true
            discoveryMode = .bluetooth
            statusMessage = "Looking for card readers… Turn your reader on."
            discoverCancelable = Terminal.shared.discoverReaders(config, delegate: self) { [weak self] error in
                Task { @MainActor in self?.discoveryEnded(error: error) }
            }
        } catch {
            isScanning = false
            lastError = error.localizedDescription
        }
    }

    func stopScan() {
        if let discoverCancelable, !discoverCancelable.completed {
            discoverCancelable.cancel { _ in }
        }
        discoverCancelable = nil
        isScanning = false
        if discoveryMode == .bluetooth { discoveryMode = .none }
    }

    /// Connects a reader found by `startBluetoothScan()` and remembers it for next time.
    @discardableResult
    func connectBluetooth(serial: String) async throws -> Reader {
        guard let api else { throw TerminalError.notConfigured }
        guard let reader = bluetoothReaders[serial] else { throw TerminalError.readerNotFound }
        stopScan()
        isConnecting = true
        lastError = nil
        defer { isConnecting = false }
        do {
            if connectedReader != nil { await disconnect() }
            statusMessage = "Connecting to \(reader.label ?? reader.serialNumber)…"
            let locationId = try await fetchLocationId(api: api)
            let config = try BluetoothConnectionConfigurationBuilder(delegate: self, locationId: locationId)
                .setAutoReconnectOnUnexpectedDisconnect(true)
                .build()
            let connected = try await connect(reader, config: config)
            didConnect(connected, kind: .bluetooth)
            savedBluetoothSerial = connected.serialNumber
            preferredKind = .bluetooth
            statusMessage = "Connected to \(connectedReaderName ?? "reader")"
            return connected
        } catch {
            statusMessage = nil
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Scans and reconnects the remembered Bluetooth reader when it shows up.
    func reconnectSavedReader() async {
        guard let serial = savedBluetoothSerial, connectedKind != .bluetooth else { return }
        autoConnectSerial = serial
        await startBluetoothScan()
    }

    /// Disconnects and stops auto-reconnecting to the saved Bluetooth reader.
    func forgetBluetoothReader() async {
        autoConnectSerial = nil
        if connectedKind == .bluetooth { await disconnect() }
        savedBluetoothSerial = nil
        if preferredKind == .bluetooth { preferredKind = .tapToPay }
    }

    /// Installs an optional reader software update reported by `didReportAvailableUpdate`.
    func installAvailableUpdate() {
        guard connectedKind == .bluetooth else { return }
        Terminal.shared.installAvailableUpdate()
    }

    func disconnect() async {
        guard connectedReader != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Terminal.shared.disconnectReader { _ in continuation.resume() }
        }
        connectedReader = nil
        connectedKind = nil
        batteryPercent = nil
        updateAvailable = false
        statusMessage = nil
    }

    // MARK: - Shared connection helpers

    private func fetchLocationId(api: APIClient) async throws -> String {
        struct LocationResponse: Decodable { let locationId: String }
        let location: LocationResponse = try await api.get("/api/v1/payments/terminal/location")
        guard !location.locationId.isEmpty else { throw TerminalError.missingLocation }
        return location.locationId
    }

    private func connect(_ reader: Reader, config: ConnectionConfiguration) async throws -> Reader {
        try await withCheckedThrowingContinuation { continuation in
            Terminal.shared.connectReader(reader, connectionConfig: config) { reader, error in
                if let reader {
                    continuation.resume(returning: reader)
                } else {
                    continuation.resume(throwing: error ?? TerminalError.noReaderFound)
                }
            }
        }
    }

    private func didConnect(_ reader: Reader, kind: ReaderKind) {
        connectedReader = reader
        connectedKind = kind
        batteryPercent = reader.batteryLevel.map { Int(($0.floatValue * 100).rounded()) }
    }

    private func discoveryEnded(error: Error?) {
        discoverCancelable = nil
        isScanning = false
        if let pending = tapToPayContinuation {
            tapToPayContinuation = nil
            pending.resume(throwing: error ?? TerminalError.noReaderFound)
        }
        if discoveryMode == .bluetooth, let error {
            let nsError = error as NSError
            // Canceled scans (user stopped, or we connected) aren't errors worth showing.
            if nsError.code != 2020 { lastError = error.localizedDescription }
            if discoveredReaders.isEmpty, statusMessage?.hasPrefix("Looking") == true { statusMessage = nil }
        }
        discoveryMode = .none
    }

    // MARK: - Payments

    /// Creates a PaymentIntent on the TieDown API, collects the card on the chosen reader, and confirms it.
    func collectPayment(
        amountCents: Int,
        currency: String,
        orderId: String?,
        reader requested: ReaderKind? = nil
    ) async -> PaymentResult {
        guard !isCollecting else { return .failure(TerminalError.busy.localizedDescription) }
        guard amountCents > 0 else { return .failure("Amount must be greater than zero.") }
        guard let api else { return .failure(TerminalError.notConfigured.localizedDescription) }
        isCollecting = true
        defer {
            isCollecting = false
            collectCancelable = nil
        }

        let kind = ReaderKind.forPayment(requested: requested, connected: connectedKind, preferred: preferredKind)
        do {
            switch kind {
            case .tapToPay:
                try await prepare()
            case .bluetooth:
                guard connectedKind == .bluetooth else { throw TerminalError.noBluetoothReader }
            }

            statusMessage = "Creating payment…"
            struct IntentRequest: Encodable, Sendable {
                let amount: Int
                let currency: String
                let order_id: String?
            }
            struct IntentResponse: Decodable {
                let id: String
                let client_secret: String
            }
            let created: IntentResponse = try await api.post(
                "/api/v1/payments/terminal/payment-intent",
                body: IntentRequest(amount: amountCents, currency: currency.lowercased(), order_id: orderId)
            )

            let intent = try await retrieve(clientSecret: created.client_secret)
            statusMessage = kind == .tapToPay ? "Hold card near the top of the iPhone" : "Insert, tap or swipe card"
            let collected = try await collect(intent)
            statusMessage = "Processing…"
            let confirmed = try await confirm(collected)
            statusMessage = "Payment approved"

            let card = confirmed.charges.first?.paymentMethodDetails?.cardPresent
            return PaymentResult(
                paymentIntentId: confirmed.stripeId ?? created.id,
                last4: card?.last4,
                brand: card.map { Terminal.stringFromCardBrand($0.brand) },
                error: nil,
                canceled: false
            )
        } catch {
            statusMessage = nil
            let nsError = error as NSError
            let canceled = nsError.domain == "com.stripe-terminal" && nsError.code == 2020 // SCPErrorCanceled
            return .failure(canceled ? "Payment canceled." : error.localizedDescription, canceled: canceled)
        }
    }

    func cancelCollect() {
        guard let collectCancelable, !collectCancelable.completed else { return }
        collectCancelable.cancel { [weak self] error in
            Task { @MainActor in
                self?.statusMessage = error == nil ? "Canceled" : "Couldn't cancel: \(error!.localizedDescription)"
            }
        }
    }

    private func retrieve(clientSecret: String) async throws -> PaymentIntent {
        try await withCheckedThrowingContinuation { continuation in
            Terminal.shared.retrievePaymentIntent(clientSecret: clientSecret) { intent, error in
                if let intent { continuation.resume(returning: intent) } else {
                    continuation.resume(throwing: error ?? TerminalError.sdk("Couldn't load the payment."))
                }
            }
        }
    }

    private func collect(_ intent: PaymentIntent) async throws -> PaymentIntent {
        try await withCheckedThrowingContinuation { continuation in
            collectCancelable = Terminal.shared.collectPaymentMethod(intent) { collected, error in
                if let collected { continuation.resume(returning: collected) } else {
                    continuation.resume(throwing: error ?? TerminalError.sdk("Card read failed."))
                }
            }
        }
    }

    private func confirm(_ intent: PaymentIntent) async throws -> PaymentIntent {
        try await withCheckedThrowingContinuation { continuation in
            _ = Terminal.shared.confirmPaymentIntent(intent) { confirmed, error in
                if let confirmed { continuation.resume(returning: confirmed) } else {
                    continuation.resume(throwing: error ?? TerminalError.sdk("Payment was declined."))
                }
            }
        }
    }
}

// MARK: - DiscoveryDelegate

extension TerminalManager: DiscoveryDelegate {
    nonisolated func terminal(_: Terminal, didUpdateDiscoveredReaders readers: [Reader]) {
        let found = readers.map { reader in
            DiscoveredReader(
                id: reader.serialNumber,
                label: reader.label ?? reader.serialNumber,
                model: Terminal.stringFromDeviceType(reader.deviceType),
                batteryPercent: reader.batteryLevel.map { Int(($0.floatValue * 100).rounded()) },
                simulated: reader.simulated
            )
        }
        // Stripe calls discovery delegates on the main queue, so stay on the main actor
        // instead of handing the (non-Sendable) Reader objects across a Task boundary.
        MainActor.assumeIsolated {
            switch discoveryMode {
            case .tapToPay:
                guard let reader = readers.first, let continuation = tapToPayContinuation else { return }
                tapToPayContinuation = nil
                continuation.resume(returning: reader)
            case .bluetooth:
                bluetoothReaders = Dictionary(readers.map { ($0.serialNumber, $0) }, uniquingKeysWith: { first, _ in first })
                discoveredReaders = found
                if let serial = autoConnectSerial, bluetoothReaders[serial] != nil {
                    autoConnectSerial = nil
                    Task { _ = try? await self.connectBluetooth(serial: serial) }
                }
            case .none:
                break
            }
        }
    }
}

// MARK: - Reader delegates

extension TerminalManager: TapToPayReaderDelegate, MobileReaderDelegate {
    // Tap to Pay (built-in reader)

    nonisolated func tapToPayReader(
        _: Reader,
        didStartInstallingUpdate _: ReaderSoftwareUpdate,
        cancelable _: Cancelable?
    ) {
        Task { @MainActor in self.statusMessage = "Setting up Tap to Pay (first time only)…" }
    }

    nonisolated func tapToPayReader(_: Reader, didReportReaderSoftwareUpdateProgress progress: Float) {
        Task { @MainActor in self.statusMessage = "Setting up Tap to Pay… \(Int(progress * 100))%" }
    }

    nonisolated func tapToPayReader(
        _: Reader,
        didFinishInstallingUpdate _: ReaderSoftwareUpdate?,
        error: Error?
    ) {
        let message = error.map { "Setup failed: \($0.localizedDescription)" } ?? "Tap to Pay set up"
        Task { @MainActor in self.statusMessage = message }
    }

    nonisolated func tapToPayReader(_: Reader, didRequestReaderInput inputOptions: ReaderInputOptions) {
        let message = Terminal.stringFromReaderInputOptions(inputOptions)
        Task { @MainActor in self.statusMessage = message }
    }

    nonisolated func tapToPayReader(_: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {
        let message = Terminal.stringFromReaderDisplayMessage(displayMessage)
        Task { @MainActor in self.statusMessage = message }
    }

    // Bluetooth readers

    nonisolated func reader(_: Reader, didReportAvailableUpdate _: ReaderSoftwareUpdate) {
        Task { @MainActor in self.updateAvailable = true }
    }

    nonisolated func reader(_: Reader, didStartInstallingUpdate _: ReaderSoftwareUpdate, cancelable _: Cancelable?) {
        Task { @MainActor in self.statusMessage = "Updating reader software… keep the reader nearby." }
    }

    nonisolated func reader(_: Reader, didReportReaderSoftwareUpdateProgress progress: Float) {
        Task { @MainActor in self.statusMessage = "Updating reader… \(Int(progress * 100))%" }
    }

    nonisolated func reader(_: Reader, didFinishInstallingUpdate _: ReaderSoftwareUpdate?, error: Error?) {
        let message = error.map { "Reader update failed: \($0.localizedDescription)" } ?? "Reader is up to date"
        Task { @MainActor in
            self.statusMessage = message
            if error == nil { self.updateAvailable = false }
        }
    }

    nonisolated func reader(_: Reader, didRequestReaderInput inputOptions: ReaderInputOptions) {
        let message = Terminal.stringFromReaderInputOptions(inputOptions)
        Task { @MainActor in self.statusMessage = message }
    }

    nonisolated func reader(_: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {
        let message = Terminal.stringFromReaderDisplayMessage(displayMessage)
        Task { @MainActor in self.statusMessage = message }
    }

    nonisolated func reader(_: Reader, didReportBatteryLevel batteryLevel: Float, status _: BatteryStatus, isCharging _: Bool) {
        let percent = Int((batteryLevel * 100).rounded())
        Task { @MainActor in self.batteryPercent = percent }
    }

    nonisolated func readerDidReportLowBatteryWarning(_: Reader) {
        Task { @MainActor in self.statusMessage = "Card reader battery is low — charge it soon." }
    }

    // Both

    nonisolated func reader(_: Reader, didDisconnect _: DisconnectReason) {
        Task { @MainActor in
            let kind = self.connectedKind
            self.connectedReader = nil
            self.connectedKind = nil
            self.batteryPercent = nil
            self.statusMessage = kind == .bluetooth ? "Card reader disconnected" : "Tap to Pay disconnected"
        }
    }
}

// MARK: - Connection tokens

/// Fetches Stripe connection tokens from the TieDown API with the current (fresh) access token.
final class TerminalTokenProvider: NSObject, ConnectionTokenProvider, @unchecked Sendable {
    /// Written once on the main actor before the SDK is initialised.
    var api: APIClient?

    func fetchConnectionToken(_ completion: @escaping ConnectionTokenCompletionBlock) {
        guard let api else {
            completion(nil, TerminalError.notConfigured)
            return
        }
        struct TokenResponse: Decodable { let secret: String }
        // The SDK's completion block isn't annotated Sendable; it is safe to call from any thread.
        let reply = UncheckedCompletion(call: completion)
        Task {
            do {
                let response: TokenResponse = try await api.post("/api/v1/payments/terminal/connection-token")
                reply.call(response.secret, nil)
            } catch {
                reply.call(nil, error)
            }
        }
    }

    private struct UncheckedCompletion: @unchecked Sendable {
        let call: ConnectionTokenCompletionBlock
    }
}

// MARK: - Location permission

/// Tap to Pay requires location authorisation before discovery/connection.
@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Bool, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func request() async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        case .denied, .restricted: return false
        default: break
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined, let continuation = self.continuation else { return }
            self.continuation = nil
            continuation.resume(returning: status == .authorizedAlways || status == .authorizedWhenInUse)
        }
    }
}
