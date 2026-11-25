import Foundation

/// A value read from a response, for an assertion to check or an extraction to save.
public struct ValueSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case status, header, json, body, time
    }

    public var kind: Kind
    /// The header name, or the JSON path such as `$.items[0].id`. Unused for the other kinds.
    public var path: String

    public init(kind: Kind = .status, path: String = "") {
        self.kind = kind
        self.path = path
    }

    public var label: String {
        switch kind {
        case .status: return "Status"
        case .header: return "Header \(path)"
        case .json: return path.isEmpty ? "JSON body" : path
        case .body: return "Body"
        case .time: return "Response time (ms)"
        }
    }

    /// The value as text, or nil when the response has no such header or JSON path.
    public func value(in response: HTTPResponse) -> String? {
        switch kind {
        case .status:
            return String(response.status)
        case .header:
            return response.header(path)
        case .body:
            return response.text
        case .time:
            return String(Int((response.timings.total * 1000).rounded()))
        case .json:
            guard let root = try? JSONSerialization.jsonObject(with: response.body, options: [.fragmentsAllowed]),
                  let found = JSONPath.lookup(path, in: root) else { return nil }
            return JSONPath.text(found)
        }
    }
}

/// A small subset of JSONPath: `$.a.b[0].c`, `a.b`, and `["key with spaces"]`.
public enum JSONPath {
    enum Step: Equatable {
        case key(String)
        case index(Int)
    }

    static func parse(_ path: String) -> [Step]? {
        var steps: [Step] = []
        var chars = Substring(path.trimmingCharacters(in: .whitespaces))
        if chars.hasPrefix("$") { chars = chars.dropFirst() }
        while let first = chars.first {
            if first == "." {
                chars = chars.dropFirst()
                let name = chars.prefix { $0 != "." && $0 != "[" }
                guard !name.isEmpty else { return nil }
                steps.append(.key(String(name)))
                chars = chars.dropFirst(name.count)
            } else if first == "[" {
                guard let close = chars.firstIndex(of: "]") else { return nil }
                let inner = chars[chars.index(after: chars.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                if let index = Int(inner) {
                    steps.append(.index(index))
                } else if inner.count >= 2, let quote = inner.first, quote == "\"" || quote == "'", inner.last == quote {
                    steps.append(.key(String(inner.dropFirst().dropLast())))
                } else {
                    return nil
                }
                chars = chars[chars.index(after: close)...]
            } else {
                // A path may start with a bare name: "items[0].id".
                guard steps.isEmpty else { return nil }
                let name = chars.prefix { $0 != "." && $0 != "[" }
                steps.append(.key(String(name)))
                chars = chars.dropFirst(name.count)
            }
        }
        return steps
    }

    public static func lookup(_ path: String, in root: Any) -> Any? {
        guard let steps = parse(path) else { return nil }
        var current: Any = root
        for step in steps {
            switch step {
            case .key(let key):
                guard let object = current as? [String: Any], let next = object[key] else { return nil }
                current = next
            case .index(let index):
                guard let array = current as? [Any] else { return nil }
                let resolved = index < 0 ? array.count + index : index
                guard array.indices.contains(resolved) else { return nil }
                current = array[resolved]
            }
        }
        return current
    }

    /// A JSON value as plain text: strings without quotes, objects and arrays as compact JSON.
    public static func text(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case is NSNull:
            return "null"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
        }
    }
}

public enum AssertionOperator: String, Codable, CaseIterable, Sendable {
    case equals, notEquals, contains, notContains, exists, notExists, lessThan, greaterThan, matches

    public var label: String {
        switch self {
        case .equals: return "equals"
        case .notEquals: return "does not equal"
        case .contains: return "contains"
        case .notContains: return "does not contain"
        case .exists: return "exists"
        case .notExists: return "does not exist"
        case .lessThan: return "is less than"
        case .greaterThan: return "is greater than"
        case .matches: return "matches pattern"
        }
    }

    /// Whether the check compares against an expected value.
    public var needsValue: Bool {
        self != .exists && self != .notExists
    }
}

/// One result line: from an assertion or from a script's `pm.test`.
public struct TestResult: Codable, Equatable, Sendable {
    public var name: String
    public var passed: Bool
    public var message: String?
    public var skipped: Bool

    public init(name: String, passed: Bool, message: String? = nil, skipped: Bool = false) {
        self.name = name
        self.passed = passed
        self.message = message
        self.skipped = skipped
    }
}

/// A check on a response that needs no script.
public struct Assertion: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var source: ValueSource
    public var op: AssertionOperator
    public var expected: String
    public var enabled: Bool

    enum CodingKeys: String, CodingKey { case source, op, expected, enabled }

