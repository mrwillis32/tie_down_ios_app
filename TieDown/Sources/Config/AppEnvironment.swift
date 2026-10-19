import Foundation
import os

/// Deployment environment, selected at build time via the `TD_ENVIRONMENT` build setting
/// (Debug → dev, Staging → staging, Release → production) and read from Info.plist.
///
/// Non-production builds can switch servers at runtime (login screen › Server), and the
/// choice is remembered across launches. Debug builds also accept the launch environment
/// variable `TD_ENVIRONMENT=local|dev|staging|production` (Xcode: Scheme › Run › Arguments),
/// which is remembered the same way.
enum AppEnvironment: String, Sendable, CaseIterable, Identifiable {
    case local
    case dev
    case staging
    case production

    var id: String { rawValue }

    private static let overrideKey = "TDEnvironmentOverride"

    /// The environment baked into this build (Info.plist `TDEnvironment`).
    static let buildDefault: AppEnvironment = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "TDEnvironment") as? String
        let env = raw.flatMap(AppEnvironment.init(rawValue:)) ?? .production
        return env == .local ? .dev : env
    }()

    /// Release (App Store) builds are locked to production; everything else may switch.
    static let canSwitch: Bool = buildDefault != .production || isDebugBuild

    private static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    private static let selected = OSAllocatedUnfairLock<AppEnvironment>(initialState: initialSelection())

    private static func initialSelection() -> AppEnvironment {
        guard canSwitch else { return buildDefault }
        #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["TD_ENVIRONMENT"],
               let env = AppEnvironment(rawValue: raw)
            {
                UserDefaults.standard.set(env.rawValue, forKey: overrideKey)
                return env
            }
        #endif
        if let raw = UserDefaults.standard.string(forKey: overrideKey),
           let env = AppEnvironment(rawValue: raw)
        {
            return env
        }
        return buildDefault
    }

    /// The environment every request uses right now.
    static var current: AppEnvironment { selected.withLock { $0 } }

    /// Switch servers (non-production builds only). Call while signed out.
    static func select(_ env: AppEnvironment) {
        guard canSwitch else { return }
        selected.withLock { $0 = env }
        UserDefaults.standard.set(env.rawValue, forKey: overrideKey)
    }

    var displayName: String {
        switch self {
        case .local: "Local (this Mac)"
        case .dev: "Dev"
        case .staging: "Staging"
        case .production: "Production"
        }
    }

    /// Local dev-server ports — keep in sync with `LOCALHOST` in apps/app/src/config/localhost.ts.
    private enum LocalPort {
        static let app = 3001
        static let api = 8788
    }

    /// Host serving the React Router web app (screens shown inside the app).
    var appHost: String {
        switch self {
        case .local: "localhost"
        case .dev: "app-dev.tiedown.us"
        case .staging: "app-staging.tiedown.us"
        case .production: "app.tiedown.us"
        }
    }

    /// Host serving the Hono API (`/api/v1/...`).
    var apiHost: String {
        switch self {
        case .local: "localhost"
        case .dev: "api-dev.tiedown.us"
        case .staging: "api-staging.tiedown.us"
        case .production: "api.tiedown.us"
        }
    }

    var usesHTTPS: Bool { self != .local }

    var appBaseURL: URL {
        self == .local ? URL(string: "http://localhost:\(LocalPort.app)")! : URL(string: "https://\(appHost)")!
    }

    var apiBaseURL: URL {
        self == .local ? URL(string: "http://localhost:\(LocalPort.api)")! : URL(string: "https://\(apiHost)")!
    }

    /// Name of the session cookie the web app reads (see apps/app/src/lib/session-cookie.server.ts).
    static let sessionCookieName = "tiedown_session"

    /// True for the TieDown app host itself (exact match, never a look-alike suffix).
    func isAppHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == appHost
    }

    /// True for any first-party TieDown host (`tiedown.us` or a real subdomain of it).
    static func isFirstPartyHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "tiedown.us" || host.hasSuffix(".tiedown.us")
    }
}
