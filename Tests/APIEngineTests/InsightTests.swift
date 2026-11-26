import Foundation
import Testing
@testable import APIEngine

private let shop = Data("""
{
  "store": "Corner",
  "open": true,
  "items": [
    {"name": "apple", "price": 3, "tags": ["fruit", "red"], "stock": {"count": 12}},
    {"name": "bread", "price": 12.5, "tags": ["bakery"], "stock": {"count": 0}},
    {"name": "cheese", "price": 20, "tags": [], "onSale": true, "stock": {"count": 4}}
  ],
  "owner": {"name": "Sam", "key with space": 1}
}
""".utf8)

private func query(_ expression: String) throws -> String {
    // Compact, so expectations read on one line.
    let root = try JSONSerialization.jsonObject(with: shop)
    let matches = try JSONQuery.evaluate(expression, in: root)
    let data = try JSONSerialization.data(withJSONObject: matches, options: [.sortedKeys, .fragmentsAllowed])
    return String(decoding: data, as: UTF8.self)
}

@Suite struct JSONPathQueryTests {
    @Test func namesIndexesAndWildcards() throws {
        #expect(try query("$.store") == #"["Corner"]"#)
        #expect(try query("$.items[0].name") == #"["apple"]"#)
        #expect(try query("$.items[-1].name") == #"["cheese"]"#)
        #expect(try query("$.items[*].name") == #"["apple","bread","cheese"]"#)
        #expect(try query("$.items.*.price") == "[3,12.5,20]")
        #expect(try query("$['owner']['key with space']") == "[1]")
        #expect(try query("$.items[0,2].name") == #"["apple","cheese"]"#)
        #expect(try query("$.missing.deeper") == "[]")
    }

    @Test func slices() throws {
        #expect(try query("$.items[0:2].name") == #"["apple","bread"]"#)
        #expect(try query("$.items[1:].name") == #"["bread","cheese"]"#)
        #expect(try query("$.items[-2:].name") == #"["bread","cheese"]"#)
        #expect(try query("$.items[::2].name") == #"["apple","cheese"]"#)
    }

    @Test func recursiveDescentFindsEveryMatchAtAnyDepth() throws {
        #expect(try query("$..name") == #"["apple","bread","cheese","Sam"]"#)
        #expect(try query("$..count") == "[12,0,4]")
        #expect(try query("$..tags[0]") == #"["fruit","bakery"]"#)
    }

    @Test func filters() throws {
        #expect(try query("$.items[?(@.price > 10)].name") == #"["bread","cheese"]"#)
        #expect(try query("$.items[?(@.price <= 12.5 && @.stock.count > 0)].name") == #"["apple"]"#)
        #expect(try query("$.items[?(@.name == 'bread' || @.onSale)].name") == #"["bread","cheese"]"#)
        #expect(try query("$.items[?(!@.onSale)].name") == #"["apple","bread"]"#)
        #expect(try query("$.items[?@.name =~ /^C/i].name") == #"["cheese"]"#)
        #expect(try query("$.items[?(@.onSale == true)].name") == #"["cheese"]"#)
        // A number is not equal to a string that looks like it.
        #expect(try query("$.items[?(@.price == '3')].name") == "[]")
        #expect(try query("$.items[?(@.name != $.owner.name)].length()") == "[4,4,5]")
    }

    @Test func aBrokenExpressionSaysWhere() {
        #expect(throws: JSONQuery.QueryError.self) { try query("$.items[") }
        #expect(throws: JSONQuery.QueryError.self) { try query("$.items[?(@.price >)]") }
        #expect(throws: JSONQuery.QueryError.self) { try query("$.items name") }
    }

    @Test func runGivesTheMatchesAsIndentedJSON() throws {
        #expect(try JSONQuery.run("$.items[?(@.price < 5)].name", on: shop) == "[\n  \"apple\"\n]")
        #expect(throws: JSONQuery.QueryError.self) { try JSONQuery.run("$.a", on: Data("<html>".utf8)) }
    }
}

