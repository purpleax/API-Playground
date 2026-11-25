import Foundation

public enum LintSeverity: Int, Comparable, Sendable, CaseIterable {
    case error, warning, info, hint

    public static func < (a: LintSeverity, b: LintSeverity) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .error: return "Error"
        case .warning: return "Warning"
        case .info: return "Info"
        case .hint: return "Hint"
        }
    }

    /// Reads a severity as Spectral rulesets write it: a name, or 0 to 3.
    init?(_ node: SpecNode?) {
        switch node?.string?.lowercased() {
        case "error", "0": self = .error
        case "warn", "warning", "1": self = .warning
        case "info", "information", "2": self = .info
        case "hint", "3": self = .hint
        default: return nil
        }
    }
}

public struct LintIssue: Identifiable, Equatable, Sendable {
    public var id = UUID()
    /// The rule's name, such as `operation-description`.
    public var rule: String
    public var message: String
    public var severity: LintSeverity
    /// 1-based line in the spec, or 0 when the finding is not about one place.
    public var line: Int
    /// Where in the document, such as `paths./pets.get`.
    public var path: String

    public static func == (a: LintIssue, b: LintIssue) -> Bool {
        a.rule == b.rule && a.message == b.message && a.severity == b.severity && a.line == b.line && a.path == b.path
    }
}

public struct LintRuleInfo: Identifiable, Equatable, Sendable {
    public var name: String
    public var summary: String
    public var severity: LintSeverity
    public var id: String { name }
}

/// Checks an OpenAPI document against a set of rules.
///
/// The built-in rules follow Spectral's `spectral:oas` ruleset and use its rule names, so
/// a ruleset written for Spectral can switch them off or change their severity. Custom
/// rules are read from the same ruleset format, for the functions listed in `functions`.
public enum SpecLinter {
    public static let builtInRules: [LintRuleInfo] = [
        LintRuleInfo(name: "parser", summary: "The text must be valid YAML or JSON, with no key repeated.", severity: .error),
        LintRuleInfo(name: "oas3-schema", summary: "The document must have the parts OpenAPI requires.", severity: .error),
        LintRuleInfo(name: "invalid-ref", summary: "Every $ref must point at something in the document.", severity: .error),
        LintRuleInfo(name: "no-$ref-siblings", summary: "Nothing may sit beside a $ref (before OpenAPI 3.1).", severity: .error),
        LintRuleInfo(name: "path-params", summary: "Path parameters must be declared, required and used.", severity: .error),
        LintRuleInfo(name: "operation-operationId-unique", summary: "Every operationId must be different.", severity: .error),
        LintRuleInfo(name: "openapi-tags-uniqueness", summary: "Every tag name must be different.", severity: .error),
        LintRuleInfo(name: "info-contact", summary: "The info section should say who to contact.", severity: .warning),
        LintRuleInfo(name: "info-description", summary: "The info section should describe the API.", severity: .warning),
        LintRuleInfo(name: "oas3-api-servers", summary: "At least one server should be listed.", severity: .warning),
        LintRuleInfo(name: "oas3-server-trailing-slash", summary: "A server URL should not end with a slash.", severity: .warning),
        LintRuleInfo(name: "operation-operationId", summary: "Every operation should have an operationId.", severity: .warning),
        LintRuleInfo(name: "operation-operationId-valid-in-url", summary: "An operationId should only use characters that are safe in a URL.", severity: .warning),
        LintRuleInfo(name: "operation-description", summary: "Every operation should have a description.", severity: .warning),
        LintRuleInfo(name: "operation-tags", summary: "Every operation should have at least one tag.", severity: .warning),
        LintRuleInfo(name: "operation-tag-defined", summary: "An operation's tags should be listed in the document's tags.", severity: .warning),
        LintRuleInfo(name: "operation-success-response", summary: "Every operation should document a 2xx or 3xx response.", severity: .warning),
        LintRuleInfo(name: "operation-parameters", summary: "An operation should not declare the same parameter twice.", severity: .warning),
        LintRuleInfo(name: "operation-security-defined", summary: "A security requirement should name a declared scheme.", severity: .warning),
        LintRuleInfo(name: "path-keys-no-trailing-slash", summary: "A path should not end with a slash.", severity: .warning),
        LintRuleInfo(name: "path-not-include-query", summary: "A path should not contain a query string.", severity: .warning),
        LintRuleInfo(name: "path-declarations-must-exist", summary: "A path parameter should have a name between its braces.", severity: .warning),
        LintRuleInfo(name: "typed-enum", summary: "Enum values should match the schema's type.", severity: .warning),
        LintRuleInfo(name: "duplicated-entry-in-enum", summary: "An enum should not list a value twice.", severity: .warning),
        LintRuleInfo(name: "no-eval-in-markdown", summary: "Descriptions should not contain eval().", severity: .warning),
        LintRuleInfo(name: "no-script-tags-in-markdown", summary: "Descriptions should not contain <script> tags.", severity: .warning),
        LintRuleInfo(name: "oas3-unused-component", summary: "A reusable component should be used somewhere.", severity: .warning),
    ]

