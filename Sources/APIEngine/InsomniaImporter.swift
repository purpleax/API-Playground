import Foundation

public enum InsomniaImportError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case notInsomnia
    case nothingToImport(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let why): return "The file could not be read. \(why)"
        case .notInsomnia: return "The file is not an Insomnia export."
        case .nothingToImport(let what): return what
        }
    }
}

/// Reads Insomnia exports: format 4 (JSON or YAML, one file holding every workspace) and
/// format 5 (YAML, one file for each collection, design document or set of environments).
public enum InsomniaImporter {

    public static func recognises(_ root: SpecNode) -> Bool {
        if root["_type"]?.string == "export" { return true }
        if root["__export_format"] != nil, root["resources"] != nil { return true }
        if let type = root["type"]?.string, type.contains(".insomnia.rest/") || type.contains(".insomnia/") { return true }
        return false
    }

    public static func importDocuments(data: Data) throws -> [ImportedDocument] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw InsomniaImportError.unreadable("It is not text.")
        }
        let root: SpecNode
        do {
            root = try SpecParser.parse(text).root
        } catch {
            throw InsomniaImportError.unreadable(error.localizedDescription)
        }
        return try importDocuments(root: root)
    }

    public static func importDocuments(root: SpecNode) throws -> [ImportedDocument] {
        guard recognises(root) else { throw InsomniaImportError.notInsomnia }
        var documents: [ImportedDocument]
        if let type = root["type"]?.string {
            documents = importV5(root, type: type)
            if documents.isEmpty {
                let kind = type.components(separatedBy: ".insomnia").first ?? type
                throw InsomniaImportError.nothingToImport(
                    "This Insomnia file holds a \(kind) with nothing that can be imported. Collections, design documents and environments can be."
                )
            }
        } else {
            documents = importV4(root)
            if documents.isEmpty {
                throw InsomniaImportError.nothingToImport("The Insomnia export has no requests, environments or specs in it.")
            }
        }
        return documents
    }

    // MARK: Format 4

    private static let itemTypes: Set<String> = ["request", "request_group", "grpc_request", "websocket_request"]

    private static func importV4(_ root: SpecNode) -> [ImportedDocument] {
        let resources = (root["resources"]?.items ?? []).filter(\.isMap)
        func type(_ node: SpecNode) -> String { node["_type"]?.string ?? "" }

        var children: [String: [SpecNode]] = [:]
        var names: [String: String] = [:]
        var known = Set<String>()
        for resource in resources {
            let id = resource["_id"]?.string ?? ""
            known.insert(id)
            if let name = resource["name"]?.string { names[id] = name }
            children[resource["parentId"]?.string ?? "", default: []].append(resource)
        }

        struct Workspace {
            var id: String?
            var name: String
            var description: String
            var children: [SpecNode]
        }
        var workspaces = resources.filter { type($0) == "workspace" }.map { node in
            Workspace(
                id: node["_id"]?.string, name: node["name"]?.string ?? "Insomnia Import",
                description: node["description"]?.string ?? "", children: children[node["_id"]?.string ?? ""] ?? []
            )
        }
        // An export of one folder or a few requests has no workspace: gather what has no parent in the file.
        let loose = resources.filter { type($0) != "workspace" && !known.contains($0["parentId"]?.string ?? "") }
        if loose.contains(where: { itemTypes.contains(type($0)) }) || workspaces.isEmpty {
            workspaces.append(Workspace(id: nil, name: "Insomnia Import", description: "", children: loose))
        }

        var documents: [ImportedDocument] = []
        var environmentOwners: [(index: Int, workspace: String)] = []
        for workspace in workspaces {
            let session = Session(names: names)
            func build(_ nodes: [SpecNode], path: String, inherited: [KeyValue], depth: Int) -> [Node] {
                guard depth < 64 else { return [] }
                return sorted(nodes.filter { itemTypes.contains(type($0)) }).map { node in
                    if type(node) == "request_group" {
                        return session.folder(node, path: path, inherited: inherited) { folderPath, headers in
                            build(children[node["_id"]?.string ?? ""] ?? [], path: folderPath, inherited: headers, depth: depth + 1)
                        }
                    }
                    return .request(session.request(node, path: path, inherited: inherited, isGRPC: type(node) == "grpc_request"))
                }
            }
            let items = build(workspace.children, path: workspace.name, inherited: [], depth: 0)

            // The base environment's values apply whichever environment is chosen, like collection variables.
            var variables: [Variable] = []
            var environments: [APIEnvironment] = []
            for base in workspace.children where type(base) == "environment" {
                variables.append(contentsOf: session.variables(base))
                for sub in sorted(children[base["_id"]?.string ?? ""] ?? []) where type(sub) == "environment" {
                    environments.append(APIEnvironment(
                        name: sub["name"]?.string ?? "Environment", variables: session.variables(sub), postmanID: sub["_id"]?.string
                    ))
                }
            }

            if !items.isEmpty {
                var collection = APICollection(
                    name: workspace.name, description: workspace.description,
                    variables: session.merged(variables), postmanID: workspace.id, items: items
                )
                session.finish(&collection)
                documents.append(.collection(collection, session.report))
            } else if !variables.isEmpty {
                // Nothing to hang the base values on, so keep them as an environment of their own.
                environments.insert(APIEnvironment(name: "\(workspace.name) Base", variables: variables), at: 0)
            }
            for environment in environments {
                var report = ImportReport()
                report.variables = environment.variables.count
                environmentOwners.append((documents.count, workspace.name))
                documents.append(.environment(environment, isGlobals: false, report))
            }
            var settings = ImportedSettings(source: workspace.name)
            for jar in workspace.children where type(jar) == "cookie_jar" {
                settings.cookies += cookies(in: jar)
            }
            if !settings.isEmpty { documents.append(.settings(settings)) }
            for spec in workspace.children where type(spec) == "api_spec" {
                if let text = spec["contents"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    documents.append(.spec(name: spec["fileName"]?.string ?? workspace.name, text: text))
                }
            }
        }

        // Two workspaces often both have a "Production". Tell them apart by workspace.
        var counts: [String: Int] = [:]
        for owner in environmentOwners {
            if case .environment(let environment, _, _) = documents[owner.index] { counts[environment.name, default: 0] += 1 }
        }
        for owner in environmentOwners {
            guard case .environment(var environment, let isGlobals, let report) = documents[owner.index],
                  counts[environment.name, default: 0] > 1 else { continue }
            environment.name = "\(owner.workspace) – \(environment.name)"
            documents[owner.index] = .environment(environment, isGlobals: isGlobals, report)
        }
        return documents
    }

    // MARK: Format 5

    /// The cookies in an Insomnia cookie jar, which are written the way the tough-cookie library saves them.
    static func cookies(in jar: SpecNode) -> [Cookie] {
        (jar["cookies"]?.items ?? []).compactMap { node in
            guard let name = node["key"]?.string, !name.isEmpty, let domain = node["domain"]?.string, !domain.isEmpty else { return nil }
            var expires: Date?
            if let text = node["expires"]?.string, text != "Infinity" {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                expires = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            }
            return Cookie(
                name: name, value: node["value"]?.string ?? "",
                domain: domain.hasPrefix(".") ? String(domain.dropFirst()) : domain,
                hostOnly: node["hostOnly"]?.bool ?? !domain.hasPrefix("."),
                path: node["path"]?.string ?? "/", expires: expires,
                secure: node["secure"]?.bool ?? false, httpOnly: node["httpOnly"]?.bool ?? false
            )
        }
    }

    private static func importV5(_ root: SpecNode, type: String) -> [ImportedDocument] {
        let name = root["name"]?.string ?? "Insomnia Import"
        var names: [String: String] = [:]
        func collect(_ nodes: [SpecNode], depth: Int) {
            guard depth < 64 else { return }
            for node in nodes {
                if let id = node.at(["meta", "id"])?.string, let name = node["name"]?.string { names[id] = name }
                collect(node["children"]?.items ?? [], depth: depth + 1)
            }
        }
        collect(root["collection"]?.items ?? [], depth: 0)

        let session = Session(names: names)
        func build(_ nodes: [SpecNode], path: String, inherited: [KeyValue], depth: Int) -> [Node] {
            guard depth < 64 else { return [] }
            return sorted(nodes.filter(\.isMap)).map { node in
                // A folder is what has no method or address; an empty one has no children listed.
                let isGRPC = node["reflectionApi"] != nil || node["protoMethodName"] != nil || node["protoFileId"] != nil
                if node["children"] != nil || (node["method"] == nil && node["url"] == nil && !isGRPC) {
                    return session.folder(node, path: path, inherited: inherited) { folderPath, headers in
                        build(node["children"]?.items ?? [], path: folderPath, inherited: headers, depth: depth + 1)
                    }
                }
                return .request(session.request(node, path: path, inherited: inherited, isGRPC: isGRPC))
            }
        }
        // The collection itself can set headers, auth and scripts for everything in it.
        let top = session.settings(root, path: name)
        let items = build(root["collection"]?.items ?? [], path: name, inherited: top.headers, depth: 0)

        var documents: [ImportedDocument] = []
        var variables: [Variable] = []
        var environments: [APIEnvironment] = []
        if let base = root["environments"], base.isMap {
            variables = session.variables(base)
            for sub in base["subEnvironments"]?.items ?? [] where sub.isMap {
                environments.append(APIEnvironment(
                    name: sub["name"]?.string ?? "Environment", variables: session.variables(sub),
                    postmanID: sub.at(["meta", "id"])?.string
                ))
            }
        }
        if !items.isEmpty {
            var collection = APICollection(
                name: name, description: root.at(["meta", "description"])?.string ?? "",
                auth: top.auth == .inherit ? .none : top.auth,
                variables: session.merged(variables), preRequestScript: top.pre, testScript: top.post,
                postmanID: root.at(["meta", "id"])?.string, items: items
            )
            session.finish(&collection)
            documents.append(.collection(collection, session.report))
        } else if !variables.isEmpty {
            let baseName = type.hasPrefix("environment") ? name : "\(name) Base"
            environments.insert(APIEnvironment(name: baseName, variables: variables, postmanID: root.at(["environments", "meta", "id"])?.string), at: 0)
        }
        for environment in environments {
            var report = ImportReport()
            report.variables = environment.variables.count
            documents.append(.environment(environment, isGlobals: false, report))
        }
        if let contents = root.at(["spec", "contents"]) {
            // The spec is written either as text or straight into the file as a tree.
            let text = contents.isMap ? contents.jsonText() : (contents.string ?? "")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !(contents.isMap && contents.entries.isEmpty) {
                documents.append(.spec(name: name, text: text))
            }
        }
        var settings = ImportedSettings(source: root["name"]?.string ?? "Insomnia Import")
        if let jar = root["cookieJar"] { settings.cookies = cookies(in: jar) }
        if !settings.isEmpty { documents.append(.settings(settings)) }
        return documents
    }

    /// Insomnia orders a folder's contents by sort key, lowest first.
    private static func sorted(_ nodes: [SpecNode]) -> [SpecNode] {
        func key(_ node: SpecNode) -> Double {
            node["metaSortKey"]?.double ?? node.at(["meta", "sortKey"])?.double ?? 0
        }
        return nodes.enumerated().sorted { a, b in
            let (x, y) = (key(a.element), key(b.element))
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
    }
}

