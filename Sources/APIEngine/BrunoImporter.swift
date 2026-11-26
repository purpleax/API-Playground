import CryptoKit
import Foundation

public enum BrunoImportError: Error, LocalizedError, Equatable {
    case notBruno
    case noCollection(String)

    public var errorDescription: String? {
        switch self {
        case .notBruno: return "The file is not a Bruno collection."
        case .noCollection(let folder): return "“\(folder)” has no Bruno collection in it (no bruno.json and no .bru files)."
        }
    }
}

// MARK: - The .bru file format

/// One `.bru` file, as its blocks: `name { ... }` holding either rows or free text, and
/// `name [ ... ]` holding a list.
struct BruFile {
    struct Row: Equatable {
        var key: String
        var value: String
        var enabled = true
    }

    private(set) var order: [String] = []
    private var raw: [String: [String]] = [:]
    private var lists: [String: [Row]] = [:]

    init(_ text: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            guard let last = line.last, last == "{" || last == "[" else { continue }
            let name = line.dropLast().trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            // A block ends at a closing bracket in the first column; its contents are indented.
            let close = last == "{" ? "}" : "]"
            var content: [String] = []
            while index < lines.count {
                let next = lines[index]
                index += 1
                if next.hasPrefix(close), next.trimmingCharacters(in: .whitespaces) == close { break }
                content.append(next)
            }
            if raw[name] == nil, lists[name] == nil { order.append(name) }
            if last == "{" {
                raw[name] = content
            } else {
                lists[name] = content.joined(separator: ",").split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { item in
                    var key = item.trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return nil }
                    let enabled = !key.hasPrefix("~")
                    if !enabled { key.removeFirst() }
                    return Row(key: key, value: "", enabled: enabled)
                }
            }
        }
    }

    func has(_ name: String) -> Bool {
        raw[name] != nil || lists[name] != nil
    }

    /// A block read as free text, such as a body or a script.
    func text(_ name: String) -> String {
        guard let lines = raw[name] else { return "" }
        return Self.outdent(lines).joined(separator: "\n")
    }

    func list(_ name: String) -> [Row] {
        lists[name] ?? []
    }

    /// A block read as `key: value` rows. A row starting with `~` is switched off, and a value
    /// in `'''` runs over several lines.
    func rows(_ name: String) -> [Row] {
        guard let lines = raw[name] else { return [] }
        var out: [Row] = []
        var index = 0
        while index < lines.count {
            var line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            guard !line.isEmpty else { continue }
            // A line such as @number or @description(...) describes the row after it.
            if line.hasPrefix("@"), line.range(of: #"^@[A-Za-z]+(\(.*\))?$"#, options: .regularExpression) != nil { continue }
            let enabled = !line.hasPrefix("~")
            if !enabled { line.removeFirst() }

            var key: String
            var value: String
            if line.hasPrefix("\""), let end = line.dropFirst().range(of: "\":") {
                // A quoted key may hold colons and spaces.
                key = String(line[line.index(after: line.startIndex)..<end.lowerBound]).replacingOccurrences(of: "\\\"", with: "\"")
                value = String(line[end.upperBound...])
            } else if let colon = line.firstIndex(of: ":") {
                key = String(line[..<colon])
                value = String(line[line.index(after: colon)...])
            } else {
                key = line
                value = ""
            }
            key = key.trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: .whitespaces)

            if value == "[" {
                // A list inside a block, such as a request's tags: one item on each line.
                var items: [String] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                    if next == "]" { break }
                    if !next.isEmpty { items.append(next) }
                }
                value = items.joined(separator: ", ")
            } else if value.hasPrefix("'''") {
                var first = String(value.dropFirst(3))
                if let end = first.range(of: "'''") {
                    first = String(first[..<end.lowerBound])
                    value = first
                } else {
                    var body: [String] = first.isEmpty ? [] : [first]
                    while index < lines.count {
                        let next = lines[index]
                        index += 1
                        if let end = next.range(of: "'''") {
                            let before = String(next[..<end.lowerBound])
                            if !before.trimmingCharacters(in: .whitespaces).isEmpty { body.append(before) }
                            break
                        }
                        body.append(next)
                    }
                    value = Self.outdent(body).joined(separator: "\n")
                }
            }
            out.append(Row(key: key, value: value, enabled: enabled))
        }
        return out
    }

    func values(_ name: String) -> [String: String] {
        var out: [String: String] = [:]
        for row in rows(name) { out[row.key] = row.value }
        return out
    }

    /// Removes the indentation every line shares.
    private static func outdent(_ lines: [String]) -> [String] {
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
            .min() ?? 0
        return lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " || $0 == "\t" }.count))) }
    }
}

// MARK: - What a request, folder or collection holds

/// The parts of a Bruno request, folder or collection that are imported, whichever file
/// format they were read from.
struct BrunoItem {
    var name = ""
    var type = "http"
    var seq: Double?
    var method = "GET"
    var url = ""
    var bodyMode: String?
    var authMode: String?
    /// nil when the file does not list them, so they are read from the URL instead.
    var query: [KeyValue]?
    var pathVariables: [KeyValue] = []
    var headers: [KeyValue] = []
    var auth: [String: [String: String]] = [:]
    var bodyText: [String: String] = [:]
    var formURLEncoded: [KeyValue] = []
    var multipart: [FormField] = []
    var filePath = ""
    var graphQLQuery = ""
    var graphQLVariables = ""
    var preVariables: [KeyValue] = []
    var postVariables: [KeyValue] = []
    var assertions: [KeyValue] = []
    var preScript = ""
    var postScript = ""
    var tests = ""
    var docs = ""
    var grpcMethod = ""
    var grpcMessage = ""
    /// Set when a YAML file has post-response actions, whose layout is not known well enough to read.
    var hasActions = false

