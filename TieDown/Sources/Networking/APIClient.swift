import Foundation

enum APIError: LocalizedError, Sendable {
    case offline
    /// The server's hostname didn't resolve or it refused the connection.
    case unreachable(host: String)
    case unauthorized
    case server(status: Int, message: String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .offline: "You're offline. Check your connection and try again."
        case let .unreachable(host):
            "Can't reach the TieDown server at \(host). Check your connection, or choose a different server below."
        case .unauthorized: "Your session has expired. Please sign in again."
        case let .server(_, message): message
        case let .decoding(detail): "Unexpected response from server (\(detail))."
        case let .transport(detail): detail
        }
    }
}

/// `{ success, data, error }` envelope used by every `/api/v1` endpoint.
private struct Envelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: String?

    enum CodingKeys: String, CodingKey { case success, data, error }
    private struct NestedError: Decodable { let message: String? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? false
        data = try container.decodeIfPresent(T.self, forKey: .data)
        if let text = try? container.decodeIfPresent(String.self, forKey: .error) {
            error = text
        } else if let nested = try? container.decodeIfPresent(NestedError.self, forKey: .error) {
            error = nested.message
        } else {
            error = nil
        }
    }
}

struct EmptyResponse: Decodable, Sendable {}

/// Thin JSON client for the TieDown API. The backend is unchanged; this only speaks its existing contract.
struct APIClient: Sendable {
    typealias TokenProvider = @Sendable () async throws -> String?

    /// Fixed base URL, or nil to follow `AppEnvironment.current` at request time.
    private let fixedBaseURL: URL?
    let tokenProvider: TokenProvider?

    var baseURL: URL { fixedBaseURL ?? AppEnvironment.current.apiBaseURL }

    init(baseURL: URL? = nil, tokenProvider: TokenProvider? = nil) {
        fixedBaseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        try await send("GET", path, body: Optional<[String: String]>.none, as: type)
    }

    func post<T: Decodable>(
        _ path: String,
        body: (some Encodable & Sendable)? = Optional<[String: String]>.none,
        as type: T.Type = T.self
    ) async throws -> T {
        try await send("POST", path, body: body, as: type)
    }

    func send<T: Decodable>(
        _ method: String,
        _ path: String,
        body: (some Encodable & Sendable)?,
        as _: T.Type
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.transport("Invalid URL: \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UserAgent.native, forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        if let tokenProvider, let token = try await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet
            || error.code == .networkConnectionLost
        {
            throw APIError.offline
        } catch let error as URLError where error.code == .cannotFindHost
            || error.code == .cannotConnectToHost
            || error.code == .dnsLookupFailed
            || error.code == .timedOut
        {
            throw APIError.unreachable(host: url.host ?? baseURL.absoluteString)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw APIError.unauthorized }

        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            if !(200 ..< 300).contains(status) {
                throw APIError.server(status: status, message: "Request failed (HTTP \(status)).")
            }
            throw APIError.decoding(String(describing: error))
        }

        guard (200 ..< 300).contains(status), envelope.success else {
            throw APIError.server(status: status, message: envelope.error ?? "Request failed (HTTP \(status)).")
        }
        if let value = envelope.data { return value }
        if let empty = EmptyResponse() as? T { return empty }
        throw APIError.decoding("missing data")
    }
}

enum UserAgent {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Appended to WKWebView's user agent so the web app can detect the native shell during SSR.
    static var webSuffix: String { "TieDowniOS/\(appVersion)" }
    static var native: String { "TieDowniOS/\(appVersion) (iOS)" }
}