// MARK: - One collection's import

/// Carries what is learned while one workspace is read: its report, and the links between
/// requests that Insomnia writes as template tags.
private final class Session {
    var report = ImportReport()
    /// Insomnia's id for each request, and its name.
    let names: [String: String]
    private var ids: [String: UUID] = [:]
    private var built = Set<String>()
    private var chained: [String: [Extraction]] = [:]
    private var unsupportedTags: [String: Int] = [:]
    private var copiedHeaders = 0
    private var folderVariables: [Variable] = []
    private var foldersWithVariables: [String] = []

    init(names: [String: String]) {
        self.names = names
    }

    private func warn(_ text: String) {
        if !report.warnings.contains(text) { report.warnings.append(text) }
    }

    private func uuid(for id: String) -> UUID {
        if let known = ids[id] { return known }
        let new = UUID()
        ids[id] = new
        return new
    }

    private func text(_ node: SpecNode?) -> String {
        guard let node else { return "" }
        if let string = node.string { return convert(string) }
        if node.isNull { return "" }
        return convert(node.jsonText(pretty: false))
    }

    // MARK: Folders and requests

    func folder(_ node: SpecNode, path: String, inherited: [KeyValue], children: (String, [KeyValue]) -> [Node]) -> Node {
        report.folders += 1
        let name = node["name"]?.string ?? "Untitled"
        let folderPath = "\(path) / \(name)"
        let scripts = scripts(node)
        // Folders here have no headers or variables of their own, so both are handed down.
        let headers = inherited + rows(node["headers"])
        if let environment = node["environment"], !environment.entries.isEmpty {
            folderVariables.append(contentsOf: flatten(environment))
            foldersWithVariables.append(name)
        } else if let pairs = node["kvPairData"]?.items, !pairs.isEmpty {
            folderVariables.append(contentsOf: pairs.compactMap { row in
                guard let key = row["name"]?.string, !key.isEmpty else { return nil }
                return Variable(key: key, value: text(row["value"]), enabled: row["enabled"]?.bool != false, secret: row["type"]?.string == "secret")
            })
            foldersWithVariables.append(name)
        }
        return .folder(Folder(
            name: name,
            description: node["description"]?.string ?? node.at(["meta", "description"])?.string ?? "",
            auth: auth(node["authentication"], path: folderPath),
            preRequestScript: scripts.pre,
            testScript: scripts.post,
            items: children(folderPath, headers)
        ))
    }

