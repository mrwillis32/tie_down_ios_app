import Combine
import Foundation
import SwiftUI

/// Composition root: owns the long-lived services and the per-tab web screens.
@MainActor
final class AppModel: ObservableObject {
    let auth = AuthService()
    let terminal = TerminalManager()
    let lock = BiometricLock()
    let network = NetworkMonitor()
    let push = PushManager.shared

    @Published var selectedTabId: String = "home"
    @Published private(set) var tabs: [AppTab] = []
    @Published private(set) var moreItems: [AppTab] = []
    @Published var showFaceIDOffer = false

    private var screens: [String: WebScreenModel] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var lastPortal: Portal?
    private var pendingPath: String?

    init() {
        let api = auth.api
        terminal.configure(api: api)
        push.api = api
        push.onOpenPath = { [weak self] path in self?.open(path: path) }

        auth.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.authStateChanged(state) }
            .store(in: &cancellables)

        // Reload a failed screen automatically when connectivity returns.
        network.$isOnline
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.retryFailedScreens() }
            .store(in: &cancellables)

        // Forward nested service changes so SwiftUI views observing AppModel refresh.
        for publisher in [auth.objectWillChange, lock.objectWillChange, network.objectWillChange, terminal.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
    }

    func start() async {
        lock.lockOnLaunchIfEnabled()
        await auth.restore()
    }

    // MARK: - Screens

    func screen(for tab: AppTab) -> WebScreenModel {
        if let existing = screens[tab.id] { return existing }
        let model = WebScreenModel(rootPath: tab.path, auth: auth, terminal: terminal)
        screens[tab.id] = model
        return model
    }

    /// Opens a web path (deep link / notification): picks the tab whose root matches, else Home.
    func open(path: String) {
        guard auth.session != nil else {
            pendingPath = path
            return
        }
        // Match on the path alone so "/reservations?view=calendar" still picks the Reservations tab.
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let match = tabs
            .filter { $0.path != "/" && (route == $0.path || route.hasPrefix($0.path + "/")) }
            .max { $0.path.count < $1.path.count }
            ?? tabs.first
        guard let tab = match else { return }
        selectedTabId = tab.id
        screen(for: tab).load(path: path)
    }

    /// Handles `tiedown://open?path=/pos/orders/123` and `https://app.tiedown.us/...` links.
    func handle(url: URL) {
        if url.scheme == "tiedown" {
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "path" }?.value
            if let path, path.hasPrefix("/") { open(path: path) }
        } else if AppEnvironment.current.isAppHost(url.host) {
            var path = url.path.isEmpty ? "/" : url.path
            if let query = url.query { path += "?\(query)" }
            open(path: path)
        }
    }

    private func retryFailedScreens() {
        for screen in screens.values where screen.loadError != nil {
            screen.reload()
        }
    }

    // MARK: - Session changes

    private func authStateChanged(_ state: AuthService.State) {
        switch state {
        case .loading:
            break
        case let .signedIn(session):
            let portal = session.portal
            if portal != lastPortal {
                screens.removeAll()
                tabs = AppTab.primary(for: portal)
                moreItems = AppTab.more(for: portal)
                selectedTabId = tabs.first?.id ?? "home"
                lastPortal = portal
                onFirstSignIn()
            }
            if let pendingPath {
                self.pendingPath = nil
                open(path: pendingPath)
            }
        case .signedOut:
            screens.removeAll()
            tabs = []
            moreItems = []
            lastPortal = nil
            lock.reset()
            Task { await terminal.disconnect() }
        }
    }

    private func onFirstSignIn() {
        Task {
            await push.requestAndRegister()
            if lock.isAvailable, !lock.isEnabled,
               !UserDefaults.standard.bool(forKey: "faceIDOfferShown")
            {
                UserDefaults.standard.set(true, forKey: "faceIDOfferShown")
                showFaceIDOffer = true
            }
        }
    }

    func signOut() async {
        await push.unregister()
        await auth.signOut()
    }
}
