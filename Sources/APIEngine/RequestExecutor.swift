import Foundation

/// Everything that happened when one request was run.
public struct RequestRunResult: Equatable, Sendable {
    public var requestID: UUID
    public var prepared: PreparedRequest?
    public var response: HTTPResponse?
    /// Why the request did not complete: a script error before sending, a bad URL, or a network failure.
    public var error: String?
    /// Results from assertions and from scripts' `pm.test` calls, in the order they ran.
    public var tests: [TestResult] = []
    /// A script error after the response arrived. The response is still shown.
    public var scriptError: String?
    public var logs: [String] = []
    /// True when a pre-request script chose to skip the request.
    public var skipped = false

    public init(requestID: UUID) {
        self.requestID = requestID
    }

    public var failedTests: [TestResult] {
        tests.filter { !$0.passed }
    }

    /// True when the request completed and nothing failed.
    public var passed: Bool {
        error == nil && scriptError == nil && failedTests.isEmpty
    }
}

/// Runs one request the way Postman does: pre-request scripts, send, then extractions,
/// assertions and test scripts.
public struct RequestExecutor: Sendable {
    public var client: HTTPClient
    public var options: HTTPOptions
    /// Where OAuth 2 tokens are kept. Without it, requests that use OAuth 2 cannot run.
    public var tokens: OAuth2TokenStore?
    /// Client certificates to present, by host. Their passphrases are read from `secrets`.
    public var clientCertificates: [ClientCertificateRule] = []
    public var secrets: (any SecretStore)?
    /// Sends requests through a proxy when set and enabled. Its password is read from `secrets`.
    public var proxy: ProxySettings?
    /// Supplies what a gRPC server offers, such as from a saved copy. When nil, or for a
    /// server it throws for, the executor asks the server itself by reflection.
    public var grpcSchema: (@Sendable (GRPCTarget, [HTTPHeader]) async throws -> ProtoSchema)?

    /// The options for a request to this address: the usual ones, plus the host's client certificate.
    public func options(for url: String) -> HTTPOptions {
        var options = options
        if let rule = clientCertificates.rule(for: url) {
            options.clientCertificate = ClientCertificate(
                certificatePath: rule.certificatePath,
                keyPath: rule.keyPath.isEmpty ? nil : rule.keyPath,
                passphrase: secrets?.get(rule.passphraseKey)
            )
        }
        if let proxy, proxy.applies(to: url) {
            var proxy = proxy
            if !proxy.username.isEmpty { proxy.password = secrets?.get(ProxySettings.passwordKey) }
            options.proxy = proxy
        }
        return options
    }

    public init(client: HTTPClient = HTTPClient(), options: HTTPOptions = HTTPOptions(), tokens: OAuth2TokenStore? = nil) {
        self.client = client
        self.options = options
        self.tokens = tokens
    }

    /// Returns a usable access token: the stored one, a refreshed one, or a newly fetched one.
    public func accessToken(for config: OAuth2Config, resolver: VariableResolver) async throws -> OAuth2Token {
        guard let tokens else { throw OAuth2Error.needsSignIn }
        let stored = tokens.token(for: config.id)
        if let stored, !stored.isExpired() { return stored }

        if let refreshToken = stored?.refreshToken {
            let request = try OAuth2.refreshRequest(config, resolver: resolver, refreshToken: refreshToken)
            if let response = try? await client.send(request, options: options(for: request.url)), var fresh = try? OAuth2.parseToken(response) {
                // A server may omit the refresh token when it has not changed.
                fresh.refreshToken = fresh.refreshToken ?? refreshToken
                tokens.save(fresh, for: config.id)
                return fresh
            }
        }
        guard config.grant.isAutomatic else { throw OAuth2Error.needsSignIn }
        let tokenRequest = try OAuth2.tokenRequest(config, resolver: resolver)
        let response = try await client.send(tokenRequest, options: options(for: tokenRequest.url))
        let token = try OAuth2.parseToken(response)
        tokens.save(token, for: config.id)
        return token
    }