    /// The headers, auth and scripts set on a collection as a whole.
    func settings(_ node: SpecNode, path: String) -> (headers: [KeyValue], auth: Auth, pre: String, post: String) {
        let scripts = scripts(node)
        return (rows(node["headers"]), auth(node["authentication"], path: path), scripts.pre, scripts.post)
    }

    func request(_ node: SpecNode, path: String, inherited: [KeyValue], isGRPC: Bool) -> RequestItem {
        report.requests += 1
        let name = node["name"]?.string ?? "Untitled"
        let requestPath = "\(path) / \(name)"
        var request = RequestItem(name: name)
        if let id = node["_id"]?.string ?? node.at(["meta", "id"])?.string {
            request.id = uuid(for: id)
            built.insert(id)
        }
        request.description = node["description"]?.string ?? node.at(["meta", "description"])?.string ?? ""

        let url = URLParts.split(text(node["url"]))
        request.url = url.base
        request.params = url.params + rows(node["parameters"])
        request.pathVariables = rows(node["pathParameters"]).filter { !$0.key.isEmpty }
        request.auth = auth(node["authentication"], path: requestPath)

        if isGRPC {
            request.method = "GRPC"
            if !request.url.contains("://") { request.url = "grpc://" + request.url }
            var method = node["protoMethodName"]?.string ?? ""
            if method.hasPrefix("/") { method.removeFirst() }
            request.grpcMethod = method
            request.headers = inherited + rows(node["metadata"])
            let message = text(node.at(["body", "text"]))
            request.body = .raw(text: message.isEmpty ? "{}" : message, contentType: "application/json")
            if node["protoFileId"]?.string?.isEmpty == false {
                warn("gRPC requests were imported without their .proto files. Load each one's methods from its server, or from a descriptor set.")
            }
            return request
        }

        request.method = (node["method"]?.string ?? "GET").uppercased()
        let own = rows(node["headers"])
        let handedDown = inherited.filter { header in
            !own.contains { $0.key.caseInsensitiveCompare(header.key) == .orderedSame }
        }
        copiedHeaders += handedDown.count
        request.headers = handedDown + own
        request.body = body(node["body"], path: requestPath)

        let scripts = scripts(node)
        request.preRequestScript = scripts.pre
        request.testScript = scripts.post
        return request
    }

