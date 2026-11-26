import Foundation
import Testing
@testable import APIEngine

let sampleCollectionV21 = """
{
  "info": {
    "_postman_id": "abc-123",
    "name": "Pet Store",
    "description": "Sample API",
    "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
  },
  "auth": { "type": "bearer", "bearer": [ { "key": "token", "value": "{{token}}", "type": "string" } ] },
  "variable": [
    { "key": "baseUrl", "value": "https://api.example.com" },
    { "key": "unused", "value": "x", "disabled": true }
  ],
  "event": [ { "listen": "prerequest", "script": { "exec": ["console.log('collection')"] } } ],
  "item": [
    {
      "name": "Pets",
      "auth": { "type": "basic", "basic": [
        { "key": "username", "value": "admin" }, { "key": "password", "value": "{{password}}" } ] },
      "item": [
        {
          "name": "List pets",
          "request": {
            "method": "GET",
            "header": [
              { "key": "Accept", "value": "application/json" },
              { "key": "X-Debug", "value": "1", "disabled": true }
            ],
            "url": {
              "raw": "{{baseUrl}}/pets/:petId?limit=10&offset=0",
              "host": ["{{baseUrl}}"],
              "path": ["pets", ":petId"],
              "query": [
                { "key": "limit", "value": "10" },
                { "key": "offset", "value": "0", "disabled": true }
              ],
              "variable": [ { "key": "petId", "value": "42" } ]
            }
          },
          "event": [ { "listen": "test", "script": { "exec": ["pm.test('ok', function () {});", "// done"] } } ],
          "response": [
            { "name": "OK", "code": 200, "status": "OK",
              "header": [ { "key": "Content-Type", "value": "application/json" } ], "body": "[]" }
          ]
        },
        {
          "name": "Create pet",
          "request": {
            "method": "POST",
            "auth": { "type": "noauth" },
            "header": [],
            "body": { "mode": "raw", "raw": "{\\"name\\": \\"{{petName}}\\"}", "options": { "raw": { "language": "json" } } },
            "url": { "raw": "{{baseUrl}}/pets", "host": ["{{baseUrl}}"], "path": ["pets"] }
          }
        }
      ]
    },
    {
      "name": "Login",
      "request": {
        "method": "POST",
        "auth": { "type": "digest", "digest": [] },
        "header": [],
        "body": { "mode": "urlencoded", "urlencoded": [
          { "key": "user", "value": "guy" }, { "key": "skip", "value": "1", "disabled": true } ] },
        "url": "https://auth.example.com/login?next=home"
      }
    },
    {
      "name": "Key in query",
      "request": {
        "method": "GET",
        "auth": { "type": "apikey", "apikey": [
          { "key": "key", "value": "api_key" }, { "key": "value", "value": "s3cret" }, { "key": "in", "value": "query" } ] },
        "header": [],
        "url": { "raw": "https://api.example.com/status" }
      }
    }
  ]
}
"""

let sampleEnvironment = """
{
  "id": "env-1",
  "name": "Staging",
  "values": [
    { "key": "baseUrl", "value": "https://staging.example.com", "enabled": true },
    { "key": "token", "value": "tok_123", "type": "secret", "enabled": true },
    { "key": "retries", "value": 3, "enabled": true },
    { "key": "old", "value": "x", "enabled": false }
  ],
  "_postman_variable_scope": "environment"
}
"""

func importSampleCollection() throws -> (APICollection, ImportReport) {
    guard case .collection(let collection, let report) = try PostmanImporter.importDocument(data: Data(sampleCollectionV21.utf8)) else {
        throw PostmanImportError.notPostman
    }
    return (collection, report)
}

func importSampleEnvironment() throws -> APIEnvironment {
    guard case .environment(let environment, _, _) = try PostmanImporter.importDocument(data: Data(sampleEnvironment.utf8)) else {
        throw PostmanImportError.notPostman
    }
    return environment
}

