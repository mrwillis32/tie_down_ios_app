import Foundation
import UIKit
import UserNotifications

/// Push notifications: permission, APNs registration, device-token upload, and tap routing.
///
/// Backend contract (apps/api/src/routes/notifications):
///   POST   /api/v1/notifications/devices        { token, platform: "ios", environment, bundle_id, app_version }
///   DELETE /api/v1/notifications/devices/:token
/// Notification payloads may include `"path": "/pos/orders/123"` to open that screen when tapped.
@MainActor
final class PushManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushManager()

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var deviceToken: String?
    var api: APIClient?
    var onOpenPath: ((String) -> Void)?

    private var apsEnvironment: String {
        #if DEBUG
            "sandbox"
        #else
            "production"
        #endif
    }

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks for permission (once) and registers with APNs.
    func requestAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        }
        await refreshAuthorization()
        if authorization == .authorized || authorization == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func didRegister(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        Task { await upload(token: token) }
    }

    func unregister() async {
        guard let token = deviceToken, let api else { return }
        _ = try? await api.send("DELETE", "/api/v1/notifications/devices/\(token)", body: Optional<[String: String]>.none, as: EmptyResponse.self)
    }

    private func upload(token: String) async {
        guard let api else { return }
        struct Registration: Encodable, Sendable {
            let token: String
            let platform: String
            let environment: String
            let bundle_id: String
            let app_version: String
        }
        let body = Registration(
            token: token,
            platform: "ios",
            environment: apsEnvironment,
            bundle_id: Bundle.main.bundleIdentifier ?? "us.tiedown.app",
            app_version: UserAgent.appVersion
        )
        _ = try? await api.post("/api/v1/notifications/devices", body: body, as: EmptyResponse.self)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let path = response.notification.request.content.userInfo["path"] as? String
        guard let path, path.hasPrefix("/") else { return }
        await MainActor.run { self.onOpenPath?(path) }
    }
}
