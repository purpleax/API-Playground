import Foundation
import Testing
@testable import APIEngine

@Suite struct Redaction {
    @Test func sensitiveNames() {
        for name in ["Authorization", "Cookie", "Set-Cookie", "X-API-Key", "Fastly-Key", "access_token", "client_secret", "password", "X-Auth-Token", "api_key", "key"] {
            #expect(Redactor.isSensitiveName(name), "\(name) should be sensitive")
        }
        for name in ["Content-Type", "Accept", "X-Request-Id", "x-ratelimit-remaining-tokens", "X-AI-RateLimit-Limit-minute-azure", "keyboard", "monkey", "name"] {
            #expect(!Redactor.isSensitiveName(name), "\(name) should not be sensitive")
        }
    }

    @Test func masksKnownValuesAndCredentials() {
        let redactor = Redactor(secrets: ["s3cr3t-value", "ab", "longer-s3cr3t-value"])
        let mask = Redactor.mask
        #expect(redactor.redact("x longer-s3cr3t-value y s3cr3t-value z ab") == "x \(mask) y \(mask) z ab")
        #expect(redactor.redact("Authorization: Bearer abc.def-123") == "Authorization: Bearer \(mask)")
        #expect(redactor.redact("uses basic dXNlcjpwYXNz here") == "uses basic \(mask) here")
        #expect(redactor.redact("nothing secret here") == "nothing secret here")
    }

    @Test func masksSensitiveJSONFields() {
        let mask = Redactor.mask
        let input = "{\n  \"name\": \"Rex\",\n  \"access_token\" : \"eyJhbGciOi\",\n  \"password\": \"p\\\"q\",\n  \"token\": \"\",\n  \"tokens_used\": 12\n}"
        let expected = "{\n  \"name\": \"Rex\",\n  \"access_token\" : \"\(mask)\",\n  \"password\": \"\(mask)\",\n  \"token\": \"\",\n  \"tokens_used\": 12\n}"
        #expect(Redactor().redact(input) == expected)
    }

    @Test func headersAndURLs() {
        let redactor = Redactor(secrets: ["tok_live_123"])
        let mask = Redactor.mask
        #expect(redactor.header(name: "Authorization", value: "Bearer tok_live_123") == "Bearer \(mask)")
        #expect(redactor.header(name: "Fastly-Key", value: "abc") == mask)
        #expect(redactor.header(name: "Accept", value: "application/json") == "application/json")
        #expect(redactor.header(name: "X-Trace", value: "id tok_live_123") == "id \(mask)")
        #expect(redactor.header(name: "x-ratelimit-remaining-tokens", value: "49958") == "49958")

        #expect(redactor.url("https://user:hunter2@api.example.com/v1?api_key=abc&limit=10&token=xyz#frag") == "https://user:\(mask)@api.example.com/v1?api_key=\(mask)&limit=10&token=\(mask)#frag")
        #expect(redactor.url("https://api.example.com/t/tok_live_123/x") == "https://api.example.com/t/\(mask)/x")

        #expect(redactor.headerLine("Fastly-Key: abcdef") == "Fastly-Key: \(mask)")
        #expect(redactor.headerLine("Content-Type: application/json") == "Content-Type: application/json")
        #expect(redactor.headerLine("GET /v1?api_key=abc HTTP/1.1") == "GET /v1?api_key=\(mask) HTTP/1.1")
    }

    @Test func collectsSecretsFromVariablesAndAuth() {
        let variables = [
            Variable(key: "plain", value: "visible-value"),
            Variable(key: "hidden", value: "marked-secret", secret: true),
            Variable(key: "api_token", value: "shared", currentValue: "current-token"),
        ]
        let resolver = VariableResolver(scopes: [["pw": "resolved-password"]])
        let redactor = Redactor(variables: variables, auths: [.basic(username: "guy", password: "{{pw}}"), .bearer(token: "bearer-value")], resolver: resolver)
        let text = "visible-value marked-secret current-token resolved-password bearer-value " + Data("guy:resolved-password".utf8).base64EncodedString()
        let mask = Redactor.mask
        #expect(redactor.redact(text) == "visible-value \(mask) \(mask) \(mask) \(mask) \(mask)")
    }
}