    private static let httpMethods: Set<String> = ["get", "post", "put", "patch", "delete", "head", "options", "trace", "connect"]

    init() {}

    /// Reads a `.bru` file: a request, or a folder's or collection's settings.
    init(bru text: String, fallbackName: String) {
        let file = BruFile(text)
        func keyValues(_ block: String) -> [KeyValue] {
            file.rows(block).map { KeyValue(key: $0.key, value: $0.value, enabled: $0.enabled) }
        }

        let meta = file.values("meta")
        name = meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        type = meta["type"] ?? "http"
        seq = meta["seq"].flatMap(Double.init)

        // The request line is a block named after the method, or "http" with the method inside.
        var request: [String: String] = [:]
        if let block = file.order.first(where: { Self.httpMethods.contains($0.lowercased()) }) {
            request = file.values(block)
            method = block.uppercased()
        } else if file.has("http") {
            request = file.values("http")
            method = (request["method"] ?? "GET").uppercased()
        } else if file.has("grpc") {
            request = file.values("grpc")
            type = "grpc"
            grpcMethod = request["method"] ?? ""
        } else if file.has("ws") {
            request = file.values("ws")
            type = "ws"
        }
        url = request["url"] ?? ""
        bodyMode = request["body"]
        authMode = request["auth"] ?? file.values("auth")["mode"]

        if file.has("params:query") {
            query = keyValues("params:query")
        } else if file.has("query") {
            query = keyValues("query")
        }
        pathVariables = keyValues("params:path")
        headers = keyValues(file.has("metadata") ? "metadata" : "headers")

        for block in file.order where block.hasPrefix("auth:") {
            auth[String(block.dropFirst(5))] = file.values(block)
        }
        for mode in ["json", "text", "xml", "sparql"] where file.has("body:\(mode)") {
            bodyText[mode] = file.text("body:\(mode)")
        }
        if file.has("body"), bodyText["json"] == nil { bodyText["json"] = file.text("body") }
        formURLEncoded = keyValues("body:form-urlencoded")
        multipart = file.rows("body:multipart-form").map { row in
            let parsed = Self.fileReference(row.value)
            let text = row.value.replacingOccurrences(of: #"\s*@contentType\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            return FormField(key: row.key, value: parsed ?? text, isFile: parsed != nil, enabled: row.enabled)
        }
        if let row = file.rows("body:file").first(where: { $0.key == "file" && $0.enabled }) ?? file.rows("body:file").first {
            filePath = Self.fileReference(row.value) ?? row.value
        }
        graphQLQuery = file.text("body:graphql")
        graphQLVariables = file.text("body:graphql:vars")
        if file.has("body:grpc") {
            grpcMessage = file.values("body:grpc")["content"] ?? file.text("body:grpc")
        }

        preVariables = keyValues("vars:pre-request")
        postVariables = keyValues("vars:post-response")
        assertions = keyValues("assert")
        preScript = file.text("script:pre-request")
        postScript = file.text("script:post-response")
        tests = file.text("tests")
        docs = file.text("docs")
    }

    /// Reads a file from a collection saved as YAML (Bruno 3's OpenCollection format): a
    /// request, or the settings in opencollection.yml or folder.yml.
    init(yaml root: SpecNode, fallbackName: String) {
        func value(_ node: SpecNode?) -> String {
            // A value is plain text, or {type, data} when it is a number, boolean or object.
            guard let node else { return "" }
            return node.string ?? node["data"]?.string ?? ""
        }
        func rows(_ node: SpecNode?) -> [KeyValue] {
            (node?.items ?? []).compactMap { row in
                guard row.isMap else { return nil }
                let enabled = row["disabled"]?.bool != true && row["enabled"]?.bool != false
                return KeyValue(key: row["name"]?.string ?? "", value: value(row["value"]), enabled: enabled)
            }
        }

        let info = root["info"]
        name = info?["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        seq = info?["seq"]?.double
        type = info?["type"]?.string ?? "http"
        var section = root["request"]
        for (key, kind) in [("http", "http"), ("graphql", "graphql"), ("grpc", "grpc"), ("websocket", "ws")] {
            if let found = root[key], found.isMap {
                section = found
                type = kind
                break
            }
        }
        if type == "websocket" { type = "ws" }
        let request = section ?? SpecNode(.map([]))

        url = request["url"]?.string ?? ""
        if type == "grpc" {
            grpcMethod = request["method"]?.string ?? ""
            if let message = request["message"] {
                let first = message.items.first ?? message
                grpcMessage = first["message"]?.string ?? first["message"]?["data"]?.string ?? first.string ?? ""
            }
            headers = rows(request["metadata"] ?? request["headers"])
        } else {
            method = (request["method"]?.string ?? "GET").uppercased()
            headers = rows(request["headers"])
        }
        if let params = request["params"]?.items {
            query = rows(SpecNode(.list(params.filter { $0["type"]?.string != "path" })))
            pathVariables = rows(SpecNode(.list(params.filter { $0["type"]?.string == "path" })))
        }

        if let auth = request["auth"] {
            if let mode = auth.string {
                authMode = mode
            } else if let mode = auth["type"]?.string {
                authMode = mode
                // The settings sit beside the type, or in an object named after it.
                var settings: [String: String] = [:]
                for entry in (auth[mode]?.entries ?? []) + auth.entries {
                    if let text = entry.node.string, settings[entry.key] == nil { settings[entry.key] = text }
                }
                self.auth[mode] = settings
            }
        }

        if let body = request["body"], body.isMap {
            let kind = body["type"]?.string ?? (body["query"] != nil ? "graphql" : "")
            switch kind {
            case "json", "text", "xml", "sparql":
                bodyMode = kind
                bodyText[kind] = body["data"]?.string ?? ""
            case "form-urlencoded":
                bodyMode = "formUrlEncoded"
                formURLEncoded = rows(body["data"])
            case "multipart-form":
                bodyMode = "multipartForm"
                multipart = (body["data"]?.items ?? []).filter(\.isMap).map { row in
                    let isFile = row["type"]?.string == "file"
                    let text = row["value"]?.items.first?.string ?? value(row["value"])
                    return FormField(key: row["name"]?.string ?? "", value: text, isFile: isFile, enabled: row["disabled"]?.bool != true)
                }
            case "graphql":
                bodyMode = "graphql"
                let inner = body["data"]?.isMap == true ? body["data"]! : body
                graphQLQuery = inner["query"]?.string ?? ""
                graphQLVariables = inner["variables"]?.string ?? (inner["variables"]?.isMap == true ? inner["variables"]!.jsonText() : "")
            case "file":
                bodyMode = "file"
                let first = body["data"]?.items.first
                filePath = first?["filePath"]?.string ?? first?.string ?? body["data"]?.string ?? ""
            default:
                bodyMode = kind.isEmpty ? nil : kind
            }
        }

        // A request keeps these under "runtime"; a folder or collection keeps them with its settings.
        let runtime = root["runtime"] ?? request
        preVariables = rows(runtime["variables"])
        for script in runtime["scripts"]?.items ?? [] {
            let code = script["code"]?.string ?? ""
            switch script["type"]?.string {
            case "before-request": preScript = code
            case "after-response": postScript = code
            case "tests": tests = code
            default: break
            }
        }
        assertions = (runtime["assertions"]?.items ?? []).filter(\.isMap).map { row in
            let test = [row["operator"]?.string ?? "", row["value"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            return KeyValue(key: row["expression"]?.string ?? "", value: test, enabled: row["disabled"]?.bool != true)
        }
        hasActions = !(runtime["actions"]?.items ?? []).isEmpty
        docs = root["docs"]?.string ?? root["docs"]?["content"]?.string ?? ""
    }

    /// Reads an item from Bruno's JSON export. `request` is the item's "request" object, or
    /// a folder's or collection's "root.request".
    init(json request: [String: Any], name: String, type: String, seq: Double?) {
        func string(_ value: Any?) -> String {
            switch value {
            case let text as String: return text
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
                return number.stringValue
            case let object as [String: Any]:
                return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            default: return ""
            }
        }
        func keyValues(_ value: Any?) -> [KeyValue] {
            (value as? [[String: Any]] ?? []).map {
                KeyValue(key: string($0["name"]), value: string($0["value"]), enabled: $0["enabled"] as? Bool ?? true)
            }
        }

        self.name = name
        self.seq = seq
        switch type {
        case "graphql-request", "graphql": self.type = "graphql"
        case "grpc-request", "grpc": self.type = "grpc"
        case "ws-request", "ws": self.type = "ws"
        default: self.type = "http"
        }
        method = string(request["method"]).uppercased()
        if method.isEmpty { method = "GET" }
        url = string(request["url"])
        headers = keyValues(request["headers"])
        if let params = request["params"] as? [[String: Any]] {
            query = keyValues(params.filter { string($0["type"]) != "path" })
            pathVariables = keyValues(params.filter { string($0["type"]) == "path" })
        }

        let body = request["body"] as? [String: Any] ?? [:]
        bodyMode = body["mode"] as? String
        for mode in ["json", "text", "xml", "sparql"] {
            if let text = body[mode] as? String { bodyText[mode] = text }
        }
        formURLEncoded = keyValues(body["formUrlEncoded"])
        multipart = (body["multipartForm"] as? [[String: Any]] ?? []).map { field in
            let isFile = string(field["type"]) == "file"
            let value = isFile ? ((field["value"] as? [String])?.first ?? string(field["value"])) : string(field["value"])
            return FormField(key: string(field["name"]), value: value, isFile: isFile, enabled: field["enabled"] as? Bool ?? true)
        }
        if let files = body["file"] as? [[String: Any]] {
            filePath = string((files.first { $0["selected"] as? Bool == true } ?? files.first)?["filePath"])
        }
        if self.type == "grpc" {
            grpcMethod = string(request["method"])
            grpcMessage = string((body["grpc"] as? [[String: Any]])?.first?["content"])
        }
        let graphQL = body["graphql"] as? [String: Any] ?? [:]
        graphQLQuery = string(graphQL["query"])
        graphQLVariables = string(graphQL["variables"])

        let authObject = request["auth"] as? [String: Any] ?? [:]
        authMode = authObject["mode"] as? String
        for (mode, settings) in authObject {
            guard let settings = settings as? [String: Any] else { continue }
            auth[mode] = settings.mapValues { string($0) }
        }

        let script = request["script"] as? [String: Any] ?? [:]
        preScript = string(script["req"])
        postScript = string(script["res"])
        tests = string(request["tests"])
        docs = string(request["docs"])
        let vars = request["vars"] as? [String: Any] ?? [:]
        preVariables = keyValues(vars["req"])
        postVariables = keyValues(vars["res"])
        assertions = keyValues(request["assertions"])
    }

    /// The path in `@file(path)`. A row can name several files, split by `|`; the first is used.
    private static func fileReference(_ value: String) -> String? {
        guard let open = value.range(of: "@file("), let close = value[open.upperBound...].firstIndex(of: ")") else { return nil }
        let inner = value[open.upperBound..<close]
        return inner.split(separator: "|").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

// MARK: - Importer

/// Reads Bruno collections: a collection folder of `.bru` files, a single `.bru` request, or
/// the one-file JSON export.
public enum BrunoImporter {

    /// True for the JSON that Bruno's "Export collection" writes.
    public static func recognises(json root: [String: Any]) -> Bool {
        guard root["info"] == nil, let items = root["items"] as? [[String: Any]] else { return false }
        if root["brunoConfig"] != nil { return true }
        return root["name"] is String && items.allSatisfy { $0["type"] is String }
    }

    // MARK: JSON export

    public static func importDocuments(data: Data) throws -> [ImportedDocument] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], recognises(json: root) else {
            throw BrunoImportError.notBruno
        }
        let session = Session(root: nil)
        let name = root["name"] as? String ?? "Bruno Import"
        let settings = ((root["root"] as? [String: Any])?["request"] as? [String: Any]).map {
            BrunoItem(json: $0, name: name, type: "collection", seq: nil)
        }
        var settingsItem = settings ?? BrunoItem()
        if let docs = (root["root"] as? [String: Any])?["docs"] as? String, settingsItem.docs.isEmpty { settingsItem.docs = docs }

        func build(_ items: [[String: Any]], path: String, inherited: [KeyValue], depth: Int) -> [Node] {
            guard depth < 64 else { return [] }
            let entries: [(seq: Double?, isFolder: Bool, name: String, node: () -> Node?)] = items.map { item in
                let itemName = item["name"] as? String ?? "Untitled"
                let type = item["type"] as? String ?? ""
                let seq = (item["seq"] as? NSNumber)?.doubleValue
                if type == "folder" {
                    let rootRequest = (item["root"] as? [String: Any])?["request"] as? [String: Any] ?? [:]
                    var folder = BrunoItem(json: rootRequest, name: itemName, type: type, seq: seq)
                    if let docs = (item["root"] as? [String: Any])?["docs"] as? String, folder.docs.isEmpty { folder.docs = docs }
                    return (seq, true, itemName, {
                        session.folder(folder, path: path, inherited: inherited) { folderPath, headers in
                            build(item["items"] as? [[String: Any]] ?? [], path: folderPath, inherited: headers, depth: depth + 1)
                        }
                    })
                }
                guard let request = item["request"] as? [String: Any] else {
                    return (seq, false, itemName, { session.skip(itemName, type: type) })
                }
                let parsed = BrunoItem(json: request, name: itemName, type: type, seq: seq)
                return (seq, false, itemName, { .request(session.request(parsed, path: path, inherited: inherited)) })
            }
            return Session.ordered(entries).compactMap { $0() }
        }

        var collection = session.collection(settingsItem, name: name) { headers in
            build(root["items"] as? [[String: Any]] ?? [], path: name, inherited: headers, depth: 0)
        }
        session.finish(&collection)
        var documents: [ImportedDocument] = [.collection(collection, session.report)]
        for environment in root["environments"] as? [[String: Any]] ?? [] {
            let variables: [Variable] = (environment["variables"] as? [[String: Any]] ?? []).map {
                Variable(
                    key: $0["name"] as? String ?? "", value: $0["value"] as? String ?? "",
                    enabled: $0["enabled"] as? Bool ?? true, secret: $0["secret"] as? Bool ?? false
                )
            }
            var report = ImportReport()
            report.variables = variables.count
            documents.append(.environment(
                APIEnvironment(name: environment["name"] as? String ?? "Environment", variables: variables), isGlobals: false, report
            ))
        }
        return documents
    }

    // MARK: Collection folder

    /// The collection folders at or just inside `url`.
    public static func collectionFolders(in url: URL) -> [URL] {
        let fm = FileManager.default
        func isCollection(_ folder: URL) -> Bool {
            if fm.fileExists(atPath: folder.appendingPathComponent("bruno.json").path) { return true }
            if fm.fileExists(atPath: folder.appendingPathComponent("collection.bru").path) { return true }
            return yamlRoot(in: folder) != nil
        }
        if isCollection(url) { return [url] }
        let inside = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let found = inside.filter(isCollection)
        if !found.isEmpty { return found }
        // A folder of loose .bru files is still worth importing.
        let hasBru = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).contains { $0.pathExtension.lowercased() == "bru" }
        return hasBru ? [url] : []
    }

    public static func importFolder(at url: URL) throws -> [ImportedDocument] {
        let folders = collectionFolders(in: url)
        guard !folders.isEmpty else { throw BrunoImportError.noCollection(url.lastPathComponent) }
        return folders.flatMap { importCollection(at: $0) }
    }

    /// The file at the top of a collection saved as YAML, if this folder is one.
    private static func yamlRoot(in folder: URL) -> URL? {
        ["opencollection.yml", "opencollection.yaml"].map { folder.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func yaml(_ url: URL) -> SpecNode? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? SpecParser.parse(text).root
    }

    /// Imports one `.bru` request on its own, as a collection holding just that request.
    public static func importRequestFile(at url: URL) throws -> [ImportedDocument] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let item = BrunoItem(bru: text, fallbackName: url.deletingPathExtension().lastPathComponent)
        guard !item.url.isEmpty else { throw BrunoImportError.notBruno }
        let session = Session(root: url.deletingLastPathComponent())
        var collection = APICollection(name: item.name, items: [.request(session.request(item, path: item.name, inherited: []))])
        session.finish(&collection)
        return [.collection(collection, session.report)]
    }

    private static func importCollection(at root: URL) -> [ImportedDocument] {
        let fm = FileManager.default
        let session = Session(root: root)
        func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

        var name = root.lastPathComponent
        var ignored: Set<String> = ["node_modules", ".git"]
        // Bruno 3 saves collections as YAML; earlier ones are .bru files.
        let yamlFile = yamlRoot(in: root)
        let isYAML = yamlFile != nil
        var yamlSettings: BrunoItem?
        if let yamlFile, let top = yaml(yamlFile) {
            yamlSettings = BrunoItem(yaml: top, fallbackName: name)
            name = yamlSettings?.name ?? name
            for entry in top.at(["extensions", "bruno", "ignore"])?.items ?? [] { if let text = entry.string { ignored.insert(text) } }
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("bruno.json")),
           let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let configured = config["name"] as? String, !configured.isEmpty { name = configured }
            for entry in config["ignore"] as? [String] ?? [] { ignored.insert(entry) }
        }
        let settings = yamlSettings ?? read(root.appendingPathComponent("collection.bru")).map { BrunoItem(bru: $0, fallbackName: name) } ?? BrunoItem()
        let settingsFiles: Set<String> = ["collection.bru", "folder.bru", "opencollection.yml", "opencollection.yaml", "folder.yml", "folder.yaml"]
        func folderSettings(_ url: URL) -> BrunoItem? {
            if isYAML {
                return ["folder.yml", "folder.yaml"].lazy.compactMap { yaml(url.appendingPathComponent($0)) }.first
                    .map { BrunoItem(yaml: $0, fallbackName: url.lastPathComponent) }
            }
            return read(url.appendingPathComponent("folder.bru")).map { BrunoItem(bru: $0, fallbackName: url.lastPathComponent) }
        }
        func requestItem(_ url: URL) -> BrunoItem? {
            let fallback = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.lowercased()
            if isYAML {
                guard ext == "yml" || ext == "yaml", let node = yaml(url), node.isMap else { return nil }
                // Other YAML kept beside the requests is not part of the collection.
                guard node["info"] != nil, ["http", "graphql", "grpc", "websocket"].contains(where: { node[$0] != nil }) else { return nil }
                return BrunoItem(yaml: node, fallbackName: fallback)
            }
            guard ext == "bru", let text = read(url) else { return nil }
            return BrunoItem(bru: text, fallbackName: fallback)
        }

        func build(_ folder: URL, path: String, inherited: [KeyValue], depth: Int) -> [Node] {
            guard depth < 64 else { return [] }
            let contents = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            var entries: [(seq: Double?, isFolder: Bool, name: String, node: () -> Node?)] = []
            for url in contents {
                let fileName = url.lastPathComponent
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if ignored.contains(fileName) || (depth == 0 && fileName == "environments") { continue }
                    let folderSettings = folderSettings(url)
                    var item = folderSettings ?? BrunoItem()
                    if item.name.isEmpty { item.name = fileName }
                    entries.append((item.seq, true, item.name, {
                        let node = session.folder(item, path: path, inherited: inherited) { folderPath, headers in
                            build(url, path: folderPath, inherited: headers, depth: depth + 1)
                        }
                        // A folder with nothing in it and no settings is usually not part of the collection.
                        if case .folder(let made) = node, made.items.isEmpty, folderSettings == nil {
                            session.report.folders -= 1
                            return nil
                        }
                        return node
                    }))
                } else if !settingsFiles.contains(fileName) {
                    guard let item = requestItem(url) else { continue }
                    entries.append((item.seq, false, item.name, { .request(session.request(item, path: path, inherited: inherited)) }))
                }
            }
            return Session.ordered(entries).compactMap { $0() }
        }

        var collection = session.collection(settings, name: name) { headers in
            build(root, path: name, inherited: headers, depth: 0)
        }
        // Importing the same folder again updates the collection. The id is a digest, so the
        // folder's path on this Mac is not written into the workspace.
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        collection.postmanID = "bruno-\(digest)"
        session.finish(&collection)

        var documents: [ImportedDocument] = [.collection(collection, session.report)]
        let environments = ((try? fm.contentsOfDirectory(at: root.appendingPathComponent("environments"), includingPropertiesForKeys: nil)) ?? [])
            .filter { (isYAML ? ["yml", "yaml"] : ["bru"]).contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in environments {
            var variables: [Variable] = []
            var environmentName = url.deletingPathExtension().lastPathComponent
            // Secret values are kept outside the files, so only their names can be brought over.
            if isYAML {
                guard let node = yaml(url) else { continue }
                if let given = node["name"]?.string, !given.isEmpty { environmentName = given }
                for row in node["variables"]?.items ?? [] where row.isMap {
                    let isSecret = row["secret"]?.bool == true
                    let value = row["value"]?.string ?? row["value"]?["data"]?.string ?? ""
                    variables.append(Variable(key: row["name"]?.string ?? "", value: isSecret ? "" : value, enabled: row["disabled"]?.bool != true, secret: isSecret))
                }
            } else {
                guard let text = read(url) else { continue }
                let file = BruFile(text)
                variables = file.rows("vars").map { Variable(key: $0.key, value: $0.value, enabled: $0.enabled) }
                variables += file.list("vars:secret").map { Variable(key: $0.key, value: "", enabled: $0.enabled, secret: true) }
            }
            var report = ImportReport()
            report.variables = variables.count
            let secrets = variables.filter(\.secret).count
            if secrets > 0 {
                report.warnings.append("Environment “\(environmentName)”: \(secrets) secret \(secrets == 1 ? "variable has" : "variables have") no value, because Bruno keeps secret values out of its files. Enter \(secrets == 1 ? "it" : "them") here.")
            }
            documents.append(.environment(
                APIEnvironment(name: environmentName, variables: variables), isGlobals: false, report
            ))
        }
        return documents
    }
}

// MARK: - One collection's import

private final class Session {
    var report = ImportReport()
    /// The collection folder, which Bruno's relative file paths start from.
    let root: URL?
    private var copiedHeaders = 0
    private var processEnvironment = 0
    private var skippedAssertions: [String] = []
    private var skippedTypes: [String: Int] = [:]
    private var folderVariables: [Variable] = []

    init(root: URL?) {
        self.root = root
    }

    private func warn(_ text: String) {
        if !report.warnings.contains(text) { report.warnings.append(text) }
    }

    /// Bruno lists folders first, then requests, each by sequence number and then by name.
    static func ordered<T>(_ entries: [(seq: Double?, isFolder: Bool, name: String, node: T)]) -> [T] {
        entries.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let (x, y) = (a.seq ?? .greatestFiniteMagnitude, b.seq ?? .greatestFiniteMagnitude)
            if x != y { return x < y }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }.map(\.node)
    }

    func skip(_ name: String, type: String) -> Node? {
        skippedTypes[type.isEmpty ? "unknown" : type, default: 0] += 1
        return nil
    }

    private func note(_ text: String) {
        if text.contains("process.env.") { processEnvironment += 1 }
    }

    // MARK: Collection, folders, requests

    func collection(_ settings: BrunoItem, name: String, items: ([KeyValue]) -> [Node]) -> APICollection {
        let scripts = scripts(settings, path: name)
        var auth = auth(settings, path: name)
        if auth == .inherit { auth = .none }
        let variables = settings.preVariables.filter { !$0.key.isEmpty }.map { Variable(key: $0.key, value: $0.value, enabled: $0.enabled) }
        report.variables += variables.count
        let built = items(settings.headers.filter { !$0.key.isEmpty })
        var all = variables
        for variable in folderVariables where !all.contains(where: { $0.key == variable.key }) {
            all.append(variable)
            report.variables += 1
        }
        return APICollection(
            name: name, description: settings.docs, auth: auth, variables: all,
            preRequestScript: scripts.pre, testScript: scripts.post, items: built
        )
    }

    func folder(_ item: BrunoItem, path: String, inherited: [KeyValue], children: (String, [KeyValue]) -> [Node]) -> Node {
        report.folders += 1
        let folderPath = "\(path) / \(item.name)"
        let scripts = scripts(item, path: folderPath)
        // Folders here have no variables of their own.
        let variables = item.preVariables.filter { !$0.key.isEmpty }.map { Variable(key: $0.key, value: $0.value, enabled: $0.enabled) }
        if !variables.isEmpty {
            folderVariables.append(contentsOf: variables)
            warn("Folder variables (in “\(item.name)”) became collection variables, because folders here do not have variables of their own.")
        }
        return .folder(Folder(
            name: item.name, description: item.docs, auth: auth(item, path: folderPath),
            preRequestScript: scripts.pre, testScript: scripts.post,
            items: children(folderPath, inherited + item.headers.filter { !$0.key.isEmpty })
        ))
    }

    func request(_ item: BrunoItem, path: String, inherited: [KeyValue]) -> RequestItem {
        report.requests += 1
        let requestPath = "\(path) / \(item.name)"
        var request = RequestItem(name: item.name, method: item.method)
        let parts = URLParts.split(item.url)
        request.url = parts.base
        request.params = (item.query ?? parts.params).filter { !$0.key.isEmpty || !$0.value.isEmpty }
        request.pathVariables = item.pathVariables.filter { !$0.key.isEmpty }
        request.description = item.docs
        request.auth = auth(item, path: requestPath)

        let own = item.headers.filter { !$0.key.isEmpty }
        let handedDown = inherited.filter { header in
            !own.contains { $0.key.caseInsensitiveCompare(header.key) == .orderedSame }
        }
        copiedHeaders += handedDown.count
        request.headers = handedDown + own
        note(item.url)
        for header in request.headers { note(header.value) }

        if item.type == "grpc" {
            request.method = "GRPC"
            if !request.url.contains("://") { request.url = "grpc://" + request.url }
            var method = item.grpcMethod
            if method.hasPrefix("/") { method.removeFirst() }
            request.grpcMethod = method
            request.params = []
            let message = item.grpcMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            request.body = .raw(text: message.isEmpty ? "{}" : message, contentType: "application/json")
        } else {
            request.body = body(item, path: requestPath)
        }

        // Variables set before the request, and expressions saved after it, become script lines.
        var pre: [String] = []
        for variable in item.preVariables where variable.enabled && !variable.key.isEmpty {
            pre.append("bru.setVar(\(Self.quoted(variable.key)), bru.interpolate(\(Self.quoted(variable.value))));")
        }
        var post: [String] = []
        for variable in item.postVariables where !variable.key.isEmpty {
            let name = variable.key.hasPrefix("@") ? String(variable.key.dropFirst()) : variable.key
            if let source = Self.source(variable.value) {
                request.extractions.append(Extraction(variable: name, source: source, scope: .collection, enabled: variable.enabled))
            } else if variable.enabled {
                post.append("bru.setVar(\(Self.quoted(name)), \(variable.value));")
            }
        }

        for row in item.assertions where !row.key.isEmpty {
            if let assertion = Self.assertion(row) {
                request.assertions.append(assertion)
            } else {
                skippedAssertions.append("\(item.name): \(row.key) \(row.value)")
            }
        }

        if item.hasActions {
            warn("\(requestPath): its post-response actions were not imported. Add them again under “Save from response”.")
        }
        var scripts = scripts(item, path: requestPath)
        if !pre.isEmpty {
            scripts.pre = (["// From Bruno's pre-request variables"] + pre + (scripts.pre.isEmpty ? [] : ["", scripts.pre])).joined(separator: "\n")
        }
        if !post.isEmpty {
            scripts.post = (["// From Bruno's post-response variables"] + post + (scripts.post.isEmpty ? [] : ["", scripts.post])).joined(separator: "\n")
        }
        request.preRequestScript = scripts.pre
        request.testScript = scripts.post
        return request
    }

    private func scripts(_ item: BrunoItem, path: String) -> (pre: String, post: String) {
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let pre = trimmed(item.preScript)
        let post = [trimmed(item.postScript), trimmed(item.tests)].filter { !$0.isEmpty }.joined(separator: "\n\n")
        for script in [pre, post] where !script.isEmpty {
            report.scriptsPreserved += 1
            if script.contains("require(") {
                warn("\(path): its script uses require(), which is not available here; that line will stop the script.")
            }
            if script.range(of: #"\bawait\b"#, options: .regularExpression) != nil {
                warn("\(path): its script uses await, which is not available here; the script will not run until that is removed.")
            }
        }
        return (pre, post)
    }

    private func path(_ file: String) -> String {
        guard !file.isEmpty, !file.hasPrefix("/"), !file.hasPrefix("~"), !file.contains("{{"), let root else { return file }
        return root.appendingPathComponent(file).standardizedFileURL.path
    }

    private func body(_ item: BrunoItem, path requestPath: String) -> Body {
        var mode = item.bodyMode ?? ""
        if item.type == "graphql", mode.isEmpty || mode == "none" { mode = item.graphQLQuery.isEmpty ? mode : "graphql" }
        if mode.isEmpty {
            // Older files do not name the body's kind; use whichever one is there.
            if let first = ["json", "text", "xml", "sparql"].first(where: { item.bodyText[$0] != nil }) { mode = first }
            else if !item.formURLEncoded.isEmpty { mode = "formUrlEncoded" }
            else if !item.multipart.isEmpty { mode = "multipartForm" }
            else if !item.graphQLQuery.isEmpty { mode = "graphql" }
        }
        switch mode {
        case "", "none":
            return .none
        case "json", "text", "xml", "sparql":
            let types = ["json": "application/json", "text": "text/plain", "xml": "application/xml", "sparql": "application/sparql-query"]
            let text = item.bodyText[mode] ?? ""
            note(text)
            return .raw(text: text, contentType: types[mode])
        case "formUrlEncoded":
            return .urlEncoded(fields: item.formURLEncoded)
        case "multipartForm":
            return .formData(fields: item.multipart.map { field in
                var field = field
                if field.isFile { field.value = path(field.value) }
                return field
            })
        case "graphql":
            return .graphQL(query: item.graphQLQuery, variables: item.graphQLVariables)
        case "file":
            return .file(path: path(item.filePath))
        default:
            warn("\(requestPath): body type “\(mode)” is not supported; the body was left empty.")
            return .none
        }
    }

    private func auth(_ item: BrunoItem, path: String) -> Auth {
        // With no mode named, a file's auth block says which kind it is.
        let mode = item.authMode ?? item.auth.keys.sorted().first ?? "inherit"
        let settings = item.auth[mode] ?? [:]
        func field(_ names: String...) -> String {
            for name in names { if let value = settings[name], !value.isEmpty { return value } }
            return ""
        }
        for value in settings.values { note(value) }
        switch mode {
        case "inherit": return .inherit
        case "none": return .none
        case "basic": return .basic(username: field("username"), password: field("password"))
        case "bearer": return .bearer(token: field("token"))
        case "apikey":
            return .apiKey(key: field("key"), value: field("value"), placement: field("placement").lowercased().hasPrefix("query") ? .query : .header)
        case "oauth2":
            var config = OAuth2Config(
                tokenURL: field("access_token_url", "accessTokenUrl"), authURL: field("authorization_url", "authorizationUrl"),
                clientID: field("client_id", "clientId"), clientSecret: field("client_secret", "clientSecret"),
                scope: field("scope"), username: field("username"), password: field("password"),
                clientAuthInBody: field("credentials_placement", "credentialsPlacement") == "body",
                usePKCE: field("pkce") == "true"
            )
            let prefix = field("token_header_prefix", "tokenHeaderPrefix")
            if !prefix.isEmpty { config.headerPrefix = prefix }
            switch field("grant_type", "grantType") {
            case "client_credentials": config.grant = .clientCredentials
            case "password": config.grant = .password
            case "authorization_code": config.grant = .authorizationCode
            case "": config.grant = config.authURL.isEmpty ? .clientCredentials : .authorizationCode
            case let other:
                warn("\(path): OAuth 2 grant type “\(other)” is not supported; it was set to client credentials.")
            }
            return .oauth2(config)
        default:
            warn("\(path): auth type “\(mode)” is not supported yet; it was set to no auth.")
            return .none
        }
    }

    // MARK: Assertions and saved values

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
    }

