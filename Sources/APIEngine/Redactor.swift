import Foundation

/// Masks secrets in text shown on screen, so a shared screen or a recording does not leak them.
/// It changes only what is displayed. Requests are always sent with their real values.
public struct Redactor: Sendable {
    public static let mask = "••••••••"

    /// Known secret values, longest first so a longer secret is masked before a shorter one inside it.
    public let secrets: [String]

    /// - Parameter secrets: Values to hide wherever they appear. Very short values are ignored,
    ///   because masking every "1" or "ab" would make the screen unreadable.
    public init(secrets: [String] = []) {
        self.secrets = Array(Set(secrets.filter { $0.count >= 4 })).sorted { $0.count > $1.count }
    }

    /// Builds a redactor from the variables and auth settings in play.
    /// - Parameter extra: Further values to hide, such as a request's own API-key header.
    public init(variables: [Variable], auths: [Auth] = [], resolver: VariableResolver = VariableResolver(scopes: []), extra: [String] = []) {
        var values: [String] = extra
        for variable in variables where variable.secret || Self.isSensitiveName(variable.key) {
            values.append(variable.effectiveValue)
        }
        for auth in auths {
            switch auth {
            case .inherit, .none:
                break
            case .basic(let username, let password):
                let user = resolver.resolve(username).string
                let pass = resolver.resolve(password).string
                values.append(pass)
                values.append(Data("\(user):\(pass)".utf8).base64EncodedString())
            case .bearer(let token):
                values.append(resolver.resolve(token).string)
            case .apiKey(_, let value, _):
                values.append(resolver.resolve(value).string)
            case .oauth2(let config):
                values.append(resolver.resolve(config.clientSecret).string)
                values.append(resolver.resolve(config.password).string)
            }
        }
        self.init(secrets: values)
    }

    /// Whether a header, query parameter, variable or JSON key with this name usually holds a secret.
    public static func isSensitiveName(_ name: String) -> Bool {
        let lower = name.lowercased()
        // Rate-limit headers mention "tokens" but hold counts, not secrets.
        if lower.contains("ratelimit") || lower.contains("rate-limit") || lower.contains("rate_limit") { return false }
        if ["authorization", "proxy-authorization", "cookie", "set-cookie", "key", "apikey", "pwd", "pass"].contains(lower) { return true }
        for part in ["token", "secret", "password", "passwd", "apikey", "api-key", "api_key", "signature", "credential", "session"] where lower.contains(part) {
            return true
        }
        return lower.hasSuffix("-key") || lower.hasSuffix("_key") || lower.hasSuffix("-auth") || lower.hasSuffix("_auth")
    }

    /// Masks known secret values, credentials after "Bearer" or "Basic", and sensitive JSON fields.
    public func redact(_ text: String) -> String {
        var output = text
        for secret in secrets {
            output = output.replacingOccurrences(of: secret, with: Self.mask)
        }
        output = Self.replace(#"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{4,}"#, in: output) { match in
            "\(match[1]) \(Self.mask)"
        }
        // A URL quoted inside a body or log line: mask the values of its sensitive query parameters.
        output = Self.replace(#"([?&])([A-Za-z0-9_.\-\[\]%]+)=([^&#\s"'<>\\]+)"#, in: output) { match in
            guard Self.isSensitiveName(match[2].removingPercentEncoding ?? match[2]) else { return match[0] }
            return "\(match[1])\(match[2])=\(Self.mask)"
        }
        output = Self.replace(#""([^"\\]*)"(\s*:\s*)"((?:[^"\\]|\\.)*)""#, in: output) { match in
            guard Self.isSensitiveName(match[1]), !match[3].isEmpty else { return match[0] }
            return "\"\(match[1])\"\(match[2])\"\(Self.mask)\""
        }
        return output
    }

    /// The value to show for a header: fully masked when the name is sensitive.
    public func header(name: String, value: String) -> String {
        guard Self.isSensitiveName(name), !value.isEmpty else { return redact(value) }
        // Keep the scheme word, which says how the request authenticates without revealing anything.
        let pieces = value.split(separator: " ", maxSplits: 1)
        if pieces.count == 2, ["bearer", "basic", "digest", "token"].contains(pieces[0].lowercased()) {
            return "\(pieces[0]) \(Self.mask)"
        }
        return Self.mask
    }

    /// Masks passwords in the address and the values of sensitive query parameters.
    public func url(_ url: String) -> String {
        var output = Self.replace(#"(://[^/@:\s]*):([^/@\s]+)@"#, in: url) { match in
            "\(match[1]):\(Self.mask)@"
        }
        output = Self.replace(#"([?&])([^=&#\s]+)=([^&#\s]*)"#, in: output) { match in
            guard Self.isSensitiveName(match[2].removingPercentEncoding ?? match[2]), !match[3].isEmpty else { return match[0] }
            return "\(match[1])\(match[2])=\(Self.mask)"
        }
        return redact(output)
    }

    /// Masks one "Name: value" line, as found in the wire log.
    public func headerLine(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return self.url(line) }
        let name = String(line[..<colon])
        // A line such as "> POST /path HTTP/1.1" or "* Connected to host" is not a header.
        guard !name.contains(" ") else { return self.url(line) }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return "\(name): \(header(name: name, value: value))"
    }

    /// Replaces each regex match using the capture groups (index 0 is the whole match).
    private static func replace(_ pattern: String, in text: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let source = text as NSString
        var output = ""
        var position = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: position, length: match.range.location - position))
            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location == NSNotFound ? "" : source.substring(with: range))
            }
            output += transform(groups)
            position = match.range.location + match.range.length
        }
        output += source.substring(from: position)
        return output
    }
}
