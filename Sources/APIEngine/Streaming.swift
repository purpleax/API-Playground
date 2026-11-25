import Foundation

/// One event from a server-sent event stream.
public struct ServerSentEvent: Identifiable, Equatable, Sendable {
    public var id = UUID()
    /// The event's type. "message" when the server gave none.
    public var event: String
    public var data: String
    /// The id the server attached, if any.
    public var lastEventID: String?
    public var received: Date

    public init(event: String = "message", data: String, lastEventID: String? = nil, received: Date = Date()) {
        self.event = event
        self.data = data
        self.lastEventID = lastEventID
        self.received = received
    }

    public static func == (a: ServerSentEvent, b: ServerSentEvent) -> Bool {
        a.event == b.event && a.data == b.data && a.lastEventID == b.lastEventID
    }
}

/// Turns the bytes of a `text/event-stream` response into events, a piece at a time.
public struct ServerSentEventParser: Sendable {
    private var buffer = Data()
    private var event = ""
    private var data: [String] = []
    private var lastEventID: String?
    /// The reconnection delay the server asked for, in milliseconds.
    public private(set) var retry: Int?

    public init() {}

    /// Parses a whole response body at once.
    public static func events(in body: Data) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        var events = parser.feed(body)
        // A stream cut off mid-event still shows what it had.
        events += parser.feed(Data("\n\n".utf8))
        return events
    }

    /// Adds more bytes and returns the events they completed.
    public mutating func feed(_ chunk: Data) -> [ServerSentEvent] {
        buffer.append(chunk)
        var events: [ServerSentEvent] = []
        while let line = nextLine() {
            if line.isEmpty {
                // A blank line ends the event.
                if !data.isEmpty {
                    events.append(ServerSentEvent(
                        event: event.isEmpty ? "message" : event,
                        data: data.joined(separator: "\n"),
                        lastEventID: lastEventID
                    ))
                }
                event = ""
                data = []
                continue
            }
            if line.hasPrefix(":") { continue }  // A comment, often used as a keep-alive.

            let field: Substring
            var value: Substring
            if let colon = line.firstIndex(of: ":") {
                field = line[..<colon]
                value = line[line.index(after: colon)...]
                if value.hasPrefix(" ") { value = value.dropFirst() }
            } else {
                field = Substring(line)
                value = ""
            }
            switch field {
            case "event": event = String(value)
            case "data": data.append(String(value))
            case "id": lastEventID = String(value)
            case "retry": retry = Int(value)
            default: break
            }
        }
        return events
    }

    /// Takes the next complete line from the buffer. Lines end with LF, CR, or CR LF.
    private mutating func nextLine() -> String? {
        guard let end = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else { return nil }
        // A lone CR at the very end may be the first half of CR LF: wait for more.
        if buffer[end] == 0x0D, end == buffer.index(before: buffer.endIndex) { return nil }
        let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
        var next = buffer.index(after: end)
        if buffer[end] == 0x0D, next < buffer.endIndex, buffer[next] == 0x0A {
            next = buffer.index(after: next)
        }
        buffer = Data(buffer[next...])
        return line
    }
}

// MARK: - Cookies

public struct Cookie: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var value: String
    /// The host the cookie belongs to, without a leading dot.
    public var domain: String
    /// True when the cookie is sent only to that exact host, not its subdomains.
    public var hostOnly: Bool
    public var path: String
    /// Nil for a session cookie, which is kept until it is cleared.
    public var expires: Date?
    public var secure: Bool
    public var httpOnly: Bool

    public var id: String { "\(domain)|\(path)|\(name)" }

    public init(name: String, value: String, domain: String, hostOnly: Bool = true, path: String = "/", expires: Date? = nil, secure: Bool = false, httpOnly: Bool = false) {
        self.name = name
        self.value = value
        self.domain = domain
        self.hostOnly = hostOnly
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
    }
}

/// Keeps cookies set by servers and sends them back on later requests, like a browser does.
public struct CookieJar: Codable, Equatable, Sendable {
    public var cookies: [Cookie]

