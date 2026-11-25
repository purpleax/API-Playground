import Foundation

/// What an import brought across, and what needs attention.
public struct ImportReport: Equatable, Sendable {
    public var requests = 0
    public var folders = 0
    public var examples = 0
    public var variables = 0
    /// Scripts are kept but do not run until the script runtime exists.
    public var scriptsPreserved = 0
    public var warnings: [String] = []

    public init() {}
}

public enum PostmanImportError: Error, LocalizedError, Equatable {
    case notJSON
    case notPostman

    public var errorDescription: String? {
        switch self {
        case .notJSON: return "The file is not valid JSON."
        case .notPostman: return "The file is not a Postman collection or environment export."
        }
    }
}

public enum PostmanDocument: Sendable {
    case collection(APICollection, ImportReport)
    /// `isGlobals` is true for a Postman globals export.
    case environment(APIEnvironment, isGlobals: Bool, ImportReport)
}

/// Reads Postman Collection v2.0 and v2.1 files and Postman environment files.
public enum PostmanImporter {

    public static func importDocument(data: Data) throws -> PostmanDocument {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PostmanImportError.notJSON
        }
        // The Postman API wraps exports in a "collection" or "environment" key.
        if let wrapped = root["collection"] as? [String: Any] { root = wrapped }
        if let wrapped = root["environment"] as? [String: Any] { root = wrapped }