    /// - Parameter state: The variables to use. Scripts and extractions change them in place.
    /// - Parameters:
    ///   - handlers: Optional callbacks for watching the response arrive.
    ///   - cancellation: Set this to stop the request while it is in progress.
    public func run(
        _ item: RequestItem, in collection: APICollection, state: inout RunState,
        handlers: HTTPStreamHandlers = HTTPStreamHandlers(), cancellation: CancellationFlag? = nil
    ) async -> RequestRunResult {
        var result = RequestRunResult(requestID: item.id)
        var request = item
        state.locals = [:]

        let folders = collection.folders(containingRequest: item.id)
        let preScripts = [collection.preRequestScript] + folders.map(\.preRequestScript) + [item.preRequestScript]
        let testScripts = [collection.testScript] + folders.map(\.testScript) + [item.testScript]

        // 1. Pre-request scripts see the request as written, before variables are filled in.
        var rawBody = ""
        if case .raw(let text, _) = request.body { rawBody = text }
        var scriptRequest = ScriptRequest(
            method: request.method,
            url: request.url,
            headers: request.headers.filter { $0.enabled && !$0.key.isEmpty }.map { .init(key: $0.key, value: $0.value) },
            body: rawBody
        )
        let before = scriptRequest
        let pre = ScriptRunner.run(
            scripts: preScripts, phase: .preRequest, requestName: item.name, state: &state, request: &scriptRequest
        )
        result.logs += pre.logs
        result.tests += pre.tests
        if let error = pre.error {
            result.error = "Pre-request script: \(error)"
            return result
        }
        if pre.skipRequest {
            result.skipped = true
            return result
        }
        if scriptRequest.headers != before.headers {
            request.headers = scriptRequest.headers.map { KeyValue(key: $0.key, value: $0.value) }
        }
        if scriptRequest.body != before.body, case .raw(_, let contentType) = request.body {
            request.body = .raw(text: scriptRequest.body, contentType: contentType)
        }

        // 2. Send.
        if item.isGRPC {
            guard let (prepared, response) = await callGRPC(request, in: collection, state: state, handlers: handlers, cancellation: cancellation, result: &result) else {
                return result
            }
            finish(item, prepared: prepared, response: response, testScripts: testScripts, state: &state, result: &result)
            return result
        }
        var prepared: PreparedRequest
        do {
            let auth = try await resolvedAuth(for: item.id, in: collection, resolver: state.resolver)
            prepared = try RequestBuilder.prepare(request, auth: auth, resolver: state.resolver)
        } catch {
            result.error = error.localizedDescription
            return result
        }
        // Send stored cookies, unless the request sets its own Cookie header.
        let url = URL(string: prepared.url)
        if prepared.header("Cookie") == nil, let url, let cookies = state.cookies.header(for: url) {
            prepared.headers.append(HTTPHeader(name: "Cookie", value: cookies))
        }
        result.prepared = prepared

        let response: HTTPResponse
        do {
            response = try await client.send(prepared, options: options(for: prepared.url), handlers: handlers, cancellation: cancellation)
        } catch {
            result.error = error.localizedDescription
            return result
        }
        result.response = response
        if let url {
            let setCookies = response.headers.filter { $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame }.map(\.value)
            state.cookies.store(setCookieHeaders: setCookies, from: url)
        }

        finish(item, prepared: prepared, response: response, testScripts: testScripts, state: &state, result: &result)
        return result
    }

    /// The auth a request uses, with OAuth 2 swapped for the token it stands for.
    func resolvedAuth(for id: UUID, in collection: APICollection, resolver: VariableResolver) async throws -> Auth {
        let auth = collection.effectiveAuth(forRequest: id)
        guard case .oauth2(let config) = auth else { return auth }
        let token = try await accessToken(for: config, resolver: resolver)
        let prefix = config.headerPrefix.trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty || prefix == "Bearer"
            ? .bearer(token: token.accessToken)
            : .apiKey(key: "Authorization", value: "\(prefix) \(token.accessToken)", placement: .header)
    }

    /// What follows a response of any kind: saved values, checks, then test scripts.
    private func finish(
        _ item: RequestItem, prepared: PreparedRequest, response: HTTPResponse, testScripts: [String],
        state: inout RunState, result: inout RequestRunResult
    ) {
        // 3. Extractions run first, so assertions and scripts can use the saved values.
        for extraction in item.extractions where extraction.enabled && !extraction.variable.isEmpty {
            if let value = extraction.source.value(in: response) {
                state.set(extraction.variable, to: value, scope: extraction.scope)
            } else {
                result.tests.append(TestResult(
                    name: "Save \(extraction.source.label) as \(extraction.variable)",
                    passed: false,
                    message: "the response has no such value"
                ))
            }
        }

        // 4. Assertions.
        let resolver = state.resolver
        for assertion in item.assertions where assertion.enabled {
            result.tests.append(assertion.evaluate(response, expected: resolver.resolve(assertion.expected).string))
        }

        // 5. Test scripts see the request as it was sent.
        var sent = ScriptRequest(
            method: prepared.method,
            url: prepared.url,
            headers: prepared.headers.map { .init(key: $0.name, value: $0.value) },
            body: prepared.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        )
        let post = ScriptRunner.run(
            scripts: testScripts, phase: .test, requestName: item.name, state: &state, request: &sent, response: response
        )
        result.logs += post.logs
        result.tests += post.tests
        result.scriptError = post.error
    }