@Suite struct PostmanCollectionImport {
    @Test func readsStructureAndReport() throws {
        let (collection, report) = try importSampleCollection()

        #expect(collection.name == "Pet Store")
        #expect(collection.description == "Sample API")
        #expect(collection.postmanID == "abc-123")
        #expect(collection.auth == .bearer(token: "{{token}}"))
        #expect(collection.preRequestScript == "console.log('collection')")
        #expect(collection.variables == [
            Variable(key: "baseUrl", value: "https://api.example.com"),
            Variable(key: "unused", value: "x", enabled: false),
        ])
        #expect(collection.items.map(\.name) == ["Pets", "Login", "Key in query"])

        #expect(report.requests == 4)
        #expect(report.folders == 1)
        #expect(report.examples == 1)
        #expect(report.scriptsPreserved == 2)
        #expect(report.warnings.count == 1)
        #expect(report.warnings.first?.contains("digest") == true)
    }

    @Test func readsRequestDetails() throws {
        let (collection, _) = try importSampleCollection()
        let list = try #require(collection.allRequests.first { $0.name == "List pets" })

        #expect(list.method == "GET")
        #expect(list.url == "{{baseUrl}}/pets/:petId")
        #expect(list.params == [KeyValue(key: "limit", value: "10"), KeyValue(key: "offset", value: "0", enabled: false)])
        #expect(list.pathVariables == [KeyValue(key: "petId", value: "42")])
        #expect(list.headers == [
            KeyValue(key: "Accept", value: "application/json"),
            KeyValue(key: "X-Debug", value: "1", enabled: false),
        ])
        #expect(list.auth == .inherit)
        #expect(list.testScript == "pm.test('ok', function () {});\n// done")
        #expect(list.examples == [SavedResponse(
            name: "OK", status: 200, headers: [KeyValue(key: "Content-Type", value: "application/json")], body: "[]"
        )])

        let create = try #require(collection.allRequests.first { $0.name == "Create pet" })
        #expect(create.body == .raw(text: "{\"name\": \"{{petName}}\"}", contentType: "application/json"))
        #expect(create.auth == Auth.none)

        let login = try #require(collection.allRequests.first { $0.name == "Login" })
        #expect(login.url == "https://auth.example.com/login")
        #expect(login.params == [KeyValue(key: "next", value: "home")])
        #expect(login.body == .urlEncoded(fields: [
            KeyValue(key: "user", value: "guy"), KeyValue(key: "skip", value: "1", enabled: false),
        ]))
    }

    @Test func authIsInheritedFromFolderAndCollection() throws {
        let (collection, _) = try importSampleCollection()
        func auth(_ name: String) throws -> Auth {
            let request = try #require(collection.allRequests.first { $0.name == name })
            return collection.effectiveAuth(forRequest: request.id)
        }
        // From the folder.
        #expect(try auth("List pets") == .basic(username: "admin", password: "{{password}}"))
        // Its own "no auth" wins over the folder.
        #expect(try auth("Create pet") == Auth.none)
        // Its own.
        #expect(try auth("Key in query") == .apiKey(key: "api_key", value: "s3cret", placement: .query))
    }

    @Test func readsV20AuthAndStringHeaders() throws {
        let v20 = """
        { "info": { "name": "Old", "schema": "https://schema.getpostman.com/json/collection/v2.0.0/collection.json" },
          "item": [ { "name": "Ping", "request": {
              "method": "get",
              "auth": { "type": "basic", "basic": { "username": "u", "password": "p" } },
              "header": "Accept: text/plain\\nX-One: 1",
              "url": "https://example.com/ping?a=1" } },
            { "name": "Bare", "request": "https://example.com/bare" } ] }
        """
        guard case .collection(let collection, _) = try PostmanImporter.importDocument(data: Data(v20.utf8)) else {
            Issue.record("not a collection")
            return
        }
        let ping = collection.allRequests[0]
        #expect(ping.method == "GET")
        #expect(ping.auth == .basic(username: "u", password: "p"))
        #expect(ping.headers == [KeyValue(key: "Accept", value: "text/plain"), KeyValue(key: "X-One", value: "1")])
        #expect(ping.url == "https://example.com/ping")
        #expect(ping.params == [KeyValue(key: "a", value: "1")])
        #expect(collection.allRequests[1].url == "https://example.com/bare")
        // A collection with no auth of its own means "no auth", not "inherit".
        #expect(collection.auth == Auth.none)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: PostmanImportError.notJSON) {
            try PostmanImporter.importDocument(data: Data("not json".utf8))
        }
        #expect(throws: PostmanImportError.notPostman) {
            try PostmanImporter.importDocument(data: Data("{\"hello\": 1}".utf8))
        }
    }
}