    /// The functions a custom rule can use.
    public static let functions = ["truthy", "falsy", "defined", "undefined", "pattern", "casing", "length", "enumeration", "alphabetical", "xor"]

    /// - Parameter ruleset: A Spectral ruleset, or empty for the built-in rules alone.
    public static func lint(_ text: String, ruleset: String = "") -> [LintIssue] {
        var config = Ruleset(text: ruleset)
        var issues = config.problems

        let root: SpecNode
        do {
            let parsed = try SpecParser.parse(text)
            root = parsed.root
            for problem in parsed.problems {
                issues.append(LintIssue(rule: "parser", message: problem.message, severity: .error, line: problem.line, path: ""))
            }
        } catch let error as SpecParseError {
            return issues + [LintIssue(rule: "parser", message: error.message, severity: .error, line: error.line, path: "")]
        } catch {
            return issues + [LintIssue(rule: "parser", message: error.localizedDescription, severity: .error, line: 0, path: "")]
        }

        if config.useBuiltIns {
            var check = BuiltIn(root: root)
            check.run()
            for var issue in check.issues {
                // The Swagger 2 versions of a rule go by their own names in Spectral.
                let names = [issue.rule, issue.rule.replacingOccurrences(of: "oas2-", with: "oas3-")]
                if names.contains(where: { config.disabled.contains($0) }) { continue }
                if config.builtInsOffByDefault, !names.contains(where: { config.severities[$0] != nil }) { continue }
                if let severity = names.compactMap({ config.severities[$0] }).first { issue.severity = severity }
                issues.append(issue)
            }
        }
        for rule in config.custom {
            issues.append(contentsOf: rule.run(on: root, problems: &config.problems))
        }
        // Problems found while running custom rules (an unknown function, say) come last.
        for problem in config.problems where !issues.contains(problem) { issues.append(problem) }

        return issues.sorted { ($0.line, $0.severity, $0.rule) < ($1.line, $1.severity, $1.rule) }
    }
}

// MARK: - Built-in rules

private struct BuiltIn {
    let root: SpecNode
    var issues: [LintIssue] = []

    static let methods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

    init(root: SpecNode) {
        self.root = root
    }

    mutating func emit(_ rule: String, _ message: String, line: Int, path: [String]) {
        let severity = SpecLinter.builtInRules.first { $0.name == rule || $0.name == rule.replacingOccurrences(of: "oas2-", with: "oas3-") }?.severity ?? .warning
        issues.append(LintIssue(rule: rule, message: message, severity: severity, line: line, path: path.joined(separator: ".")))
    }

    func lookup(_ ref: String) -> SpecNode? {
        guard ref.hasPrefix("#/") else { return ref == "#" ? root : nil }
        let path = ref.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false).map {
            ($0.removingPercentEncoding ?? String($0)).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
        return root.at(path)
    }

    func resolve(_ node: SpecNode, depth: Int = 0) -> SpecNode {
        guard depth < 20, let ref = node["$ref"]?.string, let target = lookup(ref) else { return node }
        return resolve(target, depth: depth + 1)
    }

