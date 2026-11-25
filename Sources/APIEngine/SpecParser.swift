import Foundation

/// A value read from a YAML or JSON document, with the line it started on.
///
/// Maps keep their keys in the order they were written, and every value knows its line,
/// so a spec's routes can be listed in order and a lint finding can point at the source.
public struct SpecNode: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case null
        case bool(Bool)
        /// The number, and the text it was written as (so `1.0` can still be shown as "1.0").
        case number(Double, String)
        case string(String)
        case list([SpecNode])
        case map([SpecEntry])
    }

    public var value: Value
    /// 1-based line in the source text.
    public var line: Int

    public init(_ value: Value, line: Int = 0) {
        self.value = value
        self.line = line
    }

    public var entries: [SpecEntry] {
        if case .map(let entries) = value { return entries }
        return []
    }

    public var items: [SpecNode] {
        if case .list(let items) = value { return items }
        return []
    }

    public var isMap: Bool {
        if case .map = value { return true }
        return false
    }

    public var isList: Bool {
        if case .list = value { return true }
        return false
    }

    public var isNull: Bool { value == .null }

    /// The value for a key of a map. When a key is repeated, the last one wins.
    public subscript(key: String) -> SpecNode? {
        entries.last { $0.key == key }?.node
    }

    /// The line a key of this map is written on.
    public func line(ofKey key: String) -> Int? {
        entries.last { $0.key == key }?.line
    }

    /// Text for a string, number or boolean; nil for anything else.
    public var string: String? {
        switch value {
        case .string(let text): return text
        case .number(_, let raw): return raw
        case .bool(let flag): return flag ? "true" : "false"
        default: return nil
        }
    }

    public var bool: Bool? {
        if case .bool(let flag) = value { return flag }
        return nil
    }

    public var double: Double? {
        if case .number(let number, _) = value { return number }
        return nil
    }

    /// Follows keys and list positions down from this node.
    public func at(_ path: [String]) -> SpecNode? {
        var node = self
        for step in path {
            switch node.value {
            case .map:
                guard let next = node[step] else { return nil }
                node = next
            case .list(let items):
                guard let index = Int(step), items.indices.contains(index) else { return nil }
                node = items[index]
            default:
                return nil
            }
        }
        return node
    }

    // MARK: Writing JSON

    /// The value as JSON text, with map keys in their original order.
    public func jsonText(pretty: Bool = true) -> String {
        var out = ""
        write(to: &out, depth: 0, pretty: pretty)
        return out
    }

    private func write(to out: inout String, depth: Int, pretty: Bool) {
        let pad = pretty ? String(repeating: "  ", count: depth + 1) : ""
        let closePad = pretty ? String(repeating: "  ", count: depth) : ""
        let newline = pretty ? "\n" : ""
        switch value {
        case .null:
            out += "null"
        case .bool(let flag):
            out += flag ? "true" : "false"
        case .number(let number, let raw):
            out += Self.jsonNumber(number, raw: raw)
        case .string(let text):
            out += Self.quoted(text)
        case .list(let items):
            if items.isEmpty {
                out += "[]"
                return
            }
            out += "[" + newline
            for (index, item) in items.enumerated() {
                out += pad
                item.write(to: &out, depth: depth + 1, pretty: pretty)
                out += (index < items.count - 1 ? "," : "") + newline
            }
            out += closePad + "]"
        case .map(let entries):
            if entries.isEmpty {
                out += "{}"
                return
            }
            out += "{" + newline
            for (index, entry) in entries.enumerated() {
                out += pad + Self.quoted(entry.key) + (pretty ? ": " : ":")
                entry.node.write(to: &out, depth: depth + 1, pretty: pretty)
                out += (index < entries.count - 1 ? "," : "") + newline
            }
            out += closePad + "}"
        }
    }

    private static func jsonNumber(_ number: Double, raw: String) -> String {
        // Use the text as written when JSON would accept it.
        let plain = raw.unicodeScalars.allSatisfy { "0123456789-.eE+".unicodeScalars.contains($0) }
        if plain, let first = raw.first, first == "-" || first.isNumber, !raw.hasSuffix("."), !raw.hasPrefix("0") || raw == "0" || raw.hasPrefix("0.") {
            return raw
        }
        guard number.isFinite else { return "null" }
        if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
        return String(number)
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

public struct SpecEntry: Sendable, Equatable {
    public var key: String
    /// 1-based line of the key.
    public var line: Int
    public var node: SpecNode

    public init(key: String, line: Int = 0, node: SpecNode) {
        self.key = key
        self.line = line
        self.node = node
    }
}

/// Something wrong in the text that did not stop it being read.
public struct SpecProblem: Sendable, Equatable {
    public var message: String
    public var line: Int
}

public struct SpecParseError: Error, LocalizedError, Equatable {
    public var message: String
    public var line: Int

    public var errorDescription: String? { "Line \(line): \(message)" }
}

/// Reads YAML and JSON.
///
/// This covers the YAML that API specs are written in: block and flow maps and lists,
/// plain, quoted and block (`|`, `>`) text, comments, anchors, aliases and `<<` merges.
/// Not covered: tags that change a value's type, complex (`?`) keys, and more than one
/// document in a file (only the first is read).
public enum SpecParser {
    public static func parse(_ text: String) throws -> (root: SpecNode, problems: [SpecProblem]) {
        var parser = Parser(text: text)
        let root = try parser.parseDocument()
        return (root, parser.problems)
    }
}

private struct Parser {
    var lines: [[Character]]
    var i = 0
    var anchors: [String: SpecNode] = [:]
    var problems: [SpecProblem] = []

    init(text: String) {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Array($0) }
    }

    func fail(_ message: String, line: Int) -> SpecParseError {
        SpecParseError(message: message, line: line + 1)
    }

    // MARK: Lines

    func indent(_ l: Int) -> Int {
        var n = 0
        let line = lines[l]
        while n < line.count, line[n] == " " { n += 1 }
        return n
    }

    func isWhitespace(_ l: Int) -> Bool {
        lines[l].allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    /// Empty, or holding only a comment.
    func isBlank(_ l: Int) -> Bool {
        for ch in lines[l] {
            if ch == " " || ch == "\t" || ch == "\r" { continue }
            return ch == "#"
        }
        return true
    }

    func isMarker(_ l: Int, _ marker: String) -> Bool {
        let line = String(lines[l])
        return line == marker || line.hasPrefix(marker + " ")
    }

    mutating func skipBlank() {
        while i < lines.count, isBlank(i) { i += 1 }
    }

    func isSequenceStart(_ l: Int, _ col: Int) -> Bool {
        let line = lines[l]
        return col < line.count && line[col] == "-" && (col + 1 == line.count || line[col + 1] == " ")
    }

    /// The text from `col`, without a trailing comment or surrounding spaces.
    func plainText(_ l: Int, from col: Int) -> String {
        let line = lines[l]
        var end = line.count
        var j = col
        while j < line.count {
            if line[j] == "#", j == col || line[j - 1] == " " || line[j - 1] == "\t" {
                end = j
                break
            }
            j += 1
        }
        return String(line[min(col, end)..<end]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Document

    mutating func parseDocument() throws -> SpecNode {
        skipBlank()
        if i < lines.count, isMarker(i, "---") {
            if String(lines[i]) == "---" {
                i += 1
            } else {
                lines[i].replaceSubrange(0..<3, with: [" ", " ", " "])
            }
        }
        // A second document, or the end marker, ends the first.
        if let end = (i..<lines.count).first(where: { isMarker($0, "---") || isMarker($0, "...") }) {
            lines.removeSubrange(end...)
        }
        let root = try parseBlock(minIndent: 0)
        skipBlank()
        if i < lines.count {
            throw fail("This line could not be read. Check its indentation.", line: i)
        }
        return root
    }

    // MARK: Blocks

    mutating func parseBlock(minIndent: Int) throws -> SpecNode {
        skipBlank()
        guard i < lines.count else { return SpecNode(.null, line: lines.count) }
        let n = indent(i)
        guard n >= minIndent else { return SpecNode(.null, line: i + 1) }
        if n < lines[i].count, lines[i][n] == "\t" {
            throw fail("Tabs cannot be used to indent YAML. Use spaces.", line: i)
        }
        if isSequenceStart(i, n) { return try parseSequence(n) }
        if key(at: i, col: n) != nil { return try parseMapping(n) }
        return try parseValue(i, n, parentIndent: n - 1)
    }

    /// Finds a `key:` at a position in a line.
    func key(at l: Int, col: Int) -> (key: String, after: Int)? {
        let line = lines[l]
        guard col < line.count else { return nil }
        let first = line[col]
        if first == "\"" || first == "'" {
            var j = col + 1
            var text = ""
            while j < line.count {
                let ch = line[j]
                if first == "\"", ch == "\\", j + 1 < line.count {
                    text.append(line[j + 1] == "n" ? "\n" : line[j + 1])
                    j += 2
                    continue
                }
                if ch == first {
                    if first == "'", j + 1 < line.count, line[j + 1] == "'" {
                        text.append("'")
                        j += 2
                        continue
                    }
                    break
                }
                text.append(ch)
                j += 1
            }
            guard j < line.count else { return nil }
            j += 1
            while j < line.count, line[j] == " " { j += 1 }
            guard j < line.count, line[j] == ":", j + 1 == line.count || line[j + 1] == " " else { return nil }
            return (text, j + 1)
        }
        if first == "[" || first == "{" || first == "#" { return nil }
        var j = col
        while j < line.count {
            if line[j] == ":", j + 1 == line.count || line[j + 1] == " " {
                let name = String(line[col..<j]).trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : (name, j + 1)
            }
            if line[j] == "#", j > col, line[j - 1] == " " { return nil }
            j += 1
        }
        return nil
    }

    mutating func parseMapping(_ n: Int) throws -> SpecNode {
        var entries: [SpecEntry] = []
        var merged: [SpecEntry] = []
        let startLine = i + 1
        while true {
            skipBlank()
            guard i < lines.count else { break }
            let m = indent(i)
            if m < n { break }
            if m > n { throw fail("This line is indented further than the lines around it.", line: i) }
            guard let (name, after) = key(at: i, col: n) else {
                throw fail("Expected “key: value” here.", line: i)
            }
            let keyLine = i + 1
            let value = try parseAfterIndicator(i, after, parentIndent: n, allowSequenceAtSameIndent: true)
            if name == "<<" {
                let sources = value.isList ? value.items : [value]
                for source in sources { merged.append(contentsOf: source.entries) }
                continue
            }
            if entries.contains(where: { $0.key == name }) {
                problems.append(SpecProblem(message: "The key “\(name)” appears more than once.", line: keyLine))
            }
            entries.append(SpecEntry(key: name, line: keyLine, node: value))
        }
        for entry in merged where !entries.contains(where: { $0.key == entry.key }) {
            entries.append(entry)
        }
        return SpecNode(.map(entries), line: startLine)
    }

    mutating func parseSequence(_ n: Int) throws -> SpecNode {
        var items: [SpecNode] = []
        let startLine = i + 1
        while true {
            skipBlank()
            guard i < lines.count, indent(i) == n, isSequenceStart(i, n) else { break }
            let l = i
            var col = n + 1
            while col < lines[l].count, lines[l][col] == " " { col += 1 }
            if col >= lines[l].count || lines[l][col] == "#" {
                i = l + 1
                skipBlank()
                if i < lines.count, indent(i) > n {
                    items.append(try parseBlock(minIndent: n + 1))
                } else {
                    items.append(SpecNode(.null, line: l + 1))
                }
            } else {
                // Blank out the dash, so the item reads as a block of its own.
                lines[l][n] = " "
                i = l
                items.append(try parseBlock(minIndent: col))
            }
        }
        return SpecNode(.list(items), line: startLine)
    }

    /// Reads the value that follows a `key:` or an anchor, on this line or the lines below.
    mutating func parseAfterIndicator(_ l: Int, _ after: Int, parentIndent n: Int, allowSequenceAtSameIndent: Bool) throws -> SpecNode {
        var col = after
        let line = lines[l]
        while col < line.count, line[col] == " " || line[col] == "\t" { col += 1 }
        if col >= line.count || line[col] == "#" {
            i = l + 1
            skipBlank()
            if i < lines.count {
                let m = indent(i)
                if m > n { return try parseBlock(minIndent: n + 1) }
                if m == n, allowSequenceAtSameIndent, isSequenceStart(i, n) { return try parseSequence(n) }
            }
            return SpecNode(.null, line: l + 1)
        }
        return try parseValue(l, col, parentIndent: n)
    }

    /// Reads a value that starts at a position in a line, and moves `i` past it.
    mutating func parseValue(_ l: Int, _ col: Int, parentIndent n: Int) throws -> SpecNode {
        let line = lines[l]
        switch line[col] {
        case "&":
            var end = col + 1
            while end < line.count, line[end] != " " { end += 1 }
            let name = String(line[(col + 1)..<end])
            let node = try parseAfterIndicator(l, end, parentIndent: n, allowSequenceAtSameIndent: false)
            anchors[name] = node
            return node
        case "*":
            let name = plainText(l, from: col + 1)
            i = l + 1
            guard let node = anchors[name] else { throw fail("Nothing is named “\(name)” above this line.", line: l) }
            return node
        case "!":
            var end = col + 1
            while end < line.count, line[end] != " " { end += 1 }
            return try parseAfterIndicator(l, end, parentIndent: n, allowSequenceAtSameIndent: false)
        case "|", ">":
            return try parseBlockScalar(l, col, parentIndent: n)
        case "[", "{":
            var cursor = Cursor(line: l, col: col)
            let node = try parseFlow(&cursor)
            try expectLineEnd(cursor)
            i = cursor.line + 1
            return node
        case "\"", "'":
            var cursor = Cursor(line: l, col: col)
            let text = try parseQuoted(&cursor)
            try expectLineEnd(cursor)
            i = cursor.line + 1
            return SpecNode(.string(text), line: l + 1)
        default:
            var text = plainText(l, from: col)
            i = l + 1
            // A plain value can carry on over further, more indented, lines.
            while i < lines.count, !isBlank(i), indent(i) > n {
                text += " " + plainText(i, from: indent(i))
                i += 1
            }
            return Parser.scalar(text, line: l + 1)
        }
    }

    mutating func parseBlockScalar(_ l: Int, _ col: Int, parentIndent n: Int) throws -> SpecNode {
        let header = plainText(l, from: col)
        let folded = header.hasPrefix(">")
        let strip = header.contains("-")
        let keep = header.contains("+")
        var blockIndent: Int? = header.compactMap { $0.wholeNumberValue }.first.map { max(n, 0) + $0 }
        i = l + 1
        var body: [String] = []
        while i < lines.count {
            if isWhitespace(i) {
                body.append("")
                i += 1
                continue
            }
            let m = indent(i)
            if blockIndent == nil {
                if m <= n { break }
                blockIndent = m
            }
            guard let width = blockIndent, m >= width else { break }
            body.append(String(lines[i][width...]))
            i += 1
        }
        var trailing = 0
        while let last = body.last, last.isEmpty {
            body.removeLast()
            trailing += 1
        }
        var text = ""
        if folded {
            enum Kind { case start, text, indented, blank }
            var previous = Kind.start
            for line in body {
                if line.isEmpty {
                    text += "\n"
                    previous = .blank
                } else if line.hasPrefix(" ") {
                    if previous == .text || previous == .indented { text += "\n" }
                    text += line
                    previous = .indented
                } else {
                    if previous == .text { text += " " } else if previous == .indented { text += "\n" }
                    text += line
                    previous = .text
                }
            }
        } else {
            text = body.joined(separator: "\n")
        }
        if !text.isEmpty || keep {
            if keep {
                text += String(repeating: "\n", count: trailing + (body.isEmpty ? 0 : 1))
            } else if !strip {
                text += "\n"
            }
        }
        return SpecNode(.string(text), line: l + 1)
    }

    // MARK: Flow values and quoted text

    struct Cursor {
        var line: Int
        var col: Int
    }

    /// The character at the cursor. The end of a line reads as a newline; the end of the text as nil.
    func peek(_ c: Cursor) -> Character? {
        guard c.line < lines.count else { return nil }
        if c.col < lines[c.line].count { return lines[c.line][c.col] }
        return c.line + 1 < lines.count ? "\n" : nil
    }

    func advance(_ c: inout Cursor) {
        guard c.line < lines.count else { return }
        if c.col < lines[c.line].count {
            c.col += 1
        } else {
            c.line += 1
            c.col = 0
        }
    }

    func skipSpace(_ c: inout Cursor) {
        while let ch = peek(c) {
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                advance(&c)
            } else if ch == "#", c.col == 0 || lines[c.line][c.col - 1] == " " || lines[c.line][c.col - 1] == "\t" {
                c.col = lines[c.line].count
            } else {
                break
            }
        }
    }

    func expectLineEnd(_ c: Cursor) throws {
        guard c.line < lines.count else { return }
        let rest = plainText(c.line, from: min(c.col, lines[c.line].count))
        // A comment needs a space before it, which plainText has already allowed for.
        if !rest.isEmpty, !rest.hasPrefix("#") {
            throw fail("Unexpected text after the end of a value: “\(rest.prefix(30))”.", line: c.line)
        }
    }

    mutating func parseFlow(_ c: inout Cursor) throws -> SpecNode {
        skipSpace(&c)
        let startLine = c.line
        guard let ch = peek(c) else { throw fail("The text ends in the middle of a value.", line: lines.count - 1) }
        switch ch {
        case "[":
            advance(&c)
            var items: [SpecNode] = []
            while true {
                skipSpace(&c)
                guard let next = peek(c) else { throw fail("This “[” is never closed with “]”.", line: startLine) }
                if next == "]" {
                    advance(&c)
                    break
                }
                items.append(try parseFlow(&c))
                skipSpace(&c)
                guard let separator = peek(c) else { throw fail("This “[” is never closed with “]”.", line: startLine) }
                if separator == "," {
                    advance(&c)
                } else if separator != "]" {
                    throw fail("Expected “,” or “]” but found “\(separator)”.", line: c.line)
                }
            }
            return SpecNode(.list(items), line: startLine + 1)
        case "{":
            advance(&c)
            var entries: [SpecEntry] = []
            while true {
                skipSpace(&c)
                guard let next = peek(c) else { throw fail("This “{” is never closed with “}”.", line: startLine) }
                if next == "}" {
                    advance(&c)
                    break
                }
                let keyLine = c.line
                var name = ""
                if next == "\"" || next == "'" {
                    name = try parseQuoted(&c)
                } else {
                    while let k = peek(c), k != ":", k != ",", k != "}", k != "\n" {
                        name.append(k)
                        advance(&c)
                    }
                    name = name.trimmingCharacters(in: .whitespaces)
                    if name.isEmpty { throw fail("Expected a key here.", line: c.line) }
                }
                skipSpace(&c)
                var value = SpecNode(.null, line: keyLine + 1)
                if peek(c) == ":" {
                    advance(&c)
                    skipSpace(&c)
                    if let after = peek(c), after != ",", after != "}" {
                        value = try parseFlow(&c)
                    }
                }
                if entries.contains(where: { $0.key == name }) {
                    problems.append(SpecProblem(message: "The key “\(name)” appears more than once.", line: keyLine + 1))
                }
                entries.append(SpecEntry(key: name, line: keyLine + 1, node: value))
                skipSpace(&c)
                guard let separator = peek(c) else { throw fail("This “{” is never closed with “}”.", line: startLine) }
                if separator == "," {
                    advance(&c)
                } else if separator != "}" {
                    throw fail("Expected “,” or “}” but found “\(separator)”.", line: c.line)
                }
            }
            return SpecNode(.map(entries), line: startLine + 1)
        case "\"", "'":
            return SpecNode(.string(try parseQuoted(&c)), line: startLine + 1)
        case "*":
            advance(&c)
            var name = ""
            while let k = peek(c), k != ",", k != "]", k != "}", k != "\n", k != " " {
                name.append(k)
                advance(&c)
            }
            guard let node = anchors[name] else { throw fail("Nothing is named “\(name)” above this line.", line: startLine) }
            return node
        case "&":
            advance(&c)
            var name = ""
            while let k = peek(c), k != " ", k != "\n" {
                name.append(k)
                advance(&c)
            }
            let node = try parseFlow(&c)
            anchors[name] = node
            return node
        default:
            var text = ""
            while let k = peek(c), k != ",", k != "]", k != "}", k != "\n" {
                if k == "#", text.hasSuffix(" ") { break }
                text.append(k)
                advance(&c)
            }
            text = text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { throw fail("Unexpected “\(ch)”.", line: startLine) }
            return Parser.scalar(text, line: startLine + 1)
        }
    }

    func parseQuoted(_ c: inout Cursor) throws -> String {
        let startLine = c.line
        guard let quote = peek(c) else { throw fail("Expected quoted text.", line: startLine) }
        advance(&c)
        var out = ""
        func unterminated() -> SpecParseError { fail("This quote is never closed.", line: startLine) }

        /// A line break inside quotes joins the lines with one space.
        func foldLineBreak(_ c: inout Cursor) {
            while out.hasSuffix(" ") { out.removeLast() }
            var breaks = 0
            while let ch = peek(c), ch == "\n" || ch == " " || ch == "\t" {
                if ch == "\n" { breaks += 1 }
                advance(&c)
            }
            out += breaks > 1 ? String(repeating: "\n", count: breaks - 1) : " "
        }

        while true {
            guard let ch = peek(c) else { throw unterminated() }
            if ch == "\n" {
                foldLineBreak(&c)
                continue
            }
            advance(&c)
            if ch == quote {
                if quote == "'", peek(c) == "'" {
                    out.append("'")
                    advance(&c)
                    continue
                }
                return out
            }
            guard quote == "\"", ch == "\\" else {
                out.append(ch)
                continue
            }
            guard let escape = peek(c) else { throw unterminated() }
            advance(&c)
            func hex(_ count: Int) throws -> UInt32 {
                var digits = ""
                for _ in 0..<count {
                    guard let d = peek(c), d.isHexDigit else { throw fail("A \\u escape needs \(count) hex digits.", line: c.line) }
                    digits.append(d)
                    advance(&c)
                }
                return UInt32(digits, radix: 16) ?? 0
            }
            switch escape {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "0": out.append("\0")
            case "e": out.append("\u{1B}")
            case "\n":
                // A backslash at the end of a line joins the lines with nothing between.
                while let next = peek(c), next == " " || next == "\t" { advance(&c) }
            case "x":
                out.unicodeScalars.append(Unicode.Scalar(try hex(2)) ?? "\u{FFFD}")
            case "u":
                var code = try hex(4)
                // Two escapes in a row can make one character outside the basic plane.
                if (0xD800...0xDBFF).contains(code), peek(c) == "\\" {
                    var ahead = c
                    advance(&ahead)
                    if peek(ahead) == "u" {
                        advance(&ahead)
                        c = ahead
                        let low = try hex(4)
                        if (0xDC00...0xDFFF).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                    }
                }
                out.unicodeScalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
            case "U":
                out.unicodeScalars.append(Unicode.Scalar(try hex(8)) ?? "\u{FFFD}")
            default:
                out.append(escape)
            }
        }
    }

    // MARK: Plain values

    static func scalar(_ text: String, line: Int) -> SpecNode {
        switch text {
        case "", "~", "null", "Null", "NULL":
            return SpecNode(.null, line: line)
        case "true", "True", "TRUE":
            return SpecNode(.bool(true), line: line)
        case "false", "False", "FALSE":
            return SpecNode(.bool(false), line: line)
        default:
            break
        }
        let numeric = text.unicodeScalars.allSatisfy { "0123456789+-.eE".unicodeScalars.contains($0) }
        if numeric, text.contains(where: \.isNumber), let number = Double(text) {
            return SpecNode(.number(number, text), line: line)
        }
        if text.hasPrefix("0x"), let number = UInt64(text.dropFirst(2), radix: 16) {
            return SpecNode(.number(Double(number), text), line: line)
        }
        return SpecNode(.string(text), line: line)
    }
}
