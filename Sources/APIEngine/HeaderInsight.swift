import Foundation

// MARK: - JSON Web Tokens

/// A JSON Web Token taken apart for reading. The signature is not checked: that needs the
/// issuer's key, which the app does not have.
public struct DecodedJWT: Equatable, Sendable {
    public var token: String
    /// The header and the claims, as indented JSON.
    public var header: String
    public var payload: String
    public var algorithm: String?
    public var subject: String?
    public var issuer: String?
    public var issuedAt: Date?
    public var notBefore: Date?
    public var expires: Date?

    public func isExpired(at date: Date = Date()) -> Bool {
        expires.map { $0 <= date } ?? false
    }
}

public enum JWT {
    /// Three base64url parts joined by dots, the first two starting the way encoded JSON objects do.
    private static let pattern = try! NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{2,}\.[A-Za-z0-9_-]*"#)

    private static func decodePart(_ part: Substring) -> [String: Any]? {
        var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func decode(_ token: String) -> DecodedJWT? {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let header = decodePart(parts[0]), let payload = decodePart(parts[1]) else { return nil }
        func date(_ key: String) -> Date? {
            (payload[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        }
        return DecodedJWT(
            token: token,
            header: JSONQuery.text(header),
            payload: JSONQuery.text(payload),
            algorithm: header["alg"] as? String,
            subject: payload["sub"] as? String,
            issuer: payload["iss"] as? String,
            issuedAt: date("iat"),
            notBefore: date("nbf"),
            expires: date("exp")
        )
    }

    /// Every token in a piece of text, in order, without repeats.
    public static func find(in text: String) -> [DecodedJWT] {
        var seen: Set<String> = []
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let token = String(text[range])
            guard seen.insert(token).inserted else { return nil }
            return decode(token)
        }
    }

    public struct Found: Equatable, Sendable, Identifiable {
        /// Where the token was seen, such as "Request header Authorization".
        public var source: String
        public var jwt: DecodedJWT
        public var id: String { source + jwt.token }
    }

    /// The tokens in a request and its response: headers on both sides, and the response body.
    public static func find(request: PreparedRequest?, response: HTTPResponse) -> [Found] {
        var found: [Found] = []
        var seen: Set<String> = []
        func add(_ text: String, _ source: String) {
            for jwt in find(in: text) where seen.insert(jwt.token).inserted {
                found.append(Found(source: source, jwt: jwt))
            }
        }
        for header in request?.headers ?? [] { add(header.value, "Request header \(header.name)") }
        for header in response.headers { add(header.value, "Response header \(header.name)") }
        // Tokens sit in small JSON bodies. Do not search a download for them.
        if response.body.count <= 1_000_000, let text = response.text { add(text, "Response body") }
        return found
    }
}

// MARK: - Rate limits

/// What a response's headers say about the caller's quota.
public struct RateLimit: Equatable, Sendable {
    public var limit: Int?
    public var remaining: Int?
    /// When the quota refills.
    public var reset: Date?
    /// How long the server asked the caller to wait, from Retry-After.
    public var retryAfter: TimeInterval?

    /// The share of the quota still unused, from 0 to 1, when both numbers are known.
    public var fractionRemaining: Double? {
        guard let limit, let remaining, limit > 0 else { return nil }
        return min(1, max(0, Double(remaining) / Double(limit)))
    }

    /// Reads the headers in common use: `RateLimit-*` and the single `RateLimit` header from
    /// the IETF drafts, `X-RateLimit-*` as GitHub and many others send it, `X-Rate-Limit-*`,
    /// and `Retry-After`. Returns nil when the response has none of them.
    public static func parse(_ headers: [HTTPHeader], now: Date = Date()) -> RateLimit? {
        func value(_ names: String...) -> String? {
            for name in names {
                if let header = headers.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return header.value }
            }
            return nil
        }
        /// The number a value starts with: "100", "100, 100;w=60" and "30.5" all count.
        func leadingNumber(_ text: String?) -> Double? {
            guard let text else { return nil }
            let digits = text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." }
            return Double(digits)
        }
        func date(_ text: String?) -> Date? {
            guard let text else { return nil }
            if let number = leadingNumber(text) {
                // A large number is a clock time, in seconds or milliseconds. A small one counts down.
                if number > 100_000_000_000 { return Date(timeIntervalSince1970: number / 1000) }
                if number > 1_000_000_000 { return Date(timeIntervalSince1970: number) }
                return now.addingTimeInterval(number)
            }
            return httpDate(text) ?? ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespaces))
        }

        var result = RateLimit()
        result.limit = leadingNumber(value("RateLimit-Limit", "X-RateLimit-Limit", "X-Rate-Limit-Limit")).map(Int.init)
        result.remaining = leadingNumber(value("RateLimit-Remaining", "X-RateLimit-Remaining", "X-Rate-Limit-Remaining")).map(Int.init)
        result.reset = date(value("RateLimit-Reset", "X-RateLimit-Reset", "X-Rate-Limit-Reset"))

        // The single header: `limit=100, remaining=50, reset=30`, or `"name";r=50;t=30`
        // with the limit in `RateLimit-Policy: "name";q=100;w=60`.
        func parameters(_ text: String?) -> [String: String] {
            var out: [String: String] = [:]
            for piece in (text ?? "").split(whereSeparator: { $0 == "," || $0 == ";" }) {
                let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2 { out[pair[0].lowercased()] = pair[1] }
            }
            return out
        }
        let combined = parameters(value("RateLimit"))
        let policy = parameters(value("RateLimit-Policy"))
        if result.limit == nil { result.limit = leadingNumber(combined["limit"] ?? policy["q"]).map(Int.init) }
        if result.remaining == nil { result.remaining = leadingNumber(combined["remaining"] ?? combined["r"]).map(Int.init) }
        if result.reset == nil, let seconds = leadingNumber(combined["reset"] ?? combined["t"]) {
            result.reset = now.addingTimeInterval(seconds)
        }

        if let retry = value("Retry-After") {
            if let seconds = leadingNumber(retry) {
                result.retryAfter = seconds
            } else if let when = httpDate(retry) {
                result.retryAfter = max(0, when.timeIntervalSince(now))
            }
        }
        return result == RateLimit() ? nil : result
    }

    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }
}