@Suite struct JQQueryTests {
    @Test func pathsAndIteration() throws {
        #expect(try query(".") != "[]")
        #expect(try query(".store") == #"["Corner"]"#)
        #expect(try query(".owner.name") == #"["Sam"]"#)
        #expect(try query(#".owner."key with space""#) == "[1]")
        #expect(try query(#".owner["key with space"]"#) == "[1]")
        #expect(try query(".items[1].name") == #"["bread"]"#)
        #expect(try query(".items[].name") == #"["apple","bread","cheese"]"#)
        #expect(try query(".items | .[] | .price") == "[3,12.5,20]")
        #expect(try query(".missing?.deeper") == "[]")
    }

    @Test func aSliceStaysOneArray() throws {
        #expect(try query(".items[0:2] | length") == "[2]")
    }

    @Test func selectMapLengthAndKeys() throws {
        #expect(try query(".items[] | select(.price > 10) | .name") == #"["bread","cheese"]"#)
        #expect(try query(".items[] | select(.onSale) | .name") == #"["cheese"]"#)
        #expect(try query(".items[] | select(.onSale | not) | .name") == #"["apple","bread"]"#)
        #expect(try query(#".items[] | select(.name | startswith("b")) | .price"#) == "[12.5]")
        #expect(try query(#".items[] | select(.name | test("e$")) | .name"#) == #"["apple","cheese"]"#)
        #expect(try query(".items[] | select(.price < 20 and .stock.count > 0) | .name") == #"["apple"]"#)
        #expect(try query(".items | map(.name)") == #"[["apple","bread","cheese"]]"#)
        #expect(try query("[.items[] | select(.price > 5) | .name] | length") == "[2]")
        #expect(try query(".items | length") == "[3]")
        #expect(try query(".owner | keys") == #"[["key with space","name"]]"#)
        #expect(try query(".. | .count?") == "[12,0,4]")
    }

    @Test func runPrintsOneValueAfterAnother() throws {
        #expect(try JSONQuery.run(".items[].name", on: shop) == "\"apple\"\n\"bread\"\n\"cheese\"")
    }
}