    public init(source: ValueSource = ValueSource(), op: AssertionOperator = .equals, expected: String = "200", enabled: Bool = true) {
        self.source = source
        self.op = op
        self.expected = expected
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(ValueSource.self, forKey: .source) ?? ValueSource()
        op = try c.decodeIfPresent(AssertionOperator.self, forKey: .op) ?? .equals
        expected = try c.decodeIfPresent(String.self, forKey: .expected) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public static func == (a: Assertion, b: Assertion) -> Bool {
        a.source == b.source && a.op == b.op && a.expected == b.expected && a.enabled == b.enabled
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(op)
        hasher.combine(expected)
    }

    /// - Parameter expected: The expected value with variables already filled in.
    public func evaluate(_ response: HTTPResponse, expected: String) -> TestResult {
        let actual = source.value(in: response)
        let name = op.needsValue ? "\(source.label) \(op.label) \(expected)" : "\(source.label) \(op.label)"

        func result(_ passed: Bool) -> TestResult {
            let shown = actual.map { $0.count > 200 ? String($0.prefix(200)) + "…" : $0 }
            return TestResult(name: name, passed: passed, message: passed ? nil : (shown.map { "was \($0)" } ?? "was missing"))
        }

        switch op {
        case .exists:
            return result(actual != nil)
        case .notExists:
            return result(actual == nil)
        default:
            break
        }
        guard let actual else { return result(false) }

        switch op {
        case .equals:
            return result(Self.same(actual, expected))
        case .notEquals:
            return result(!Self.same(actual, expected))
        case .contains:
            return result(actual.contains(expected))
        case .notContains:
            return result(!actual.contains(expected))
        case .lessThan:
            guard let a = Double(actual), let b = Double(expected) else { return result(false) }
            return result(a < b)
        case .greaterThan:
            guard let a = Double(actual), let b = Double(expected) else { return result(false) }
            return result(a > b)
        case .matches:
            guard let regex = try? NSRegularExpression(pattern: expected) else {
                return TestResult(name: name, passed: false, message: "the pattern is not valid")
            }
            let range = NSRange(actual.startIndex..., in: actual)
            return result(regex.firstMatch(in: actual, range: range) != nil)
        case .exists, .notExists:
            return result(false)
        }
    }

    /// Equal as text, or as numbers when both are numbers ("200" equals "200.0").
    private static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if let x = Double(a), let y = Double(b) { return x == y }
        return false
    }
}

public enum VariableScopeKind: String, Codable, CaseIterable, Sendable {
    case environment, collection, globals

    public var label: String {
        switch self {
        case .environment: return "Environment"
        case .collection: return "Collection"
        case .globals: return "Globals"
        }
    }
}

/// Copies a value from the response into a variable, so a later request can use it.
public struct Extraction: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var variable: String
    public var source: ValueSource
    public var scope: VariableScopeKind
    public var enabled: Bool

    enum CodingKeys: String, CodingKey { case variable, source, scope, enabled }

    public init(variable: String = "", source: ValueSource = ValueSource(kind: .json, path: "$."), scope: VariableScopeKind = .environment, enabled: Bool = true) {
        self.variable = variable
        self.source = source
        self.scope = scope
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variable = try c.decodeIfPresent(String.self, forKey: .variable) ?? ""
        source = try c.decodeIfPresent(ValueSource.self, forKey: .source) ?? ValueSource()
        scope = try c.decodeIfPresent(VariableScopeKind.self, forKey: .scope) ?? .environment
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public static func == (a: Extraction, b: Extraction) -> Bool {
        a.variable == b.variable && a.source == b.source && a.scope == b.scope && a.enabled == b.enabled
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(variable)
        hasher.combine(source)
    }
}

/// The variables a run reads, and that scripts and extractions change as it goes.
public struct RunState: Equatable, Sendable {
    public var globals: [Variable]
    public var collectionVariables: [Variable]
    public var environment: [Variable]
    /// Variables set with `pm.variables.set`. They last for one run and are never saved.
    public var locals: [String: String] = [:]

    public init(globals: [Variable] = [], collectionVariables: [Variable] = [], environment: [Variable] = []) {
        self.globals = globals
        self.collectionVariables = collectionVariables
        self.environment = environment
    }

    static func dictionary(_ variables: [Variable]) -> [String: String] {
        var out: [String: String] = [:]
        for variable in variables where variable.enabled && !variable.key.isEmpty {
            out[variable.key] = variable.effectiveValue
        }
        return out
    }

    public var resolver: VariableResolver {
        VariableResolver(scopes: [
            Self.dictionary(globals), Self.dictionary(collectionVariables), Self.dictionary(environment), locals,
        ])
    }

    /// Sets a variable the way Postman's `set` does: the new value is a current value, kept on
    /// this Mac only, so tokens fetched during a run never reach the workspace files.
    public mutating func set(_ name: String, to value: String, scope: VariableScopeKind) {
        func update(_ variables: inout [Variable]) {
            if let index = variables.firstIndex(where: { $0.key == name }) {
                variables[index].enabled = true
                if variables[index].secret {
                    variables[index].value = value
                } else {
                    variables[index].currentValue = value
                }
            } else {
                variables.append(Variable(key: name, value: "", currentValue: value))
            }
        }
        switch scope {
        case .environment: update(&environment)
        case .collection: update(&collectionVariables)
        case .globals: update(&globals)
        }
    }

    public mutating func unset(_ name: String, scope: VariableScopeKind) {
        switch scope {
        case .environment: environment.removeAll { $0.key == name }
        case .collection: collectionVariables.removeAll { $0.key == name }
        case .globals: globals.removeAll { $0.key == name }
        }
    }

    /// Applies the differences between what a script was given and what it left behind.
    mutating func apply(before: [String: String], after: [String: String], scope: VariableScopeKind) {
        for (key, value) in after where before[key] != value {
            set(key, to: value, scope: scope)
        }
        for key in before.keys where after[key] == nil {
            unset(key, scope: scope)
        }
    }
}