    // MARK: gRPC

    /// Calls a gRPC method. The address is the request's URL, the message its body as JSON,
    /// and the metadata its headers and auth. Returns nil, with `result.error` set, when the
    /// call could not be made. A server stream is passed to `handlers` as an event stream,
    /// one event per message.
    private func callGRPC(
        _ request: RequestItem, in collection: APICollection, state: RunState,
        handlers: HTTPStreamHandlers, cancellation: CancellationFlag?, result: inout RequestRunResult
    ) async -> (PreparedRequest, HTTPResponse)? {
        let resolver = state.resolver
        guard let target = GRPCTarget(resolver.resolve(request.url).string) else {
            result.error = "The address is not valid. Use grpc://host:port, or grpcs:// for a server with TLS."
            return nil
        }
        do {
            // Metadata is the request's headers and auth, worked out the way an HTTP request's are.
            var stand = request
            stand.url = "http://grpc.invalid"
            stand.method = "POST"
            stand.body = .none
            stand.params = []
            let auth = try await resolvedAuth(for: request.id, in: collection, resolver: resolver)
            let unwanted: Set<String> = ["user-agent", "accept", "accept-encoding", "content-type", "content-length", "host", "cookie"]
            let metadata = try RequestBuilder.prepare(stand, auth: auth, resolver: resolver).headers
                .filter { !unwanted.contains($0.name.lowercased()) }

            var options = options(for: target.baseURL)
            let client = GRPCClient(http: self.client)
            let schema: ProtoSchema
            if let grpcSchema {
                schema = try await grpcSchema(target, metadata)
            } else {
                schema = try await client.reflect(target, metadata: metadata, options: options)
            }
            guard let name = request.grpcMethod, !name.isEmpty else { throw GRPCError("Choose a method to call.") }
            guard let method = schema.method(name) else {
                throw GRPCError("“\(name)” is not among the methods this server described. Load its methods again, or choose another.")
            }

            var text = ""
            if case .raw(let raw, _) = request.body { text = resolver.resolve(raw).string }
            let json = ProtoJSON(schema: schema)
            var messages: [Data] = []
            do {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let root = trimmed.isEmpty ? SpecNode(.map([])) : try SpecParser.parse(trimmed).root
                // A list sends one message per item, which is how a client stream is written.
                if root.isList, method.clientStreaming {
                    messages = try root.items.enumerated().map { try json.encode($0.element, as: method.inputType, path: "[\($0.offset)]") }
                } else if root.isList {
                    throw GRPCError("“\(method.name)” takes one message, so the message should be an object in { }, not a list.")
                } else {
                    messages = [try json.encode(root, as: method.inputType)]
                }
            } catch let error as SpecParseError {
                throw GRPCError("The message is not valid JSON. \(error.localizedDescription)")
            }

            let outputType = method.outputType
            var onMessage: (@Sendable (Data) -> Void)?
            if method.serverStreaming {
                // A stream may be meant to stay open; it is stopped by cancelling.
                options.timeout = 3600
                handlers.onHeaders?(200, [HTTPHeader(name: "Content-Type", value: "text/event-stream")])
                let onData = handlers.onData
                onMessage = { data in
                    let shown = (try? json.decode(data, as: outputType).jsonText(pretty: false)) ?? "\(data.count) bytes that could not be read"
                    onData?(Data("event: message\ndata: \(shown)\n\n".utf8))
                }
            }
            let prepared = PreparedRequest(method: "GRPC", url: "\(target.display)/\(method.id)", headers: metadata, body: Data(text.utf8))
            result.prepared = prepared

            let reply = try await client.call(
                target, method: method.id, messages: messages, metadata: metadata, options: options,
                onMessage: onMessage, cancellation: cancellation
            )
            let decoded = try reply.messages.map { try json.decode($0, as: outputType) }
            var body = method.serverStreaming ? SpecNode(.list(decoded)).jsonText() : decoded.first?.jsonText() ?? ""
            var bodyType = "application/json"
            // A failed call has no message to show, so show what the server said went wrong.
            if decoded.isEmpty, reply.status != 0 {
                body = reply.statusMessage
                bodyType = "text/plain"
            }
            let response = HTTPResponse(
                status: reply.status, statusText: reply.statusName, httpVersion: "gRPC",
                headers: reply.headers + (body.isEmpty ? [] : [HTTPHeader(name: "Content-Type", value: bodyType)]),
                body: Data(body.utf8), timings: reply.timings, remoteAddress: reply.remoteAddress,
                wireLog: reply.wireLog, wasCancelled: reply.wasCancelled
            )
            result.response = response
            return (prepared, response)
        } catch {
            result.error = error.localizedDescription
            return nil
        }
    }
}