    mutating func run() {
        guard root.isMap else {
            emit("oas3-schema", "The document should be a map that starts with “openapi:”.", line: root.line, path: [])
            return
        }
        let swagger = root["swagger"] != nil
        let schemaRule = swagger ? "oas2-schema" : "oas3-schema"
        let version = root["openapi"]?.string ?? root["swagger"]?.string
        guard let version else {
            emit("oas3-schema", "The document has no “openapi” version, so it cannot be checked as an OpenAPI document.", line: 1, path: [])
            return
        }
        let is31 = version.hasPrefix("3.1")

        // Required structure
        if let info = root["info"], info.isMap {
            let infoLine = root.line(ofKey: "info") ?? info.line
            if info["title"]?.string?.isEmpty ?? true { emit(schemaRule, "“info” needs a “title”.", line: infoLine, path: ["info"]) }
            if info["version"] == nil { emit(schemaRule, "“info” needs a “version”.", line: infoLine, path: ["info"]) }
            if info["contact"] == nil { emit("info-contact", "“info” should have a “contact”.", line: infoLine, path: ["info"]) }
            if info["description"]?.string?.isEmpty ?? true { emit("info-description", "“info” should have a “description”.", line: infoLine, path: ["info"]) }
        } else {
            emit(schemaRule, "The document needs an “info” section.", line: 1, path: [])
        }
        let paths = root["paths"]
        if paths == nil, !(is31 && (root["webhooks"] != nil || root["components"] != nil)) {
            emit(schemaRule, "The document needs a “paths” section.", line: 1, path: [])
        } else if let paths, !paths.isMap, !paths.isNull {
            emit(schemaRule, "“paths” should be a map of paths.", line: paths.line, path: ["paths"])
        }

        // Servers
        if swagger {
            if root["host"]?.string?.isEmpty ?? true { emit("oas2-api-host", "The document should give a “host”.", line: 1, path: []) }
            if root["schemes"]?.items.isEmpty ?? true { emit("oas2-api-schemes", "The document should list its “schemes”.", line: 1, path: []) }
        } else {
            let servers = root["servers"]?.items ?? []
            if servers.isEmpty { emit("oas3-api-servers", "The document should list at least one server.", line: root.line(ofKey: "servers") ?? 1, path: ["servers"]) }
            for (index, server) in servers.enumerated() {
                if let url = server["url"]?.string, url.count > 1, url.hasSuffix("/") {
                    emit("oas3-server-trailing-slash", "The server URL should not end with a slash.", line: server.line(ofKey: "url") ?? server.line, path: ["servers", String(index), "url"])
                }
            }
        }

        // Tags
        var tagNames: [String] = []
        for (index, tag) in (root["tags"]?.items ?? []).enumerated() {
            guard let name = tag["name"]?.string else { continue }
            if tagNames.contains(name) {
                emit("openapi-tags-uniqueness", "The tag “\(name)” is listed more than once.", line: tag.line, path: ["tags", String(index)])
            }
            tagNames.append(name)
        }

        let schemes = swagger ? root["securityDefinitions"] : root["components"]?["securitySchemes"]
        checkSecurity(root["security"], schemes: schemes, path: ["security"])

        // Paths and operations
        var operationIDs: [String: Int] = [:]
        for pathEntry in paths?.entries ?? [] where pathEntry.key.hasPrefix("/") {
            let path = pathEntry.key
            let location = ["paths", path]
            if path.count > 1, path.hasSuffix("/") {
                emit("path-keys-no-trailing-slash", "The path should not end with a slash.", line: pathEntry.line, path: location)
            }
            if path.contains("?") {
                emit("path-not-include-query", "The path should not contain a query string. Declare query parameters instead.", line: pathEntry.line, path: location)
            }
            if path.contains("{}") {
                emit("path-declarations-must-exist", "A path parameter has no name between its braces.", line: pathEntry.line, path: location)
            }
            let item = resolve(pathEntry.node)
            let shared = (item["parameters"]?.items ?? []).map { resolve($0) }
            let templated = Self.templateNames(in: path)

            for operationEntry in item.entries where Self.methods.contains(operationEntry.key.lowercased()) {
                let operation = operationEntry.node
                let here = location + [operationEntry.key]
                let line = operationEntry.line

                if let id = operation["operationId"]?.string, !id.isEmpty {
                    if let first = operationIDs[id] {
                        emit("operation-operationId-unique", "The operationId “\(id)” is already used on line \(first).", line: operation.line(ofKey: "operationId") ?? line, path: here + ["operationId"])
                    } else {
                        operationIDs[id] = line
                    }
                    if id.range(of: #"^[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=]*$"#, options: .regularExpression) == nil {
                        emit("operation-operationId-valid-in-url", "The operationId “\(id)” has characters that are not safe in a URL.", line: operation.line(ofKey: "operationId") ?? line, path: here + ["operationId"])
                    }
                } else {
                    emit("operation-operationId", "The operation should have an “operationId”.", line: line, path: here)
                }
                if operation["description"]?.string?.isEmpty ?? true {
                    emit("operation-description", "The operation should have a “description”.", line: line, path: here)
                }
                let tags = (operation["tags"]?.items ?? []).compactMap(\.string)
                if tags.isEmpty {
                    emit("operation-tags", "The operation should have at least one tag.", line: line, path: here)
                }
                for tag in tags where !tagNames.contains(tag) {
                    emit("operation-tag-defined", "The tag “\(tag)” is not listed in the document's “tags”.", line: operation.line(ofKey: "tags") ?? line, path: here + ["tags"])
                }
                let statuses = operation["responses"]?.entries.map(\.key) ?? []
                if !statuses.contains(where: { $0.hasPrefix("2") || $0.hasPrefix("3") }) {
                    emit("operation-success-response", "The operation should document at least one 2xx or 3xx response.", line: operation.line(ofKey: "responses") ?? line, path: here + ["responses"])
                }
                checkSecurity(operation["security"], schemes: schemes, path: here + ["security"])

                // Parameters
                let own = (operation["parameters"]?.items ?? []).map { resolve($0) }
                var seen: [String] = []
                for parameter in own {
                    let key = "\(parameter["in"]?.string ?? "")/\(parameter["name"]?.string ?? "")"
                    if seen.contains(key) {
                        emit("operation-parameters", "The \(parameter["in"]?.string ?? "") parameter “\(parameter["name"]?.string ?? "")” is declared more than once.", line: parameter.line, path: here + ["parameters"])
                    }
                    seen.append(key)
                }
                var declared: [String] = []
                for parameter in shared + own where parameter["in"]?.string == "path" {
                    guard let name = parameter["name"]?.string else { continue }
                    declared.append(name)
                    if parameter["required"]?.bool != true {
                        emit("path-params", "The path parameter “\(name)” must have “required: true”.", line: parameter.line, path: here + ["parameters"])
                    }
                    if !templated.contains(name) {
                        emit("path-params", "The path parameter “\(name)” is declared but “{\(name)}” is not in the path.", line: parameter.line, path: here + ["parameters"])
                    }
                }
                for name in templated where !declared.contains(name) {
                    emit("path-params", "The operation does not declare the path parameter “\(name)”.", line: line, path: here)
                }
            }
        }

        // Everything else is found by walking the whole document.
        var refs = Set<String>()
        walk(root, path: [], is31: is31, refs: &refs)

        let components: [(section: SpecNode?, prefix: String, rule: String, where: [String])] = swagger
            ? [(root["definitions"], "#/definitions/", "oas2-unused-definition", ["definitions"])]
            : ["schemas", "parameters", "responses", "requestBodies", "headers", "examples"].map {
                (root["components"]?[$0], "#/components/\($0)/", "oas3-unused-component", ["components", $0])
            }
        for component in components {
            for entry in component.section?.entries ?? [] where !refs.contains(component.prefix + entry.key) {
                emit(component.rule, "“\(entry.key)” is never used.", line: entry.line, path: component.where + [entry.key])
            }
        }
    }

