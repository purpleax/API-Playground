import Foundation

public enum SnippetLanguage: String, CaseIterable, Identifiable, Sendable {
    case curl, javascript, python, swift

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .curl: return "cURL"
        case .javascript: return "JavaScript (fetch)"
        case .python: return "Python (requests)"
        case .swift: return "Swift (URLSession)"
        }
    }
}

/// Writes a request out as a command or a piece of code that sends the same thing.
public enum CodeSnippet {
    public static func generate(_ request: PreparedRequest, language: SnippetLanguage) -> String {
        // The app's own User-Agent is not part of what the user wrote.
        var request = request
        request.headers.removeAll { $0.name.caseInsensitiveCompare("User-Agent") == .orderedSame && $0.value == RequestBuilder.userAgent }
        switch language {
        case .curl: return curl(request)
        case .javascript: return javascript(request)
        case .python: return python(request)
        case .swift: return swift(request)
        }
    }

    /// The body as text, or nil when it is binary and cannot be written into source code.
    private static func bodyText(_ request: PreparedRequest) -> String? {
        request.body.flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func binaryNote(_ request: PreparedRequest, comment: String) -> String? {
        guard let body = request.body, bodyText(request) == nil else { return nil }
        return "\(comment) The body is \(body.count) bytes of binary data, which cannot be written out here."
    }

    // MARK: cURL

    /// Quotes text for a POSIX shell: single quotes, with any single quote inside closed, escaped and reopened.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func curl(_ request: PreparedRequest) -> String {
        var parts: [String] = []
        let hasBody = request.body != nil
        // curl works out GET, and POST when there is a body, for itself.
        if !(request.method == "GET" && !hasBody) && !(request.method == "POST" && hasBody) {
            parts.append("--request \(request.method)")
        }
        parts.append(shellQuote(request.url))
        for header in request.headers {
            // curl's own way of writing a header with no value.
            parts.append("--header " + shellQuote(header.value.isEmpty ? "\(header.name);" : "\(header.name): \(header.value)"))
        }
        if let text = bodyText(request) {
            parts.append("--data-raw " + shellQuote(text))
        } else if hasBody {
            parts.append("--data-binary @path/to/body")
        }
        let command = "curl " + parts.joined(separator: " \\\n  ")
        return [binaryNote(request, comment: "#"), command].compactMap { $0 }.joined(separator: "\n")
    }

    // MARK: Code

    /// A double-quoted string literal. `unicode` writes a control character's escape for the language.
    private static func literal(_ text: String, unicode: (UInt32) -> String, escapeDollar: Bool = false) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "$" where escapeDollar: out += "\\$"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += unicode(scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func javascript(_ request: PreparedRequest) -> String {
        func quote(_ text: String) -> String { literal(text) { String(format: "\\u%04x", $0) } }
        var options = ["  method: \(quote(request.method)),"]
        if !request.headers.isEmpty {
            // A list of pairs, so a header that appears twice is sent twice.
            let pairs = request.headers.map { "    [\(quote($0.name)), \(quote($0.value))]," }
            options.append("  headers: [\n" + pairs.joined(separator: "\n") + "\n  ],")
        }
        if let text = bodyText(request) {
            options.append("  body: \(quote(text)),")
        } else if request.body != nil {
            options.append("  body: bodyBytes,")
        }
        let lines: [String?] = [
            binaryNote(request, comment: "//").map { $0 + " Set bodyBytes to it." },
            "const response = await fetch(\(quote(request.url)), {",
            options.joined(separator: "\n"),
            "});",
            "",
            "console.log(response.status);",
            "console.log(await response.text());",
        ]
        return lines.compactMap { $0 }.joined(separator: "\n")
    }

    private static func python(_ request: PreparedRequest) -> String {
        func quote(_ text: String) -> String { literal(text) { String(format: "\\x%02x", $0) } }
        var arguments = ["    \(quote(request.method)),", "    \(quote(request.url)),"]
        if !request.headers.isEmpty {
            let pairs = request.headers.map { "        \(quote($0.name)): \(quote($0.value))," }
            arguments.append("    headers={\n" + pairs.joined(separator: "\n") + "\n    },")
        }
        if let text = bodyText(request) {
            arguments.append("    data=\(quote(text)).encode(\"utf-8\"),")
        } else if request.body != nil {
            arguments.append("    data=body_bytes,")
        }
        let lines: [String?] = [
            "import requests",
            "",
            binaryNote(request, comment: "#").map { $0 + " Set body_bytes to it." },
            "response = requests.request(",
            arguments.joined(separator: "\n"),
            ")",
            "",
            "print(response.status_code)",
            "print(response.text)",
        ]
        return lines.compactMap { $0 }.joined(separator: "\n")
    }

    private static func swift(_ request: PreparedRequest) -> String {
        func quote(_ text: String) -> String { literal(text) { String(format: "\\u{%x}", $0) } }
        var lines = [
            "import Foundation",
            "",
            "var request = URLRequest(url: URL(string: \(quote(request.url)))!)",
            "request.httpMethod = \(quote(request.method))",
        ]
        for header in request.headers {
            lines.append("request.addValue(\(quote(header.value)), forHTTPHeaderField: \(quote(header.name)))")
        }
        if let text = bodyText(request) {
            lines.append("request.httpBody = Data(\(quote(text)).utf8)")
        } else if let note = binaryNote(request, comment: "//") {
            lines.append(note + " Set request.httpBody to it.")
        }
        lines += [
            "",
            "let (data, response) = try await URLSession.shared.data(for: request)",
            "print((response as! HTTPURLResponse).statusCode)",
            "print(String(decoding: data, as: UTF8.self))",
        ]
        return lines.joined(separator: "\n")
    }
}
