import Foundation

public struct OpenAPIParameter: Equatable, Sendable {
    public var name: String
    /// "query", "path", "header" or "cookie".
    public var location: String
    public var required: Bool
    public var description: String
    public var example: String
}

public struct OpenAPIBody: Equatable, Sendable {
    public var contentType: String
    public var example: String
}

public struct OpenAPIResponse: Equatable, Sendable {
    /// "200", "404", "default" and so on, as written in the spec.
    public var status: String
    public var description: String
    public var contentType: String?
    public var example: String?
}

public struct OpenAPIOperation: Equatable, Identifiable, Sendable {
    public var method: String
    public var path: String
    public var operationID: String?
    public var summary: String
    public var description: String
    public var tags: [String]
    public var deprecated: Bool
    public var parameters: [OpenAPIParameter]
    public var body: OpenAPIBody?
    public var responses: [OpenAPIResponse]
    /// Nil when the operation uses the document's security; empty when it has none.
    public var security: [String]?
    /// 1-based line of the operation in the spec's text.
    public var line: Int

    public var id: String { "\(method) \(path)" }

    /// What the route is called in a list: its summary, else its operation id, else "GET /pets".
    public var title: String {
        if !summary.isEmpty { return summary }
        if let operationID, !operationID.isEmpty { return operationID }
        return id
    }

    /// The first success response, which a generated test expects.
    public var successStatus: Int? {
        responses.compactMap { Int($0.status) }.filter { (200..<300).contains($0) }.min()
    }
}

public struct OpenAPIError: Error, LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
}

/// An OpenAPI 3.x or Swagger 2.0 document, read far enough to list, send and mock its routes.
public struct OpenAPIDocument: Sendable {
    public var root: SpecNode
    /// "3.0.3", "3.1.0", "2.0" and so on.
    public var specVersion: String
    public var title: String
    public var version: String
    public var description: String
    /// Where the API is served, as full addresses with no trailing slash. A server the spec
    /// gives as a path alone ("/" or "/v1") stands on `placeholderServer`.
    public var servers: [String]
    /// True when the spec does not say which host serves the API: it lists no servers, or its
    /// first is a path alone, which means "wherever this document was fetched from". A file
    /// on disk cannot answer that, so the address is for the person using it to fill in.
    public var needsHost = false
    public var tags: [String]
    public var operations: [OpenAPIOperation]
    /// The scheme names in the document's own `security`, and what each scheme is.
    var securitySchemes: [String: SpecNode] = [:]
    var defaultSecurity: [String] = []

    public var isSwagger2: Bool { specVersion.hasPrefix("2") }

    static let methods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

    /// The host a request is sent to when the spec names none.
    public static let placeholderServer = "http://localhost:8080"

    /// A server's address in the form requests are built on, and whether the spec gave it
    /// as a path alone. `/` becomes the placeholder host, and `https://api.example.com/v1/`
    /// loses its last slash, so that adding `/pets` never makes `//pets`.
    static func address(ofServer url: String) -> (address: String, isPath: Bool) {
        var url = url.trimmingCharacters(in: .whitespaces)
        var isPath = false
        if url.hasPrefix("//") {
            // The same scheme as the document's: assume the usual one.
            url = "https:" + url
        } else if url.isEmpty || url.hasPrefix("/") {
            isPath = true
            url = placeholderServer + url
        }
        while url.hasSuffix("/"), !url.hasSuffix("://") { url.removeLast() }
        return (url, isPath)
    }

    public init(text: String) throws {
        let parsed: SpecNode
        do {
            parsed = try SpecParser.parse(text).root
        } catch let error as SpecParseError {
            throw OpenAPIError(message: error.localizedDescription)
        }
        try self.init(root: parsed)
    }

