import CryptoKit
import Foundation

public enum OAuth2Grant: String, Codable, CaseIterable, Sendable {
    case clientCredentials, authorizationCode, password

    public var label: String {
        switch self {
        case .clientCredentials: return "Client credentials"
        case .authorizationCode: return "Authorization code"
        case .password: return "Password"
        }
    }

    /// Whether a token can be fetched without the user signing in through a browser.
    public var isAutomatic: Bool {
        self != .authorizationCode
    }
}

/// The settings for getting an OAuth 2 access token. The token itself is kept in the
/// secret store under `id`, never in a workspace file.
public struct OAuth2Config: Codable, Hashable, Sendable {
    public var id: UUID
    public var grant: OAuth2Grant
    public var tokenURL: String
    /// The sign-in page, for the authorization code grant.
    public var authURL: String
    public var clientID: String
    public var clientSecret: String
    public var scope: String
    public var username: String
    public var password: String
    /// Sends the client id and secret in the form body instead of a Basic auth header.
    public var clientAuthInBody: Bool
    public var usePKCE: Bool
    /// The word before the token in the Authorization header. Almost always "Bearer".
    public var headerPrefix: String

    public init(
        id: UUID = UUID(), grant: OAuth2Grant = .clientCredentials, tokenURL: String = "", authURL: String = "",
        clientID: String = "", clientSecret: String = "", scope: String = "", username: String = "", password: String = "",
        clientAuthInBody: Bool = false, usePKCE: Bool = true, headerPrefix: String = "Bearer"
    ) {
        self.id = id
        self.grant = grant
        self.tokenURL = tokenURL
        self.authURL = authURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scope = scope
        self.username = username
        self.password = password
        self.clientAuthInBody = clientAuthInBody
        self.usePKCE = usePKCE
        self.headerPrefix = headerPrefix
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        grant = try c.decodeIfPresent(OAuth2Grant.self, forKey: .grant) ?? .clientCredentials
        tokenURL = try c.decodeIfPresent(String.self, forKey: .tokenURL) ?? ""
        authURL = try c.decodeIfPresent(String.self, forKey: .authURL) ?? ""
        clientID = try c.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        clientSecret = try c.decodeIfPresent(String.self, forKey: .clientSecret) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        clientAuthInBody = try c.decodeIfPresent(Bool.self, forKey: .clientAuthInBody) ?? false
        usePKCE = try c.decodeIfPresent(Bool.self, forKey: .usePKCE) ?? true
        headerPrefix = try c.decodeIfPresent(String.self, forKey: .headerPrefix) ?? "Bearer"
    }
}

public struct OAuth2Token: Codable, Equatable, Sendable {
    public var accessToken: String
    public var tokenType: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scope: String?

    public init(accessToken: String, tokenType: String = "Bearer", refreshToken: String? = nil, expiresAt: Date? = nil, scope: String? = nil) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    /// Treats a token as expired slightly early, so it does not lapse mid-request.
    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(-30) <= now
    }
}

public enum OAuth2Error: Error, LocalizedError, Equatable {
    case missing(String)
    case server(String)
    case noToken
    case stateMismatch
    case needsSignIn

    public var errorDescription: String? {
        switch self {
        case .missing(let field): return "OAuth 2 needs \(field)."
        case .server(let message): return "The token server refused the request: \(message)"
        case .noToken: return "The token server's reply had no access token."
        case .stateMismatch: return "The sign-in reply did not match this request, so it was ignored."
        case .needsSignIn: return "There is no OAuth 2 token yet. Use Get Token in the request's Auth tab to sign in."
        }
    }
}

public enum OAuth2 {
    /// The address the sign-in page returns to. It uses the app's own URL scheme.
    public static let redirectURI = "apiplayground://oauth/callback"

    private static func form(_ fields: [(String, String)]) -> Data {
        Data(fields.filter { !$0.1.isEmpty }
            .map { "\(RequestBuilder.encodeForm($0.0))=\(RequestBuilder.encodeForm($0.1))" }
            .joined(separator: "&").utf8)
    }

    private static func request(_ config: OAuth2Config, resolver: VariableResolver, fields: [(String, String)]) throws -> PreparedRequest {
        func resolve(_ text: String) -> String { resolver.resolve(text).string }
        let url = resolve(config.tokenURL).trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { throw OAuth2Error.missing("a token URL") }
        let clientID = resolve(config.clientID)
        let clientSecret = resolve(config.clientSecret)

        var fields = fields
        var headers = [
            HTTPHeader(name: "Content-Type", value: "application/x-www-form-urlencoded"),
            HTTPHeader(name: "Accept", value: "application/json"),
            HTTPHeader(name: "User-Agent", value: RequestBuilder.userAgent),
        ]
        if config.clientAuthInBody || clientSecret.isEmpty {
            fields.append(("client_id", clientID))
            fields.append(("client_secret", clientSecret))
        } else {
            let credentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
            headers.append(HTTPHeader(name: "Authorization", value: "Basic \(credentials)"))
        }
        return PreparedRequest(method: "POST", url: url.contains("://") ? url : "https://" + url, headers: headers, body: form(fields))
    }