    /// What `res.status`, `res.body.items[0].id` or `res.headers.etag` reads, if it is that simple.
    static func source(_ expression: String) -> ValueSource? {
        var text = expression.trimmingCharacters(in: .whitespaces)
        // Older files write $res.
        if text.hasPrefix("$res") { text.removeFirst() }
        if text == "res.status" { return ValueSource(kind: .status) }
        if text == "res.responseTime" { return ValueSource(kind: .time) }
        if text == "res.body" { return ValueSource(kind: .body) }
        for prefix in ["res.body", "res.headers"] where text.hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count))
            guard rest.hasPrefix(".") || rest.hasPrefix("[") else { continue }
            if prefix == "res.body" {
                guard let steps = JSONPath.parse("$" + rest), !steps.isEmpty else { return nil }
                return ValueSource(kind: .json, path: "$" + rest)
            }
            guard let steps = JSONPath.parse("$" + rest), steps.count == 1, case .key(let name) = steps[0] else { return nil }
            return ValueSource(kind: .header, path: name)
        }
        return nil
    }

    /// An `assert` row such as `res.status: eq 200`, where it has an equivalent here.
    static func assertion(_ row: KeyValue) -> Assertion? {
        guard let source = source(row.key) else { return nil }
        let text = row.value.trimmingCharacters(in: .whitespaces)
        let word = String(text.prefix { !$0.isWhitespace })
        var operand = String(text.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
        func unquoted(_ value: String) -> String {
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                return String(value.dropFirst().dropLast())
            }
            return value
        }
        let op: AssertionOperator
        switch word {
        case "eq": op = .equals
        case "neq": op = .notEquals
        case "gt": op = .greaterThan
        case "lt": op = .lessThan
        case "contains": op = .contains
        case "notContains": op = .notContains
        case "matches": op = .matches
        case "startsWith":
            op = .matches
            operand = "^" + NSRegularExpression.escapedPattern(for: unquoted(operand))
        case "endsWith":
            op = .matches
            operand = NSRegularExpression.escapedPattern(for: unquoted(operand)) + "$"
        case "isDefined": op = .exists
        case "isUndefined": op = .notExists
        case "gte", "lte", "in", "notIn", "length", "notMatches", "between", "isEmpty", "isNotEmpty", "isNull", "isNotNull",
             "isTruthy", "isFalsy", "isJson", "isNumber", "isString", "isBoolean", "isArray":
            return nil
        default:
            // With no operator, the whole value is what the result should equal.
            op = .equals
            operand = text
        }
        return Assertion(source: source, op: op, expected: unquoted(operand), enabled: row.enabled)
    }

    // MARK: Finishing

    func finish(_ collection: inout APICollection) {
        if copiedHeaders > 0 {
            warn("Headers set on the collection and its folders were copied onto the requests inside them (\(copiedHeaders) in all), because only requests have headers here.")
        }
        if !skippedAssertions.isEmpty {
            let shown = skippedAssertions.prefix(5).joined(separator: "; ")
            let more = skippedAssertions.count > 5 ? "; and \(skippedAssertions.count - 5) more" : ""
            warn("\(skippedAssertions.count) \(skippedAssertions.count == 1 ? "assertion has" : "assertions have") no equivalent here and \(skippedAssertions.count == 1 ? "was" : "were") left out: \(shown)\(more).")
        }
        if processEnvironment > 0 {
            warn("\(processEnvironment) \(processEnvironment == 1 ? "value reads" : "values read") {{process.env…}}, from a .env file. Those are not read here; add them as variables.")
        }
        if !skippedTypes.isEmpty {
            let list = skippedTypes.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
            warn("Items of a kind that cannot be imported were left out: \(list).")
        }
    }
}