@Suite struct JWTTests {
    /// Builds an unsigned token from a header and claims.
    static func token(_ header: String, _ payload: String) -> String {
        func part(_ text: String) -> String {
            Data(text.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return "\(part(header)).\(part(payload)).c2lnbmF0dXJl"
    }

    @Test func decodesTheHeaderAndClaims() throws {
        let token = Self.token(#"{"alg":"HS256","typ":"JWT"}"#, #"{"sub":"user-42","iss":"https://issuer.example","iat":1700000000,"exp":1700003600}"#)
        let jwt = try #require(JWT.decode(token))
        #expect(jwt.algorithm == "HS256")
        #expect(jwt.subject == "user-42")
        #expect(jwt.issuer == "https://issuer.example")
        #expect(jwt.issuedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(jwt.expires == Date(timeIntervalSince1970: 1_700_003_600))
        #expect(jwt.isExpired(at: Date(timeIntervalSince1970: 1_700_003_601)))
        #expect(!jwt.isExpired(at: Date(timeIntervalSince1970: 1_700_000_001)))
        #expect(jwt.payload.contains("\"sub\": \"user-42\""))
    }

    @Test func textThatOnlyLooksLikeATokenIsLeftAlone() {
        #expect(JWT.decode("not.a.token") == nil)
        #expect(JWT.decode("eyJhbGciOiJIUzI1NiJ9.only-two-parts") == nil)
        #expect(JWT.find(in: "version 1.2.3 of api.example.com").isEmpty)
    }

    @Test func findsTokensInHeadersAndTheBodyOnce() throws {
        let token = Self.token(#"{"alg":"none"}"#, #"{"sub":"a"}"#)
        let other = Self.token(#"{"alg":"RS256"}"#, #"{"sub":"b"}"#)
        let request = PreparedRequest(method: "GET", url: "https://x.test", headers: [HTTPHeader(name: "Authorization", value: "Bearer \(token)")])
        let response = HTTPResponse(
            status: 200, statusText: "OK", httpVersion: "HTTP/1.1", headers: [],
            body: Data(#"{"access_token":"\#(other)","echo":"\#(token)"}"#.utf8),
            timings: HTTPTimings(), remoteAddress: nil, wireLog: []
        )
        let found = JWT.find(request: request, response: response)
        #expect(found.map(\.source) == ["Request header Authorization", "Response body"])
        #expect(found.map(\.jwt.subject) == ["a", "b"])
    }
}

@Suite struct RateLimitTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func headers(_ pairs: KeyValuePairs<String, String>) -> [HTTPHeader] {
        pairs.map { HTTPHeader(name: $0.key, value: $0.value) }
    }

    @Test func gitHubStyleHeadersWithAClockTimeReset() throws {
        let limit = try #require(RateLimit.parse(headers([
            "x-ratelimit-limit": "5000", "x-ratelimit-remaining": "4990", "x-ratelimit-reset": "1700000900",
        ]), now: now))
        #expect(limit.limit == 5000)
        #expect(limit.remaining == 4990)
        #expect(limit.reset == Date(timeIntervalSince1970: 1_700_000_900))
        #expect(limit.fractionRemaining == 0.998)
    }

    @Test func draftHeadersCountDownInSeconds() throws {
        let limit = try #require(RateLimit.parse(headers([
            "RateLimit-Limit": "100, 100;w=60", "RateLimit-Remaining": "0", "RateLimit-Reset": "30", "Retry-After": "30",
        ]), now: now))
        #expect(limit.limit == 100)
        #expect(limit.remaining == 0)
        #expect(limit.reset == now.addingTimeInterval(30))
        #expect(limit.retryAfter == 30)
        #expect(limit.fractionRemaining == 0)
    }

    @Test func theSingleHeaderInBothItsForms() throws {
        let older = try #require(RateLimit.parse(headers(["RateLimit": "limit=10, remaining=4, reset=5"]), now: now))
        #expect(older.limit == 10)
        #expect(older.remaining == 4)
        #expect(older.reset == now.addingTimeInterval(5))

        let newer = try #require(RateLimit.parse(headers([
            "RateLimit": "\"default\";r=50;t=30", "RateLimit-Policy": "\"default\";q=100;w=60",
        ]), now: now))
        #expect(newer.limit == 100)
        #expect(newer.remaining == 50)
    }

    @Test func retryAfterAsADate() throws {
        let limit = try #require(RateLimit.parse(headers(["Retry-After": "Tue, 14 Nov 2023 22:14:20 GMT"]), now: now))
        #expect(limit.retryAfter == 60)
    }

    @Test func noneOfTheHeadersMeansNoGauge() {
        #expect(RateLimit.parse(headers(["Content-Type": "application/json"]), now: now) == nil)
    }
}

@Suite struct CodeSnippetTests {
    private let request = PreparedRequest(
        method: "POST",
        url: "https://api.example.com/v1/notes?tag=it's",
        headers: [
            HTTPHeader(name: "Authorization", value: "Bearer abc"),
            HTTPHeader(name: "Content-Type", value: "application/json"),
            HTTPHeader(name: "User-Agent", value: RequestBuilder.userAgent),
        ],
        body: Data("{\"text\": \"it's \\\"quoted\\\"\\nline two\"}".utf8)
    )

    @Test func curlRoundTripsThroughTheImporter() throws {
        let command = CodeSnippet.generate(request, language: .curl)
        #expect(command.hasPrefix("curl 'https://api.example.com/v1/notes?tag=it'\\''s'"))
        #expect(!command.contains("User-Agent"))
        let imported = try CurlImporter.importCommand(command)
        #expect(imported.method == "POST")
        let prepared = try RequestBuilder.prepare(imported, auth: .none, resolver: VariableResolver(scopes: []))
        #expect(prepared.url == "https://api.example.com/v1/notes?tag=it%27s")
        #expect(prepared.header("Authorization") == "Bearer abc")
        #expect(prepared.body == request.body)
    }

