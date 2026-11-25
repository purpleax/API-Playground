import Foundation

/// Replaces `{{name}}` placeholders, using the same syntax and scope order as Postman.
public struct VariableResolver: Sendable {
    private let values: [String: String]

    /// - Parameter scopes: Broadest first. A later scope overrides an earlier one.
    public init(scopes: [[String: String]]) {
        var merged: [String: String] = [:]
        for scope in scopes {
            merged.merge(scope) { _, narrower in narrower }
        }
        values = merged
    }

    /// Builds a resolver from the standard scopes: globals, then collection, then environment.
    public init(globals: [Variable] = [], collection: [Variable] = [], environment: [Variable] = []) {
        func dictionary(_ variables: [Variable]) -> [String: String] {
            var out: [String: String] = [:]
            for variable in variables where variable.enabled && !variable.key.isEmpty {
                out[variable.key] = variable.effectiveValue
            }
            return out
        }
        self.init(scopes: [dictionary(globals), dictionary(collection), dictionary(environment)])
    }

    public struct Result: Equatable, Sendable {
        public var string: String
        /// Names that had no value. Their placeholders are left in the string unchanged.
        public var unresolved: [String]
    }

    public func resolve(_ input: String) -> Result {
        var unresolved: [String] = []
        let string = resolve(input, depth: 0, unresolved: &unresolved)
        return Result(string: string, unresolved: unresolved)
    }

    private func resolve(_ input: String, depth: Int, unresolved: inout [String]) -> String {
        guard input.contains("{{") else { return input }
        var output = ""
        var rest = Substring(input)
        while let open = rest.range(of: "{{") {
            output += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else {
                output += rest[open.lowerBound...]
                return output
            }
            let name = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if let value = values[name] {
                // A variable's value may itself contain variables. The depth limit stops cycles.
                output += depth < 10 ? resolve(value, depth: depth + 1, unresolved: &unresolved) : value
            } else if let dynamic = Self.dynamicValue(name) {
                output += dynamic
            } else {
                if !unresolved.contains(name) { unresolved.append(name) }
                output += "{{\(name)}}"
            }
            rest = afterOpen[close.upperBound...]
        }
        output += rest
        return output
    }

    /// Postman's built-in dynamic variables. Each use produces a fresh value.
    static func dynamicValue(_ name: String) -> String? {
        switch name {
        case "$guid", "$randomUUID":
            return UUID().uuidString.lowercased()
        case "$timestamp":
            return String(Int(Date().timeIntervalSince1970))
        case "$isoTimestamp":
            return ISO8601DateFormatter().string(from: Date())
        case "$randomInt":
            return String(Int.random(in: 0...1000))
        case "$randomBoolean":
            return Bool.random() ? "true" : "false"
        default:
            return nil
        }
    }
}