    /// The request that exchanges credentials, or a sign-in code, for a token.
    public static func tokenRequest(
        _ config: OAuth2Config, resolver: VariableResolver, code: String? = nil, codeVerifier: String? = nil
    ) throws -> PreparedRequest {
        func resolve(_ text: String) -> String { resolver.resolve(text).string }
        switch config.grant {
        case .clientCredentials:
            return try request(config, resolver: resolver, fields: [
                ("grant_type", "client_credentials"), ("scope", resolve(config.scope)),
            ])
        case .password:
            return try request(config, resolver: resolver, fields: [
                ("grant_type", "password"), ("username", resolve(config.username)),
                ("password", resolve(config.password)), ("scope", resolve(config.scope)),
            ])
        case .authorizationCode:
            guard let code else { throw OAuth2Error.needsSignIn }
            return try request(config, resolver: resolver, fields: [
                ("grant_type", "authorization_code"), ("code", code),
                ("redirect_uri", redirectURI), ("code_verifier", codeVerifier ?? ""),
            ])
        }
    }

    public static func refreshRequest(_ config: OAuth2Config, resolver: VariableResolver, refreshToken: String) throws -> PreparedRequest {
        try request(config, resolver: resolver, fields: [
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("scope", resolver.resolve(config.scope).string),
        ])
    }

    public static func parseToken(_ response: HTTPResponse, now: Date = Date()) throws -> OAuth2Token {
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        if let error = object["error"] as? String {
            let detail = object["error_description"] as? String
            throw OAuth2Error.server(detail.map { "\(error): \($0)" } ?? error)
        }
        guard (200..<300).contains(response.status) else {
            throw OAuth2Error.server("HTTP \(response.status) \(response.statusText)")
        }
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty else { throw OAuth2Error.noToken }
        // Some servers send expires_in as a string.
        let lifetime = (object["expires_in"] as? Double) ?? (object["expires_in"] as? String).flatMap(Double.init)
        return OAuth2Token(
            accessToken: accessToken,
            tokenType: object["token_type"] as? String ?? "Bearer",
            refreshToken: object["refresh_token"] as? String,
            expiresAt: lifetime.map { now.addingTimeInterval($0) },
            scope: object["scope"] as? String
        )
    }

    // MARK: Authorization code

    /// A random verifier and its SHA-256 challenge, for PKCE.
    public static func pkce() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let verifier = base64URL(Data(bytes))
        return (verifier, challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The sign-in page address to open in a browser.
    public static func authorizationURL(_ config: OAuth2Config, resolver: VariableResolver, state: String, codeChallenge: String?) throws -> URL {
        func resolve(_ text: String) -> String { resolver.resolve(text).string }
        let base = resolve(config.authURL).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { throw OAuth2Error.missing("an authorization URL") }
        var fields = [
            ("response_type", "code"), ("client_id", resolve(config.clientID)), ("redirect_uri", redirectURI),
            ("scope", resolve(config.scope)), ("state", state),
        ]
        if config.usePKCE, let codeChallenge {
            fields.append(("code_challenge", codeChallenge))
            fields.append(("code_challenge_method", "S256"))
        }
        let query = fields.filter { !$0.1.isEmpty }
            .map { "\(RequestBuilder.encodeQuery($0.0))=\(RequestBuilder.encodeQuery($0.1))" }
            .joined(separator: "&")
        guard let url = URL(string: base + (base.contains("?") ? "&" : "?") + query) else {
            throw OAuth2Error.missing("a valid authorization URL")
        }
        return url
    }

    /// Reads the sign-in code from the address the browser returned to.
    public static func code(fromCallback url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw OAuth2Error.server(value("error_description").map { "\(error): \($0)" } ?? error)
        }
        guard value("state") == expectedState else { throw OAuth2Error.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw OAuth2Error.noToken }
        return code
    }
}

/// Keeps OAuth 2 tokens in the secret store.
public struct OAuth2TokenStore: Sendable {
    public let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    private func key(_ id: UUID) -> String { "oauth2/\(id.uuidString)" }

    public func token(for id: UUID) -> OAuth2Token? {
        guard let json = secrets.get(key(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(OAuth2Token.self, from: Data(json.utf8))
    }

    public func save(_ token: OAuth2Token, for id: UUID) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(token), let json = String(data: data, encoding: .utf8) {
            secrets.set(json, for: key(id))
        }
    }

    public func clear(_ id: UUID) {
        secrets.delete(key(id))
    }
}