    static func templateNames(in path: String) -> [String] {
        var names: [String] = []
        var rest = Substring(path)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let name = String(rest[rest.index(after: open)..<close])
            if !name.isEmpty { names.append(name) }
            rest = rest[rest.index(after: close)...]
        }
        return names
    }

    mutating func checkSecurity(_ security: SpecNode?, schemes: SpecNode?, path: [String]) {
        for requirement in security?.items ?? [] {
            for entry in requirement.entries where schemes?[entry.key] == nil {
                emit("operation-security-defined", "The security scheme “\(entry.key)” is not declared.", line: entry.line, path: path)
            }
        }
    }

    mutating func walk(_ node: SpecNode, path: [String], is31: Bool, refs: inout Set<String>) {
        switch node.value {
        case .list(let items):
            for (index, item) in items.enumerated() { walk(item, path: path + [String(index)], is31: is31, refs: &refs) }
        case .map(let entries):
            // A map named "properties" holds schemas by name, so its keys are not keywords.
            let keysAreNames = ["properties", "patternProperties", "schemas", "definitions", "headers", "parameters", "responses", "examples", "paths"].contains(path.last ?? "")
            for entry in entries {
                let here = path + [entry.key]
                if !keysAreNames {
                    switch entry.key {
                    case "$ref":
                        guard let ref = entry.node.string else { break }
                        refs.insert(ref)
                        if ref.hasPrefix("#"), lookup(ref) == nil {
                            emit("invalid-ref", "“\(ref)” does not point at anything in this document.", line: entry.line, path: here)
                        }
                        if !is31, entries.count > 1 {
                            emit("no-$ref-siblings", "Nothing else may sit beside a $ref here; the other keys are ignored.", line: entry.line, path: path)
                        }
                        continue
                    case "enum":
                        checkEnum(entry, type: node["type"]?.string, path: here)
                        continue
                    case "description", "title", "summary":
                        if let text = entry.node.string {
                            if text.contains("eval(") { emit("no-eval-in-markdown", "The text should not contain “eval(”.", line: entry.line, path: here) }
                            if text.lowercased().contains("<script") { emit("no-script-tags-in-markdown", "The text should not contain a <script> tag.", line: entry.line, path: here) }
                        }
                        continue
                    case "example", "examples", "default", "const":
                        // Example data can look like anything, so it is not checked.
                        continue
                    default:
                        break
                    }
                }
                walk(entry.node, path: here, is31: is31, refs: &refs)
            }
        default:
            break
        }
    }

    mutating func checkEnum(_ entry: SpecEntry, type: String?, path: [String]) {
        guard entry.node.isList else { return }
        var seen: [SpecNode.Value] = []
        for value in entry.node.items {
            if seen.contains(value.value) {
                emit("duplicated-entry-in-enum", "The enum lists “\(value.string ?? value.jsonText(pretty: false))” more than once.", line: value.line, path: path)
            }
            seen.append(value.value)
            guard let type else { continue }
            let fits: Bool
            switch (type, value.value) {
            case (_, .null): fits = true
            case ("string", .string), ("boolean", .bool), ("number", .number), ("array", .list), ("object", .map): fits = true
            case ("integer", .number(let number, _)): fits = number == number.rounded()
            case ("string", _), ("boolean", _), ("number", _), ("integer", _), ("array", _), ("object", _): fits = false
            default: fits = true
            }
            if !fits {
                emit("typed-enum", "The enum value “\(value.string ?? value.jsonText(pretty: false))” is not a \(type).", line: value.line, path: path)
            }
        }
    }
}

