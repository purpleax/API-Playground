import Foundation
import Testing
@testable import APIEngine

@Suite struct VariableResolution {
    @Test func narrowerScopeWins() {
        let resolver = VariableResolver(
            globals: [Variable(key: "host", value: "global"), Variable(key: "onlyGlobal", value: "g")],
            collection: [Variable(key: "host", value: "collection")],
            environment: [Variable(key: "host", value: "environment")]
        )
        #expect(resolver.resolve("{{host}}/{{onlyGlobal}}").string == "environment/g")
    }

    @Test func disabledVariablesAreIgnored() {
        let resolver = VariableResolver(
            collection: [Variable(key: "host", value: "collection")],
            environment: [Variable(key: "host", value: "environment", enabled: false)]
        )
        #expect(resolver.resolve("{{host}}").string == "collection")
    }

    @Test func nestedValuesAndWhitespace() {
        let resolver = VariableResolver(scopes: [["base": "https://{{host}}", "host": "example.com"]])
        #expect(resolver.resolve("{{ base }}/v1").string == "https://example.com/v1")
    }

    @Test func unresolvedNamesAreReportedAndLeftInPlace() {
        let result = VariableResolver(scopes: [[:]]).resolve("{{a}}/{{b}}/{{a}}")
        #expect(result.string == "{{a}}/{{b}}/{{a}}")
        #expect(result.unresolved == ["a", "b"])
    }

    @Test func cyclesStop() {
        let resolver = VariableResolver(scopes: [["a": "{{b}}", "b": "{{a}}"]])
        _ = resolver.resolve("{{a}}")  // Must return rather than recurse forever.
    }

    @Test func dynamicVariables() {
        let resolver = VariableResolver(scopes: [[:]])
        #expect(UUID(uuidString: resolver.resolve("{{$guid}}").string) != nil)
        #expect(Int(resolver.resolve("{{$timestamp}}").string) != nil)
        #expect(resolver.resolve("{{$guid}}").string != resolver.resolve("{{$guid}}").string)
    }

    @Test func unclosedBracesAreLeftAlone() {
        #expect(VariableResolver(scopes: [["a": "1"]]).resolve("{{a}} {{a").string == "1 {{a")
    }
}

@Suite struct RequestBuilding {
    let resolver = VariableResolver(scopes: [["host": "example.com", "token": "abc"]])

    @Test func queryIsEncodedAndSchemeAdded() throws {
        let request = RequestItem(url: "{{host}}/search", params: [
            KeyValue(key: "q", value: "a b&c"), KeyValue(key: "", value: "ignored"),
        ])
        let prepared = try RequestBuilder.prepare(request, auth: .none, resolver: resolver)
        #expect(prepared.url == "http://example.com/search?q=a%20b%26c")
        #expect(prepared.header("User-Agent") == RequestBuilder.userAgent)
        #expect(prepared.body == nil)
    }

    @Test func bearerAuthAndExplicitHeaderPrecedence() throws {
        let plain = RequestItem(url: "https://example.com")
        let withAuth = try RequestBuilder.prepare(plain, auth: .bearer(token: "{{token}}"), resolver: resolver)
        #expect(withAuth.header("Authorization") == "Bearer abc")

        let explicit = RequestItem(url: "https://example.com", headers: [KeyValue(key: "authorization", value: "mine")])
        let kept = try RequestBuilder.prepare(explicit, auth: .bearer(token: "{{token}}"), resolver: resolver)
        #expect(kept.headers.filter { $0.name.lowercased() == "authorization" }.map(\.value) == ["mine"])
    }

    @Test func apiKeyInHeader() throws {
        let prepared = try RequestBuilder.prepare(
            RequestItem(url: "https://example.com"),
            auth: .apiKey(key: "X-API-Key", value: "{{token}}", placement: .header),
            resolver: resolver
        )
        #expect(prepared.header("X-API-Key") == "abc")
    }

    @Test func rawBodyGetsDefaultContentType() throws {
        let request = RequestItem(method: "post", url: "https://example.com",
                                  body: .raw(text: "{\"t\": \"{{token}}\"}", contentType: "application/json"))
        let prepared = try RequestBuilder.prepare(request, auth: .none, resolver: resolver)
        #expect(prepared.method == "POST")
        #expect(prepared.body == Data("{\"t\": \"abc\"}".utf8))
        #expect(prepared.header("Content-Type") == "application/json")
    }

