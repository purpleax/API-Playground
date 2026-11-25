import Foundation

/// Version of the on-disk file format. Bump when files change shape, and add a migration.
public let currentFormatVersion = 1

// MARK: - Small value types

/// A name/value row used for headers, query parameters, path variables and form fields.
/// `id` exists only so the UI can track rows; it is not saved and is ignored by equality.
public struct KeyValue: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var key: String
    public var value: String
    public var enabled: Bool
    public var note: String?

    enum CodingKeys: String, CodingKey { case key, value, enabled, note }

    public init(key: String = "", value: String = "", enabled: Bool = true, note: String? = nil) {
        self.key = key
        self.value = value
        self.enabled = enabled
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    public static func == (a: KeyValue, b: KeyValue) -> Bool {
        a.key == b.key && a.value == b.value && a.enabled == b.enabled && a.note == b.note
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(value)
        hasher.combine(enabled)
    }
}

/// One part of a multipart form body. For a file part, `value` is the file path.
public struct FormField: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var key: String
    public var value: String
    public var isFile: Bool
    public var enabled: Bool

    enum CodingKeys: String, CodingKey { case key, value, isFile, enabled }

    public init(key: String = "", value: String = "", isFile: Bool = false, enabled: Bool = true) {
        self.key = key
        self.value = value
        self.isFile = isFile
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        isFile = try c.decodeIfPresent(Bool.self, forKey: .isFile) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public static func == (a: FormField, b: FormField) -> Bool {
        a.key == b.key && a.value == b.value && a.isFile == b.isFile && a.enabled == b.enabled
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(value)
    }
}

/// A variable in the globals, a collection or an environment.
/// A secret variable's value is kept in the secret store, never in a file.
public struct Variable: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var key: String
    public var value: String
    public var enabled: Bool
    public var secret: Bool
    /// A value used on this Mac only, in place of `value`. It is never written to the
    /// workspace, so it stays out of Git. Not used for secrets, whose value is already local.
    public var currentValue: String?

    enum CodingKeys: String, CodingKey { case key, value, enabled, secret }

    public init(key: String = "", value: String = "", enabled: Bool = true, secret: Bool = false, currentValue: String? = nil) {
        self.key = key
        self.value = value
        self.enabled = enabled
        self.secret = secret
        self.currentValue = currentValue
    }

    /// The value requests actually use.
    public var effectiveValue: String {
        if !secret, let currentValue { return currentValue }
        return value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        secret = try c.decodeIfPresent(Bool.self, forKey: .secret) ?? false
    }

    public static func == (a: Variable, b: Variable) -> Bool {
        a.key == b.key && a.value == b.value && a.enabled == b.enabled && a.secret == b.secret
            && a.currentValue == b.currentValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(value)
    }
}

// MARK: - Auth and body

public enum APIKeyPlacement: String, Codable, Sendable, CaseIterable {
    case header, query
}

public enum Auth: Codable, Hashable, Sendable {
    /// Use the auth of the nearest parent folder or collection.
    case inherit
    case none
    case basic(username: String, password: String)
    case bearer(token: String)
    case apiKey(key: String, value: String, placement: APIKeyPlacement)
}

public enum Body: Codable, Hashable, Sendable {
    case none
    /// `contentType` is used only when the request has no Content-Type header of its own.
    case raw(text: String, contentType: String?)
    case urlEncoded(fields: [KeyValue])
    case formData(fields: [FormField])
    case graphQL(query: String, variables: String)
    case file(path: String)
}

// MARK: - Requests, folders, collections

/// A response saved alongside a request (a Postman "example").
public struct SavedResponse: Codable, Hashable, Sendable {
    public var name: String
    public var status: Int
    public var headers: [KeyValue]
    public var body: String

