import Foundation
import LocalAuthentication

/// Optional Face ID / Touch ID / passcode lock shown when the app returns from the background.
@MainActor
final class BiometricLock: ObservableObject {
    @Published private(set) var isLocked = false
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// Re-lock only if the app was in the background at least this long.
    private static let graceInterval: TimeInterval = 30
    private static let enabledKey = "biometricLockEnabled"
    private var backgroundedAt: Date?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func lockOnLaunchIfEnabled() {
        if isEnabled { isLocked = true }
    }

    func didEnterBackground() {
        backgroundedAt = Date()
    }

    func willEnterForeground() {
        guard isEnabled, let backgroundedAt else { return }
        if Date().timeIntervalSince(backgroundedAt) >= Self.graceInterval {
            isLocked = true
        }
        self.backgroundedAt = nil
    }

    func unlock() async {
        guard isLocked else { return }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock TieDown")
            if ok { isLocked = false }
        } catch {
            // Stay locked; the lock screen offers another try or sign out.
        }
    }

    /// Verifies the user can authenticate before turning the lock on.
    func enable() async -> Bool {
        let context = LAContext()
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Turn on \(biometryName) for TieDown")
            if ok { isEnabled = true }
            return ok
        } catch {
            return false
        }
    }

    func reset() {
        isLocked = false
        backgroundedAt = nil
    }
}