        if root["info"] is [String: Any], root["item"] != nil {
            var report = ImportReport()
            let collection = parseCollection(root, report: &report)
            return .collection(collection, report)
        }
        if root["values"] is [Any] {
            var report = ImportReport()
            let environment = parseEnvironment(root, report: &report)
            let isGlobals = (root["_postman_variable_scope"] as? String) == "globals"
            return .environment(environment, isGlobals: isGlobals, report)
        }
        throw PostmanImportError.notPostman
    }

    // MARK: Collection

    private static func parseCollection(_ root: [String: Any], report: inout ImportReport) -> APICollection {
        let info = root["info"] as? [String: Any] ?? [:]
        let name = info["name"] as? String ?? "Imported Collection"
        let scripts = parseScripts(root["event"], report: &report)
        let variables = parseVariables(root["variable"] as? [Any] ?? [], enabledKey: nil)
        report.variables += variables.count

        var auth = parseAuth(root["auth"], path: name, report: &report)
        if auth == .inherit { auth = .none }

        return APICollection(
            name: name,
            description: descriptionText(info["description"]),
            auth: auth,
            variables: variables,
            preRequestScript: scripts.preRequest,
            testScript: scripts.test,
            postmanID: info["_postman_id"] as? String,
            items: parseItems(root["item"] as? [Any] ?? [], path: name, report: &report)
        )
    }

    private static func parseItems(_ items: [Any], path: String, report: inout ImportReport) -> [Node] {
        var nodes: [Node] = []
        for case let item as [String: Any] in items {
            let name = item["name"] as? String ?? "Untitled"
            let itemPath = "\(path) / \(name)"
            if let children = item["item"] as? [Any] {
                let scripts = parseScripts(item["event"], report: &report)
                report.folders += 1
                nodes.append(.folder(Folder(
                    name: name,
                    description: descriptionText(item["description"]),
                    auth: parseAuth(item["auth"], path: itemPath, report: &report),
                    preRequestScript: scripts.preRequest,
                    testScript: scripts.test,
                    items: parseItems(children, path: itemPath, report: &report)
                )))
            } else if let request = item["request"] {
                nodes.append(.request(parseRequest(request, item: item, name: name, path: itemPath, report: &report)))
            }
        }
        return nodes
    }

    private static func parseRequest(
        _ raw: Any, item: [String: Any], name: String, path: String, report: inout ImportReport
    ) -> RequestItem {
        report.requests += 1
        var request = RequestItem(name: name)

        // In v2.0 a request can be just a URL string.
        if let urlString = raw as? String {
            let parts = URLParts.split(urlString)
            request.url = parts.base
            request.params = parts.params
            return request
        }
        guard let dict = raw as? [String: Any] else { return request }

        request.method = (dict["method"] as? String ?? "GET").uppercased()
        request.description = descriptionText(dict["description"])
        request.auth = parseAuth(dict["auth"], path: path, report: &report)
        request.headers = parseHeaders(dict["header"])
        request.body = parseBody(dict["body"], path: path, report: &report)

        let url = parseURL(dict["url"])
        request.url = url.base
        request.params = url.params
        request.pathVariables = url.pathVariables

        let scripts = parseScripts(item["event"], report: &report)
        request.preRequestScript = scripts.preRequest
        request.testScript = scripts.test

        for case let example as [String: Any] in item["response"] as? [Any] ?? [] {
            report.examples += 1
            request.examples.append(SavedResponse(
                name: example["name"] as? String ?? "Example",
                status: example["code"] as? Int ?? 0,
                headers: parseHeaders(example["header"]),
                body: example["body"] as? String ?? ""
            ))
        }
        return request
    }

    private static func parseURL(_ raw: Any?) -> (base: String, params: [KeyValue], pathVariables: [KeyValue]) {
        if let string = raw as? String {
            let parts = URLParts.split(string)
            return (parts.base, parts.params, [])
        }
        guard let dict = raw as? [String: Any] else { return ("", [], []) }

        var rawURL = dict["raw"] as? String ?? ""
        if rawURL.isEmpty {
            // Rebuild from the parts when "raw" is missing.
            let host = (dict["host"] as? [String])?.joined(separator: ".") ?? (dict["host"] as? String ?? "")
            let pathPart = (dict["path"] as? [Any])?.map { "\($0)" }.joined(separator: "/") ?? (dict["path"] as? String ?? "")
            let scheme = (dict["protocol"] as? String).map { "\($0)://" } ?? ""
            let port = (dict["port"] as? String).map { ":\($0)" } ?? ""
            rawURL = scheme + host + port + (pathPart.isEmpty ? "" : "/" + pathPart)
        }
        let parts = URLParts.split(rawURL)

        var params = parts.params
        if let query = dict["query"] as? [Any] {
            // The structured list is more reliable than the raw string, and keeps disabled rows.
            params = query.compactMap { entry in
                guard let q = entry as? [String: Any] else { return nil }
                return KeyValue(
                    key: stringValue(q["key"]),
                    value: stringValue(q["value"]),
                    enabled: !(q["disabled"] as? Bool ?? false),
                    note: nonEmpty(descriptionText(q["description"]))
                )
            }
        }

        let pathVariables: [KeyValue] = (dict["variable"] as? [Any] ?? []).compactMap { entry in
            guard let v = entry as? [String: Any] else { return nil }
            return KeyValue(
                key: stringValue(v["key"]),
                value: stringValue(v["value"]),
                note: nonEmpty(descriptionText(v["description"]))
            )
        }
        return (parts.base, params, pathVariables)
    }

    private static func parseHeaders(_ raw: Any?) -> [KeyValue] {
        if let list = raw as? [Any] {
            return list.compactMap { entry in
                guard let h = entry as? [String: Any] else { return nil }
                return KeyValue(
                    key: stringValue(h["key"]),
                    value: stringValue(h["value"]),
                    enabled: !(h["disabled"] as? Bool ?? false),
                    note: nonEmpty(descriptionText(h["description"]))
                )
            }
        }
        // v2.0 allows headers as one "Name: value" string per line.
        if let text = raw as? String {
            return text.split(whereSeparator: \.isNewline).compactMap { line in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return KeyValue(
                    key: line[..<colon].trimmingCharacters(in: .whitespaces),
                    value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                )
            }
        }
        return []
    }

    private static func parseBody(_ raw: Any?, path: String, report: inout ImportReport) -> Body {
        guard let dict = raw as? [String: Any], !(dict["disabled"] as? Bool ?? false) else { return .none }
        switch dict["mode"] as? String {
        case "raw":
            let options = (dict["options"] as? [String: Any])?["raw"] as? [String: Any]
            let contentType: String?
            switch options?["language"] as? String {
            case "json": contentType = "application/json"
            case "xml": contentType = "application/xml"
            case "html": contentType = "text/html"
            case "javascript": contentType = "application/javascript"
            case "text": contentType = "text/plain"
            default: contentType = nil
            }
            return .raw(text: dict["raw"] as? String ?? "", contentType: contentType)
        case "urlencoded":
            let fields: [KeyValue] = (dict["urlencoded"] as? [Any] ?? []).compactMap { entry in
                guard let f = entry as? [String: Any] else { return nil }
                return KeyValue(
                    key: stringValue(f["key"]),
                    value: stringValue(f["value"]),
                    enabled: !(f["disabled"] as? Bool ?? false)
                )
            }
            return .urlEncoded(fields: fields)
        case "formdata":
            let fields: [FormField] = (dict["formdata"] as? [Any] ?? []).compactMap { entry in
                guard let f = entry as? [String: Any] else { return nil }
                let isFile = (f["type"] as? String) == "file"
                let source = (f["src"] as? String) ?? (f["src"] as? [String])?.first ?? ""
                return FormField(
                    key: stringValue(f["key"]),
                    value: isFile ? source : stringValue(f["value"]),
                    isFile: isFile,
                    enabled: !(f["disabled"] as? Bool ?? false)
                )
            }
            return .formData(fields: fields)
        case "graphql":
            let graphql = dict["graphql"] as? [String: Any] ?? [:]
            return .graphQL(query: graphql["query"] as? String ?? "", variables: stringValue(graphql["variables"]))
        case "file":
            return .file(path: (dict["file"] as? [String: Any])?["src"] as? String ?? "")
        case nil:
            return .none
        case let other?:
            report.warnings.append("\(path): body type \"\(other)\" is not supported; the body was left empty.")
            return .none
        }
    }

    private static func parseAuth(_ raw: Any?, path: String, report: inout ImportReport) -> Auth {
        guard let dict = raw as? [String: Any], let type = dict["type"] as? String else { return .inherit }

        // v2.1 stores settings as a list of {key, value}; v2.0 stores them as a dictionary.
        var settings: [String: String] = [:]
        if let list = dict[type] as? [Any] {
            for case let entry as [String: Any] in list {
                if let key = entry["key"] as? String { settings[key] = stringValue(entry["value"]) }
            }
        } else if let map = dict[type] as? [String: Any] {
            for (key, value) in map { settings[key] = stringValue(value) }
        }

        switch type {
        case "noauth":
            return .none
        case "basic":
            return .basic(username: settings["username"] ?? "", password: settings["password"] ?? "")
        case "bearer":
            return .bearer(token: settings["token"] ?? "")
        case "apikey":
            let placement: APIKeyPlacement = settings["in"] == "query" ? .query : .header
            return .apiKey(key: settings["key"] ?? "", value: settings["value"] ?? "", placement: placement)
        default:
            report.warnings.append("\(path): auth type \"\(type)\" is not supported yet; it was set to no auth.")
            return .none
        }
    }

    private static func parseScripts(_ raw: Any?, report: inout ImportReport) -> (preRequest: String, test: String) {
        var preRequest = ""
        var test = ""
        for case let event as [String: Any] in raw as? [Any] ?? [] {
            let script = event["script"] as? [String: Any]
            let source: String
            if let lines = script?["exec"] as? [String] {
                source = lines.joined(separator: "\n")
            } else {
                source = script?["exec"] as? String ?? ""
            }
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            switch event["listen"] as? String {
            case "prerequest":
                preRequest = source
                report.scriptsPreserved += 1
            case "test":
                test = source
                report.scriptsPreserved += 1
            default:
                continue
            }
        }
        return (preRequest, test)
    }

    // MARK: Environment

    private static func parseEnvironment(_ root: [String: Any], report: inout ImportReport) -> APIEnvironment {
        let variables = parseVariables(root["values"] as? [Any] ?? [], enabledKey: "enabled")
        report.variables += variables.count
        return APIEnvironment(
            name: root["name"] as? String ?? "Imported Environment",
            variables: variables,
            postmanID: root["id"] as? String
        )
    }

    /// Environments mark rows with "enabled"; collection variables use "disabled".
    private static func parseVariables(_ list: [Any], enabledKey: String?) -> [Variable] {
        list.compactMap { entry in
            guard let v = entry as? [String: Any] else { return nil }
            let enabled: Bool
            if let enabledKey {
                enabled = v[enabledKey] as? Bool ?? true
            } else {
                enabled = !(v["disabled"] as? Bool ?? false)
            }
            return Variable(
                key: stringValue(v["key"]),
                value: stringValue(v["value"]),
                enabled: enabled,
                secret: (v["type"] as? String) == "secret"
            )
        }
    }

    // MARK: Helpers

    /// Postman descriptions are either a string or `{content, type}`.
    private static func descriptionText(_ raw: Any?) -> String {
        if let text = raw as? String { return text }
        if let dict = raw as? [String: Any] { return dict["content"] as? String ?? "" }
        return ""
    }

    /// Postman values are usually strings but can be numbers, booleans or null.
    private static func stringValue(_ raw: Any?) -> String {
        switch raw {
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            return ""
        }
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }
}

/// Splits a URL string into the part before `?` and its query parameters.
enum URLParts {
    static func split(_ raw: String) -> (base: String, params: [KeyValue]) {
        var url = raw
        if let hash = url.firstIndex(of: "#") { url = String(url[..<hash]) }
        guard let question = url.firstIndex(of: "?") else { return (url, []) }
        let base = String(url[..<question])
        let query = url[url.index(after: question)...]
        let params: [KeyValue] = query.split(separator: "&").map { pair in
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(pieces[0])
            let value = pieces.count > 1 ? String(pieces[1]) : ""
            return KeyValue(key: key.removingPercentEncoding ?? key, value: value.removingPercentEncoding ?? value)
        }
        return (base, params)
    }
}