    public init(name: String, status: Int, headers: [KeyValue] = [], body: String = "") {
        self.name = name
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public struct RequestItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var method: String
    /// URL without the query string. May contain `{{variables}}` and `:pathVariables`.
    public var url: String
    public var params: [KeyValue]
    public var pathVariables: [KeyValue]
    public var headers: [KeyValue]
    public var body: Body
    public var auth: Auth
    public var description: String
    /// Scripts are stored as written. They do not run until the script runtime exists (phase 2).
    public var preRequestScript: String
    public var testScript: String
    public var examples: [SavedResponse]
    /// Checks made against the response without writing a script.
    public var assertions: [Assertion]
    /// Values copied from the response into variables, for use by later requests.
    public var extractions: [Extraction]

    public init(
        id: UUID = UUID(),
        name: String = "New Request",
        method: String = "GET",
        url: String = "",
        params: [KeyValue] = [],
        pathVariables: [KeyValue] = [],
        headers: [KeyValue] = [],
        body: Body = .none,
        auth: Auth = .inherit,
        description: String = "",
        preRequestScript: String = "",
        testScript: String = "",
        examples: [SavedResponse] = [],
        assertions: [Assertion] = [],
        extractions: [Extraction] = []
    ) {
        self.assertions = assertions
        self.extractions = extractions
        self.id = id
        self.name = name
        self.method = method
        self.url = url
        self.params = params
        self.pathVariables = pathVariables
        self.headers = headers
        self.body = body
        self.auth = auth
        self.description = description
        self.preRequestScript = preRequestScript
        self.testScript = testScript
        self.examples = examples
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "GET"
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        params = try c.decodeIfPresent([KeyValue].self, forKey: .params) ?? []
        pathVariables = try c.decodeIfPresent([KeyValue].self, forKey: .pathVariables) ?? []
        headers = try c.decodeIfPresent([KeyValue].self, forKey: .headers) ?? []
        body = try c.decodeIfPresent(Body.self, forKey: .body) ?? .none
        auth = try c.decodeIfPresent(Auth.self, forKey: .auth) ?? .inherit
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        preRequestScript = try c.decodeIfPresent(String.self, forKey: .preRequestScript) ?? ""
        testScript = try c.decodeIfPresent(String.self, forKey: .testScript) ?? ""
        examples = try c.decodeIfPresent([SavedResponse].self, forKey: .examples) ?? []
        assertions = try c.decodeIfPresent([Assertion].self, forKey: .assertions) ?? []
        extractions = try c.decodeIfPresent([Extraction].self, forKey: .extractions) ?? []
    }
}

public struct Folder: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var description: String
    public var auth: Auth
    public var preRequestScript: String
    public var testScript: String
    public var items: [Node]

    public init(
        id: UUID = UUID(),
        name: String = "New Folder",
        description: String = "",
        auth: Auth = .inherit,
        preRequestScript: String = "",
        testScript: String = "",
        items: [Node] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.auth = auth
        self.preRequestScript = preRequestScript
        self.testScript = testScript
        self.items = items
    }
}

/// An entry in a collection's tree.
public indirect enum Node: Hashable, Identifiable, Sendable {
    case folder(Folder)
    case request(RequestItem)

    public var id: UUID {
        switch self {
        case .folder(let f): return f.id
        case .request(let r): return r.id
        }
    }

    public var name: String {
        switch self {
        case .folder(let f): return f.name
        case .request(let r): return r.name
        }
    }
}

public struct APICollection: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var description: String
    public var auth: Auth
    public var variables: [Variable]
    public var preRequestScript: String
    public var testScript: String
    /// The Postman collection this was imported from, so a later import updates it in place.
    public var postmanID: String?
    public var items: [Node]

    public init(
        id: UUID = UUID(),
        name: String = "New Collection",
        description: String = "",
        auth: Auth = .none,
        variables: [Variable] = [],
        preRequestScript: String = "",
        testScript: String = "",
        postmanID: String? = nil,
        items: [Node] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.auth = auth
        self.variables = variables
        self.preRequestScript = preRequestScript
        self.testScript = testScript
        self.postmanID = postmanID
        self.items = items
    }
}

public struct APIEnvironment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var variables: [Variable]
    public var postmanID: String?

    public init(id: UUID = UUID(), name: String = "New Environment", variables: [Variable] = [], postmanID: String? = nil) {
        self.id = id
        self.name = name
        self.variables = variables
        self.postmanID = postmanID
    }
}

// MARK: - Tree helpers

extension APICollection {
    /// Every request in the collection, in display order.
    public var allRequests: [RequestItem] {
        var out: [RequestItem] = []
        func walk(_ nodes: [Node]) {
            for node in nodes {
                switch node {
                case .request(let r): out.append(r)
                case .folder(let f): walk(f.items)
                }
            }
        }
        walk(items)
        return out
    }

    public func request(id: UUID) -> RequestItem? {
        allRequests.first { $0.id == id }
    }

    /// Replaces the request with the same id. Returns false if it is not in this collection.
    @discardableResult
    public mutating func updateRequest(_ request: RequestItem) -> Bool {
        func update(_ nodes: inout [Node]) -> Bool {
            for index in nodes.indices {
                switch nodes[index] {
                case .request(let r) where r.id == request.id:
                    nodes[index] = .request(request)
                    return true
                case .folder(var f):
                    if update(&f.items) {
                        nodes[index] = .folder(f)
                        return true
                    }
                default:
                    continue
                }
            }
            return false
        }
        return update(&items)
    }

