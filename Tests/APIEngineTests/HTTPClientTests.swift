import Foundation
import Network
import Testing
@testable import APIEngine

/// A tiny HTTP server on localhost, so the HTTP tests need no internet access.
/// It answers every request with a JSON description of what it received.
final class EchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "echo-server")
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Flag()
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    port = listener.port?.rawValue ?? 0
                    if resumed.set() { continuation.resume() }
                case .failed(let error):
                    if resumed.set() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(on: connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private final class Flag: @unchecked Sendable {
        private var value = false
        private let lock = NSLock()
        /// Returns true the first time only.
        func set() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if value { return false }
            value = true
            return true
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            let head = String(decoding: buffer.prefix(64), as: UTF8.self)
            if head.hasPrefix("GET /sse"), buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                stream(on: connection, forever: head.hasPrefix("GET /sse-forever"))
            } else if let response = respond(to: buffer) {
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
        }
    }

    /// Sends a few server-sent events a moment apart, then closes, or keeps going until the client leaves.
    private func stream(on connection: NWConnection, forever: Bool) {
        connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        func send(_ index: Int) {
            let event = index == 2 ? "event: update\nid: \(index)\ndata: {\"n\": \(index)}\n\n" : ": keep-alive\ndata: tick \(index)\n\n"
            connection.send(content: Data(event.utf8), completion: .contentProcessed { [self] error in
                if error != nil {
                    connection.cancel()
                } else if index < 3 || forever {
                    queue.asyncAfter(deadline: .now() + 0.05) { send(index + 1) }
                } else {
                    connection.cancel()
                }
            })
        }
        send(1)
    }

    private var tokensIssued = 0

    /// Returns nil until the whole request has arrived.
    private func respond(to buffer: Data) -> Data? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= length else { return nil }

        let method = requestLine.count > 0 ? String(requestLine[0]) : ""
        let path = requestLine.count > 1 ? String(requestLine[1]) : ""

        if path.hasPrefix("/redirect") {
            return Data("HTTP/1.1 302 Found\r\nLocation: /landed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }
        if path.hasPrefix("/login") {
            return Data("HTTP/1.1 200 OK\r\nSet-Cookie: session=abc123; Path=/; HttpOnly\r\nSet-Cookie: admin=1; Path=/admin\r\nSet-Cookie: gone=1; Max-Age=0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }
        if path.hasPrefix("/token") {
            let form = String(decoding: body.prefix(length), as: UTF8.self)
            var json: String
            if form.contains("grant_type=refresh_token") {
                json = "{\"access_token\": \"refreshed\", \"token_type\": \"Bearer\", \"expires_in\": \"3600\"}"
            } else if form.contains("client_secret=wrong") || headers["authorization"] == "Basic " + Data("app:wrong".utf8).base64EncodedString() {
                json = "{\"error\": \"invalid_client\", \"error_description\": \"Bad secret\"}"
                return Data("HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)".utf8)
            } else {
                tokensIssued += 1
                json = "{\"access_token\": \"tok-\(tokensIssued)\", \"token_type\": \"Bearer\", \"expires_in\": 3600, \"refresh_token\": \"r-1\", \"form\": \"\(form)\", \"auth\": \"\(headers["authorization"] ?? "")\"}"
            }
            return Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)".utf8)
        }
        if path.hasPrefix("/status/404") {
            return Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }

        let payload: [String: Any] = [
            "method": method,
            "path": path,
            "headers": headers,
            "body": String(decoding: body.prefix(length), as: UTF8.self),
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Echo: yes\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        if method != "HEAD" { response.append(json) }
        return response
    }
}

struct Echo: Decodable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: String
}

@Suite struct HTTPClientRequests {
    func withServer<T>(_ work: (String) async throws -> T) async throws -> T {
        let server = try EchoServer()
        try await server.start()
        defer { server.stop() }
        return try await work("http://127.0.0.1:\(server.port)")
    }

    @Test func getReturnsStatusHeadersBodyAndTimings() async throws {
        try await withServer { base in
            let request = PreparedRequest(method: "GET", url: "\(base)/hello?x=1", headers: [HTTPHeader(name: "X-Test", value: "abc")])
            let response = try await HTTPClient().send(request)

            #expect(response.status == 200)
            #expect(response.statusText == "OK")
            #expect(response.httpVersion == "HTTP/1.1")
            #expect(response.header("x-echo") == "yes")
            #expect(response.remoteAddress == "127.0.0.1")

            let echo = try JSONDecoder().decode(Echo.self, from: response.body)
            #expect(echo.method == "GET")
            #expect(echo.path == "/hello?x=1")
            #expect(echo.headers["x-test"] == "abc")

            #expect(response.timings.total > 0)
            let phases = response.timings.phases.map(\.seconds)
            #expect(phases.allSatisfy { $0 >= 0 })
            #expect(phases.reduce(0, +) <= response.timings.total + 0.001)

            #expect(response.wireLog.contains { $0.kind == .requestHeader && $0.text.contains("GET /hello?x=1") })
            #expect(response.wireLog.contains { $0.kind == .responseHeader && $0.text.contains("200 OK") })
        }
    }

    @Test func postSendsBodyWithoutExtraHeaders() async throws {
        try await withServer { base in
            let request = PreparedRequest(method: "POST", url: "\(base)/items", body: Data("{\"a\":1}".utf8))
            let response = try await HTTPClient().send(request)
            let echo = try JSONDecoder().decode(Echo.self, from: response.body)

            #expect(echo.method == "POST")
            #expect(echo.body == "{\"a\":1}")
            #expect(echo.headers["content-length"] == "7")
            // libcurl would add these on its own; the request did not ask for them.
            #expect(echo.headers["content-type"] == nil)
            #expect(echo.headers["expect"] == nil)
        }
    }

    @Test func otherMethodsAndEmptyBodies() async throws {
        try await withServer { base in
            for method in ["PUT", "PATCH", "DELETE"] {
                let response = try await HTTPClient().send(PreparedRequest(method: method, url: "\(base)/x", body: Data("b".utf8)))
                #expect(try JSONDecoder().decode(Echo.self, from: response.body).method == method)
            }
            let empty = try await HTTPClient().send(PreparedRequest(method: "POST", url: "\(base)/x", body: Data()))
            #expect(try JSONDecoder().decode(Echo.self, from: empty.body).headers["content-length"] == "0")

            let head = try await HTTPClient().send(PreparedRequest(method: "HEAD", url: "\(base)/x"))
            #expect(head.status == 200)
            #expect(head.body.isEmpty)
        }
    }

    @Test func redirectsAreFollowedOrNot() async throws {
        try await withServer { base in
            let request = PreparedRequest(method: "GET", url: "\(base)/redirect")
            let followed = try await HTTPClient().send(request)
            #expect(followed.status == 200)
            #expect(try JSONDecoder().decode(Echo.self, from: followed.body).path == "/landed")
            // Only the final response's headers are kept.
            #expect(followed.header("Location") == nil)

            let stopped = try await HTTPClient().send(request, options: HTTPOptions(followRedirects: false))
            #expect(stopped.status == 302)
            #expect(stopped.header("Location") == "/landed")
        }
    }

    @Test func errorStatusIsAResponseNotAnError() async throws {
        try await withServer { base in
            let response = try await HTTPClient().send(PreparedRequest(method: "GET", url: "\(base)/status/404"))
            #expect(response.status == 404)
            #expect(response.statusText == "Not Found")
        }
    }

    @Test func connectionFailureThrows() async throws {
        // Port 1 on localhost has nothing listening.
        await #expect(throws: HTTPClientError.self) {
            try await HTTPClient().send(PreparedRequest(method: "GET", url: "http://127.0.0.1:1/"), options: HTTPOptions(timeout: 5))
        }
    }

    @Test func importedRequestRunsEndToEnd() async throws {
        try await withServer { base in
            let (collection, _) = try importSampleCollection()
            let environment = APIEnvironment(name: "Local", variables: [
                Variable(key: "baseUrl", value: base), Variable(key: "petName", value: "Rex"),
            ])
            let resolver = VariableResolver(collection: collection.variables, environment: environment.variables)
            let create = try #require(collection.allRequests.first { $0.name == "Create pet" })
            let prepared = try RequestBuilder.prepare(create, auth: collection.effectiveAuth(forRequest: create.id), resolver: resolver)
            let response = try await HTTPClient().send(prepared)
            let echo = try JSONDecoder().decode(Echo.self, from: response.body)

            #expect(echo.method == "POST")
            #expect(echo.path == "/pets")
            #expect(echo.body == "{\"name\": \"Rex\"}")
            #expect(echo.headers["content-type"] == "application/json")
            #expect(echo.headers["authorization"] == nil)
        }
    }
}

@Suite struct HistoryStorage {
    @Test func keepsNewestFirstAndTrims() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apiplayground-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(root: root, limitPerRequest: 3)
        let requestID = UUID()
        let request = PreparedRequest(method: "GET", url: "https://example.com")

        for index in 0..<5 {
            let response = HTTPResponse(
                status: 200 + index, statusText: "", httpVersion: "HTTP/1.1", headers: [],
                body: Data("body \(index)".utf8), timings: HTTPTimings(), remoteAddress: nil, wireLog: []
            )
            let date = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            try store.record(HistoryEntry(date: date, request: request, response: response), requestID: requestID)
        }

        let entries = store.entries(requestID: requestID)
        #expect(entries.map(\.status) == [204, 203, 202])
        #expect(entries.first?.text == "body 4")

        store.clear(requestID: requestID)
        #expect(store.entries(requestID: requestID).isEmpty)
    }
}