// MARK: - Rulesets

/// A Spectral ruleset, as far as this linter understands it.
struct Ruleset {
    var useBuiltIns = true
    /// True when the ruleset extends `spectral:oas` with every rule off, to switch on a chosen few.
    var builtInsOffByDefault = false
    var disabled = Set<String>()
    var severities: [String: LintSeverity] = [:]
    var custom: [CustomRule] = []
    var problems: [LintIssue] = []

    init(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        func problem(_ message: String) -> LintIssue {
            LintIssue(rule: "ruleset", message: message, severity: .info, line: 0, path: "")
        }
        let root: SpecNode
        do {
            root = try SpecParser.parse(text).root
        } catch {
            problems.append(problem("The ruleset could not be read, so only the built-in rules were used. \(error.localizedDescription)"))
            return
        }
        guard root.isMap else {
            problems.append(problem("The ruleset should be a map with “extends” and “rules”. Only the built-in rules were used."))
            return
        }

        // Without "extends: spectral:oas", a ruleset stands alone, as it does in Spectral.
        useBuiltIns = false
        let extends = root["extends"]
        let entries = extends.map { $0.isList ? $0.items : [$0] } ?? []
        for entry in entries {
            let name = entry.isList ? entry.items.first?.string : entry.string
            guard let name else { continue }
            if name == "spectral:oas" {
                useBuiltIns = true
                if entry.isList, entry.items.dropFirst().first?.string == "off" { builtInsOffByDefault = true }
            } else {
                problems.append(problem("The ruleset extends “\(name)”, which is not available here. Only “spectral:oas” can be extended."))
            }
        }
        for key in root.entries.map(\.key) where !["extends", "rules", "formats", "documentationUrl", "description"].contains(key) {
            problems.append(problem("The ruleset's “\(key)” section is not supported and was ignored."))
        }

        for entry in root["rules"]?.entries ?? [] {
            let node = entry.node
            if node.isMap {
                if node["given"] == nil, node["then"] == nil {
                    // A built-in rule with only its severity changed.
                    if let severity = LintSeverity(node["severity"]) { severities[entry.key] = severity }
                    continue
                }
                custom.append(CustomRule(name: entry.key, node: node))
            } else if node.bool == false || node.string?.lowercased() == "off" || node.string == "-1" {
                disabled.insert(entry.key)
            } else if let severity = LintSeverity(node) {
                severities[entry.key] = severity
            } else if node.bool == true {
                severities[entry.key] = SpecLinter.builtInRules.first { $0.name == entry.key }?.severity ?? .warning
            }
        }
    }
}