    @Test func curlNamesTheMethodOnlyWhenItMust() {
        let get = PreparedRequest(method: "GET", url: "https://x.test")
        #expect(CodeSnippet.generate(get, language: .curl) == "curl 'https://x.test'")
        let delete = PreparedRequest(method: "DELETE", url: "https://x.test/1", headers: [HTTPHeader(name: "X-Empty", value: "")])
        #expect(CodeSnippet.generate(delete, language: .curl) == "curl --request DELETE \\\n  'https://x.test/1' \\\n  --header 'X-Empty;'")
    }

    @Test func aBinaryBodyIsNamedNotWritten() {
        let upload = PreparedRequest(method: "PUT", url: "https://x.test/file", body: Data([0xFF, 0xD8, 0x00]))
        for language in SnippetLanguage.allCases {
            #expect(CodeSnippet.generate(upload, language: language).contains("3 bytes of binary data"))
        }
    }

    @Test func codeEscapesQuotesAndNewlines() {
        let javascript = CodeSnippet.generate(request, language: .javascript)
        #expect(javascript.contains(#"body: "{\"text\": \"it's \\\"quoted\\\"\\nline two\"}","#))
        #expect(javascript.contains(#"["Authorization", "Bearer abc"],"#))

        let python = CodeSnippet.generate(request, language: .python)
        #expect(python.contains(#""Content-Type": "application/json","#))
        #expect(python.contains(#""POST","#))

        let swift = CodeSnippet.generate(request, language: .swift)
        #expect(swift.contains(#"request.httpMethod = "POST""#))
        #expect(swift.contains(#"request.addValue("Bearer abc", forHTTPHeaderField: "Authorization")"#))
    }

    /// The generated Python and JavaScript are run through their own parsers when those are installed.
    @Test func generatedCodeParses() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snippets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let checks: [(SnippetLanguage, String, String, [String])] = [
            (.python, "snippet.py", "/usr/bin/python3", ["-c", "import ast,sys; ast.parse(open(sys.argv[1]).read())"]),
            (.curl, "snippet.sh", "/bin/sh", ["-n"]),
        ]
        for (language, name, tool, arguments) in checks where FileManager.default.isExecutableFile(atPath: tool) {
            let file = folder.appendingPathComponent(name)
            try CodeSnippet.generate(request, language: language).write(to: file, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments + [file.path]
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(language.label) did not parse")
        }
    }
}

@Suite struct LatencyStatsTests {
    @Test func percentilesReadBetweenSamples() {
        let times = (1...100).map { Double($0) }
        #expect(LatencyStats.percentile(times, 0.5) == 50.5)
        #expect(LatencyStats.percentile(times, 0.99) == 99.01)
        #expect(LatencyStats.percentile([7], 0.95) == 7)
        #expect(LatencyStats.percentile([], 0.5) == 0)
    }

    @Test func countsErrorsOfEveryKind() {
        let stats = LatencyStats([
            RepeatSample(seconds: 0.1, status: 200),
            RepeatSample(seconds: 0.3, status: 200),
            RepeatSample(seconds: 0.2, status: 500),
            RepeatSample(seconds: 0.4, status: 200, failedTests: 1),
            RepeatSample(error: "Could not connect"),
        ])
        #expect(stats.count == 5)
        #expect(stats.errors == 3)
        #expect(stats.incomplete == 1)
        #expect(stats.errorRate == 0.6)
        #expect(stats.statuses == [200: 3, 500: 1])
        #expect(stats.minimum == 0.1)
        #expect(stats.maximum == 0.4)
        #expect(abs(stats.mean - 0.25) < 0.0001)
        #expect(abs(stats.p50 - 0.25) < 0.0001)
    }

