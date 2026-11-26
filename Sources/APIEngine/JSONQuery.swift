import Foundation

/// Filters a JSON body with a JSONPath expression (`$.items[?(@.price > 10)].name`) or a
/// jq-style one (`.items[] | select(.price > 10) | .name`). An expression that starts with
/// `$` is read as JSONPath, anything else as jq.
///
/// The jq side covers paths, `[]`, slices, pipes, `select`, `map`, `length` and `keys`,
/// which is what filtering a response needs. It is not the whole jq language.
public enum JSONQuery {
    public struct QueryError: Error, LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
    }

    public enum Dialect: Sendable { case jsonPath, jq }

    public static func dialect(of expression: String) -> Dialect {
        expression.trimmingCharacters(in: .whitespaces).hasPrefix("$") ? .jsonPath : .jq
    }

    /// Every value the expression selects, in document order.
    public static func evaluate(_ expression: String, in root: Any) throws -> [Any] {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [root] }
        var parser = Parser(trimmed, jq: dialect(of: trimmed) == .jq)
        let steps = try parser.parseWhole()
        return apply(steps, to: [root], root: root, jq: parser.jq)
    }

    /// Runs the expression over a JSON body and returns the result as text: a JSON array of
    /// the matches for JSONPath, and one value after another for jq, as each tool prints them.
    public static func run(_ expression: String, on body: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            throw QueryError(message: "The body is not JSON, so it cannot be filtered.")
        }
        let matches = try evaluate(expression, in: root)
        if dialect(of: expression) == .jsonPath { return text(matches) }
        return matches.map(text).joined(separator: "\n")
    }

    static func text(_ value: Any) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
        return data.map { LineDiff.tightenColons(String(decoding: $0, as: UTF8.self)) } ?? "\(value)"
    }

    // MARK: - What an expression is made of

    indirect enum Step {
        case child(String)
        case index(Int)
        case slice(Int?, Int?, Int?)
        case wildcard
        /// The node itself and everything beneath it.
        case descendants
        case union([Step])
        case filter(Condition)
        /// Gathers what the inner steps produce into one array, as jq's `map` and `[…]` do.
        case collect([Step])
        case length
        case keys
    }

    indirect enum Condition {
        case or(Condition, Condition)
        case and(Condition, Condition)
        case not(Condition)
        case exists(Operand)
        case compare(Operand, String, Operand)
        case textTest(Operand, String, String)
    }

    enum Operand {
        case literal(Any)
        case current([Step])
        case root([Step])
    }

    // MARK: - Parsing

    struct Parser {
        private let chars: [Character]
        private var position = 0
        let jq: Bool

        init(_ text: String, jq: Bool) {
            chars = Array(text)
            self.jq = jq
        }

        private var peek: Character? { position < chars.count ? chars[position] : nil }
        private func peek(_ offset: Int) -> Character? { position + offset < chars.count ? chars[position + offset] : nil }
        private mutating func skipSpaces() { while let c = peek, c.isWhitespace { position += 1 } }

        private func fail(_ message: String) -> QueryError {
            QueryError(message: "\(message) (at character \(position + 1))")
        }

        private mutating func take(_ text: String) -> Bool {
            let wanted = Array(text)
            guard position + wanted.count <= chars.count, Array(chars[position..<position + wanted.count]) == wanted else { return false }
            position += wanted.count
            return true
        }

        /// Takes a word such as `and`, but only when it is not the start of a longer name.
        private mutating func takeWord(_ word: String) -> Bool {
            let start = position
            guard take(word) else { return false }
            if let next = peek, Self.isNameCharacter(next) {
                position = start
                return false
            }
            return true
        }

        private static func isNameCharacter(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "-" || c == "$"
        }

        private mutating func name() -> String {
            let start = position
            while let c = peek, Self.isNameCharacter(c) { position += 1 }
            return String(chars[start..<position])
        }

        private mutating func quoted() throws -> String {
            guard let quote = peek, quote == "\"" || quote == "'" else { throw fail("Expected a quoted name") }
            position += 1
            var out = ""
            while let c = peek {
                position += 1
                if c == "\\", let next = peek {
                    position += 1
                    switch next {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(next)
                    }
                } else if c == quote {
                    return out
                } else {
                    out.append(c)
                }
            }
            throw fail("A quoted name is missing its closing quote")
        }

        private mutating func integer() -> Int? {
            let start = position
            if peek == "-" { position += 1 }
            while let c = peek, c.isNumber { position += 1 }
            if let value = Int(String(chars[start..<position])) { return value }
            position = start
            return nil
        }

        mutating func parseWhole() throws -> [Step] {
            let steps = try jq ? pipeline() : jsonPath()
            skipSpaces()
            if let c = peek { throw fail("Did not expect \"\(c)\"") }
            return steps
        }

        // JSONPath: $ followed by .name, ..name, [ … ]
        private mutating func jsonPath() throws -> [Step] {
            guard take("$") else { throw fail("A JSONPath expression starts with $") }
            return try jsonPathSteps()
        }

        private mutating func jsonPathSteps() throws -> [Step] {
            var steps: [Step] = []
            while let c = peek {
                if c == "." {
                    position += 1
                    if peek == "." {
                        position += 1
                        steps.append(.descendants)
                        if peek == "[" { continue }
                    }
                    if peek == "*" {
                        position += 1
                        steps.append(.wildcard)
                        continue
                    }
                    let word = name()
                    guard !word.isEmpty else { throw fail("Expected a name after the dot") }
                    if word == "length", take("()") {
                        steps.append(.length)
                    } else {
                        steps.append(.child(word))
                    }
                } else if c == "[" {
                    steps.append(try bracket())
                } else {
                    break
                }
            }
            return steps
        }

        /// What sits between square brackets, in either dialect.
        private mutating func bracket() throws -> Step {
            position += 1
            skipSpaces()
            if peek == "]" {
                guard jq else { throw fail("Empty brackets") }
                position += 1
                return .wildcard
            }
            if peek == "*" {
                position += 1
                skipSpaces()
                guard take("]") else { throw fail("Expected ]") }
                return .wildcard
            }
            if peek == "?" {
                position += 1
                skipSpaces()
                let wrapped = take("(")
                let condition = try orCondition()
                skipSpaces()
                if wrapped, !take(")") { throw fail("Expected )") }
                skipSpaces()
                guard take("]") else { throw fail("Expected ]") }
                return .filter(condition)
            }
            var parts: [Step] = []
            while true {
                skipSpaces()
                if peek == "\"" || peek == "'" {
                    parts.append(.child(try quoted()))
                } else {
                    let first = integer()
                    skipSpaces()
                    if peek == ":" {
                        position += 1
                        skipSpaces()
                        let end = integer()
                        skipSpaces()
                        var stride: Int?
                        if peek == ":" {
                            position += 1
                            skipSpaces()
                            stride = integer()
                        }
                        parts.append(.slice(first, end, stride))
                    } else if let first {
                        parts.append(.index(first))
                    } else {
                        throw fail("Expected a number, a quoted name, * or a ?( ) filter")
                    }
                }
                skipSpaces()
                if take(",") { continue }
                guard take("]") else { throw fail("Expected ]") }
                break
            }
            return parts.count == 1 ? parts[0] : .union(parts)
        }

        // jq: terms joined by |
        private mutating func pipeline() throws -> [Step] {
            var steps: [Step] = []
            while true {
                skipSpaces()
                steps += try term()
                skipSpaces()
                if !take("|") { break }
            }
            return steps
        }

        private mutating func term() throws -> [Step] {
            skipSpaces()
            if peek == "." { return try jqPath() }
            if peek == "[" {
                // [ pipeline ] gathers the results into an array.
                position += 1
                let inner = try pipeline()
                skipSpaces()
                guard take("]") else { throw fail("Expected ]") }
                return [.collect(inner)]
            }
            if takeWord("select") {
                skipSpaces()
                guard take("(") else { throw fail("Expected ( after select") }
                let condition = try orCondition()
                skipSpaces()
                guard take(")") else { throw fail("Expected )") }
                return [.filter(condition)]
            }
            if takeWord("map") {
                skipSpaces()
                guard take("(") else { throw fail("Expected ( after map") }
                let inner = try pipeline()
                skipSpaces()
                guard take(")") else { throw fail("Expected )") }
                return [.collect([.wildcard] + inner)]
            }
            if takeWord("length") { return [.length] }
            if takeWord("keys") { return [.keys] }
            throw fail("Expected a path such as .name, or select, map, length or keys")
        }

        private mutating func jqPath() throws -> [Step] {
            var steps: [Step] = []
            if peek == ".", peek(1) == "." {
                position += 2
                steps.append(.descendants)
            }
            while let c = peek {
                if c == "." {
                    position += 1
                    if peek == "\"" {
                        steps.append(.child(try quoted()))
                    } else if peek == "[" {
                        steps.append(try bracket())
                    } else {
                        let word = name()
                        // A dot on its own is the value itself.
                        if !word.isEmpty { steps.append(.child(word)) }
                    }
                } else if c == "[" {
                    steps.append(try bracket())
                } else if c == "?" {
                    // jq's "do not complain if missing"; a missing value is never an error here.
                    position += 1
                } else {
                    break
                }
            }
            return steps
        }

        // Conditions, for ?( … ) and select( … )
        private mutating func orCondition() throws -> Condition {
            var left = try andCondition()
            while true {
                skipSpaces()
                guard take("||") || takeWord("or") else { return left }
                left = .or(left, try andCondition())
            }
        }

        private mutating func andCondition() throws -> Condition {
            var left = try notCondition()
            while true {
                skipSpaces()
                guard take("&&") || takeWord("and") else { return left }
                left = .and(left, try notCondition())
            }
        }

        private mutating func notCondition() throws -> Condition {
            skipSpaces()
            if peek == "!", peek(1) != "=" {
                position += 1
                return .not(try notCondition())
            }
            if peek == "(" {
                position += 1
                let inner = try orCondition()
                skipSpaces()
                guard take(")") else { throw fail("Expected )") }
                return inner
            }
            let left = try operand()
            skipSpaces()
            // jq: .name | test("^a"), and its relatives.
            let start = position
            if jq, take("|") {
                skipSpaces()
                for function in ["test", "startswith", "endswith", "contains"] where takeWord(function) {
                    skipSpaces()
                    guard take("(") else { throw fail("Expected ( after \(function)") }
                    skipSpaces()
                    let argument = try quoted()
                    skipSpaces()
                    guard take(")") else { throw fail("Expected )") }
                    return .textTest(left, function, argument)
                }
                if takeWord("not") { return .not(.exists(left)) }
                position = start
            }
            // JSONPath: @.name =~ /^a/
            if take("=~") {
                skipSpaces()
                guard take("/") else { throw fail("Expected a /pattern/ after =~") }
                var pattern = ""
                while let c = peek, c != "/" {
                    position += 1
                    if c == "\\", peek == "/" {
                        position += 1
                        pattern.append("/")
                    } else {
                        pattern.append(c)
                    }
                }
                guard take("/") else { throw fail("The pattern is missing its closing /") }
                let insensitive = take("i")
                return .textTest(left, insensitive ? "test-i" : "test", pattern)
            }
            for op in ["==", "!=", "<=", ">=", "<", ">"] where take(op) {
                return .compare(left, op, try operand())
            }
            return .exists(left)
        }

        private mutating func operand() throws -> Operand {
            skipSpaces()
            guard let c = peek else { throw fail("The condition is incomplete") }
            if c == "\"" || c == "'" { return .literal(try quoted()) }
            if jq {
                if c == "." { return .current(try jqPath()) }
            } else {
                if c == "@" {
                    position += 1
                    return .current(try jsonPathSteps())
                }
                if c == "$" {
                    position += 1
                    return .root(try jsonPathSteps())
                }
            }
            if takeWord("true") { return .literal(true) }
            if takeWord("false") { return .literal(false) }
            if takeWord("null") { return .literal(NSNull()) }
            let start = position
            if peek == "-" { position += 1 }
            while let d = peek, d.isNumber || d == "." || d == "e" || d == "E" { position += 1 }
            if let number = Double(String(chars[start..<position])) { return .literal(number) }
            position = start
            throw fail("Expected a value to compare")
        }
    }

    // MARK: - Evaluating

    static func apply(_ steps: [Step], to nodes: [Any], root: Any, jq: Bool) -> [Any] {
        var current = nodes
        for step in steps {
            var next: [Any] = []
            for node in current {
                next += apply(step, to: node, root: root, jq: jq)
            }
            current = next
        }
        return current
    }

    private static func children(of node: Any) -> [Any] {
        if let array = node as? [Any] { return array }
        if let object = node as? [String: Any] { return object.keys.sorted().compactMap { object[$0] } }
        return []
    }

    private static func apply(_ step: Step, to node: Any, root: Any, jq: Bool) -> [Any] {
        switch step {
        case .child(let key):
            return (node as? [String: Any])?[key].map { [$0] } ?? []
        case .index(let index):
            guard let array = node as? [Any] else { return [] }
            let resolved = index < 0 ? array.count + index : index
            return array.indices.contains(resolved) ? [array[resolved]] : []
        case .slice(let from, let to, let stride):
            guard let array = node as? [Any] else { return [] }
            let step = stride ?? 1
            guard step > 0 else { return [] }
            func clamp(_ value: Int?, fallback: Int) -> Int {
                guard let value else { return fallback }
                return min(max(value < 0 ? array.count + value : value, 0), array.count)
            }
            let start = clamp(from, fallback: 0)
            let end = clamp(to, fallback: array.count)
            let picked = start < end ? Swift.stride(from: start, to: end, by: step).map { array[$0] } : []
            // jq gives a slice back as one array; JSONPath gives its items.
            return jq ? [picked] : picked
        case .wildcard:
            return children(of: node)
        case .descendants:
            var out: [Any] = []
            func walk(_ value: Any) {
                out.append(value)
                for child in children(of: value) { walk(child) }
            }
            walk(node)
            return out
        case .union(let parts):
            return parts.flatMap { apply($0, to: node, root: root, jq: jq) }
        case .filter(let condition):
            if jq {
                return holds(condition, for: node, root: root, jq: jq) ? [node] : []
            }
            // A JSONPath filter looks at each item of an array, or each value of an object.
            return children(of: node).filter { holds(condition, for: $0, root: root, jq: jq) }
        case .collect(let inner):
            return [apply(inner, to: [node], root: root, jq: jq)]
        case .length:
            if let array = node as? [Any] { return [array.count] }
            if let object = node as? [String: Any] { return [object.count] }
            if let string = node as? String { return [string.count] }
            return node is NSNull ? [0] : []
        case .keys:
            if let object = node as? [String: Any] { return [object.keys.sorted()] }
            if let array = node as? [Any] { return [Array(array.indices)] }
            return []
        }
    }

    private static func values(_ operand: Operand, for node: Any, root: Any, jq: Bool) -> [Any] {
        switch operand {
        case .literal(let value): return [value]
        case .current(let steps): return apply(steps, to: [node], root: root, jq: jq)
        case .root(let steps): return apply(steps, to: [root], root: root, jq: jq)
        }
    }

    private static func isBool(_ value: Any) -> Bool {
        if value is Bool, let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() }
        return false
    }

    private static func number(_ value: Any) -> Double? {
        if isBool(value) { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    private static func holds(_ condition: Condition, for node: Any, root: Any, jq: Bool) -> Bool {
        switch condition {
        case .or(let a, let b):
            return holds(a, for: node, root: root, jq: jq) || holds(b, for: node, root: root, jq: jq)
        case .and(let a, let b):
            return holds(a, for: node, root: root, jq: jq) && holds(b, for: node, root: root, jq: jq)
        case .not(let inner):
            return !holds(inner, for: node, root: root, jq: jq)
        case .exists(let operand):
            let found = values(operand, for: node, root: root, jq: jq)
            // JSONPath asks whether the value is there. jq asks whether it is neither false nor null.
            guard jq else { return !found.isEmpty }
            guard let first = found.first else { return false }
            if first is NSNull { return false }
            if isBool(first), let flag = first as? Bool { return flag }
            return true
        case .compare(let left, let op, let right):
            let lefts = values(left, for: node, root: root, jq: jq)
            let rights = values(right, for: node, root: root, jq: jq)
            if lefts.isEmpty || rights.isEmpty { return false }
            return lefts.contains { a in rights.contains { b in compare(a, op, b) } }
        case .textTest(let operand, let function, let argument):
            return values(operand, for: node, root: root, jq: jq).contains { value in
                guard let text = value as? String else { return false }
                switch function {
                case "startswith": return text.hasPrefix(argument)
                case "endswith": return text.hasSuffix(argument)
                case "contains": return text.contains(argument)
                default:
                    let options: NSRegularExpression.Options = function == "test-i" ? [.caseInsensitive] : []
                    guard let regex = try? NSRegularExpression(pattern: argument, options: options) else { return false }
                    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                }
            }
        }
    }

    private static func compare(_ a: Any, _ op: String, _ b: Any) -> Bool {
        if let x = number(a), let y = number(b) {
            switch op {
            case "==": return x == y
            case "!=": return x != y
            case "<": return x < y
            case "<=": return x <= y
            case ">": return x > y
            default: return x >= y
            }
        }
        if let x = a as? String, let y = b as? String {
            switch op {
            case "==": return x == y
            case "!=": return x != y
            case "<": return x < y
            case "<=": return x <= y
            case ">": return x > y
            default: return x >= y
            }
        }
        // Different kinds of value, or booleans, nulls, arrays and objects: only equality means anything.
        let same = isBool(a) == isBool(b) && (a as? NSObject)?.isEqual(b) == true
        switch op {
        case "==": return same
        case "!=": return !same
        default: return false
        }
    }
}
