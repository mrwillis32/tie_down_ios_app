import Foundation
import Network

/// Publishes connectivity so the UI can show an offline banner and retry when the network returns.
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "us.tiedown.network-monitor"))
    }

    deinit {
        monitor.cancel()
    }
}
