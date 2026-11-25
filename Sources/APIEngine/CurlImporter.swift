import Foundation

public enum CurlImportError: Error, LocalizedError, Equatable {
    case notCurl
    case noURL

    public var errorDescription: String? {
        switch self {
        case .notCurl: return "The text is not a curl command."
        case .noURL: return "The curl command has no URL."
        }
    }
}

/// Turns a pasted `curl` command into a request.
public enum CurlImporter {

    public static func importCommand(_ command: String) throws -> RequestItem {
        var tokens = tokenize(command)
        guard tokens.first == "curl" else { throw CurlImportError.notCurl }
        tokens.removeFirst()

        var method: String?
        var url: String?
        var headers: [KeyValue] = []
        var data: [String] = []
        var form: [FormField] = []
        var auth: Auth = .none
        var forceGet = false
        var isJSON = false

        // Options that take a value we do not use; the value must still be skipped.
        let ignoredWithValue: Set<String> = [
            "-o", "--output", "-m", "--max-time", "--connect-timeout", "-x", "--proxy", "--cert",
            "--key", "--cacert", "-w", "--write-out", "--retry", "-E", "--resolve", "-c", "--cookie-jar",
        ]

        var index = 0
        func next() -> String? {
            index += 1
            return index < tokens.count ? tokens[index] : nil
        }

        while index < tokens.count {
            var token = tokens[index]
            var attached: String?
            // Short options can carry their value with no space: -XPOST, -H'Name: value'.
            if token.count > 2, token.hasPrefix("-"), !token.hasPrefix("--"),
               ["-X", "-H", "-d", "-u", "-F", "-A", "-e", "-b"].contains(String(token.prefix(2))) {
                attached = String(token.dropFirst(2))
                token = String(token.prefix(2))
            }
            func value() -> String? { attached ?? next() }

            switch token {
            case "-X", "--request":
                method = value()?.uppercased()
            case "-H", "--header":
                if let header = value(), let colon = header.firstIndex(of: ":") {
                    headers.append(KeyValue(
                        key: header[..<colon].trimmingCharacters(in: .whitespaces),
                        value: header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    ))
                }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode":
                if let v = value() { data.append(v) }
            case "--json":
                if let v = value() { data.append(v) }
                isJSON = true
            case "-F", "--form":
                if let v = value() {
                    let pieces = v.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    let fieldValue = pieces.count > 1 ? String(pieces[1]) : ""
                    if fieldValue.hasPrefix("@") {
                        form.append(FormField(key: String(pieces[0]), value: String(fieldValue.dropFirst()), isFile: true))
                    } else {
                        form.append(FormField(key: String(pieces[0]), value: fieldValue))
                    }
                }
            case "-u", "--user":
                if let v = value() {
                    let pieces = v.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    auth = .basic(username: String(pieces[0]), password: pieces.count > 1 ? String(pieces[1]) : "")
                }
            case "-A", "--user-agent":
                if let v = value() { headers.append(KeyValue(key: "User-Agent", value: v)) }
            case "-e", "--referer":
                if let v = value() { headers.append(KeyValue(key: "Referer", value: v)) }
            case "-b", "--cookie":
                if let v = value() { headers.append(KeyValue(key: "Cookie", value: v)) }
            case "--url":
                url = value()
            case "-G", "--get":
                forceGet = true
            case "-I", "--head":
                method = "HEAD"
            default:
                if ignoredWithValue.contains(token) {
                    _ = next()
                } else if !token.hasPrefix("-"), url == nil {
                    url = token
                }
            }
            index += 1
        }

        guard let url, !url.isEmpty else { throw CurlImportError.noURL }
        let parts = URLParts.split(url)
        var request = RequestItem(url: parts.base, params: parts.params, headers: headers, auth: auth)

        if isJSON {
            if !headers.contains(where: { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                request.headers.append(KeyValue(key: "Content-Type", value: "application/json"))
            }
            if !headers.contains(where: { $0.key.caseInsensitiveCompare("Accept") == .orderedSame }) {
                request.headers.append(KeyValue(key: "Accept", value: "application/json"))
            }
        }

        if !form.isEmpty {
            request.body = .formData(fields: form)
        } else if !data.isEmpty {
            let joined = data.joined(separator: "&")
            if forceGet {
                request.params += URLParts.split("?" + joined).params
            } else {
                let hasContentType = request.headers.contains { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }
                // curl sends form encoding by default when given data without a Content-Type.
                request.body = .raw(text: joined, contentType: hasContentType ? nil : "application/x-www-form-urlencoded")
            }
        }

        request.method = method ?? (request.body == .none ? "GET" : "POST")

        // Name the request after the last part of its path.
        let path = URL(string: parts.base)?.path ?? ""
        let last = path.split(separator: "/").last.map(String.init)
        request.name = last ?? URL(string: parts.base)?.host ?? "Imported Request"
        return request
    }

    /// Splits a command line the way a shell would: quotes, escapes and line continuations.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var chars = Array(input)[...]

        func finish() {
            if hasToken { tokens.append(current) }
            current = ""
            hasToken = false
        }

        while let c = chars.popFirst() {
            switch c {
            case "\\":
                guard let escaped = chars.popFirst() else { break }
                // A backslash before a line break continues the command on the next line.
                if escaped.isNewline { break }
                current.append(escaped)
                hasToken = true
            case "'":
                hasToken = true
                while let q = chars.popFirst(), q != "'" { current.append(q) }
            case "\"":
                hasToken = true
                while let q = chars.popFirst(), q != "\"" {
                    if q == "\\", let escaped = chars.first, "\"\\$`".contains(escaped) {
                        current.append(chars.removeFirst())
                    } else {
                        current.append(q)
                    }
                }
            case "$" where chars.first == "'":
                // ANSI-C quoting: $'line\nbreak'
                chars.removeFirst()
                hasToken = true
                while let q = chars.popFirst(), q != "'" {
                    guard q == "\\", let escaped = chars.popFirst() else {
                        current.append(q)
                        continue
                    }
                    switch escaped {
                    case "n": current.append("\n")
                    case "t": current.append("\t")
                    case "r": current.append("\r")
                    default: current.append(escaped)
                    }
                }
            case _ where c.isWhitespace:
                finish()
            default:
                current.append(c)
                hasToken = true
            }
        }
        finish()
        return tokens
    }
}