    public init(root: SpecNode) throws {
        guard root.isMap else { throw OpenAPIError(message: "This is not an OpenAPI document: it should start with “openapi:”.") }
        self.root = root
        if let version = root["openapi"]?.string {
            specVersion = version
        } else if let version = root["swagger"]?.string {
            specVersion = version
        } else {
            throw OpenAPIError(message: "This is not an OpenAPI document: it has no “openapi” or “swagger” version.")
        }
        let info = root["info"]
        title = info?["title"]?.string ?? "Untitled API"
        version = info?["version"]?.string ?? ""
        description = info?["description"]?.string ?? ""
        tags = (root["tags"]?.items ?? []).compactMap { $0["name"]?.string }
        servers = []
        operations = []

        if specVersion.hasPrefix("2") {
            let host = root["host"]?.string ?? ""
            var base = root["basePath"]?.string ?? ""
            if base == "/" { base = "" }
            if !host.isEmpty {
                let scheme = root["schemes"]?.items.first?.string ?? "https"
                servers = [Self.address(ofServer: "\(scheme)://\(host)\(base)").address]
            } else if base.hasPrefix("/") {
                // A base path with no host is served from wherever the document was.
                servers = [Self.address(ofServer: base).address]
                needsHost = true
            }
            for entry in root["securityDefinitions"]?.entries ?? [] { securitySchemes[entry.key] = entry.node }
        } else {
            let listed = (root["servers"]?.items ?? []).compactMap { server -> (address: String, isPath: Bool)? in
                guard var url = server["url"]?.string else { return nil }
                // Fill in each {variable} with its default.
                for variable in server["variables"]?.entries ?? [] {
                    if let value = variable.node["default"]?.string {
                        url = url.replacingOccurrences(of: "{\(variable.key)}", with: value)
                    }
                }
                return Self.address(ofServer: url)
            }
            servers = listed.map(\.address)
            needsHost = listed.first?.isPath ?? false
            for entry in root["components"]?["securitySchemes"]?.entries ?? [] {
                securitySchemes[entry.key] = resolve(entry.node)
            }
        }
        if servers.isEmpty { needsHost = true }
        defaultSecurity = Self.schemeNames(root["security"]) ?? []

        for pathEntry in root["paths"]?.entries ?? [] where pathEntry.key.hasPrefix("/") {
            let item = resolve(pathEntry.node)
            let shared = item["parameters"]?.items ?? []
            for operationEntry in item.entries where Self.methods.contains(operationEntry.key.lowercased()) {
                operations.append(operation(
                    method: operationEntry.key.uppercased(), path: pathEntry.key,
                    node: operationEntry.node, line: operationEntry.line, sharedParameters: shared
                ))
            }
        }
    }

    private static func schemeNames(_ security: SpecNode?) -> [String]? {
        guard let security, security.isList else { return nil }
        return security.items.first?.entries.map(\.key) ?? []
    }

    // MARK: References

    /// Follows a local `$ref` (`#/components/schemas/Pet`) to what it points at.
    /// A reference to another file, or to nothing, is returned as it is.
    public func resolve(_ node: SpecNode, depth: Int = 0) -> SpecNode {
        guard depth < 20, let ref = node["$ref"]?.string, let target = lookup(ref) else { return node }
        return resolve(target, depth: depth + 1)
    }

