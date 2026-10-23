import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MainActor.assumeIsolated {
            PushManager.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[push] APNs registration failed: \(error.localizedDescription)")
    }
}

@main
struct TieDownApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.auth)
                .environmentObject(model.lock)
                .environmentObject(model.network)
                .environmentObject(model.terminal)
                .environmentObject(model.printers)
                .task { await model.start() }
                .onOpenURL { model.handle(url: $0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { model.handle(url: url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.lock.didEnterBackground()
            case .active:
                model.lock.willEnterForeground()
                Task { _ = try? await model.auth.validAccessToken() }
            default:
                break
            }
        }
    }
}
