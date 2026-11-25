import Foundation
import Network

/// One endpoint a mock server answers: a request from a collection and its pinned responses.
public struct MockRoute: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var method: String
    /// The path to match, such as `/pets/:id`. A part starting with `:` or holding a `{{variable}}` matches anything.
    public var path: String
    public var examples: [SavedResponse]

    public init(id: UUID = UUID(), name: String, method: String, path: String, examples: [SavedResponse] = []) {
        self.id = id
        self.name = name
        self.method = method
        self.path = path
        self.examples = examples
    }
}

/// A request the mock server received, for showing in a log.
public struct MockHit: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var method: String
    public var path: String
    public var status: Int
    /// The route that answered, or nil when nothing matched.
    public var routeName: String?
}

public struct MockReply: Equatable, Sendable {
    public var status: Int
    public var headers: [HTTPHeader]
    public var body: Data
    public var routeName: String?
}

/// A local HTTP server that answers with a collection's pinned responses, so a demo
/// needs no backend and no network.
public final class MockServer: @unchecked Sendable {
    public let routes: [MockRoute]
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mock-server")
    private let lock = NSLock()
    private var hitHandler: (@Sendable (MockHit) -> Void)?

    public init(routes: [MockRoute]) {
        self.routes = routes
    }

    /// Called for every request received. May be called on any thread.
    public func onHit(_ handler: @escaping @Sendable (MockHit) -> Void) {
        lock.lock()
        hitHandler = handler
        lock.unlock()
    }

    // MARK: Routes

    public static func routes(for collection: APICollection) -> [MockRoute] {
        collection.allRequests.map { request in
            MockRoute(
                id: request.id,
                name: request.name,
                method: request.method.uppercased(),
                path: pathPattern(from: request.url),
                examples: request.examples
            )
        }
    }