@Suite struct Mocking {
    let routes = [
        MockRoute(name: "List", method: "GET", path: "/pets", examples: [
            SavedResponse(name: "OK", status: 200, headers: [KeyValue(key: "Content-Type", value: "application/json"), KeyValue(key: "Content-Length", value: "999")], body: "[{\"id\": 1}]"),
            SavedResponse(name: "Empty", status: 200, body: "[]"),
            SavedResponse(name: "Down", status: 503, body: "busy"),
        ]),
        MockRoute(name: "Get", method: "GET", path: "/pets/:id", examples: [
            SavedResponse(name: "OK", status: 200, body: "{\"id\": \"{{id}}\", \"view\": \"{{view}}\", \"ref\": \"{{$guid}}\"}"),
        ]),
        MockRoute(name: "Latest", method: "GET", path: "/pets/latest", examples: [SavedResponse(name: "OK", status: 200, body: "latest")]),
        MockRoute(name: "Create", method: "POST", path: "/pets"),
        MockRoute(name: "Tenant", method: "GET", path: "/{{tenant}}/info", examples: [SavedResponse(name: "OK", status: 0, body: "{{tenant}}")]),
    ]

    func reply(_ method: String, _ target: String, headers: [String: String] = [:]) -> MockReply {
        MockServer.reply(method: method, target: target, headers: headers, routes: routes)
    }

    @Test func pathPatterns() {
        #expect(MockServer.pathPattern(from: "{{baseUrl}}/pets/:id?x=1") == "/pets/:id")
        #expect(MockServer.pathPattern(from: "https://api.example.com:8443/v1/pets#top") == "/v1/pets")
        #expect(MockServer.pathPattern(from: "https://api.example.com") == "/")
        #expect(MockServer.pathPattern(from: "{{baseUrl}}") == "/")
        #expect(MockServer.pathPattern(from: "api.example.com/pets") == "/pets")
        #expect(MockServer.pathPattern(from: "/pets/{{petId}}") == "/pets/{{petId}}")
    }

    @Test func servesTheFirstExampleAndDropsTransferHeaders() {
        let list = reply("GET", "/pets?limit=5")
        #expect(list.status == 200)
        #expect(String(decoding: list.body, as: UTF8.self) == "[{\"id\": 1}]")
        #expect(list.routeName == "List")
        #expect(list.headers.contains(HTTPHeader(name: "Content-Type", value: "application/json")))
        #expect(!list.headers.contains { $0.name == "Content-Length" })
        #expect(list.headers.contains(HTTPHeader(name: "Access-Control-Allow-Origin", value: "*")))
    }

    @Test func examplesCanBeChosenByNameOrCode() {
        #expect(String(decoding: reply("GET", "/pets", headers: ["x-mock-response-name": "Empty"]).body, as: UTF8.self) == "[]")
        #expect(reply("GET", "/pets", headers: ["x-mock-response-code": "503"]).status == 503)
        #expect(reply("GET", "/pets", headers: ["x-mock-response-name": "Nope"]).status == 200)
    }

    @Test func wildcardsFillTheBodyAndSpecificRoutesWin() throws {
        let get = reply("GET", "/pets/42?view=full")
        let object = try #require(try JSONSerialization.jsonObject(with: get.body) as? [String: String])
        #expect(object["id"] == "42")
        #expect(object["view"] == "full")
        #expect(UUID(uuidString: object["ref"] ?? "") != nil)

        #expect(reply("GET", "/pets/latest").routeName == "Latest")
        #expect(reply("HEAD", "/pets/latest").routeName == "Latest")
        let tenant = reply("GET", "/acme/info")
        #expect(String(decoding: tenant.body, as: UTF8.self) == "acme")
        #expect(tenant.status == 200)
    }

    @Test func unmatchedAndUnpinnedAreExplained() {
        let missing = reply("DELETE", "/pets/1")
        #expect(missing.status == 404)
        #expect(String(decoding: missing.body, as: UTF8.self).contains("No mock route matches DELETE /pets/1"))
        #expect(missing.routeName == nil)

        let unpinned = reply("POST", "/pets")
        #expect(unpinned.status == 501)
        #expect(String(decoding: unpinned.body, as: UTF8.self).contains("no pinned response"))

        #expect(reply("OPTIONS", "/anything").status == 204)
    }

    @Test func baseVariableIsTheMostCommonPrefix() {
        let collection = APICollection(items: [
            .request(RequestItem(url: "{{baseUrl}}/a")), .request(RequestItem(url: "{{ baseUrl }}/b")),
            .request(RequestItem(url: "{{auth}}/login")), .request(RequestItem(url: "https://example.com/c")),
        ])
        #expect(MockServer.baseVariable(of: collection) == "baseUrl")
        #expect(MockServer.baseVariable(of: APICollection(items: [.request(RequestItem(url: "https://example.com"))])) == nil)
    }