    public func lookup(_ ref: String) -> SpecNode? {
        guard ref.hasPrefix("#/") else { return ref == "#" ? root : nil }
        let path = ref.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false).map {
            ($0.removingPercentEncoding ?? String($0))
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
        }
        return root.at(path)
    }

    // MARK: Operations

    private func operation(method: String, path: String, node: SpecNode, line: Int, sharedParameters: [SpecNode]) -> OpenAPIOperation {
        var parameters: [OpenAPIParameter] = []
        var body: OpenAPIBody?
        var formFields: [SpecNode] = []
        let consumes = (node["consumes"] ?? root["consumes"])?.items.first?.string ?? "application/json"
        let produces = (node["produces"] ?? root["produces"])?.items.first?.string ?? "application/json"

        // An operation's own parameter replaces a path-level one with the same name and place.
        var combined: [SpecNode] = []
        for raw in sharedParameters + (node["parameters"]?.items ?? []) {
            let parameter = resolve(raw)
            let key = "\(parameter["in"]?.string ?? "")/\(parameter["name"]?.string ?? "")"
            combined.removeAll { "\($0["in"]?.string ?? "")/\($0["name"]?.string ?? "")" == key }
            combined.append(parameter)
        }
        for parameter in combined {
            let location = parameter["in"]?.string ?? ""
            let name = parameter["name"]?.string ?? ""
            switch location {
            case "body":
                // Swagger 2 puts the request body among the parameters.
                let sample = parameter["schema"].map { self.sample($0, forRequest: true) } ?? SpecNode(.null)
                body = OpenAPIBody(contentType: consumes, example: Self.text(sample, contentType: consumes))
            case "formData":
                formFields.append(parameter)
            default:
                let schema = parameter["schema"] ?? parameter
                var example = parameter["example"] ?? parameter["examples"]?.entries.first.map { resolve($0.node)["value"] ?? SpecNode(.null) }
                if example == nil || example?.isNull == true { example = self.sample(schema, forRequest: true) }
                parameters.append(OpenAPIParameter(
                    name: name, location: location,
                    required: parameter["required"]?.bool ?? (location == "path"),
                    description: parameter["description"]?.string ?? "",
                    example: Self.plain(example ?? SpecNode(.null))
                ))
            }
        }
        if !formFields.isEmpty {
            let pairs = formFields.map { field -> String in
                let value = Self.plain(field["default"] ?? self.sample(field, forRequest: true))
                return "\(RequestBuilder.encodeForm(field["name"]?.string ?? ""))=\(RequestBuilder.encodeForm(value))"
            }
            body = OpenAPIBody(contentType: "application/x-www-form-urlencoded", example: pairs.joined(separator: "&"))
        }
        if let requestBody = node["requestBody"].map({ resolve($0) }), let media = Self.preferredMedia(requestBody["content"]) {
            body = OpenAPIBody(contentType: media.type, example: example(of: media.node, contentType: media.type, forRequest: true) ?? "")
        }

        var responses: [OpenAPIResponse] = []
        for entry in node["responses"]?.entries ?? [] {
            let response = resolve(entry.node)
            var contentType: String?
            var example: String?
            if let media = Self.preferredMedia(response["content"]) {
                contentType = media.type
                example = self.example(of: media.node, contentType: media.type, forRequest: false)
            } else if isSwagger2 {
                if let given = response["examples"]?.entries.first {
                    contentType = given.key
                    example = Self.text(given.node, contentType: given.key)
                } else if let schema = response["schema"] {
                    contentType = produces
                    example = Self.text(sample(schema, forRequest: false), contentType: produces)
                }
            }
            responses.append(OpenAPIResponse(
                status: entry.key, description: response["description"]?.string ?? "",
                contentType: contentType, example: example
            ))
        }

        return OpenAPIOperation(
            method: method, path: path,
            operationID: node["operationId"]?.string,
            summary: node["summary"]?.string ?? "",
            description: node["description"]?.string ?? "",
            tags: (node["tags"]?.items ?? []).compactMap(\.string),
            deprecated: node["deprecated"]?.bool ?? false,
            parameters: parameters, body: body, responses: responses,
            security: Self.schemeNames(node["security"]),
            line: line
        )
    }

    /// The media type to show for a body: JSON when there is one, otherwise the first listed.
    private static func preferredMedia(_ content: SpecNode?) -> (type: String, node: SpecNode)? {
        guard let entries = content?.entries, !entries.isEmpty else { return nil }
        let chosen = entries.first { $0.key.lowercased().contains("json") } ?? entries[0]
        return (chosen.key, chosen.node)
    }

    private func example(of media: SpecNode, contentType: String, forRequest: Bool) -> String? {
        if let example = media["example"] { return Self.text(example, contentType: contentType) }
        if let first = media["examples"]?.entries.first, let value = resolve(first.node)["value"] {
            return Self.text(value, contentType: contentType)
        }
        if let schema = media["schema"] { return Self.text(sample(schema, forRequest: forRequest), contentType: contentType) }
        return nil
    }

    /// A value as body text: JSON for structured values, and as it is for plain text.
    static func text(_ node: SpecNode, contentType: String) -> String {
        if case .string(let text) = node.value, !contentType.lowercased().contains("json") { return text }
        return node.jsonText()
    }

    /// A value as it would be typed into a parameter field.
    static func plain(_ node: SpecNode) -> String {
        switch node.value {
        case .null: return ""
        case .list(let items): return items.map(plain).joined(separator: ",")
        case .map: return node.jsonText(pretty: false)
        default: return node.string ?? ""
        }
    }

    // MARK: Example values from schemas

    /// Makes an example value that fits a schema, preferring the examples and defaults it gives.
    public func sample(_ schema: SpecNode, forRequest: Bool, depth: Int = 0) -> SpecNode {
        let schema = resolve(schema)
        if let example = schema["example"] { return example }
        if let first = schema["examples"]?.items.first { return first }
        if let fallback = schema["default"] { return fallback }
        if let fixed = schema["const"] { return fixed }
        if let first = schema["enum"]?.items.first { return first }
        guard depth < 8 else { return SpecNode(.null) }

        if let parts = schema["allOf"]?.items, !parts.isEmpty {
            var entries: [SpecEntry] = []
            var other: SpecNode?
            for part in parts {
                let value = sample(part, forRequest: forRequest, depth: depth + 1)
                if value.isMap {
                    for entry in value.entries where !entries.contains(where: { $0.key == entry.key }) { entries.append(entry) }
                } else {
                    other = other ?? value
                }
            }
            if entries.isEmpty, let other { return other }
            let own = properties(of: schema, forRequest: forRequest, depth: depth)
            for entry in own where !entries.contains(where: { $0.key == entry.key }) { entries.append(entry) }
            return SpecNode(.map(entries))
        }
        if let first = (schema["oneOf"] ?? schema["anyOf"])?.items.first {
            return sample(first, forRequest: forRequest, depth: depth + 1)
        }

        var type = schema["type"]?.string
        if let types = schema["type"]?.items, !types.isEmpty {
            type = types.compactMap(\.string).first { $0 != "null" }
        }
        if type == nil {
            if schema["properties"] != nil || schema["additionalProperties"] != nil { type = "object" }
            if schema["items"] != nil { type = "array" }
        }
        switch type {
        case "object":
            var entries = properties(of: schema, forRequest: forRequest, depth: depth)
            if entries.isEmpty, let extra = schema["additionalProperties"], extra.isMap {
                entries.append(SpecEntry(key: "key", node: sample(extra, forRequest: forRequest, depth: depth + 1)))
            }
            return SpecNode(.map(entries))
        case "array":
            guard let items = schema["items"] else { return SpecNode(.list([])) }
            return SpecNode(.list([sample(items, forRequest: forRequest, depth: depth + 1)]))
        case "integer":
            let value = schema["minimum"]?.double ?? 0
            return SpecNode(.number(value, String(Int(value))))
        case "number":
            let value = schema["minimum"]?.double ?? 0
            return SpecNode(.number(value, value == value.rounded() ? String(Int(value)) : String(value)))
        case "boolean":
            return SpecNode(.bool(true))
        case "string":
            switch schema["format"]?.string {
            case "date-time": return SpecNode(.string("2024-01-01T00:00:00Z"))
            case "date": return SpecNode(.string("2024-01-01"))
            case "uuid": return SpecNode(.string("3fa85f64-5717-4562-b3fc-2c963f66afa6"))
            case "email": return SpecNode(.string("user@example.com"))
            case "uri", "url": return SpecNode(.string("https://example.com"))
            case "hostname": return SpecNode(.string("example.com"))
            case "ipv4": return SpecNode(.string("192.0.2.1"))
            case "byte": return SpecNode(.string("c3RyaW5n"))
            default: return SpecNode(.string("string"))
            }
        default:
            return SpecNode(.null)
        }
    }

    private func properties(of schema: SpecNode, forRequest: Bool, depth: Int) -> [SpecEntry] {
        (schema["properties"]?.entries ?? []).compactMap { entry in
            let property = resolve(entry.node)
            // A read-only value is not sent, and a write-only one is not returned.
            if forRequest, property["readOnly"]?.bool == true { return nil }
            if !forRequest, property["writeOnly"]?.bool == true { return nil }
            return SpecEntry(key: entry.key, node: sample(property, forRequest: forRequest, depth: depth + 1))
        }
    }

    // MARK: Making a collection

    /// The variable generated requests start with.
    public static let baseVariable = "baseUrl"

    /// A request that calls one operation, with example values filled in.
    public func request(for operation: OpenAPIOperation) -> RequestItem {
        // {petId} in a spec is :petId in a request URL.
        var path = operation.path
        var pathVariables: [KeyValue] = []
        for parameter in operation.parameters where parameter.location == "path" {
            path = path.replacingOccurrences(of: "{\(parameter.name)}", with: ":\(parameter.name)")
            pathVariables.append(KeyValue(key: parameter.name, value: parameter.example, note: parameter.description.nilIfEmpty))
        }
        // Path parts the spec forgot to declare still need a value.
        while let open = path.firstIndex(of: "{"), let close = path[open...].firstIndex(of: "}") {
            let name = String(path[path.index(after: open)..<close])
            path.replaceSubrange(open...close, with: ":\(name)")
            pathVariables.append(KeyValue(key: name, value: ""))
        }

        let params = operation.parameters.filter { $0.location == "query" }.map {
            KeyValue(key: $0.name, value: $0.example, enabled: $0.required, note: $0.description.nilIfEmpty)
        }
        var headers = operation.parameters.filter { $0.location == "header" }.map {
            KeyValue(key: $0.name, value: $0.example, enabled: $0.required, note: $0.description.nilIfEmpty)
        }
        var body = Body.none
        if let given = operation.body {
            headers.insert(KeyValue(key: "Content-Type", value: given.contentType), at: 0)
            body = .raw(text: given.example, contentType: given.contentType)
        }
        if let accept = operation.responses.first(where: { $0.contentType != nil })?.contentType {
            headers.append(KeyValue(key: "Accept", value: accept))
        }

        // Each documented response becomes an example, which is what a mock server replies with.
        let examples = operation.responses.compactMap { response -> SavedResponse? in
            guard let status = Int(response.status) ?? (response.status == "default" && operation.responses.count == 1 ? 200 : nil) else { return nil }
            let name = response.description.isEmpty ? response.status : "\(response.status) \(response.description)"
            return SavedResponse(
                name: String(name.prefix(80)), status: status,
                headers: response.contentType.map { [KeyValue(key: "Content-Type", value: $0)] } ?? [],
                body: response.example ?? ""
            )
        }.sorted { ($0.status / 100 == 2 ? 0 : 1, $0.status) < ($1.status / 100 == 2 ? 0 : 1, $1.status) }

        var assertions: [Assertion] = []
        if let status = operation.successStatus {
            assertions.append(Assertion(source: ValueSource(kind: .status), op: .equals, expected: String(status)))
        }

        var auth = Auth.inherit
        if let own = operation.security {
            auth = own.isEmpty ? .none : (Self.auth(for: own, schemes: securitySchemes) ?? .inherit)
        }

        return RequestItem(
            name: operation.title, method: operation.method,
            url: "{{\(Self.baseVariable)}}\(path)",
            params: params, pathVariables: pathVariables, headers: headers, body: body, auth: auth,
            description: operation.description.isEmpty && operation.deprecated ? "Deprecated." : operation.description,
            examples: examples, assertions: assertions
        )
    }

    /// The auth for the first scheme the app can send, with variables standing in for the credentials.
    private static func auth(for names: [String], schemes: [String: SpecNode]) -> Auth? {
        for name in names {
            guard let scheme = schemes[name] else { continue }
            switch scheme["type"]?.string?.lowercased() {
            case "http":
                if scheme["scheme"]?.string?.lowercased() == "basic" { return .basic(username: "{{username}}", password: "{{password}}") }
                return .bearer(token: "{{bearerToken}}")
            case "basic":
                return .basic(username: "{{username}}", password: "{{password}}")
            case "apikey":
                guard let key = scheme["name"]?.string else { continue }
                let placement: APIKeyPlacement = scheme["in"]?.string == "query" ? .query : .header
                return .apiKey(key: key, value: "{{apiKey}}", placement: placement)
            case "oauth2", "openidconnect":
                return .bearer(token: "{{bearerToken}}")
            default:
                continue
            }
        }
        return nil
    }

    /// A collection with a folder for each tag and a request for each operation.
    /// - Parameter specFile: Recorded on the collection, so generating again updates it.
    public func collection(specFile: String? = nil) -> APICollection {
        var order = tags
        var byTag: [String: [Node]] = [:]
        var loose: [Node] = []
        for operation in operations {
            let node = Node.request(request(for: operation))
            if let tag = operation.tags.first {
                if !order.contains(tag) { order.append(tag) }
                byTag[tag, default: []].append(node)
            } else {
                loose.append(node)
            }
        }
        let folders = order.compactMap { tag -> Node? in
            guard let items = byTag[tag] else { return nil }
            return .folder(Folder(name: tag, items: items))
        }

        var variables = [Variable(key: Self.baseVariable, value: servers.first ?? Self.placeholderServer)]
        let auth = Self.auth(for: defaultSecurity, schemes: securitySchemes) ?? .none
        var needed: [String] = []
        func note(_ auth: Auth) {
            switch auth {
            case .basic: needed += ["username", "password"]
            case .bearer: needed.append("bearerToken")
            case .apiKey: needed.append("apiKey")
            default: break
            }
        }
        note(auth)
        for operation in operations { note(request(for: operation).auth) }
        for name in needed where !variables.contains(where: { $0.key == name }) {
            variables.append(Variable(key: name, value: ""))
        }

        var collection = APICollection(
            name: title, description: description, auth: auth, variables: variables, items: loose + folders
        )
        collection.specFile = specFile
        return collection
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