    /// The path part of a request URL: `{{baseUrl}}/pets/:id` and `https://api.example.com/pets/:id` both give `/pets/:id`.
    public static func pathPattern(from url: String) -> String {
        var rest = Substring(url.trimmingCharacters(in: .whitespaces))
        if let query = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<query] }
        if let scheme = rest.range(of: "://") {
            // Drop the scheme and host.
            let afterScheme = rest[scheme.upperBound...]
            rest = afterScheme.firstIndex(of: "/").map { afterScheme[$0...] } ?? ""
        } else if rest.hasPrefix("{{"), let close = rest.range(of: "}}") {
            // A leading variable stands for the base URL.
            rest = rest[close.upperBound...]
        } else if !rest.hasPrefix("/") {
            // "api.example.com/pets": the first part is the host.
            rest = rest.firstIndex(of: "/").map { rest[$0...] } ?? ""
        }
        let path = String(rest)
        return path.isEmpty ? "/" : path
    }

    /// The variable a collection's URLs start with, such as `baseUrl` in `{{baseUrl}}/pets`,
    /// when most of its requests share one. Pointing it at the mock redirects the whole collection.
    public static func baseVariable(of collection: APICollection) -> String? {
        var counts: [String: Int] = [:]
        for request in collection.allRequests {
            let url = request.url.trimmingCharacters(in: .whitespaces)
            guard url.hasPrefix("{{"), let close = url.range(of: "}}") else { continue }
            let name = url[url.index(url.startIndex, offsetBy: 2)..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            counts[name, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func segments(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }

    private static func isWildcard(_ segment: Substring) -> Bool {
        segment.hasPrefix(":") || segment.contains("{{")
    }

    /// Finds the best route for a request, and the values its wildcard parts matched.
    static func match(method: String, path: String, routes: [MockRoute]) -> (route: MockRoute, parameters: [String: String])? {
        let wanted = method.uppercased() == "HEAD" ? "GET" : method.uppercased()
        let actual = segments(path)
        var best: (route: MockRoute, parameters: [String: String], literals: Int)?
        for route in routes where route.method == wanted {
            let pattern = segments(route.path)
            guard pattern.count == actual.count else { continue }
            var parameters: [String: String] = [:]
            var literals = 0
            var matches = true
            for (expected, given) in zip(pattern, actual) {
                if isWildcard(expected) {
                    let name = expected.hasPrefix(":")
                        ? String(expected.dropFirst())
                        : expected.replacingOccurrences(of: "{{", with: "").replacingOccurrences(of: "}}", with: "")
                    parameters[name.trimmingCharacters(in: .whitespaces)] = given.removingPercentEncoding ?? String(given)
                } else if expected == given {
                    literals += 1
                } else {
                    matches = false
                    break
                }
            }
            // A route with more fixed parts is more specific: /pets/latest beats /pets/:id.
            if matches, literals > (best?.literals ?? -1) {
                best = (route, parameters, literals)
            }
        }
        return best.map { ($0.route, $0.parameters) }
    }

    // MARK: Answering

    /// Works out the reply to a request. `target` is the request line's path, with any query string.
    public static func reply(method: String, target: String, headers: [String: String], routes: [MockRoute]) -> MockReply {
        let cors = [
            HTTPHeader(name: "Access-Control-Allow-Origin", value: "*"),
            HTTPHeader(name: "Access-Control-Allow-Headers", value: "*"),
            HTTPHeader(name: "Access-Control-Allow-Methods", value: "GET, POST, PUT, PATCH, DELETE, OPTIONS"),
        ]
        func json(_ status: Int, _ payload: [String: Any], route: String? = nil) -> MockReply {
            let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return MockReply(status: status, headers: [HTTPHeader(name: "Content-Type", value: "application/json")] + cors, body: body, routeName: route)
        }

        let parts = URLParts.split(target)
        if method.uppercased() == "OPTIONS" {
            // A browser's preflight check before a cross-origin request.
            return MockReply(status: 204, headers: cors, body: Data(), routeName: nil)
        }
        guard let found = match(method: method, path: parts.base, routes: routes) else {
            return json(404, [
                "error": "No mock route matches \(method.uppercased()) \(parts.base)",
                "routes": routes.map { "\($0.method) \($0.path)" },
            ])
        }
        let route = found.route
        guard !route.examples.isEmpty else {
            return json(501, ["error": "\"\(route.name)\" has no pinned response to serve. Send it once and pin the response."], route: route.name)
        }

        // Postman's headers for picking a particular example.
        var example = route.examples[0]
        if let name = headers["x-mock-response-name"], let named = route.examples.first(where: { $0.name == name }) {
            example = named
        } else if let code = headers["x-mock-response-code"].flatMap(Int.init), let coded = route.examples.first(where: { $0.status == code }) {
            example = coded
        }

        // Path and query values can be used in the body, along with dynamic variables such as {{$guid}}.
        var query: [String: String] = [:]
        for param in parts.params { query[param.key] = param.value }
        let resolver = VariableResolver(scopes: [query, found.parameters])
        let body = Data(resolver.resolve(example.body).string.utf8)

        // These describe the original transfer, not this one.
        let skipped: Set<String> = ["content-length", "content-encoding", "transfer-encoding", "connection", "keep-alive"]
        var replyHeaders = example.headers
            .filter { $0.enabled && !$0.key.isEmpty && !skipped.contains($0.key.lowercased()) }
            .map { HTTPHeader(name: $0.key, value: $0.value) }
        for header in cors where !replyHeaders.contains(where: { $0.name.caseInsensitiveCompare(header.name) == .orderedSame }) {
            replyHeaders.append(header)
        }
        return MockReply(status: example.status == 0 ? 200 : example.status, headers: replyHeaders, body: body, routeName: route.name)
    }

    // MARK: Listening

    /// Starts listening on localhost only. Pass 0 to let the system pick a free port.
    /// - Returns: The port in use.
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only: the mock is never reachable from another machine.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.first() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.first() { continuation.resume(throwing: error) }
                case .cancelled:
                    if resumed.first() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.receive(on: connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private final class Once: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let response = self.respond(to: buffer) {
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if isComplete || error != nil || buffer.count > 10_000_000 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

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
        guard buffer.count - headerEnd.upperBound >= length else { return nil }

        let method = requestLine.count > 0 ? String(requestLine[0]) : "GET"
        let target = requestLine.count > 1 ? String(requestLine[1]) : "/"
        let reply = Self.reply(method: method, target: target, headers: headers, routes: routes)

        lock.lock()
        let handler = hitHandler
        lock.unlock()
        handler?(MockHit(method: method, path: URLParts.split(target).base, status: reply.status, routeName: reply.routeName))

        var response = "HTTP/1.1 \(reply.status) \(Self.reason(reply.status))\r\n"
        for header in reply.headers {
            response += "\(header.name): \(header.value)\r\n"
        }
        response += "Content-Length: \(reply.body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(response.utf8)
        if method.uppercased() != "HEAD" { data.append(reply.body) }
        return data
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 422: return "Unprocessable Content"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        }
    }
}
