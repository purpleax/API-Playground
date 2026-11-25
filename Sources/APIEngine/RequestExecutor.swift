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
            if let response = try? await client.send(request, options: options), var fresh = try? OAuth2.parseToken(response) {
                // A server may omit the refresh token when it has not changed.
                fresh.refreshToken = fresh.refreshToken ?? refreshToken
                tokens.save(fresh, for: config.id)
                return fresh
            }
        }
        guard config.grant.isAutomatic else { throw OAuth2Error.needsSignIn }
        let response = try await client.send(try OAuth2.tokenRequest(config, resolver: resolver), options: options)
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
        var prepared: PreparedRequest
        do {
            var auth = collection.effectiveAuth(forRequest: item.id)
            if case .oauth2(let config) = auth {
                let token = try await accessToken(for: config, resolver: state.resolver)
                let prefix = config.headerPrefix.trimmingCharacters(in: .whitespaces)
                auth = prefix.isEmpty || prefix == "Bearer"
                    ? .bearer(token: token.accessToken)
                    : .apiKey(key: "Authorization", value: "\(prefix) \(token.accessToken)", placement: .header)
            }
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
            response = try await client.send(prepared, options: options, handlers: handlers, cancellation: cancellation)
        } catch {
            result.error = error.localizedDescription
            return result
        }
        result.response = response
        if let url {
            let setCookies = response.headers.filter { $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame }.map(\.value)
            state.cookies.store(setCookieHeaders: setCookies, from: url)
        }

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
        return result
    }
}