@Suite struct PostmanEnvironmentImport {
    @Test func readsVariables() throws {
        guard case .environment(let environment, let isGlobals, let report) =
            try PostmanImporter.importDocument(data: Data(sampleEnvironment.utf8)) else {
            Issue.record("not an environment")
            return
        }
        #expect(environment.name == "Staging")
        #expect(environment.postmanID == "env-1")
        #expect(!isGlobals)
        #expect(report.variables == 4)
        #expect(environment.variables == [
            Variable(key: "baseUrl", value: "https://staging.example.com"),
            Variable(key: "token", value: "tok_123", secret: true),
            Variable(key: "retries", value: "3"),
            Variable(key: "old", value: "x", enabled: false),
        ])
    }

    @Test func recognisesGlobals() throws {
        let globals = """
        { "name": "Globals", "values": [ { "key": "g", "value": "1" } ], "_postman_variable_scope": "globals" }
        """
        guard case .environment(_, let isGlobals, _) = try PostmanImporter.importDocument(data: Data(globals.utf8)) else {
            Issue.record("not an environment")
            return
        }
        #expect(isGlobals)
    }
}

/// The phase 1 acceptance test, without the network: an imported collection plus an
/// imported environment produce the right request with no editing.
@Suite struct ImportedRequestsResolve {
    @Test func collectionAndEnvironmentProduceTheRightRequest() throws {
        let (collection, _) = try importSampleCollection()
        let environment = try importSampleEnvironment()
        let resolver = VariableResolver(collection: collection.variables, environment: environment.variables)

        let list = try #require(collection.allRequests.first { $0.name == "List pets" })
        let prepared = try RequestBuilder.prepare(
            list, auth: collection.effectiveAuth(forRequest: list.id), resolver: resolver
        )
        // The environment's baseUrl overrides the collection's; the disabled param and header are left out.
        #expect(prepared.method == "GET")
        #expect(prepared.url == "https://staging.example.com/pets/42?limit=10")
        #expect(prepared.header("Accept") == "application/json")
        #expect(prepared.header("X-Debug") == nil)
        // Folder auth, with {{password}} missing from both scopes.
        #expect(prepared.header("Authorization") == "Basic " + Data("admin:{{password}}".utf8).base64EncodedString())
        #expect(prepared.unresolved == ["password"])

        let key = try #require(collection.allRequests.first { $0.name == "Key in query" })
        let preparedKey = try RequestBuilder.prepare(
            key, auth: collection.effectiveAuth(forRequest: key.id), resolver: resolver
        )
        #expect(preparedKey.url == "https://api.example.com/status?api_key=s3cret")
    }
}

@Suite struct ReimportAndArchives {
    @Test func reimportKeepsIdentities() throws {
        let (first, _) = try importSampleCollection()
        var (second, _) = try importSampleCollection()
        // The newer export renames nothing, drops one request and adds another.
        second.removeNode(id: try #require(second.allRequests.first { $0.name == "Login" }).id)
        second.append(.request(RequestItem(name: "Brand new")))

        let merged = second.adoptingIdentities(from: first)
        #expect(merged.id == first.id)
        for name in ["List pets", "Create pet", "Key in query"] {
            let old = try #require(first.allRequests.first { $0.name == name })
            let new = try #require(merged.allRequests.first { $0.name == name })
            #expect(old.id == new.id, "\(name) should keep its id")
        }
        #expect(merged.items.first?.id == first.items.first?.id)
        let added = try #require(merged.allRequests.first { $0.name == "Brand new" })
        #expect(!first.allRequests.contains { $0.id == added.id })
    }

    @Test func duplicateNamesKeepTheirOrder() {
        let old = APICollection(name: "C", items: [.request(RequestItem(name: "Same")), .request(RequestItem(name: "Same"))])
        let new = APICollection(name: "C", items: [.request(RequestItem(name: "Same")), .request(RequestItem(name: "Same"))])
        #expect(new.adoptingIdentities(from: old).items.map(\.id) == old.items.map(\.id))
    }

    func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apiplayground-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func importsEveryPostmanFileInAZip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = dir.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: content.appendingPathComponent("collection"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: content.appendingPathComponent("environment"), withIntermediateDirectories: true)
        try Data(sampleCollectionV21.utf8).write(to: content.appendingPathComponent("collection/pets.json"))
        try Data(sampleEnvironment.utf8).write(to: content.appendingPathComponent("environment/staging.json"))
        try Data("{\"version\": 1}".utf8).write(to: content.appendingPathComponent("archive.json"))

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = content
        zip.arguments = ["-qr", dir.appendingPathComponent("export.zip").path, "."]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)

