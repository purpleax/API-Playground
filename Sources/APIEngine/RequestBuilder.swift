import Foundation

public struct HTTPHeader: Codable, Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A request with every variable replaced and auth applied, ready to send.
public struct PreparedRequest: Equatable, Sendable {
    public var method: String
    public var url: String
    public var headers: [HTTPHeader]
    public var body: Data?
    /// Variable names that had no value. Their `{{placeholders}}` are still in the request.
    public var unresolved: [String]

    public init(method: String, url: String, headers: [HTTPHeader] = [], body: Data? = nil, unresolved: [String] = []) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.unresolved = unresolved
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public enum RequestBuildError: Error, LocalizedError, Equatable {
    case emptyURL
    case unreadableFile(String)

    public var errorDescription: String? {
        switch self {
        case .emptyURL: return "The request has no URL."
        case .unreadableFile(let path): return "Could not read the file at \(path)."
        }
    }
}

public enum RequestBuilder {
    public static let userAgent = "APIPlayground/0.1"

    /// - Parameter auth: The auth the request actually uses, after inheritance
    ///   (see `APICollection.effectiveAuth(forRequest:)`).
    public static func prepare(
        _ request: RequestItem, auth: Auth, resolver: VariableResolver
    ) throws -> PreparedRequest {
        var unresolved: [String] = []
        func resolve(_ text: String) -> String {
            let result = resolver.resolve(text)
            for name in result.unresolved where !unresolved.contains(name) { unresolved.append(name) }
            return result.string
        }

        // URL and path variables
        var url = resolve(request.url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw RequestBuildError.emptyURL }
        let pathValues = request.pathVariables.filter { $0.enabled && !$0.key.isEmpty }.map { (key: $0.key, value: resolve($0.value)) }
        url = fillPath(url, with: pathValues)
        if !url.contains("://") { url = "http://" + url }

        // Query parameters
        var query: [String] = []
        for param in request.params where param.enabled && !param.key.isEmpty {
            query.append("\(encodeQuery(resolve(param.key)))=\(encodeQuery(resolve(param.value)))")
        }

        // Headers
        var headers: [HTTPHeader] = []
        for header in request.headers where header.enabled && !header.key.isEmpty {
            headers.append(HTTPHeader(name: resolve(header.key), value: resolve(header.value)))
        }
        func hasHeader(_ name: String) -> Bool {
            headers.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        // Auth. A header the user set by hand wins over the auth settings.
        switch auth {
        case .inherit, .none:
            break
        case .oauth2:
            // The executor swaps OAuth 2 for the token it fetched before calling this.
            break
        case .basic(let username, let password):
            if !hasHeader("Authorization") {
                let token = Data("\(resolve(username)):\(resolve(password))".utf8).base64EncodedString()
                headers.append(HTTPHeader(name: "Authorization", value: "Basic \(token)"))
            }
        case .bearer(let token):
            if !hasHeader("Authorization") {
                headers.append(HTTPHeader(name: "Authorization", value: "Bearer \(resolve(token))"))
            }
        case .apiKey(let key, let value, let placement):
            switch placement {
            case .header:
                if !hasHeader(resolve(key)) {
                    headers.append(HTTPHeader(name: resolve(key), value: resolve(value)))
                }
            case .query:
                query.append("\(encodeQuery(resolve(key)))=\(encodeQuery(resolve(value)))")
            }
        }

        if !query.isEmpty {
            url += (url.contains("?") ? "&" : "?") + query.joined(separator: "&")
        }

        // Body
        var body: Data?
        var defaultContentType: String?
        switch request.body {
        case .none:
            break
        case .raw(let text, let contentType):
            body = Data(resolve(text).utf8)
            defaultContentType = contentType
        case .urlEncoded(let fields):
            let pairs = fields.filter { $0.enabled && !$0.key.isEmpty }
                .map { "\(encodeForm(resolve($0.key)))=\(encodeForm(resolve($0.value)))" }
            body = Data(pairs.joined(separator: "&").utf8)
            defaultContentType = "application/x-www-form-urlencoded"
        case .formData(let fields):
            let boundary = "----APIPlayground\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            var data = Data()
            for field in fields where field.enabled && !field.key.isEmpty {
                data.append(Data("--\(boundary)\r\n".utf8))
                let name = resolve(field.key).replacingOccurrences(of: "\"", with: "%22")
                if field.isFile {
                    let path = (resolve(field.value) as NSString).expandingTildeInPath
                    guard let contents = FileManager.default.contents(atPath: path) else {
                        throw RequestBuildError.unreadableFile(path)
                    }
                    let filename = (path as NSString).lastPathComponent.replacingOccurrences(of: "\"", with: "%22")
                    data.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
                    data.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
                    data.append(contents)
                } else {
                    data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
                    data.append(Data(resolve(field.value).utf8))
                }
                data.append(Data("\r\n".utf8))
            }
            data.append(Data("--\(boundary)--\r\n".utf8))
            body = data
            defaultContentType = "multipart/form-data; boundary=\(boundary)"
            // A hand-written multipart Content-Type cannot know the boundary, so replace it.
            headers.removeAll { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
        case .graphQL(let queryText, let variables):
            var payload: [String: Any] = ["query": resolve(queryText)]
            let resolvedVariables = resolve(variables)
            if let object = try? JSONSerialization.jsonObject(with: Data(resolvedVariables.utf8)), object is [String: Any] {
                payload["variables"] = object
            }
            body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            defaultContentType = "application/json"
        case .file(let path):
            let expanded = (resolve(path) as NSString).expandingTildeInPath
            guard let contents = FileManager.default.contents(atPath: expanded) else {
                throw RequestBuildError.unreadableFile(expanded)
            }
            body = contents
            defaultContentType = "application/octet-stream"
        }

        if let defaultContentType, !hasHeader("Content-Type") {
            headers.append(HTTPHeader(name: "Content-Type", value: defaultContentType))
        }
        if !hasHeader("User-Agent") {
            headers.append(HTTPHeader(name: "User-Agent", value: userAgent))
        }

        return PreparedRequest(
            method: request.method.uppercased(),
            url: url,
            headers: headers,
            body: body,
            unresolved: unresolved
        )
    }

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Puts path values into a URL in place of their `:name` markers. A marker can be a whole
    /// part of the path (`/pets/:id`) or sit inside one (`/images/:seed.svg`, `/v:version/pets`,
    /// `/docs/:name:publish`), as long as the name ends there: `:id` is not found in `:idea`.
    static func fillPath(_ url: String, with values: [(key: String, value: String)]) -> String {
        guard !values.isEmpty, url.contains(":") else { return url }
        // The first value given for a name is the one used, and a longer name is tried
        // before a shorter one that starts it: `:user-id` before `:user`.
        var candidates: [(key: String, value: String)] = []
        for value in values where !candidates.contains(where: { $0.key == value.key }) { candidates.append(value) }
        candidates.sort { $0.key.count > $1.key.count }

        let end = url.firstIndex { $0 == "?" || $0 == "#" } ?? url.endIndex
        // Before the path comes the host, where a colon is a port unless it starts a part.
        var afterScheme = url.startIndex
        if let scheme = url.range(of: "://"), scheme.upperBound <= end { afterScheme = scheme.upperBound }
        let pathStart = url[afterScheme..<end].firstIndex(of: "/") ?? end

        func endsName(_ next: Character?) -> Bool {
            guard let next else { return true }
            return !(next.isLetter || next.isNumber || next == "_")
        }

        var out = ""
        var index = url.startIndex
        while index < end {
            if url[index] == ":" {
                let rest = url[url.index(after: index)..<end]
                let startsPart = index == url.startIndex || url[url.index(before: index)] == "/"
                if index >= pathStart || startsPart,
                   let found = candidates.first(where: { rest.hasPrefix($0.key) && endsName(rest.dropFirst($0.key.count).first) }) {
                    out += found.value
                    index = url.index(index, offsetBy: found.key.count + 1)
                    continue
                }
            }
            out.append(url[index])
            index = url.index(after: index)
        }
        return out + url[end...]
    }

    static func encodeQuery(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? text
    }

    /// Form encoding is the same as query encoding, except a space becomes `+`.
    static func encodeForm(_ text: String) -> String {
        encodeQuery(text).replacingOccurrences(of: "%20", with: "+")
    }
}
