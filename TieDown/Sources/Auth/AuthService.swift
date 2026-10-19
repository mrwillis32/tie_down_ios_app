import Foundation

/// User returned by `POST /api/v1/auth/login` (see apps/api/src/routes/auth/login.ts `AuthUser`).
struct AuthUser: Codable, Equatable, Sendable {
    let id: String
    let email: String
    let name: String
    let role: String
    let portal: String
    let organizationId: String?
    let organizationName: String?

    enum CodingKeys: String, CodingKey {
        case id, email, name, role, portal
        case organizationId = "organization_id"
        case organizationName = "organization_name"
    }

    var displayName: String { name.isEmpty ? email : name }
}

/// Which part of the web app this user lives in. Mirrors the API's `portal` values.
enum Portal: Sendable {
    case staff
    case customer
    case owner

    init(user: AuthUser) {
        switch user.portal.lowercased() {
        case "customer": self = .customer
        case "owner", "owners": self = .owner
        default: self = .staff
        }
    }
}

struct StoredSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var user: AuthUser

    var portal: Portal { Portal(user: user) }
}

private struct LoginRequest: Encodable, Sendable {
    let email: String
    let password: String
    let portal: String
}

private struct RefreshRequest: Encodable, Sendable {
    let refresh_token: String
}

private struct LoginResponse: Decodable, Sendable {
    let token: String
    let refresh_token: String?
    let expires_in: Double?
    let user: AuthUser?
}

/// Owns the signed-in session: native login, Keychain persistence, token refresh, and sign-out.
/// Every other component asks this service for a fresh access token instead of caching one.
@MainActor
final class AuthService: ObservableObject {
    enum State: Equatable {
        case loading
        case signedOut(message: String?)
        case signedIn(StoredSession)
    }

    @Published private(set) var state: State = .loading

    private static let keychainKey = "session.v1"
    /// Refresh this long before the access token expires.
    private static let refreshLeeway: TimeInterval = 120
    private let anonymousAPI = APIClient()
    private var refreshTask: Task<StoredSession, Error>?
    private var refreshTimer: Task<Void, Never>?

    var session: StoredSession? {
        if case let .signedIn(session) = state { return session }
        return nil
    }

    /// API client that authenticates with a fresh access token on every call.
    lazy var api: APIClient = APIClient { [weak self] in
        try await self?.validAccessToken()
    }

    // MARK: - Lifecycle

    func restore() async {
        guard let data = KeychainStore.data(for: Self.keychainKey),
              let saved = try? JSONDecoder().decode(StoredSession.self, from: data)
        else {
            state = .signedOut(message: nil)
            return
        }
        if saved.expiresAt.timeIntervalSinceNow > Self.refreshLeeway {
            apply(saved)
            return
        }
        guard saved.refreshToken != nil else {
            await clear(message: nil)
            return
        }
        do {
            state = .signedIn(saved)
            _ = try await refresh()
        } catch APIError.offline, APIError.unreachable {
            // Keep the saved session; screens will show the offline state and retry later.
            apply(saved)
        } catch {
            await clear(message: "Your session has expired. Please sign in again.")
        }
    }

    // MARK: - Sign in / out

    /// Mirrors the web login (apps/app/src/routes/login.tsx): try tenant, then customer, then owner portal.
    func signIn(email: String, password: String) async throws {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        var lastError: Error = APIError.server(status: 401, message: "Invalid email or password")
        for portal in ["tenant", "customer", "owner"] {
            do {
                let response: LoginResponse = try await anonymousAPI.post(
                    "/api/v1/auth/login",
                    body: LoginRequest(email: trimmed, password: password, portal: portal)
                )
                guard let user = response.user else { throw APIError.decoding("missing user") }
                let session = StoredSession(
                    accessToken: response.token,
                    refreshToken: response.refresh_token,
                    expiresAt: Date().addingTimeInterval(response.expires_in ?? 3600),
                    user: user
                )
                apply(session)
                return
            } catch APIError.offline {
                throw APIError.offline
            } catch let APIError.unreachable(host) {
                // No point trying the other portals: the server itself can't be reached.
                throw APIError.unreachable(host: host)
            } catch let APIError.server(status, _) where status == 429 {
                // Each sign-in may try three portals, so stop at the first rate-limit response.
                throw APIError.server(
                    status: 429,
                    message: "Too many sign-in attempts. Please wait a minute, then try again."
                )
            } catch let APIError.server(status, message) where status >= 500 {
                throw APIError.server(status: status, message: message)
            } catch {
                lastError = error
            }
        }
        if case APIError.unauthorized = lastError {
            throw APIError.server(status: 401, message: "Invalid email or password")
        }
        throw lastError
    }

    func signOut(message: String? = nil) async {
        if let token = session?.accessToken {
            // Best effort: revoke the token server-side so a copied token stops working.
            let revoke = APIClient { token }
            _ = try? await revoke.post("/api/v1/auth/logout", as: EmptyResponse.self)
        }
        await clear(message: message)
    }

    /// Called when the web app reports an expired session (e.g. it navigated to /login).
    func handleWebSessionExpired() async {
        guard session != nil else { return }
        do {
            _ = try await refresh()
        } catch {
            await clear(message: "Your session has expired. Please sign in again.")
        }
    }

    // MARK: - Tokens

    /// Returns an access token valid for at least `refreshLeeway` seconds, refreshing if needed.
    func validAccessToken() async throws -> String {
        guard let current = session else { throw APIError.unauthorized }
        if current.expiresAt.timeIntervalSinceNow > Self.refreshLeeway {
            return current.accessToken
        }
        return try await refresh().accessToken
    }

    /// Single-flight refresh: concurrent callers share one network request.
    @discardableResult
    func refresh() async throws -> StoredSession {
        if let refreshTask { return try await refreshTask.value }
        guard let current = session, let refreshToken = current.refreshToken else {
            throw APIError.unauthorized
        }
        let api = anonymousAPI
        let task = Task<StoredSession, Error> {
            let response: LoginResponse = try await api.post(
                "/api/v1/auth/refresh",
                body: RefreshRequest(refresh_token: refreshToken)
            )
            return StoredSession(
                accessToken: response.token,
                refreshToken: response.refresh_token ?? refreshToken,
                expiresAt: Date().addingTimeInterval(response.expires_in ?? 3600),
                user: response.user ?? current.user
            )
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let updated = try await task.value
            apply(updated)
            return updated
        } catch APIError.unauthorized {
            await clear(message: "Your session has expired. Please sign in again.")
            throw APIError.unauthorized
        } catch let APIError.server(status, _) where status == 401 || status == 403 {
            await clear(message: "Your session has expired. Please sign in again.")
            throw APIError.unauthorized
        }
    }

    // MARK: - Private

    private func apply(_ session: StoredSession) {
        if let data = try? JSONEncoder().encode(session) {
            KeychainStore.set(data, for: Self.keychainKey)
        }
        state = .signedIn(session)
        WebSession.shared.installSessionCookie(token: session.accessToken)
        scheduleRefresh(for: session)
    }

    private func clear(message: String?) async {
        refreshTimer?.cancel()
        refreshTimer = nil
        KeychainStore.delete(Self.keychainKey)
        await WebSession.shared.clearWebsiteData()
        state = .signedOut(message: message)
    }

    private func scheduleRefresh(for session: StoredSession) {
        refreshTimer?.cancel()
        guard session.refreshToken != nil else { return }
        let delay = max(session.expiresAt.timeIntervalSinceNow - Self.refreshLeeway - 60, 30)
        refreshTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            _ = try? await self?.refresh()
        }
    }
}
