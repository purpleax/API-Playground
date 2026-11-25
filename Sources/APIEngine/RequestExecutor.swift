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

    public init(client: HTTPClient = HTTPClient(), options: HTTPOptions = HTTPOptions()) {
        self.client = client
        self.options = options
    }

    /// - Parameter state: The variables to use. Scripts and extractions change them in place.
    public func run(_ item: RequestItem, in collection: APICollection, state: inout RunState) async -> RequestRunResult {
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
        let prepared: PreparedRequest
        do {
            prepared = try RequestBuilder.prepare(
                request, auth: collection.effectiveAuth(forRequest: item.id), resolver: state.resolver
            )
        } catch {
            result.error = error.localizedDescription
            return result
        }
        result.prepared = prepared

        let response: HTTPResponse
        do {
            response = try await client.send(prepared, options: options)
        } catch {
            result.error = error.localizedDescription
            return result
        }
        result.response = response

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