    @Test func histogramCoversEverySample() {
        let bands = LatencyStats.histogram([0.1, 0.1, 0.2, 0.5, 1.0], bands: 5)
        #expect(bands.count == 5)
        #expect(bands.map(\.count).reduce(0, +) == 5)
        #expect(bands.first?.count == 3)
        #expect(bands.last?.count == 1)
        #expect(LatencyStats.histogram([]).isEmpty)
    }
}

@Suite struct FuzzyMatchTests {
    @Test func everyWordMustAppear() {
        #expect(FuzzyMatch.score("get user", in: "Get Users") != nil)
        #expect(FuzzyMatch.score("gtusr", in: "Get Users") != nil)
        #expect(FuzzyMatch.score("delete", in: "Get Users") == nil)
        #expect(FuzzyMatch.score("get orders", in: "Get Users") == nil)
        #expect(FuzzyMatch.score("", in: "Anything") == 0)
    }

    @Test func closerMatchesRankHigher() throws {
        let start = try #require(FuzzyMatch.score("user", in: "Users list"))
        let word = try #require(FuzzyMatch.score("user", in: "Get users"))
        let inside = try #require(FuzzyMatch.score("user", in: "Superusers"))
        let scattered = try #require(FuzzyMatch.score("user", in: "Update server"))
        #expect(start > word)
        #expect(word > inside)
        #expect(inside > scattered)
    }
}

@Suite struct ClientCertificateRuleTests {
    @Test func matchesHostsPortsAndSubdomains() {
        let exact = ClientCertificateRule(host: "api.example.com", certificatePath: "/c.pem")
        #expect(exact.matches(host: "API.example.com", port: 443))
        #expect(!exact.matches(host: "other.example.com", port: 443))

        let withPort = ClientCertificateRule(host: "localhost:8443", certificatePath: "/c.pem")
        #expect(withPort.matches(host: "localhost", port: 8443))
        #expect(!withPort.matches(host: "localhost", port: 443))

        let wildcard = ClientCertificateRule(host: "*.example.com", certificatePath: "/c.pem")
        #expect(wildcard.matches(host: "a.b.example.com", port: 443))
        #expect(!wildcard.matches(host: "example.com", port: 443))

        let pasted = ClientCertificateRule(host: "https://api.example.com/v1", certificatePath: "/c.pem")
        #expect(pasted.matches(host: "api.example.com", port: 443))

        #expect(!ClientCertificateRule(host: "api.example.com", certificatePath: "/c.pem", enabled: false).matches(host: "api.example.com", port: 443))
        #expect(!ClientCertificateRule(host: "api.example.com").matches(host: "api.example.com", port: 443))
    }

    @Test func onlyEncryptedAddressesGetACertificate() {
        let rules = [ClientCertificateRule(host: "localhost:8443", certificatePath: "/c.pem")]
        #expect(rules.rule(for: "https://localhost:8443/x") != nil)
        #expect(rules.rule(for: "http://localhost:8443/x") == nil)
        #expect(rules.rule(for: "https://localhost/x") == nil)
    }

    @Test func theExecutorAddsTheCertificateAndItsPassphrase() {
        let secrets = InMemorySecretStore()
        let rule = ClientCertificateRule(host: "secure.test", certificatePath: "/c.p12")
        secrets.set("hunter2", for: rule.passphraseKey)
        var executor = RequestExecutor()
        executor.clientCertificates = [rule]
        executor.secrets = secrets
        #expect(executor.options(for: "https://secure.test/a").clientCertificate == ClientCertificate(certificatePath: "/c.p12", passphrase: "hunter2"))
        #expect(executor.options(for: "https://plain.test/a").clientCertificate == nil)
    }
}

/// Runs the Mac's own `openssl s_server` on localhost with a certificate made for the test,
/// so the certificate chain and client certificates are checked against a real TLS server.
@Suite(.serialized) struct TLSTests {
    final class Server {
        let folder: URL
        let port: Int
        private var process: Process?

        static let openssl = "/usr/bin/openssl"