        let batch = try PostmanImporter.importFile(at: dir.appendingPathComponent("export.zip"))
        var collections = 0
        var environments = 0
        for document in batch.documents {
            switch document {
            case .collection: collections += 1
            case .environment: environments += 1
            case .spec: break
            }
        }
        #expect(collections == 1)
        #expect(environments == 1)
        #expect(batch.skipped.count == 1)
        #expect(batch.skipped.first?.hasPrefix("archive.json") == true)
    }

    @Test func importsABackupFileAndReportsOldFormats() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = """
        { "version": 1,
          "collections": [ \(sampleCollectionV21), { "name": "Legacy", "requests": [] } ],
          "environments": [ \(sampleEnvironment) ] }
        """
        let file = dir.appendingPathComponent("Backup.postman_dump.json")
        try Data(backup.utf8).write(to: file)

        let batch = try PostmanImporter.importFile(at: file)
        #expect(batch.documents.count == 2)
        #expect(batch.skipped.count == 1)
        #expect(batch.skipped.first?.contains("Legacy") == true)
    }

    @Test func aLoneNonPostmanFileIsAnError() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("other.json")
        try Data("{\"hello\": 1}".utf8).write(to: file)
        #expect(throws: PostmanImportError.notPostman) { try PostmanImporter.importFile(at: file) }
        #expect(throws: PostmanImportError.unreadableArchive) {
            try PostmanImporter.importFile(at: dir.appendingPathComponent("missing.zip"))
        }
    }
}

@Suite struct CurrentValues {
    @Test func currentValueOverridesButSecretsIgnoreIt() {
        #expect(Variable(key: "a", value: "shared", currentValue: "mine").effectiveValue == "mine")
        // An empty current value is still an override: a script may clear a token on purpose.
        #expect(Variable(key: "a", value: "shared", currentValue: "").effectiveValue == "")
        #expect(Variable(key: "a", value: "shared").effectiveValue == "shared")
        #expect(Variable(key: "a", value: "s", secret: true, currentValue: "mine").effectiveValue == "s")
        let resolver = VariableResolver(environment: [Variable(key: "host", value: "shared", currentValue: "mine")])
        #expect(resolver.resolve("{{host}}").string == "mine")
    }

    @Test func currentValuesStayOutOfTheWorkspace() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("apiplayground-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let local = LocalValueStore(file: base.appendingPathComponent("local/values.json"))
        let store = WorkspaceStore(root: base.appendingPathComponent("workspace"), secrets: InMemorySecretStore(), localValues: local)

        let environment = APIEnvironment(name: "Dev", variables: [
            Variable(key: "host", value: "shared.example.com", currentValue: "localhost:9999"),
            Variable(key: "plain", value: "x"),
        ])
        try store.save(environment)

        let file = base.appendingPathComponent("workspace/environments/dev.env.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("shared.example.com"))
        #expect(!text.contains("localhost:9999"))
        #expect(!text.contains("currentValue"))

        #expect(try store.loadEnvironments() == [environment])
        #expect(local.values(owner: environment.id.uuidString) == ["host": "localhost:9999"])

        // Clearing the current value removes it from the local file too.
        var cleared = environment
        cleared.variables[0].currentValue = nil
        try store.save(cleared)
        #expect(local.values(owner: environment.id.uuidString).isEmpty)
        #expect(try store.loadEnvironments() == [cleared])
    }
}