struct CustomRule {
    var name: String
    var summary: String
    var message: String?
    var severity: LintSeverity
    var given: [String]
    var checks: [(field: String?, function: String, options: SpecNode?)]

    init(name: String, node: SpecNode) {
        self.name = name
        summary = node["description"]?.string ?? ""
        message = node["message"]?.string
        severity = LintSeverity(node["severity"]) ?? .warning
        let givenNode = node["given"]
        given = givenNode.map { $0.isList ? $0.items.compactMap(\.string) : [$0.string ?? "$"] } ?? ["$"]
        let then = node["then"]
        checks = (then.map { $0.isList ? $0.items : [$0] } ?? []).map {
            ($0["field"]?.string, $0["function"]?.string ?? "", $0["functionOptions"])
        }
    }

    func run(on root: SpecNode, problems: inout [LintIssue]) -> [LintIssue] {
        var issues: [LintIssue] = []
        func note(_ text: String) {
            let issue = LintIssue(rule: "ruleset", message: "The rule “\(name)” \(text)", severity: .info, line: 0, path: "")
            if !problems.contains(issue) { problems.append(issue) }
        }
        for expression in given {
            guard let matches = SpecPath.select(expression, in: root) else {
                note("uses the path “\(expression)”, which is not supported, so it was skipped.")
                continue
            }
            for match in matches {
                for check in checks {
                    guard SpecLinter.functions.contains(check.function) else {
                        note("uses the function “\(check.function)”, which is not supported, so it was skipped.")
                        continue
                    }
                    // "@key" checks each key of the matched map; a field checks one property.
                    var targets: [(node: SpecNode?, property: String, line: Int)] = []
                    if check.field == "@key" {
                        targets = match.node.entries.map { (SpecNode(.string($0.key), line: $0.line), $0.key, $0.line) }
                    } else if let field = check.field {
                        let found = match.node.isList ? Int(field).flatMap { match.node.items.indices.contains($0) ? match.node.items[$0] : nil } : match.node[field]
                        let line = match.node.line(ofKey: field) ?? match.keyLine
                        targets = [(found, field, line)]
                    } else {
                        targets = [(match.node, match.path.last ?? "", match.node.line)]
                    }
                    for target in targets {
                        guard let failure = Self.apply(check.function, to: target.node, options: check.options, property: target.property) else { continue }
                        let path = match.path + (check.field.map { $0 == "@key" ? [] : [$0] } ?? [])
                        var text = message ?? (summary.isEmpty ? failure : summary)
                        text = text.replacingOccurrences(of: "{{error}}", with: failure)
                            .replacingOccurrences(of: "{{property}}", with: target.property)
                            .replacingOccurrences(of: "{{path}}", with: path.joined(separator: "."))
                            .replacingOccurrences(of: "{{description}}", with: summary)
                            .replacingOccurrences(of: "{{value}}", with: target.node?.string ?? "")
                        let issue = LintIssue(rule: name, message: text, severity: severity, line: target.line, path: path.joined(separator: "."))
                        if !issues.contains(issue) { issues.append(issue) }
                    }
                }
            }
        }
        return issues
    }