    private func scripts(_ node: SpecNode) -> (pre: String, post: String) {
        let pre = node["preRequestScript"]?.string ?? node.at(["scripts", "preRequest"])?.string ?? ""
        let post = node["afterResponseScript"]?.string ?? node.at(["scripts", "afterResponse"])?.string ?? ""
        for script in [pre, post] where !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report.scriptsPreserved += 1
        }
        return (pre, post)
    }

    /// Headers, parameters and the like: a list of `{name, value, disabled, description}`.
    private func rows(_ node: SpecNode?) -> [KeyValue] {
        (node?.items ?? []).compactMap { row in
            guard row.isMap else { return nil }
            let name = text(row["name"])
            let value = text(row["value"])
            if name.isEmpty, value.isEmpty { return nil }
            let note = row["description"]?.string
            return KeyValue(key: name, value: value, enabled: row["disabled"]?.bool != true, note: note?.isEmpty == false ? note : nil)
        }
    }

    private func body(_ node: SpecNode?, path: String) -> Body {
        guard let node, node.isMap, !node.entries.isEmpty else { return .none }
        let mime = node["mimeType"]?.string ?? ""
        switch mime.lowercased() {
        case "application/x-www-form-urlencoded":
            return .urlEncoded(fields: rows(node["params"]))
        case "multipart/form-data":
            let fields: [FormField] = (node["params"]?.items ?? []).compactMap { row in
                guard row.isMap else { return nil }
                let isFile = row["type"]?.string == "file"
                return FormField(
                    key: text(row["name"]), value: isFile ? (row["fileName"]?.string ?? "") : text(row["value"]),
                    isFile: isFile, enabled: row["disabled"]?.bool != true
                )
            }
            return .formData(fields: fields)
        case "application/graphql":
            // The query and its variables are stored together as JSON text.
            let raw = node["text"]?.string ?? ""
            guard let parsed = try? SpecParser.parse(raw).root, parsed.isMap else {
                return .graphQL(query: convert(raw), variables: "")
            }
            var variables = ""
            if let node = parsed["variables"], !node.isNull {
                variables = node.string ?? node.jsonText()
            }
            return .graphQL(query: text(parsed["query"]), variables: convert(variables))
        case "application/octet-stream" where node["fileName"] != nil:
            return .file(path: node["fileName"]?.string ?? "")
        default:
            if let fileName = node["fileName"]?.string, !fileName.isEmpty, node["text"] == nil {
                return .file(path: fileName)
            }
            guard let raw = node["text"]?.string else { return .none }
            return .raw(text: convert(raw), contentType: mime.isEmpty ? nil : mime)
        }
    }

    private func auth(_ node: SpecNode?, path: String) -> Auth {
        guard let node, node.isMap, !node.entries.isEmpty else { return .inherit }
        guard let type = node["type"]?.string?.lowercased(), !type.isEmpty else { return .inherit }
        if node["disabled"]?.bool == true { return .none }
        func field(_ key: String) -> String { text(node[key]) }

        switch type {
        case "none":
            return .none
        case "basic":
            return .basic(username: field("username"), password: field("password"))
        case "bearer":
            let prefix = field("prefix")
            if !prefix.isEmpty, prefix != "Bearer" {
                warn("\(path): the bearer token's prefix “\(prefix)” was not kept; “Bearer” is sent. Use a header instead if the prefix matters.")
            }
            return .bearer(token: field("token"))
        case "apikey":
            return .apiKey(key: field("key"), value: field("value"), placement: field("addTo").lowercased().hasPrefix("query") ? .query : .header)
        case "oauth2":
            var config = OAuth2Config(
                tokenURL: field("accessTokenUrl"), authURL: field("authorizationUrl"),
                clientID: field("clientId"), clientSecret: field("clientSecret"), scope: field("scope"),
                username: field("username"), password: field("password"),
                clientAuthInBody: node["credentialsInBody"]?.bool == true || field("credentialsInBody") == "true",
                usePKCE: node["usePkce"]?.bool == true
            )
            let prefix = field("tokenPrefix")
            if !prefix.isEmpty { config.headerPrefix = prefix }
            switch field("grantType") {
            case "client_credentials": config.grant = .clientCredentials
            case "password": config.grant = .password
            case "authorization_code": config.grant = .authorizationCode
            case "": config.grant = config.authURL.isEmpty ? .clientCredentials : .authorizationCode
            case let other:
                warn("\(path): OAuth 2 grant type “\(other)” is not supported; it was set to client credentials.")
            }
            return .oauth2(config)
        default:
            warn("\(path): auth type “\(type)” is not supported yet; it was set to no auth.")
            return .none
        }
    }

    // MARK: Variables

    /// An environment's values. Insomnia allows nested objects, read as `{{ _.a.b }}`; they
    /// become one variable for each leaf, named `a.b`.
    func variables(_ environment: SpecNode) -> [Variable] {
        var out = flatten(environment["data"])
        // Newer exports can also list the values as rows, which is where secrets are marked.
        for row in environment["kvPairData"]?.items ?? [] where row.isMap {
            let name = row["name"]?.string ?? ""
            guard !name.isEmpty else { continue }
            let isSecret = row["type"]?.string == "secret"
            if let index = out.firstIndex(where: { $0.key == name }) {
                out[index].secret = isSecret
                out[index].enabled = row["enabled"]?.bool != false
            } else if row["type"]?.string != "json" {
                out.append(Variable(key: name, value: text(row["value"]), enabled: row["enabled"]?.bool != false, secret: isSecret))
            }
        }
        report.variables += out.count
        return out
    }

    private func flatten(_ node: SpecNode?, prefix: String = "") -> [Variable] {
        var out: [Variable] = []
        for entry in node?.entries ?? [] {
            let key = prefix + entry.key
            if entry.node.isMap, !entry.node.entries.isEmpty {
                out.append(contentsOf: flatten(entry.node, prefix: key + "."))
            } else {
                out.append(Variable(key: key, value: text(entry.node)))
            }
        }
        return out
    }

    /// The collection's variables: the base environment's, then any that folders set.
    func merged(_ base: [Variable]) -> [Variable] {
        var out = base
        var clashes: [String] = []
        for variable in folderVariables {
            if let existing = out.first(where: { $0.key == variable.key }) {
                if existing.value != variable.value, !clashes.contains(variable.key) { clashes.append(variable.key) }
                continue
            }
            out.append(variable)
            report.variables += 1
        }
        if !foldersWithVariables.isEmpty {
            var line = "Folder environments (\(foldersWithVariables.joined(separator: ", "))) became collection variables, because folders here do not have variables of their own."
            if !clashes.isEmpty {
                line += " These had more than one value and kept the first: \(clashes.joined(separator: ", "))."
            }
            warn(line)
        }
        return out
    }

    // MARK: Templates

    /// Rewrites Insomnia's template syntax as this app's: `{{ _.name }}` becomes `{{name}}`,
    /// and the template tags that have an equivalent are replaced by it.
    func convert(_ text: String) -> String {
        guard text.contains("{{") || text.contains("{%") else { return text }
        var out = ""
        var rest = Substring(text)
        while true {
            let variable = rest.range(of: "{{")
            let tag = rest.range(of: "{%")
            guard let open = [variable, tag].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) else { break }
            let isTag = rest[open] == "{%"
            let after = rest[open.upperBound...]
            guard let close = after.range(of: isTag ? "%}" : "}}") else { break }
            out += rest[..<open.lowerBound]
            let inner = after[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            let original = String(rest[open.lowerBound..<close.upperBound])
            out += isTag ? self.tag(inner, original: original) : self.variable(inner, original: original)
            rest = after[close.upperBound...]
        }
        return out + rest
    }

    private func variable(_ inner: String, original: String) -> String {
        if inner.hasPrefix("_.") { return "{{\(inner.dropFirst(2))}}" }
        if inner.hasPrefix("_["), inner.hasSuffix("]") {
            let key = inner.dropFirst(2).dropLast().trimmingCharacters(in: .whitespaces)
            if key.count >= 2, let quote = key.first, quote == "'" || quote == "\"", key.last == quote {
                return "{{\(key.dropFirst().dropLast())}}"
            }
        }
        return original
    }

    private func tag(_ inner: String, original: String) -> String {
        let name = String(inner.prefix { !$0.isWhitespace })
        let arguments = Self.arguments(String(inner.dropFirst(name.count)))
        switch name {
        case "uuid":
            return "{{$guid}}"
        case "now", "timestamp":
            switch arguments.first ?? (name == "timestamp" ? "unix" : "iso-8601") {
            case "iso-8601": return "{{$isoTimestamp}}"
            case "unix": return "{{$timestamp}}"
            default: break
            }
        case "response":
            if let replacement = responseTag(arguments) { return replacement }
        default:
            break
        }
        unsupportedTags[name, default: 0] += 1
        return original
    }

    /// `{% response 'body', 'req_1', '$.token' %}` reads a value out of another request's last
    /// response. Here that is a "Save from response" rule on the other request, and a variable.
    private func responseTag(_ arguments: [String]) -> String? {
        guard arguments.count >= 2 else { return nil }
        let field = arguments[0]
        let requestID = arguments[1]
        var filter = arguments.count > 2 ? arguments[2] : ""
        // The filter may be wrapped as b64::<base64 of the percent-encoded text>::46b.
        if filter.hasPrefix("b64::") {
            let encoded = filter.dropFirst(5).components(separatedBy: "::").first ?? ""
            guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) else { return nil }
            filter = decoded.removingPercentEncoding ?? decoded
        }

        let source: ValueSource
        var suffix: String
        switch field {
        case "body" where filter.isEmpty, "raw":
            source = ValueSource(kind: .body)
            suffix = "body"
        case "body":
            guard let steps = JSONPath.parse(filter), !steps.isEmpty else { return nil }
            source = ValueSource(kind: .json, path: filter)
            suffix = "value"
            if case .key(let key)? = steps.last(where: { if case .key = $0 { return true } else { return false } }) { suffix = key }
        case "header":
            guard !filter.isEmpty else { return nil }
            source = ValueSource(kind: .header, path: filter)
            suffix = filter
        default:
            return nil
        }

        let variable = Self.slug(names[requestID] ?? "response") + "_" + Self.slug(suffix)
        let extraction = Extraction(variable: variable, source: source, scope: .collection)
        if !(chained[requestID] ?? []).contains(where: { $0.variable == variable }) {
            chained[requestID, default: []].append(extraction)
        }
        _ = uuid(for: requestID)
        return "{{\(variable)}}"
    }

    /// Splits a tag's arguments: `'body', 'req_1', 60` gives `body`, `req_1`, `60`.
    static func arguments(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var hasCurrent = false
        var escaped = false
        for character in text {
            if let open = quote {
                if escaped {
                    current.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
                hasCurrent = true
            } else if character == "," {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                hasCurrent = false
            } else {
                if !character.isWhitespace { hasCurrent = true }
                current.append(character)
            }
        }
        if hasCurrent { out.append(current.trimmingCharacters(in: .whitespaces)) }
        return out
    }

    static func slug(_ text: String) -> String {
        var out = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
            } else if !out.isEmpty, out.last != "_" {
                out.append("_")
            }
        }
        while out.last == "_" { out.removeLast() }
        return out.isEmpty ? "value" : out
    }

    // MARK: Finishing

    /// Adds the "Save from response" rules that replace Insomnia's response tags, and the
    /// notes for the report.
    func finish(_ collection: inout APICollection) {
        var missing = 0
        for (insomniaID, extractions) in chained.sorted(by: { $0.key < $1.key }) {
            guard built.contains(insomniaID), let id = ids[insomniaID], var request = collection.request(id: id) else {
                missing += extractions.count
                continue
            }
            request.extractions.append(contentsOf: extractions)
            collection.updateRequest(request)
            let variables = extractions.map { "{{\($0.variable)}}" }.joined(separator: ", ")
            warn("“\(request.name)” now saves \(variables) from its response, in place of Insomnia's response tag. Send it before the requests that use \(extractions.count == 1 ? "that value" : "those values").")
        }
        if missing > 0 {
            warn("\(missing) response \(missing == 1 ? "tag reads" : "tags read") from a request that is not in this collection; the variable it was replaced by has no value yet.")
        }
        if copiedHeaders > 0 {
            warn("Headers set on the collection or its folders were copied onto the requests inside them (\(copiedHeaders) in all), because only requests have headers here.")
        }
        if !unsupportedTags.isEmpty {
            let list = unsupportedTags.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
            warn("Insomnia template tags with no equivalent here were left as written: \(list).")
        }
    }
}