    public init(cookies: [Cookie] = []) {
        self.cookies = cookies
    }

    /// Parses one `Set-Cookie` header value. Returns nil when it is malformed or not allowed for the URL.
    public static func parse(_ header: String, from url: URL, now: Date = Date()) -> Cookie? {
        guard let host = url.host?.lowercased() else { return nil }
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, let equals = first.firstIndex(of: "=") else { return nil }
        let name = first[..<equals].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // The default path is the directory of the request path.
        var defaultPath = "/"
        if let slash = url.path.lastIndex(of: "/"), slash != url.path.startIndex {
            defaultPath = String(url.path[..<slash])
        }
        var cookie = Cookie(
            name: name, value: first[first.index(after: equals)...].trimmingCharacters(in: .whitespaces),
            domain: host, path: defaultPath
        )
        var maxAge: Int?

        for attribute in parts.dropFirst() {
            let pieces = attribute.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let key = pieces[0].lowercased()
            let value = pieces.count > 1 ? pieces[1] : ""
            switch key {
            case "domain":
                let domain = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                // A server may only set cookies for its own host or a parent of it.
                guard !domain.isEmpty, host == domain || host.hasSuffix("." + domain) else { return nil }
                cookie.domain = domain
                cookie.hostOnly = false
            case "path":
                if value.hasPrefix("/") { cookie.path = value }
            case "expires":
                cookie.expires = Self.date(value)
            case "max-age":
                maxAge = Int(value)
            case "secure":
                cookie.secure = true
            case "httponly":
                cookie.httpOnly = true
            default:
                break
            }
        }
        // Max-Age wins over Expires.
        if let maxAge { cookie.expires = now.addingTimeInterval(TimeInterval(maxAge)) }
        return cookie
    }

    private static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Stores the cookies a response set. A cookie that has already expired removes the stored one.
    public mutating func store(setCookieHeaders: [String], from url: URL, now: Date = Date()) {
        for header in setCookieHeaders {
            guard let cookie = Self.parse(header, from: url, now: now) else { continue }
            cookies.removeAll { $0.id == cookie.id }
            if let expires = cookie.expires, expires <= now { continue }
            cookies.append(cookie)
        }
    }

    /// The cookies that should be sent to a URL.
    public func matching(_ url: URL, now: Date = Date()) -> [Cookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let isSecure = url.scheme?.lowercased() == "https"
        let path = url.path.isEmpty ? "/" : url.path
        return cookies.filter { cookie in
            if let expires = cookie.expires, expires <= now { return false }
            if cookie.secure && !isSecure { return false }
            let domainMatches = cookie.hostOnly ? host == cookie.domain : (host == cookie.domain || host.hasSuffix("." + cookie.domain))
            guard domainMatches else { return false }
            if cookie.path == "/" || path == cookie.path { return true }
            return path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")
        }
        // Longer paths first, as browsers send them.
        .sorted { $0.path.count > $1.path.count }
    }

    /// The `Cookie` header value for a URL, or nil when no cookie applies.
    public func header(for url: URL, now: Date = Date()) -> String? {
        let matches = matching(url, now: now)
        return matches.isEmpty ? nil : matches.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public mutating func removeExpired(now: Date = Date()) {
        cookies.removeAll { ($0.expires ?? .distantFuture) <= now }
    }
}

// MARK: - GraphQL

public struct GraphQLArgument: Equatable, Sendable {
    public var name: String
    public var type: String
    public var defaultValue: String?
}

public struct GraphQLField: Equatable, Identifiable, Sendable {
    public var name: String
    public var description: String
    /// The type as written in a schema, such as `[Pet!]!`.
    public var type: String
    public var arguments: [GraphQLArgument]
    public var id: String { name }