    @Test func urlEncodedBody() throws {
        let request = RequestItem(method: "POST", url: "https://example.com", body: .urlEncoded(fields: [
            KeyValue(key: "name", value: "a b"), KeyValue(key: "off", value: "1", enabled: false),
        ]))
        let prepared = try RequestBuilder.prepare(request, auth: .none, resolver: resolver)
        #expect(prepared.body == Data("name=a+b".utf8))
        #expect(prepared.header("Content-Type") == "application/x-www-form-urlencoded")
    }

    @Test func multipartBody() throws {
        let request = RequestItem(method: "POST", url: "https://example.com",
                                  body: .formData(fields: [FormField(key: "field", value: "{{token}}")]))
        let prepared = try RequestBuilder.prepare(request, auth: .none, resolver: resolver)
        let contentType = try #require(prepared.header("Content-Type"))
        let boundary = try #require(contentType.components(separatedBy: "boundary=").last)
        let text = String(decoding: try #require(prepared.body), as: UTF8.self)
        #expect(text == "--\(boundary)\r\nContent-Disposition: form-data; name=\"field\"\r\n\r\nabc\r\n--\(boundary)--\r\n")
    }

    @Test func graphQLBody() throws {
        let request = RequestItem(method: "POST", url: "https://example.com",
                                  body: .graphQL(query: "{ me }", variables: "{\"id\": 1}"))
        let prepared = try RequestBuilder.prepare(request, auth: .none, resolver: resolver)
        #expect(String(decoding: try #require(prepared.body), as: UTF8.self) == "{\"query\":\"{ me }\",\"variables\":{\"id\":1}}")
    }

    @Test func emptyURLIsAnError() {
        #expect(throws: RequestBuildError.emptyURL) {
            try RequestBuilder.prepare(RequestItem(url: "  "), auth: .none, resolver: resolver)
        }
    }
}

@Suite struct Storage {
    func makeStore() throws -> (WorkspaceStore, InMemorySecretStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apiplayground-tests-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        return (WorkspaceStore(root: root, secrets: secrets), secrets, root)
    }