    /// The phase 3 goal: a collection run against its own mock, with no network beyond localhost.
    @Test func aCollectionRunsAgainstItsOwnMock() async throws {
        let list = RequestItem(name: "List", url: "{{baseUrl}}/pets", examples: [
            SavedResponse(name: "OK", status: 200, headers: [KeyValue(key: "Content-Type", value: "application/json"), KeyValue(key: "X-Demo", value: "yes")], body: "{\"pets\": [{\"id\": 7}]}", statusText: "OK"),
        ], assertions: [Assertion(source: ValueSource(kind: .header, path: "X-Demo"), op: .equals, expected: "yes")],
           extractions: [Extraction(variable: "petId", source: ValueSource(kind: .json, path: "$.pets[0].id"))])
        let get = RequestItem(name: "Get", url: "{{baseUrl}}/pets/{{petId}}", examples: [
            SavedResponse(name: "Created", status: 201, body: "{\"id\": \"{{petId}}\"}"),
        ], assertions: [
            Assertion(source: ValueSource(kind: .status), op: .equals, expected: "201"),
            Assertion(source: ValueSource(kind: .json, path: "$.id"), op: .equals, expected: "7"),
        ])
        let collection = APICollection(name: "Demo", items: [.request(list), .request(get)])

        let server = MockServer(routes: MockServer.routes(for: collection))
        let hits = HitLog()
        server.onHit { hits.add($0) }
        let port = try await server.start()
        defer { server.stop() }
        #expect(port != 0)

        var state = RunState(environment: [Variable(key: MockServer.baseVariable(of: collection) ?? "", value: "http://127.0.0.1:\(port)")])
        let executor = RequestExecutor()
        let first = await executor.run(list, in: collection, state: &state)
        #expect(first.passed, "\(first.error ?? "") \(first.tests)")
        #expect(first.response?.statusText == "OK")
        let second = await executor.run(get, in: collection, state: &state)
        #expect(second.passed, "\(second.error ?? "") \(second.tests)")
        #expect(second.response?.statusText == "Created")

        #expect(hits.all.map(\.path) == ["/pets", "/pets/7"])
        #expect(hits.all.map(\.routeName) == ["List", "Get"])
    }

    final class HitLog: @unchecked Sendable {
        private var hits: [MockHit] = []
        private let lock = NSLock()
        func add(_ hit: MockHit) { lock.lock(); hits.append(hit); lock.unlock() }
        var all: [MockHit] { lock.lock(); defer { lock.unlock() }; return hits }
    }
}

@Suite struct PinningAndSequences {
    @Test func pinningALiveResponse() {
        let live = makeResponse(status: 201, statusText: "Created", headers: [HTTPHeader(name: "X-A", value: "1")], body: "{\"ok\": true}")
        let pinned = SavedResponse(name: "Created", pinning: live)
        #expect(pinned == SavedResponse(name: "Created", status: 201, headers: [KeyValue(key: "X-A", value: "1")], body: "{\"ok\": true}", statusText: "Created"))
        let shown = pinned.asResponse
        #expect(shown.status == 201)
        #expect(shown.statusText == "Created")
        #expect(shown.header("x-a") == "1")
        #expect(shown.text == "{\"ok\": true}")
    }

    @Test func sequencesAreSavedAndSurviveReimport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apiplayground-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root, secrets: InMemorySecretStore())

        var (collection, _) = try importSampleCollection()
        let list = try #require(collection.allRequests.first { $0.name == "List pets" })
        let login = try #require(collection.allRequests.first { $0.name == "Login" })
        collection.sequences = [DemoSequence(name: "Tour", steps: [
            DemoStep(requestID: list.id, note: "Start by listing pets."), DemoStep(requestID: login.id, note: "Then log in."),
        ])]
        try store.save(collection)
        #expect(try store.loadCollections() == [collection])

        // A newer export without the Login request: the sequence stays, minus that step.
        var (newer, _) = try importSampleCollection()
        newer.removeNode(id: try #require(newer.allRequests.first { $0.name == "Login" }).id)
        let merged = newer.adoptingIdentities(from: collection)
        #expect(merged.sequences.count == 1)
        #expect(merged.sequences[0].steps == [DemoStep(requestID: list.id, note: "Start by listing pets.")])
    }
}
