import CoreLocation
import Foundation
@preconcurrency import StripeTerminal

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

enum TerminalError: LocalizedError {
    case busy
    case notConfigured
    case locationDenied
    case noReaderFound
    case missingLocation
    case sdk(String)

    var errorDescription: String? {
        switch self {
        case .busy: "A payment is already in progress."
        case .notConfigured: "Tap to Pay isn't set up yet. Please sign in again."
        case .locationDenied: "Tap to Pay needs location access. Turn it on in Settings › TieDown › Location."
        case .noReaderFound: "This iPhone doesn't support Tap to Pay (iPhone XS or later on iOS 16.7+ required)."
        case .missingLocation: "No Stripe Terminal location is configured for this business."
        case let .sdk(message): message
        }
    }
}

/// Stripe Terminal (Tap to Pay on iPhone) lifecycle, written against StripeTerminal 5.8.x:
/// SDK init, location permission, one-at-a-time discovery/connection, and payment collection.
@MainActor
final class TerminalManager: NSObject, ObservableObject {
    @Published private(set) var statusMessage: String?
    @Published private(set) var connectedReader: Reader?
    @Published private(set) var isCollecting = false
    @Published private(set) var isConnecting = false

    private var api: APIClient?
    private let tokenProvider = TerminalTokenProvider()
    private let locationPermission = LocationPermission()

    private var discoverCancelable: Cancelable?
    private var collectCancelable: Cancelable?
    private var connectTask: Task<Reader, Error>?
    private var discoveryContinuation: CheckedContinuation<Reader, Error>?

    /// Called once at launch/sign-in. Initialising early means `Terminal.shared` is always safe to touch.
    func configure(api: APIClient) {
        self.api = api
        tokenProvider.api = api
        if !Terminal.isInitialized() {
            Terminal.initWithTokenProvider(tokenProvider)
        }
    }

    // MARK: - Connection

    /// Connects to the built-in Tap to Pay reader. Safe to call repeatedly; concurrent callers share one attempt.
    @discardableResult
    func prepare() async throws -> Reader {
        if let reader = connectedReader { return reader }
        if let connectTask { return try await connectTask.value }
        guard let api else { throw TerminalError.notConfigured }

        let task = Task<Reader, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.connect(api: api)
        }
        connectTask = task
        isConnecting = true
        defer {
            connectTask = nil
            isConnecting = false
        }
        return try await task.value
    }

    private func connect(api: APIClient) async throws -> Reader {
        guard await locationPermission.request() else { throw TerminalError.locationDenied }

        statusMessage = "Preparing Tap to Pay…"
        struct LocationResponse: Decodable { let locationId: String }
        let location: LocationResponse = try await api.get("/api/v1/payments/terminal/location")
        guard !location.locationId.isEmpty else { throw TerminalError.missingLocation }

        let reader = try await discoverReader()

        statusMessage = "Connecting…"
        let connectionConfig = try TapToPayConnectionConfigurationBuilder(
            delegate: self,
            locationId: location.locationId
        )
        .setMerchantDisplayName("TieDown")
        .setTosAcceptancePermitted(true)
        .setAutoReconnectOnUnexpectedDisconnect(true)
        .build()

        let connected: Reader = try await withCheckedThrowingContinuation { continuation in
            Terminal.shared.connectReader(reader, connectionConfig: connectionConfig) { reader, error in
                if let reader {
                    continuation.resume(returning: reader)
                } else {
                    continuation.resume(throwing: error ?? TerminalError.noReaderFound)
                }
            }
        }
        connectedReader = connected
        statusMessage = "Tap to Pay ready"
        return connected
    }

    private func discoverReader() async throws -> Reader {
        let builder = TapToPayDiscoveryConfigurationBuilder()
        #if targetEnvironment(simulator)
            builder.setSimulated(true)
        #endif
        let config = try builder.build()
        statusMessage = "Starting Tap to Pay…"

        return try await withCheckedThrowingContinuation { continuation in
            discoveryContinuation = continuation
            discoverCancelable = Terminal.shared.discoverReaders(config, delegate: self) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.discoverCancelable = nil
                    // Discovery ends either because we found a reader (continuation already resumed)
                    // or with an error.
                    if let pending = self.discoveryContinuation {
                        self.discoveryContinuation = nil
                        pending.resume(throwing: error ?? TerminalError.noReaderFound)
                    }
                }
            }
        }
    }

    func disconnect() async {
        guard connectedReader != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Terminal.shared.disconnectReader { _ in continuation.resume() }
        }
        connectedReader = nil
        statusMessage = nil
    }

    // MARK: - Payments

    /// Creates a PaymentIntent on the TieDown API, collects the card via Tap to Pay, and confirms it.
    func collectPayment(amountCents: Int, currency: String, orderId: String?) async -> PaymentResult {
        guard !isCollecting else { return .failure(TerminalError.busy.localizedDescription) }
        guard amountCents > 0 else { return .failure("Amount must be greater than zero.") }
        guard let api else { return .failure(TerminalError.notConfigured.localizedDescription) }
        isCollecting = true
        defer {
            isCollecting = false
            collectCancelable = nil
        }

        do {
            try await prepare()

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
            statusMessage = "Hold card near the top of the iPhone"
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
        guard let reader = readers.first else { return }
        Task { @MainActor in
            guard let continuation = self.discoveryContinuation else { return }
            self.discoveryContinuation = nil
            continuation.resume(returning: reader)
        }
    }
}

// MARK: - TapToPayReaderDelegate

extension TerminalManager: TapToPayReaderDelegate {
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

    nonisolated func reader(_: Reader, didDisconnect _: DisconnectReason) {
        Task { @MainActor in
            self.connectedReader = nil
            self.statusMessage = "Tap to Pay disconnected"
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