    @Test func collectionRoundTrips() throws {
        let (store, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (collection, _) = try importSampleCollection()

        try store.save(collection)
        let loaded = try store.loadCollections()
        #expect(loaded == [collection])

        // One file per request, in folders that mirror the tree.
        let dir = root.appendingPathComponent("collections/pet-store")
        for path in ["collection.json", "pets/folder.json", "pets/list-pets.request.json", "pets/create-pet.request.json", "login.request.json"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path), "missing \(path)")
        }
    }

    @Test func savingAgainReplacesRatherThanDuplicates() throws {
        let (store, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var (collection, _) = try importSampleCollection()

        try store.save(collection)
        collection.name = "Renamed"
        collection.removeNode(id: collection.items[1].id)
        try store.save(collection)

        let loaded = try store.loadCollections()
        #expect(loaded == [collection])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("collections/pet-store").path))
    }

    @Test func duplicateNamesGetDistinctFiles() throws {
        let (store, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = APICollection(name: "Dupes", items: [
            .request(RequestItem(name: "Same", url: "https://one.example")),
            .request(RequestItem(name: "Same", url: "https://two.example")),
        ])
        try store.save(collection)
        #expect(try store.loadCollections() == [collection])
    }

    @Test func filesAddedByHandAreLoaded() throws {
        let (store, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(APICollection(name: "Manual", items: [.request(RequestItem(name: "First"))]))

        let extra = root.appendingPathComponent("collections/manual/added.request.json")
        try Data("{\"name\": \"Added\", \"url\": \"https://example.com\"}".utf8).write(to: extra)

        let loaded = try #require(try store.loadCollections().first)
        #expect(loaded.items.map(\.name) == ["First", "Added"])
    }

    @Test func secretsStayOutOfFiles() throws {
        let (store, secrets, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try importSampleEnvironment()

        try store.save(environment)
        let file = root.appendingPathComponent("environments/staging.env.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("tok_123"))
        #expect(text.contains("https://staging.example.com"))
        #expect(secrets.get("\(environment.id.uuidString)/token") == "tok_123")

        // Loading puts the secret value back.
        #expect(try store.loadEnvironments() == [environment])
    }

    @Test func environmentRenameAndDelete() throws {
        let (store, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = APIEnvironment(name: "Dev", variables: [Variable(key: "a", value: "1")])
        try store.save(environment)
        environment.name = "Development"
        try store.save(environment)
        #expect(try store.loadEnvironments() == [environment])

        try store.deleteEnvironment(id: environment.id)
        #expect(try store.loadEnvironments().isEmpty)
    }

    @Test func globalsRoundTrip() throws {
        let (store, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try store.loadGlobals().isEmpty)
        let globals = [Variable(key: "g", value: "1"), Variable(key: "s", value: "hidden", secret: true)]
        try store.saveGlobals(globals)
        #expect(try store.loadGlobals() == globals)
    }
}

@Suite struct CurlImport {
    @Test func tokenizer() {
        #expect(CurlImporter.tokenize("curl 'a b' \"c \\\"d\\\"\" e\\ f \\\n  g $'h\\ni'") == ["curl", "a b", "c \"d\"", "e f", "g", "h\ni"])
    }

    @Test func postWithHeadersAndData() throws {
        let request = try CurlImporter.importCommand("""
        curl -X POST 'https://api.example.com/v1/chat?stream=true' \\
          -H 'Content-Type: application/json' \\
          -H 'X-AI-Provider: azure' \\
          --data-raw '{"messages": []}' --compressed
        """)
        #expect(request.method == "POST")
        #expect(request.url == "https://api.example.com/v1/chat")
        #expect(request.params == [KeyValue(key: "stream", value: "true")])
        #expect(request.headers == [
            KeyValue(key: "Content-Type", value: "application/json"), KeyValue(key: "X-AI-Provider", value: "azure"),
        ])
        #expect(request.body == .raw(text: "{\"messages\": []}", contentType: nil))
        #expect(request.name == "chat")
    }

    @Test func impliedPostBasicAuthAndAttachedValues() throws {
        let request = try CurlImporter.importCommand("curl -u user:pass -d a=1 -d b=2 -o out.txt https://example.com/form")
        #expect(request.method == "POST")
        #expect(request.auth == .basic(username: "user", password: "pass"))
        #expect(request.body == .raw(text: "a=1&b=2", contentType: "application/x-www-form-urlencoded"))

        let attached = try CurlImporter.importCommand("curl -XDELETE -H'Accept: */*' https://example.com/items/1")
        #expect(attached.method == "DELETE")
        #expect(attached.headers == [KeyValue(key: "Accept", value: "*/*")])
    }

    @Test func rejectsOtherText() {
        #expect(throws: CurlImportError.notCurl) { try CurlImporter.importCommand("wget https://example.com") }
        #expect(throws: CurlImportError.noURL) { try CurlImporter.importCommand("curl -X POST") }
    }
}

@Suite struct Diffing {
    @Test func marksAddedAndRemovedLines() {
        let diff = LineDiff.diff(old: "a\nb\nc", new: "a\nx\nc\nd")
        #expect(diff == [
            DiffLine(kind: .same, text: "a"),
            DiffLine(kind: .removed, text: "b"),
            DiffLine(kind: .added, text: "x"),
            DiffLine(kind: .same, text: "c"),
            DiffLine(kind: .added, text: "d"),
        ])
    }

    @Test func identicalTextsHaveNoChanges() {
        #expect(LineDiff.diff(old: "a\nb", new: "a\nb").allSatisfy { $0.kind == .same })
    }

    @Test func prettyJSONNormalisesLayout() {
        #expect(LineDiff.prettyJSON(Data("{\"b\":1,\"a\":[1,2]}".utf8)) == LineDiff.prettyJSON(Data("{ \"a\": [1, 2], \"b\": 1 }".utf8)))
        #expect(LineDiff.prettyJSON(Data("<html>".utf8)) == nil)
        // No space before the colon, and a " : " inside a key or value is left alone.
        #expect(LineDiff.prettyJSON(Data("{\"a \\\" : b\":\"x : y\"}".utf8)) == "{\n  \"a \\\" : b\": \"x : y\"\n}")
    }
}