    /// Adds a node to the folder with the given id, or to the top level when `folderID` is nil.
    @discardableResult
    public mutating func append(_ node: Node, toFolder folderID: UUID? = nil) -> Bool {
        guard let folderID else {
            items.append(node)
            return true
        }
        func add(_ nodes: inout [Node]) -> Bool {
            for index in nodes.indices {
                guard case .folder(var f) = nodes[index] else { continue }
                if f.id == folderID {
                    f.items.append(node)
                    nodes[index] = .folder(f)
                    return true
                }
                if add(&f.items) {
                    nodes[index] = .folder(f)
                    return true
                }
            }
            return false
        }
        return add(&items)
    }

    /// Removes the folder or request with the given id.
    @discardableResult
    public mutating func removeNode(id: UUID) -> Bool {
        func remove(_ nodes: inout [Node]) -> Bool {
            if let index = nodes.firstIndex(where: { $0.id == id }) {
                nodes.remove(at: index)
                return true
            }
            for index in nodes.indices {
                guard case .folder(var f) = nodes[index] else { continue }
                if remove(&f.items) {
                    nodes[index] = .folder(f)
                    return true
                }
            }
            return false
        }
        return remove(&items)
    }

    /// The folders a request sits in, outermost first.
    public func folders(containingRequest id: UUID) -> [Folder] {
        func find(_ nodes: [Node], path: [Folder]) -> [Folder]? {
            for node in nodes {
                switch node {
                case .request(let r) where r.id == id:
                    return path
                case .folder(let f):
                    if let found = find(f.items, path: path + [f]) { return found }
                default:
                    continue
                }
            }
            return nil
        }
        return find(items, path: []) ?? []
    }

    /// Every request under a folder, in order, or every request in the collection when `folderID` is nil.
    public func requests(inFolder folderID: UUID?) -> [RequestItem] {
        guard let folderID else { return allRequests }
        func find(_ nodes: [Node]) -> Folder? {
            for case .folder(let f) in nodes {
                if f.id == folderID { return f }
                if let found = find(f.items) { return found }
            }
            return nil
        }
        guard let folder = find(items) else { return [] }
        return APICollection(items: folder.items).allRequests
    }

    /// Carries ids over from an earlier version of this collection, matching folders and
    /// requests by their position in the tree and their name. Used when a Postman collection
    /// is imported again, so each request keeps its history.
    public func adoptingIdentities(from old: APICollection) -> APICollection {
        var known: [String: UUID] = [:]
        func collect(_ nodes: [Node], path: String) {
            var seen: [String: Int] = [:]
            for node in nodes {
                let kind = { if case .folder = node { return "F" } else { return "R" } }()
                let base = "\(path)/\(kind):\(node.name)"
                seen[base, default: 0] += 1
                let key = "\(base)#\(seen[base]!)"
                known[key] = node.id
                if case .folder(let folder) = node { collect(folder.items, path: key) }
            }
        }
        collect(old.items, path: "")

        func adopt(_ nodes: [Node], path: String) -> [Node] {
            var seen: [String: Int] = [:]
            return nodes.map { node in
                let kind = { if case .folder = node { return "F" } else { return "R" } }()
                let base = "\(path)/\(kind):\(node.name)"
                seen[base, default: 0] += 1
                let key = "\(base)#\(seen[base]!)"
                switch node {
                case .request(var request):
                    if let id = known[key] { request.id = id }
                    return .request(request)
                case .folder(var folder):
                    if let id = known[key] { folder.id = id }
                    folder.items = adopt(folder.items, path: key)
                    return .folder(folder)
                }
            }
        }

        var copy = self
        copy.id = old.id
        copy.items = adopt(items, path: "")
        return copy
    }

    /// The auth a request actually uses: its own, or the nearest parent's that is not "inherit".
    public func effectiveAuth(forRequest id: UUID) -> Auth {
        func find(_ nodes: [Node], inherited: Auth) -> Auth? {
            for node in nodes {
                switch node {
                case .request(let r) where r.id == id:
                    return r.auth == .inherit ? inherited : r.auth
                case .folder(let f):
                    let next = f.auth == .inherit ? inherited : f.auth
                    if let found = find(f.items, inherited: next) { return found }
                default:
                    continue
                }
            }
            return nil
        }
        let top: Auth = auth == .inherit ? .none : auth
        return find(items, inherited: top) ?? .none
    }
}