    /// The field with its arguments, such as `pet(id: ID!): Pet`.
    public var signature: String {
        let args = arguments.isEmpty ? "" : "(" + arguments.map { "\($0.name): \($0.type)" }.joined(separator: ", ") + ")"
        return "\(name)\(args): \(type)"
    }
}

public struct GraphQLType: Equatable, Identifiable, Sendable {
    public var name: String
    /// OBJECT, INPUT_OBJECT, ENUM, SCALAR, INTERFACE or UNION.
    public var kind: String
    public var description: String
    /// Fields of an object or interface, or the input fields of an input object.
    public var fields: [GraphQLField]
    public var enumValues: [String]
    public var id: String { name }
}

public struct GraphQLSchema: Equatable, Sendable {
    public var queryType: String?
    public var mutationType: String?
    public var subscriptionType: String?
    /// Every type except GraphQL's own built-in `__` types, sorted by name.
    public var types: [GraphQLType]

    public func type(named name: String?) -> GraphQLType? {
        types.first { $0.name == name }
    }
}

public enum GraphQLError: Error, LocalizedError, Equatable {
    case notASchema(String)

    public var errorDescription: String? {
        switch self {
        case .notASchema(let detail): return "The server did not return a schema. \(detail)"
        }
    }
}

public enum GraphQL {
    /// The standard query that asks a server to describe its schema.
    public static let introspectionQuery = """
    query IntrospectionQuery { __schema { queryType { name } mutationType { name } subscriptionType { name }
      types { kind name description
        fields(includeDeprecated: true) { name description args { name defaultValue type { ...TypeRef } } type { ...TypeRef } }
        inputFields { name description defaultValue type { ...TypeRef } }
        enumValues(includeDeprecated: true) { name } } } }
    fragment TypeRef on __Type { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } } }
    """

    /// Turns a prepared GraphQL request into one that asks for the schema, keeping its URL, headers and auth.
    public static func introspectionRequest(from request: PreparedRequest) -> PreparedRequest {
        var copy = request
        copy.method = "POST"
        copy.body = try? JSONSerialization.data(withJSONObject: ["query": introspectionQuery])
        copy.headers.removeAll { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
        copy.headers.append(HTTPHeader(name: "Content-Type", value: "application/json"))
        return copy
    }

    public static func parseSchema(_ data: Data) throws -> GraphQLSchema {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GraphQLError.notASchema("The response was not JSON.")
        }
        guard let schema = (root["data"] as? [String: Any])?["__schema"] as? [String: Any] else {
            let message = ((root["errors"] as? [[String: Any]])?.first?["message"] as? String) ?? "Introspection may be turned off."
            throw GraphQLError.notASchema(message)
        }

        func name(_ key: String) -> String? { (schema[key] as? [String: Any])?["name"] as? String }

        let types: [GraphQLType] = (schema["types"] as? [[String: Any]] ?? []).compactMap { type in
            guard let typeName = type["name"] as? String, !typeName.hasPrefix("__") else { return nil }
            func field(_ raw: [String: Any]) -> GraphQLField {
                GraphQLField(
                    name: raw["name"] as? String ?? "",
                    description: raw["description"] as? String ?? "",
                    type: typeString(raw["type"]),
                    arguments: (raw["args"] as? [[String: Any]] ?? []).map {
                        GraphQLArgument(name: $0["name"] as? String ?? "", type: typeString($0["type"]), defaultValue: $0["defaultValue"] as? String)
                    }
                )
            }
            let fields = (type["fields"] as? [[String: Any]] ?? []) + (type["inputFields"] as? [[String: Any]] ?? [])
            return GraphQLType(
                name: typeName,
                kind: type["kind"] as? String ?? "",
                description: type["description"] as? String ?? "",
                fields: fields.map(field),
                enumValues: (type["enumValues"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            )
        }
        return GraphQLSchema(
            queryType: name("queryType"),
            mutationType: name("mutationType"),
            subscriptionType: name("subscriptionType"),
            types: types.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }

    /// Renders an introspection type reference the way a schema writes it: `[Pet!]!`.
    static func typeString(_ raw: Any?) -> String {
        guard let type = raw as? [String: Any] else { return "" }
        switch type["kind"] as? String {
        case "NON_NULL": return typeString(type["ofType"]) + "!"
        case "LIST": return "[" + typeString(type["ofType"]) + "]"
        default: return type["name"] as? String ?? ""
        }
    }
}