    /// Runs one Spectral function. Returns what is wrong, or nil when the value passes.
    static func apply(_ function: String, to node: SpecNode?, options: SpecNode?, property: String) -> String? {
        let label = property.isEmpty ? "The value" : "“\(property)”"
        func isTruthy(_ node: SpecNode?) -> Bool {
            guard let node else { return false }
            switch node.value {
            case .null: return false
            case .bool(let flag): return flag
            case .number(let number, _): return number != 0
            case .string(let text): return !text.isEmpty
            case .list, .map: return true
            }
        }
        switch function {
        case "truthy":
            return isTruthy(node) ? nil : "\(label) must be present and not empty."
        case "falsy":
            return isTruthy(node) ? "\(label) must be absent, empty or false." : nil
        case "defined":
            return node == nil ? "\(label) must be defined." : nil
        case "undefined":
            return node == nil ? nil : "\(label) must not be defined."
        case "pattern":
            guard let text = node?.string else { return nil }
            if let match = options?["match"]?.string, matches(text, match) == false { return "\(label) must match the pattern \(match)." }
            if let notMatch = options?["notMatch"]?.string, matches(text, notMatch) == true { return "\(label) must not match the pattern \(notMatch)." }
            return nil
        case "casing":
            guard let text = node?.string, !text.isEmpty, let type = options?["type"]?.string else { return nil }
            let patterns = [
                "camel": "^[a-z][a-zA-Z0-9]*$", "pascal": "^[A-Z][a-zA-Z0-9]*$",
                "kebab": "^[a-z][a-z0-9]*(-[a-z0-9]+)*$", "snake": "^[a-z][a-z0-9]*(_[a-z0-9]+)*$",
                "macro": "^[A-Z][A-Z0-9]*(_[A-Z0-9]+)*$", "cobol": "^[A-Z][A-Z0-9]*(-[A-Z0-9]+)*$",
                "flat": "^[a-z][a-z0-9]*$",
            ]
            guard let pattern = patterns[type] else { return nil }
            return matches(text, pattern) == false ? "\(label) must be \(type) case." : nil
        case "length":
            guard let node else { return nil }
            let size: Double
            switch node.value {
            case .string(let text): size = Double(text.count)
            case .list(let items): size = Double(items.count)
            case .map(let entries): size = Double(entries.count)
            case .number(let number, _): size = number
            default: return nil
            }
            if let min = options?["min"]?.double, size < min { return "\(label) must not be shorter than \(Int(min))." }
            if let max = options?["max"]?.double, size > max { return "\(label) must not be longer than \(Int(max))." }
            return nil
        case "enumeration":
            guard let node, let allowed = options?["values"]?.items else { return nil }
            if allowed.contains(where: { $0.value == node.value }) { return nil }
            return "\(label) must be one of: \(allowed.compactMap(\.string).joined(separator: ", "))."
        case "alphabetical":
            guard let node, node.isList else { return nil }
            let keyedBy = options?["keyedBy"]?.string
            let names = node.items.compactMap { item -> String? in
                if let keyedBy { return item[keyedBy]?.string }
                return item.string
            }
            return names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending } ? nil : "\(label) must be in alphabetical order."
        case "xor":
            guard let node, let properties = options?["properties"]?.items.compactMap(\.string), !properties.isEmpty else { return nil }
            let present = properties.filter { node[$0] != nil }
            return present.count == 1 ? nil : "Exactly one of \(properties.joined(separator: ", ")) must be defined."
        default:
            return nil
        }
    }

    /// Tests a value against a pattern written either plainly or as `/pattern/flags`.
    /// - Returns: nil when the pattern itself is not valid, so a broken rule reports nothing.
    static func matches(_ text: String, _ pattern: String) -> Bool? {
        var source = pattern
        var options: NSRegularExpression.Options = []
        if pattern.hasPrefix("/"), let end = pattern.lastIndex(of: "/"), end != pattern.startIndex {
            source = String(pattern[pattern.index(after: pattern.startIndex)..<end])
            let flags = pattern[pattern.index(after: end)...]
            if flags.contains("i") { options.insert(.caseInsensitive) }
            if flags.contains("m") { options.insert(.anchorsMatchLines) }
            if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        }
        guard let regex = try? NSRegularExpression(pattern: source, options: options) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

// MARK: - Paths

/// The part of JSONPath that lint rules use to say where they apply:
/// `$`, `.name`, `['name']`, `[0]`, `.*`, `[*]`, `..name`, `..*`, and a final `~` for keys.
/// Filters (`[?(…)]`) and slices are not supported.
enum SpecPath {
    struct Match {
        var node: SpecNode
        var path: [String]
        /// The line the key (or list item) is written on.
        var keyLine: Int
    }

    enum Step: Equatable {
        case child(String)
        case wildcard
        case descendants(String?)
        case keys
    }

    static func parse(_ expression: String) -> [Step]? {
        var steps: [Step] = []
        var rest = Substring(expression.trimmingCharacters(in: .whitespaces))
        guard rest.hasPrefix("$") else { return nil }
        rest = rest.dropFirst()

        func name(_ text: inout Substring) -> String? {
            let taken = text.prefix { $0 != "." && $0 != "[" && $0 != "~" }
            guard !taken.isEmpty else { return nil }
            text = text.dropFirst(taken.count)
            return String(taken)
        }
        func bracket(_ text: inout Substring) -> String? {
            guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
            let inner = text[text.index(after: text.startIndex)..<close].trimmingCharacters(in: .whitespaces)
            text = text[text.index(after: close)...]
            if inner == "*" { return "*" }
            if inner.count >= 2, let quote = inner.first, quote == "'" || quote == "\"", inner.last == quote {
                return String(inner.dropFirst().dropLast())
            }
            return Int(inner).map(String.init)
        }

        while !rest.isEmpty {
            if rest.hasPrefix("~") {
                rest = rest.dropFirst()
                guard rest.isEmpty else { return nil }
                steps.append(.keys)
            } else if rest.hasPrefix("..") {
                rest = rest.dropFirst(2)
                let found = rest.hasPrefix("[") ? bracket(&rest) : name(&rest)
                guard let found else { return nil }
                steps.append(.descendants(found == "*" ? nil : found))
            } else if rest.hasPrefix(".") {
                rest = rest.dropFirst()
                guard let found = name(&rest) else { return nil }
                steps.append(found == "*" ? .wildcard : .child(found))
            } else if rest.hasPrefix("[") {
                guard let found = bracket(&rest) else { return nil }
                steps.append(found == "*" ? .wildcard : .child(found))
            } else {
                return nil
            }
        }
        return steps
    }

    /// Every place in the document a path expression matches, or nil when the expression is not supported.
    static func select(_ expression: String, in root: SpecNode) -> [Match]? {
        guard let steps = parse(expression) else { return nil }
        var current = [Match(node: root, path: [], keyLine: root.line)]
        for step in steps {
            var next: [Match] = []
            for match in current {
                switch step {
                case .child(let name):
                    if let found = children(of: match).last(where: { $0.path.last == name }) { next.append(found) }
                case .wildcard:
                    next.append(contentsOf: children(of: match))
                case .descendants(let name):
                    var stack = children(of: match).reversed() as [Match]
                    while let found = stack.popLast() {
                        if name == nil || found.path.last == name { next.append(found) }
                        stack.append(contentsOf: children(of: found).reversed())
                    }
                case .keys:
                    // The key itself, as text, on the line the key is written.
                    next.append(Match(node: SpecNode(.string(match.path.last ?? ""), line: match.keyLine), path: match.path, keyLine: match.keyLine))
                }
            }
            current = next
        }
        return current
    }

    private static func children(of match: Match) -> [Match] {
        switch match.node.value {
        case .map(let entries):
            return entries.map { Match(node: $0.node, path: match.path + [$0.key], keyLine: $0.line) }
        case .list(let items):
            return items.enumerated().map { Match(node: $0.element, path: match.path + [String($0.offset)], keyLine: $0.element.line) }
        default:
            return []
        }
    }
}