/// A proxy to send requests through.
public struct ProxySettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// The proxy's address, such as `http://proxy.example.com:8080` or `socks5://127.0.0.1:1080`.
    public var url: String
    public var username: String
    /// Hosts to reach directly, separated by commas, such as `localhost, .internal.example.com`.
    public var bypass: String
    /// Filled in from the secret store when a request is sent. Never saved with the settings.
    public var password: String?

    enum CodingKeys: String, CodingKey { case enabled, url, username, bypass }

    /// The name the proxy's password is kept under in the secret store.
    public static let passwordKey = "proxy-password"

    public init(enabled: Bool = false, url: String = "", username: String = "", bypass: String = "localhost, 127.0.0.1") {
        self.enabled = enabled
        self.url = url
        self.username = username
        self.bypass = bypass
    }

    var bypassList: [String] {
        bypass.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    /// Whether a request to this address goes through the proxy.
    public func applies(to url: String) -> Bool {
        guard enabled, !self.url.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return true }
        return !bypassList.contains { entry in
            if entry == "*" { return true }
            let suffix = entry.hasPrefix("*.") ? String(entry.dropFirst(1)) : entry
            return host == suffix || host == suffix.drop(while: { $0 == "." }) || host.hasSuffix(suffix.hasPrefix(".") ? suffix : "." + suffix)
        }
    }
}

/// Says which client certificate to present to which host. The files stay where they are
/// on this Mac; the rule holds their paths, and the passphrase goes in the Keychain.
public struct ClientCertificateRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// A host name, optionally with a port, such as `api.example.com` or `localhost:8443`.
    /// A leading `*.` matches every subdomain.
    public var host: String
    public var certificatePath: String
    public var keyPath: String
    public var enabled: Bool

    public init(id: UUID = UUID(), host: String = "", certificatePath: String = "", keyPath: String = "", enabled: Bool = true) {
        self.id = id
        self.host = host
        self.certificatePath = certificatePath
        self.keyPath = keyPath
        self.enabled = enabled
    }

    /// The name the passphrase is kept under in the secret store.
    public var passphraseKey: String { "client-certificate-\(id.uuidString)" }

    public func matches(host: String, port: Int?) -> Bool {
        var pattern = self.host.trimmingCharacters(in: .whitespaces).lowercased()
        guard enabled, !pattern.isEmpty, !certificatePath.isEmpty else { return false }
        // Tolerate a pasted address: drop the scheme and any path.
        if let scheme = pattern.range(of: "://") { pattern = String(pattern[scheme.upperBound...]) }
        if let slash = pattern.firstIndex(of: "/") { pattern = String(pattern[..<slash]) }
        if let colon = pattern.lastIndex(of: ":"), let wanted = Int(pattern[pattern.index(after: colon)...]) {
            guard port == wanted else { return false }
            pattern = String(pattern[..<colon])
        }
        let host = host.lowercased()
        if pattern.hasPrefix("*.") {
            return host.hasSuffix(String(pattern.dropFirst(1)))
        }
        return host == pattern
    }
}

extension Array where Element == ClientCertificateRule {
    /// The first rule that applies to an https address.
    public func rule(for url: String) -> ClientCertificateRule? {
        guard let components = URLComponents(string: url), let host = components.host,
              ["https", "wss", "grpcs"].contains(components.scheme?.lowercased() ?? "") else { return nil }
        let port = components.port ?? 443
        return first { $0.matches(host: host, port: port) }
    }
}