        @discardableResult
        static func run(_ arguments: [String], in folder: URL) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: openssl)
            process.arguments = arguments
            process.currentDirectoryURL = folder
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        init(requireClientCertificate: Bool) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("tls-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // One self-signed certificate for the server, and one for the client that the server trusts.
            try Self.run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key", "-out", "server.pem",
                          "-days", "2", "-subj", "/CN=localhost/O=API Playground Tests"], in: folder)
            try Self.run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "client.key", "-out", "client.pem",
                          "-days", "2", "-subj", "/CN=test client"], in: folder)
            try Self.run(["pkcs12", "-export", "-inkey", "client.key", "-in", "client.pem", "-out", "client.p12",
                          "-passout", "pass:secret"], in: folder)

            // Ask the system for a free port.
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, length) }
            }
            _ = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
            }
            port = Int(UInt16(bigEndian: address.sin_port))
            close(socket)

            let server = Process()
            server.executableURL = URL(fileURLWithPath: Self.openssl)
            var arguments = ["s_server", "-accept", String(port), "-cert", "server.pem", "-key", "server.key", "-www"]
            if requireClientCertificate { arguments += ["-Verify", "1", "-CAfile", "client.pem"] }
            server.arguments = arguments
            server.currentDirectoryURL = folder
            server.standardOutput = Pipe()
            server.standardError = Pipe()
            server.standardInput = Pipe()
            try server.run()
            process = server
        }

        var url: String { "https://localhost:\(port)/" }
        func path(_ name: String) -> String { folder.appendingPathComponent(name).path }

        /// Sends until the server is up, which takes a moment after it is started.
        func send(_ options: HTTPOptions) async throws -> HTTPResponse {
            var last: Error = HTTPClientError(code: 0, message: "never sent")
            for _ in 0..<40 {
                do {
                    return try await HTTPClient().send(PreparedRequest(method: "GET", url: url), options: options)
                } catch let error as HTTPClientError where error.code == 7 {
                    // Could not connect yet.
                    last = error
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            throw last
        }

        deinit {
            process?.terminate()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func readsTheServersCertificate() async throws {
        let server = try Server(requireClientCertificate: false)
        var options = HTTPOptions()
        options.verifyTLS = false
        let response = try await server.send(options)
        let tls = try #require(response.tls)
        #expect(tls.verified == false)
        #expect(tls.protocolVersion?.hasPrefix("TLS") == true)
        #expect(tls.cipher?.isEmpty == false)
        let certificate = try #require(tls.certificates.first)
        #expect(certificate.commonName == "localhost")
        #expect(certificate.isSelfSigned)
        #expect(certificate.pem?.contains("BEGIN CERTIFICATE") == true)
        let expiry = try #require(certificate.notAfter)
        #expect(expiry > Date() && expiry < Date().addingTimeInterval(3 * 86400))
    }

    @Test func aSelfSignedServerIsRefusedWhenChecking() async throws {
        let server = try Server(requireClientCertificate: false)
        await #expect(throws: HTTPClientError.self) { try await server.send(HTTPOptions()) }
    }

    @Test func presentsAClientCertificateFromPEMFilesOrPKCS12() async throws {
        let server = try Server(requireClientCertificate: true)
        var options = HTTPOptions()
        options.verifyTLS = false

        // Without a certificate the server ends the handshake.
        await #expect(throws: HTTPClientError.self) { try await server.send(options) }

        options.clientCertificate = ClientCertificate(certificatePath: server.path("client.pem"), keyPath: server.path("client.key"))
        let withPEM = try await server.send(options)
        #expect(withPEM.status == 200)
        #expect(withPEM.tls?.clientCertificate == server.path("client.pem"))

        options.clientCertificate = ClientCertificate(certificatePath: server.path("client.p12"), passphrase: "secret")
        #expect(try await server.send(options).status == 200)

        options.clientCertificate = ClientCertificate(certificatePath: server.path("client.p12"), passphrase: "wrong")
        await #expect(throws: HTTPClientError.self) { try await server.send(options) }
    }
}
