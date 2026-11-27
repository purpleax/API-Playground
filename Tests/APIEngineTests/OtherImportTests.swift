import Foundation
import Testing
@testable import APIEngine

private func collections(_ documents: [ImportedDocument]) -> [(APICollection, ImportReport)] {
    documents.compactMap { if case .collection(let collection, let report) = $0 { return (collection, report) } else { return nil } }
}

private func environments(_ documents: [ImportedDocument]) -> [APIEnvironment] {
    documents.compactMap { if case .environment(let environment, _, _) = $0 { return environment } else { return nil } }
}

private func specs(_ documents: [ImportedDocument]) -> [(name: String, text: String)] {
    documents.compactMap { if case .spec(let name, let text) = $0 { return (name, text) } else { return nil } }
}

private func folder(_ node: Node?) -> Folder? {
    if case .folder(let folder)? = node { return folder }
    return nil
}

private func request(_ node: Node?) -> RequestItem? {
    if case .request(let request)? = node { return request }
    return nil
}

private let tokenFilter = "b64::" + Data("%24.token".utf8).base64EncodedString() + "::46b"

private let insomniaV4 = """
{
  "_type": "export",
  "__export_format": 4,
  "__export_source": "insomnia.desktop.app:v2023.5.8",
  "resources": [
    { "_id": "req_list", "parentId": "fld_pets", "_type": "request", "name": "List pets", "metaSortKey": -100,
      "url": "{{ _.base_url }}/pets?limit=10", "method": "GET",
      "headers": [ { "name": "Accept", "value": "application/json" }, { "name": "X-Off", "value": "1", "disabled": true } ],
      "parameters": [ { "name": "tag", "value": "{{ _.user.tag }}" }, { "name": "skip", "value": "0", "disabled": true } ],
      "authentication": { "type": "bearer", "token": "{% response 'body', 'req_login', '\(tokenFilter)', 'never', 60 %}" },
      "body": {} },
    { "_id": "req_create", "parentId": "fld_pets", "_type": "request", "name": "Create pet", "metaSortKey": -50,
      "url": "{{ _.base_url }}/pets/:id", "method": "post",
      "pathParameters": [ { "name": "id", "value": "7" } ],
      "headers": [ { "name": "Content-Type", "value": "application/json" } ],
      "body": { "mimeType": "application/json", "text": "{\\"id\\": \\"{% uuid 'v4' %}\\", \\"at\\": \\"{% now 'iso-8601' %}\\", \\"who\\": \\"{% faker 'randomEmail' %}\\"}" },
      "authentication": {},
      "preRequestScript": "insomnia.environment.set('seen', 'yes');",
      "afterResponseScript": "insomnia.test('ok', () => insomnia.expect(insomnia.response.code).to.eql(200));" },
    { "_id": "fld_pets", "parentId": "wrk_1", "_type": "request_group", "name": "Pets", "metaSortKey": -200,
      "description": "Everything about pets",
      "environment": { "folder_only": "f" },
      "authentication": { "type": "basic", "username": "admin", "password": "{{ _.password }}" } },
    { "_id": "req_login", "parentId": "wrk_1", "_type": "request", "name": "Log In", "metaSortKey": -300,
      "url": "https://auth.example.com/token", "method": "POST",
      "body": { "mimeType": "application/x-www-form-urlencoded", "params": [ { "name": "user", "value": "a" }, { "name": "off", "value": "b", "disabled": true } ] },
      "authentication": { "type": "oauth2", "grantType": "authorization_code", "accessTokenUrl": "https://auth.example.com/token",
        "authorizationUrl": "https://auth.example.com/authorize", "clientId": "abc", "clientSecret": "shh", "scope": "read", "usePkce": true } },
    { "_id": "req_upload", "parentId": "wrk_1", "_type": "request", "name": "Upload", "metaSortKey": -250,
      "url": "https://api.example.com/upload", "method": "POST",
      "body": { "mimeType": "multipart/form-data", "params": [ { "name": "note", "value": "hi" }, { "name": "file", "type": "file", "fileName": "/tmp/a.png" } ] },
      "authentication": { "type": "apikey", "key": "X-Key", "value": "k", "addTo": "queryParams" } },
    { "_id": "req_gql", "parentId": "wrk_1", "_type": "request", "name": "Query", "metaSortKey": -240,
      "url": "https://api.example.com/graphql", "method": "POST",
      "body": { "mimeType": "application/graphql", "text": "{\\"query\\":\\"query { pets { id } }\\",\\"variables\\":{\\"first\\":2}}" },
      "authentication": { "type": "digest", "username": "a" } },
    { "_id": "greq_1", "parentId": "wrk_1", "_type": "grpc_request", "name": "Greet", "metaSortKey": -230,
      "url": "localhost:50051", "protoFileId": "pf_1", "protoMethodName": "/demo.Greeter/SayHello",
      "metadata": [ { "name": "x-token", "value": "t" } ], "body": { "text": "{\\"name\\": \\"Ada\\"}" } },
    { "_id": "ws_1", "parentId": "wrk_1", "_type": "websocket_request", "name": "Feed", "metaSortKey": -220,
      "url": "wss://example.com/feed", "headers": [], "parameters": [], "authentication": {} },
    { "_id": "wrk_1", "parentId": null, "_type": "workspace", "name": "Pet Store", "description": "Demo", "scope": "collection" },
    { "_id": "env_base", "parentId": "wrk_1", "_type": "environment", "name": "Base Environment",
      "data": { "base_url": "https://api.example.com", "user": { "tag": "dog", "id": 5 }, "list": [1, 2] } },
    { "_id": "env_prod", "parentId": "env_base", "_type": "environment", "name": "Production", "metaSortKey": 2,
      "data": { "base_url": "https://prod.example.com", "password": "p" } },
    { "_id": "env_dev", "parentId": "env_base", "_type": "environment", "name": "Dev", "metaSortKey": 1, "data": { "password": "d" } },
    { "_id": "jar_1", "parentId": "wrk_1", "_type": "cookie_jar", "name": "Default Jar", "cookies": [] },
    { "_id": "wrk_2", "parentId": null, "_type": "workspace", "name": "Design Doc", "scope": "design" },
    { "_id": "spc_1", "parentId": "wrk_2", "_type": "api_spec", "fileName": "Pets API", "contents": "openapi: 3.0.0\\ninfo:\\n  title: Pets\\n  version: '1'\\npaths: {}\\n" },
    { "_id": "env_base2", "parentId": "wrk_2", "_type": "environment", "name": "Base Environment", "data": {} },
    { "_id": "env_prod2", "parentId": "env_base2", "_type": "environment", "name": "Production", "data": { "x": "1" } }
  ]
}
"""

private let insomniaV5 = """
type: collection.insomnia.rest/5.0
name: Orders
meta:
  id: wrk_55
  created: 1700000000000
  modified: 1700000000001
  description: Order API
collection:
  - name: Admin
    meta:
      id: fld_1
      sortKey: -2
      description: Admin calls
    headers:
      - name: X-Team
        value: ops
    authentication:
      type: bearer
      token: "{{ _.admin_token }}"
    scripts:
      preRequest: console.log('folder');
    children:
      - url: "{{ _.host }}/orders/:id"
        name: Get order
        meta:
          id: req_1
          sortKey: -1
          description: One order
        method: GET
        pathParameters:
          - name: id
            value: "12"
        headers:
          - name: Accept
            value: application/json
        scripts:
          afterResponse: |-
            insomnia.test("ok", () => {
              insomnia.expect(insomnia.response.code).to.eql(200);
            });
        authentication:
          type: none
  - url: "{{ _.host }}/orders"
    name: Create order
    meta:
      id: req_2
      sortKey: -3
    method: POST
    body:
      mimeType: application/json
      text: |-
        {"item": "tea"}
    parameters:
      - name: dry
        value: "true"
        disabled: true
  - url: grpcs://grpc.example.com
    name: Track
    meta:
      id: greq_1
      sortKey: 5
    protoMethodName: /orders.Tracker/Watch
    body:
      text: '{"id": 1}'
    metadata:
      - name: x-key
        value: abc
  - name: Empty
    meta:
      id: fld_2
      sortKey: 9
headers:
  - name: X-All
    value: "1"
authentication:
  type: basic
  username: user
  password: pass
scripts:
  preRequest: console.log("before");
cookieJar:
  name: Default Jar
  meta:
    id: jar_1
environments:
  name: Base Environment
  meta:
    id: env_1
  data:
    host: https://orders.example.com
  subEnvironments:
    - name: Staging
      meta:
        id: env_2
      data:
        host: https://staging.example.com
        admin_token: s3
"""

@Suite struct InsomniaImport {
    @Test func readsAFormat4Export() throws {
        let documents = try InsomniaImporter.importDocuments(data: Data(insomniaV4.utf8))
        let all = collections(documents)
        #expect(all.count == 1)
        let (collection, report) = try #require(all.first)
        #expect(collection.name == "Pet Store")
        #expect(collection.description == "Demo")
        #expect(collection.postmanID == "wrk_1")
        // Lowest sort key first.
        #expect(collection.items.map(\.name) == ["Log In", "Upload", "Query", "Greet", "Feed", "Pets"])
        #expect(report.requests == 7)
        #expect(report.folders == 1)
        #expect(report.scriptsPreserved == 2)

        // The base environment becomes collection variables, with nested values flattened.
        let variables = Dictionary(uniqueKeysWithValues: collection.variables.map { ($0.key, $0.value) })
        #expect(variables["base_url"] == "https://api.example.com")
        #expect(variables["user.tag"] == "dog")
        #expect(variables["user.id"] == "5")
        #expect(variables["list"] == "[1,2]")
        #expect(variables["folder_only"] == "f")

        let pets = try #require(folder(collection.items.last))
        #expect(pets.description == "Everything about pets")
        #expect(pets.auth == .basic(username: "admin", password: "{{password}}"))
        #expect(pets.items.map(\.name) == ["List pets", "Create pet"])

        let list = try #require(request(pets.items.first))
        #expect(list.url == "{{base_url}}/pets")
        #expect(list.params == [
            KeyValue(key: "limit", value: "10"), KeyValue(key: "tag", value: "{{user.tag}}"),
            KeyValue(key: "skip", value: "0", enabled: false),
        ])
        #expect(list.headers == [KeyValue(key: "Accept", value: "application/json"), KeyValue(key: "X-Off", value: "1", enabled: false)])
        // The response tag becomes a variable, filled by a rule on the request it read from.
        #expect(list.auth == .bearer(token: "{{log_in_token}}"))
        let login = try #require(request(collection.items.first))
        #expect(login.extractions == [Extraction(variable: "log_in_token", source: ValueSource(kind: .json, path: "$.token"), scope: .collection)])
        #expect(login.body == .urlEncoded(fields: [KeyValue(key: "user", value: "a"), KeyValue(key: "off", value: "b", enabled: false)]))
        guard case .oauth2(let oauth) = login.auth else {
            Issue.record("expected OAuth 2")
            return
        }
        #expect(oauth.grant == .authorizationCode)
        #expect(oauth.usePKCE)
        #expect(oauth.tokenURL == "https://auth.example.com/token")
        #expect(oauth.clientID == "abc")

        let create = try #require(request(pets.items.last))
        #expect(create.method == "POST")
        #expect(create.auth == .inherit)
        #expect(create.pathVariables == [KeyValue(key: "id", value: "7")])
        #expect(create.body == .raw(
            text: "{\"id\": \"{{$guid}}\", \"at\": \"{{$isoTimestamp}}\", \"who\": \"{% faker 'randomEmail' %}\"}",
            contentType: "application/json"
        ))
        #expect(create.preRequestScript.contains("insomnia.environment.set"))
        #expect(create.testScript.contains("insomnia.test"))

        let upload = try #require(request(collection.items[1]))
        #expect(upload.body == .formData(fields: [FormField(key: "note", value: "hi"), FormField(key: "file", value: "/tmp/a.png", isFile: true)]))
        #expect(upload.auth == .apiKey(key: "X-Key", value: "k", placement: .query))

        let query = try #require(request(collection.items[2]))
        guard case .graphQL(let text, let graphVariables) = query.body else {
            Issue.record("expected GraphQL")
            return
        }
        #expect(text == "query { pets { id } }")
        #expect(graphVariables.contains("\"first\""))
        #expect(query.auth == Auth.none)

        let greet = try #require(request(collection.items[3]))
        #expect(greet.isGRPC)
        #expect(greet.url == "grpc://localhost:50051")
        #expect(greet.grpcMethod == "demo.Greeter/SayHello")
        #expect(greet.headers == [KeyValue(key: "x-token", value: "t")])
        #expect(greet.body == .raw(text: "{\"name\": \"Ada\"}", contentType: "application/json"))

        let feed = try #require(request(collection.items[4]))
        #expect(WebSocketClient.isWebSocketURL(feed.url))

        #expect(report.warnings.contains { $0.contains("“Log In” now saves {{log_in_token}}") })
        #expect(report.warnings.contains { $0.contains("digest") })
        #expect(report.warnings.contains { $0.contains("faker (1)") })
        #expect(report.warnings.contains { $0.contains("Folder environments (Pets)") })
        #expect(report.warnings.contains { $0.contains(".proto") })

        // Sub-environments become environments; a name used by two workspaces is told apart.
        let imported = environments(documents)
        #expect(imported.map(\.name) == ["Dev", "Pet Store – Production", "Design Doc – Production"])
        #expect(imported[1].variables.map(\.key) == ["base_url", "password"])
        #expect(imported[1].postmanID == "env_prod")

        // A design document's spec comes too.
        let found = specs(documents)
        #expect(found.count == 1)
        #expect(found.first?.name == "Pets API")
        #expect(found.first?.text.hasPrefix("openapi: 3.0.0") == true)
    }

    @Test func readsAFormat5File() throws {
        let documents = try InsomniaImporter.importDocuments(data: Data(insomniaV5.utf8))
        let (collection, report) = try #require(collections(documents).first)
        #expect(collection.name == "Orders")
        #expect(collection.description == "Order API")
        #expect(collection.postmanID == "wrk_55")
        #expect(collection.items.map(\.name) == ["Create order", "Admin", "Track", "Empty"])
        #expect(folder(collection.items[3])?.items.isEmpty == true)
        #expect(collection.auth == .basic(username: "user", password: "pass"))
        #expect(collection.preRequestScript == "console.log(\"before\");")
        #expect(collection.variables == [Variable(key: "host", value: "https://orders.example.com")])
        #expect(report.requests == 3)
        #expect(report.scriptsPreserved == 3)

        let create = try #require(request(collection.items[0]))
        #expect(create.method == "POST")
        #expect(create.url == "{{host}}/orders")
        #expect(create.params == [KeyValue(key: "dry", value: "true", enabled: false)])
        #expect(create.body == .raw(text: "{\"item\": \"tea\"}", contentType: "application/json"))

        let admin = try #require(folder(collection.items[1]))
        #expect(admin.auth == .bearer(token: "{{admin_token}}"))
        #expect(admin.description == "Admin calls")
        #expect(admin.preRequestScript == "console.log('folder');")
        let get = try #require(request(admin.items.first))
        #expect(get.url == "{{host}}/orders/:id")
        #expect(get.description == "One order")
        #expect(get.pathVariables == [KeyValue(key: "id", value: "12")])
        #expect(get.auth == Auth.none)
        // The folder's header is handed down to the request.
        #expect(get.headers == [
            KeyValue(key: "X-All", value: "1"), KeyValue(key: "X-Team", value: "ops"), KeyValue(key: "Accept", value: "application/json"),
        ])
        #expect(get.testScript.contains("insomnia.expect(insomnia.response.code).to.eql(200);"))
        #expect(report.warnings.contains { $0.contains("copied onto the requests") })

        let track = try #require(request(collection.items[2]))
        #expect(track.isGRPC)
        #expect(track.url == "grpcs://grpc.example.com")
        #expect(track.grpcMethod == "orders.Tracker/Watch")

        let staging = try #require(environments(documents).first)
        #expect(staging.name == "Staging")
        #expect(staging.postmanID == "env_2")
        #expect(staging.variables.map(\.key) == ["host", "admin_token"])
    }

    @Test func readsADesignDocumentAndEnvironmentsOnTheirOwn() throws {
        let design = """
        type: spec.insomnia.rest/5.0
        name: Pets API
        meta:
          id: wrk_9
        spec:
          contents:
            openapi: 3.0.0
            info:
              title: Pets
              version: "1"
            paths: {}
        """
        let documents = try InsomniaImporter.importDocuments(data: Data(design.utf8))
        #expect(collections(documents).isEmpty)
        let spec = try #require(specs(documents).first)
        #expect(spec.name == "Pets API")
        #expect(try OpenAPIDocument(text: spec.text).title == "Pets")

        let global = """
        type: environment.insomnia.rest/5.0
        name: Shared
        environments:
          name: Base Environment
          data:
            region: eu
          subEnvironments:
            - name: Blue
              data:
                colour: blue
        """
        let shared = environments(try InsomniaImporter.importDocuments(data: Data(global.utf8)))
        #expect(shared.map(\.name) == ["Shared", "Blue"])
        #expect(shared.first?.variables == [Variable(key: "region", value: "eu")])
    }

    @Test func refusesWhatIsNotInsomnia() {
        #expect(throws: InsomniaImportError.notInsomnia) {
            try InsomniaImporter.importDocuments(data: Data(sampleCollectionV21.utf8))
        }
        #expect(throws: InsomniaImportError.self) {
            try InsomniaImporter.importDocuments(data: Data("type: mock.insomnia.rest/5.0\nname: Mock\n".utf8))
        }
    }

    @Test func insomniaScriptsRun() {
        var state = RunState()
        var request = ScriptRequest(method: "GET", url: "https://example.com")
        let outcome = ScriptRunner.run(
            scripts: ["insomnia.environment.set('seen', 'yes'); insomnia.test('ok', () => insomnia.expect(insomnia.response.code).to.eql(200));"],
            phase: .test, requestName: "Sample", state: &state, request: &request, response: makeResponse()
        )
        #expect(outcome.error == nil)
        #expect(outcome.tests.map(\.passed) == [true])
        #expect(state.collectionVariables.first { $0.key == "seen" }?.effectiveValue == "yes")
    }
}

// MARK: - Bruno

private let bruRequest = """
meta {
  name: Create pet
  type: http
  seq: 2
  tags: [
    smoke
    pets
  ]
}

post {
  url: {{host}}/pets/:id?verbose=true
  body: json
  auth: bearer
}

params:query {
  verbose: true
  ~debug: 1
}

params:path {
  id: 7
}

headers {
  Content-Type: application/json
  ~X-Off: 1
  X-Note: a: b
}

auth:bearer {
  token: {{token}}
}

body:json {
  {
    "name": "Rex",
    "nested": {
      "ok": true
    }
  }
}

vars:pre-request {
  stamp: now-{{host}}
}

vars:post-response {
  petId: res.body.id
  etag: $res.headers.etag
  count: res.body.items.length
}

assert {
  res.status: eq 201
  res.body.name: contains Rex
  res.body.id: isDefined
  res.responseTime: lt 500
  res.headers.content-type: startsWith "application/json"
  ~res.body.tags: length 2
}

script:pre-request {
  bru.setVar("started", "yes");
}

script:post-response {
  bru.setEnvVar("last", res.body.id);
}

tests {
  test("created", function () {
    expect(res.getStatus()).to.equal(201);
  });
}

docs {
  Makes a pet.

  With **markdown**.
}
"""

@Suite struct BrunoImport {
    @Test func readsBruBlocks() {
        let file = BruFile("""
        meta {
          name: A: B
          seq: 3
        }

        headers {
          "x:odd key": v
          plain: '''
            line one
            line two
          '''
          ~off: 1
        }

        body:json {
          {
            "a": { "b": 1 }
          }
        }

        vars:secret [
          token,
          ~old
        ]
        """)
        #expect(file.order == ["meta", "headers", "body:json", "vars:secret"])
        #expect(file.values("meta") == ["name": "A: B", "seq": "3"])
        #expect(file.rows("headers") == [
            BruFile.Row(key: "x:odd key", value: "v"),
            BruFile.Row(key: "plain", value: "line one\nline two"),
            BruFile.Row(key: "off", value: "1", enabled: false),
        ])
        #expect(file.text("body:json") == "{\n  \"a\": { \"b\": 1 }\n}")
        #expect(file.list("vars:secret") == [BruFile.Row(key: "token", value: ""), BruFile.Row(key: "old", value: "", enabled: false)])
    }

    func makeCollection() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("apiplayground-bruno-\(UUID().uuidString)/Pet Shop")
        try fm.createDirectory(at: root.appendingPathComponent("Pets/Deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("environments"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        func write(_ text: String, _ path: String) throws {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        try write(#"{ "version": "1", "name": "Pet Shop API", "type": "collection", "ignore": ["node_modules", ".git"] }"#, "bruno.json")
        try write("""
        headers {
          X-Client: bruno
        }

        auth {
          mode: basic
        }

        auth:basic {
          username: admin
          password: {{password}}
        }

        vars:pre-request {
          host: https://api.example.com
        }

        script:pre-request {
          console.log("collection");
        }

        docs {
          The pet shop.
        }
        """, "collection.bru")
        try write("""
        meta {
          name: Pet Calls
          seq: 1
        }

        headers {
          X-Folder: pets
        }

        auth {
          mode: none
        }

        vars:pre-request {
          folderVar: 1
        }
        """, "Pets/folder.bru")
        try write(bruRequest, "Pets/create.bru")
        try write("""
        meta {
          name: List pets
          type: http
          seq: 1
        }

        get {
          url: {{host}}/pets?limit=5
        }

        headers {
          X-Client: mine
        }
        """, "Pets/list.bru")
        try write("""
        meta {
          name: Upload
          type: http
          seq: 1
        }

        post {
          url: {{host}}/upload
          body: multipartForm
          auth: inherit
        }

        body:multipart-form {
          note: hello
          photo: @file(files/rex.png)
          ~skip: x
        }
        """, "Pets/Deep/upload.bru")
        try write("""
        meta {
          name: Search
          type: graphql
          seq: 5
        }

        post {
          url: {{process.env.GRAPH_URL}}/graphql
          body: graphql
          auth: apikey
        }

        auth:apikey {
          key: X-Key
          value: k
          placement: queryparams
        }

        body:graphql {
          query {
            pets { id }
          }
        }

        body:graphql:vars {
          { "first": 2 }
        }
        """, "search.bru")
        try write("""
        meta {
          name: Token
          seq: 3
        }

        http {
          method: post
          url: https://auth.example.com/token
          body: formUrlEncoded
          auth: oauth2
        }

        auth:oauth2 {
          grant_type: client_credentials
          access_token_url: https://auth.example.com/token
          client_id: abc
          client_secret: shh
          scope: read
          credentials_placement: body
        }

        body:form-urlencoded {
          a: 1
          ~b: 2
        }
        """, "token.bru")
        try write("meta {\n  name: Ignored\n}\n\nget {\n  url: https://x\n}\n", "node_modules/x/nope.bru")
        try write("""
        vars {
          host: https://prod.example.com
          ~old: 1
        }
        vars:secret [
          token
        ]
        """, "environments/Prod.bru")
        return root
    }

    @Test func readsACollectionFolder() throws {
        let root = try makeCollection()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let batch = try Importer.importFile(at: root)
        let (collection, report) = try #require(collections(batch.documents).first)

        #expect(collection.name == "Pet Shop API")
        #expect(collection.description == "The pet shop.")
        #expect(collection.auth == .basic(username: "admin", password: "{{password}}"))
        #expect(collection.preRequestScript == "console.log(\"collection\");")
        #expect(collection.variables == [Variable(key: "host", value: "https://api.example.com"), Variable(key: "folderVar", value: "1")])
        #expect(collection.postmanID?.hasPrefix("bruno-") == true)
        // Folders first, then requests by their sequence number; node_modules is left out.
        #expect(collection.items.map(\.name) == ["Pet Calls", "Token", "Search"])
        #expect(report.requests == 5)
        #expect(report.folders == 2)

        let pets = try #require(folder(collection.items[0]))
        #expect(pets.auth == Auth.none)
        #expect(pets.items.map(\.name) == ["Deep", "List pets", "Create pet"])

        let list = try #require(request(pets.items[1]))
        #expect(list.method == "GET")
        #expect(list.url == "{{host}}/pets")
        #expect(list.params == [KeyValue(key: "limit", value: "5")])
        #expect(list.auth == .inherit)
        // The request's own header wins over the collection's; the folder's is handed down.
        #expect(list.headers == [KeyValue(key: "X-Folder", value: "pets"), KeyValue(key: "X-Client", value: "mine")])

        let create = try #require(request(pets.items[2]))
        #expect(create.method == "POST")
        #expect(create.url == "{{host}}/pets/:id")
        #expect(create.params == [KeyValue(key: "verbose", value: "true"), KeyValue(key: "debug", value: "1", enabled: false)])
        #expect(create.pathVariables == [KeyValue(key: "id", value: "7")])
        #expect(create.headers == [
            KeyValue(key: "X-Client", value: "bruno"), KeyValue(key: "X-Folder", value: "pets"),
            KeyValue(key: "Content-Type", value: "application/json"), KeyValue(key: "X-Off", value: "1", enabled: false),
            KeyValue(key: "X-Note", value: "a: b"),
        ])
        #expect(create.auth == .bearer(token: "{{token}}"))
        #expect(create.body == .raw(text: "{\n  \"name\": \"Rex\",\n  \"nested\": {\n    \"ok\": true\n  }\n}", contentType: "application/json"))
        #expect(create.description == "Makes a pet.\n\nWith **markdown**.")
        #expect(create.assertions == [
            Assertion(source: ValueSource(kind: .status), op: .equals, expected: "201"),
            Assertion(source: ValueSource(kind: .json, path: "$.name"), op: .contains, expected: "Rex"),
            Assertion(source: ValueSource(kind: .json, path: "$.id"), op: .exists, expected: ""),
            Assertion(source: ValueSource(kind: .time), op: .lessThan, expected: "500"),
            Assertion(source: ValueSource(kind: .header, path: "content-type"), op: .matches, expected: "^application\\/json"),
        ])
        #expect(create.extractions == [
            Extraction(variable: "petId", source: ValueSource(kind: .json, path: "$.id"), scope: .collection),
            Extraction(variable: "etag", source: ValueSource(kind: .header, path: "etag"), scope: .collection),
            Extraction(variable: "count", source: ValueSource(kind: .json, path: "$.items.length"), scope: .collection),
        ])
        #expect(create.preRequestScript == """
        // From Bruno's pre-request variables
        bru.setVar("stamp", bru.interpolate("now-{{host}}"));

        bru.setVar("started", "yes");
        """)
        #expect(create.testScript.hasPrefix("bru.setEnvVar(\"last\", res.body.id);\n\ntest(\"created\""))

        let deep = try #require(folder(pets.items[0]))
        let upload = try #require(request(deep.items.first))
        #expect(upload.body == .formData(fields: [
            FormField(key: "note", value: "hello"),
            FormField(key: "photo", value: root.appendingPathComponent("files/rex.png").standardizedFileURL.path, isFile: true),
            FormField(key: "skip", value: "x", enabled: false),
        ]))

        let token = try #require(request(collection.items[1]))
        #expect(token.method == "POST")
        #expect(token.body == .urlEncoded(fields: [KeyValue(key: "a", value: "1"), KeyValue(key: "b", value: "2", enabled: false)]))
        guard case .oauth2(let oauth) = token.auth else {
            Issue.record("expected OAuth 2")
            return
        }
        #expect(oauth.grant == .clientCredentials)
        #expect(oauth.clientAuthInBody)
        #expect(oauth.scope == "read")

        let search = try #require(request(collection.items[2]))
        #expect(search.body == .graphQL(query: "query {\n  pets { id }\n}", variables: "{ \"first\": 2 }"))
        #expect(search.auth == .apiKey(key: "X-Key", value: "k", placement: .query))

        #expect(report.warnings.contains { $0.contains("1 assertion has no equivalent") && $0.contains("res.body.tags") })
        #expect(report.warnings.contains { $0.contains("process.env") })
        #expect(report.warnings.contains { $0.contains("Folder variables") })
        #expect(report.warnings.contains { $0.contains("copied onto the requests") })

        let environment = try #require(environments(batch.documents).first)
        #expect(environment.name == "Prod")
        #expect(environment.variables == [
            Variable(key: "host", value: "https://prod.example.com"), Variable(key: "old", value: "1", enabled: false),
            Variable(key: "token", value: "", secret: true),
        ])

        // Importing the same folder again gives the same id, so the collection is updated in place.
        let again = try #require(collections(try Importer.importFile(at: root).documents).first)
        #expect(again.0.postmanID == collection.postmanID)
        // The folder that holds the collection works too, as does one request file.
        #expect(collections(try Importer.importFile(at: root.deletingLastPathComponent()).documents).first?.0.name == "Pet Shop API")
        let single = try #require(collections(try Importer.importFile(at: root.appendingPathComponent("token.bru")).documents).first)
        #expect(single.0.name == "Token")
        #expect(single.0.allRequests.count == 1)
    }

    @Test func refusesAFolderWithNoCollection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apiplayground-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: BrunoImportError.noCollection(dir.lastPathComponent)) { try Importer.importFile(at: dir) }
    }

    @Test func readsACollectionSavedAsYAML() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("apiplayground-brunoyaml-\(UUID().uuidString)/Users API")
        try fm.createDirectory(at: root.appendingPathComponent("Admin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("environments"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        func write(_ text: String, _ path: String) throws {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        try write("""
        opencollection: "1.0.0"
        info:
          name: Users
        request:
          headers:
            - name: X-Client
              value: bruno
          auth:
            type: bearer
            token: "{{token}}"
          variables:
            - name: host
              value: https://api.example.com
            - name: count
              value:
                type: number
                data: "42"
        docs:
          content: All about users.
          type: text/markdown
        """, "opencollection.yml")
        try write("""
        info:
          name: Admin Calls
          type: folder
          seq: 1
        request:
          auth:
            type: basic
            username: root
            password: pw
        """, "Admin/folder.yml")
        try write("""
        info:
          name: Create User
          type: http
          seq: 1

        http:
          method: POST
          url: "{{host}}/users/:id"
          params:
            - name: id
              value: "123"
              type: path
            - name: notify
              value: "true"
              type: query
              disabled: true
          headers:
            - name: Accept
              value: application/json
          body:
            type: json
            data: |-
              {
                "name": "John Doe"
              }
          auth: inherit

        runtime:
          scripts:
            - type: before-request
              code: |-
                bru.setVar("timestamp", Date.now());
            - type: tests
              code: |-
                test("made", function () { expect(res.status).to.equal(201); });
          assertions:
            - expression: res.status
              operator: eq
              value: "201"
            - expression: res.body.id
              operator: isDefined

        settings:
          encodeUrl: true

        docs: |-
          # User Creation API
        """, "Admin/create.yml")
        try write("""
        info:
          name: Find
          type: graphql
          seq: 2
        graphql:
          method: POST
          url: "{{host}}/graphql"
          body:
            query: "{ users { id } }"
            variables: "{}"
          auth:
            type: apikey
            key: X-Key
            value: k
            placement: query
        """, "find.yml")
        try write("name: notes\nitems: [1, 2]\n", "notes.yml")
        try write("""
        name: Staging
        variables:
          - name: host
            value: https://staging.example.com
          - name: retries
            value:
              type: number
              data: "3"
          - name: off
            value: x
            disabled: true
          - secret: true
            name: token
        """, "environments/staging.yml")

        let batch = try Importer.importFile(at: root)
        let (collection, report) = try #require(collections(batch.documents).first)
        #expect(collection.name == "Users")
        #expect(collection.description == "All about users.")
        #expect(collection.auth == .bearer(token: "{{token}}"))
        #expect(collection.variables == [Variable(key: "host", value: "https://api.example.com"), Variable(key: "count", value: "42")])
        #expect(collection.items.map(\.name) == ["Admin Calls", "Find"])
        #expect(report.requests == 2)

        let admin = try #require(folder(collection.items[0]))
        #expect(admin.auth == .basic(username: "root", password: "pw"))
        let create = try #require(request(admin.items.first))
        #expect(create.method == "POST")
        #expect(create.url == "{{host}}/users/:id")
        #expect(create.pathVariables == [KeyValue(key: "id", value: "123")])
        #expect(create.params == [KeyValue(key: "notify", value: "true", enabled: false)])
        #expect(create.headers == [KeyValue(key: "X-Client", value: "bruno"), KeyValue(key: "Accept", value: "application/json")])
        #expect(create.body == .raw(text: "{\n  \"name\": \"John Doe\"\n}", contentType: "application/json"))
        #expect(create.auth == .inherit)
        #expect(create.preRequestScript == "bru.setVar(\"timestamp\", Date.now());")
        #expect(create.testScript == "test(\"made\", function () { expect(res.status).to.equal(201); });")
        #expect(create.assertions == [
            Assertion(source: ValueSource(kind: .status), op: .equals, expected: "201"),
            Assertion(source: ValueSource(kind: .json, path: "$.id"), op: .exists, expected: ""),
        ])
        #expect(create.description == "# User Creation API")

        let find = try #require(request(collection.items[1]))
        #expect(find.body == .graphQL(query: "{ users { id } }", variables: "{}"))
        #expect(find.auth == .apiKey(key: "X-Key", value: "k", placement: .query))

        let staging = try #require(environments(batch.documents).first)
        #expect(staging.name == "Staging")
        #expect(staging.variables == [
            Variable(key: "host", value: "https://staging.example.com"), Variable(key: "retries", value: "3"),
            Variable(key: "off", value: "x", enabled: false), Variable(key: "token", value: "", secret: true),
        ])
    }

    @Test func readsTheJSONExport() throws {
        let export = """
        {
          "name": "Shop",
          "version": "1",
          "items": [
            { "type": "http-request", "name": "Get item", "seq": 2,
              "request": {
                "url": "{{host}}/items/:id?full=1", "method": "GET",
                "headers": [ { "name": "Accept", "value": "application/json", "enabled": true }, { "name": "X-Off", "value": "1", "enabled": false } ],
                "params": [ { "name": "full", "value": "1", "type": "query", "enabled": true }, { "name": "id", "value": "3", "type": "path", "enabled": true } ],
                "body": { "mode": "none", "formUrlEncoded": [], "multipartForm": [] },
                "auth": { "mode": "basic", "basic": { "username": "u", "password": "p" } },
                "script": { "req": "bru.setVar('a', 1);", "res": "" },
                "vars": { "req": [], "res": [ { "name": "itemId", "value": "res.body.id", "enabled": true } ] },
                "assertions": [ { "name": "res.status", "value": "eq 200", "enabled": true } ],
                "tests": "test('ok', () => expect(res.status).to.equal(200));",
                "docs": "One item."
              } },
            { "type": "folder", "name": "Admin", "seq": 1,
              "root": { "request": { "headers": [ { "name": "X-Admin", "value": "1", "enabled": true } ], "auth": { "mode": "bearer", "bearer": { "token": "t" } } } },
              "items": [
                { "type": "http-request", "name": "Save", "seq": 1,
                  "request": { "url": "{{host}}/save", "method": "PUT", "headers": [], "params": [],
                    "body": { "mode": "json", "json": "{\\"a\\": 1}" }, "auth": { "mode": "inherit" } } },
                { "type": "js", "name": "helper" }
              ] },
            { "type": "graphql", "name": "Query", "seq": 3,
              "request": { "url": "{{host}}/graphql", "method": "POST",
                "body": { "mode": "graphql", "graphql": { "query": "{ items { id } }", "variables": "{}" } }, "auth": { "mode": "none" } } }
          ],
          "environments": [
            { "name": "Local", "variables": [
              { "name": "host", "value": "http://localhost:3000", "enabled": true, "secret": false },
              { "name": "key", "value": "", "enabled": true, "secret": true } ] }
          ],
          "root": { "request": { "vars": { "req": [ { "name": "host", "value": "https://shop.example.com", "enabled": true } ] } }, "docs": "The shop." },
          "brunoConfig": { "version": "1", "name": "Shop", "type": "collection" }
        }
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apiplayground-brunojson-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Shop.json")
        try Data(export.utf8).write(to: file)

        let batch = try Importer.importFile(at: file)
        let (collection, report) = try #require(collections(batch.documents).first)
        #expect(collection.name == "Shop")
        #expect(collection.description == "The shop.")
        #expect(collection.variables == [Variable(key: "host", value: "https://shop.example.com")])
        #expect(collection.postmanID == nil)
        #expect(collection.items.map(\.name) == ["Admin", "Get item", "Query"])
        #expect(report.requests == 3)

        let admin = try #require(folder(collection.items[0]))
        #expect(admin.auth == .bearer(token: "t"))
        let save = try #require(request(admin.items.first))
        #expect(save.method == "PUT")
        #expect(save.body == .raw(text: "{\"a\": 1}", contentType: "application/json"))
        #expect(save.headers == [KeyValue(key: "X-Admin", value: "1")])
        #expect(report.warnings.contains { $0.contains("js (1)") })

        let get = try #require(request(collection.items[1]))
        #expect(get.url == "{{host}}/items/:id")
        #expect(get.params == [KeyValue(key: "full", value: "1")])
        #expect(get.pathVariables == [KeyValue(key: "id", value: "3")])
        #expect(get.auth == .basic(username: "u", password: "p"))
        #expect(get.assertions == [Assertion(source: ValueSource(kind: .status), op: .equals, expected: "200")])
        #expect(get.extractions == [Extraction(variable: "itemId", source: ValueSource(kind: .json, path: "$.id"), scope: .collection)])
        #expect(get.preRequestScript == "bru.setVar('a', 1);")
        #expect(get.testScript == "test('ok', () => expect(res.status).to.equal(200));")
        #expect(get.description == "One item.")

        #expect(request(collection.items[2])?.body == .graphQL(query: "{ items { id } }", variables: "{}"))

        let local = try #require(environments(batch.documents).first)
        #expect(local.variables == [Variable(key: "host", value: "http://localhost:3000"), Variable(key: "key", value: "", secret: true)])
    }

    @Test func brunoScriptsRun() {
        var state = RunState(collectionVariables: [Variable(key: "host", value: "https://example.com")])
        var request = ScriptRequest(method: "GET", url: "{{host}}/pets")
        let pre = ScriptRunner.run(
            scripts: ["""
            bru.setVar("stamp", bru.interpolate("at-{{host}}"));
            req.setHeader("X-Trace", "abc");
            req.setUrl(req.getUrl() + "?page=2");
            req.setBody({ a: 1 });
            """],
            phase: .preRequest, requestName: "Sample", state: &state, request: &request
        )
        #expect(pre.error == nil)
        #expect(request.url == "{{host}}/pets?page=2")
        #expect(request.headers.contains(ScriptRequest.Header(key: "X-Trace", value: "abc")))
        #expect(request.body == "{\"a\":1}")
        // A runtime variable is kept as a collection variable, so later requests can use it.
        #expect(state.collectionVariables.first { $0.key == "stamp" }?.effectiveValue == "at-https://example.com")

        let post = ScriptRunner.run(
            scripts: ["""
            bru.setEnvVar("first", res.body.pets[0].name);
            test("status and body", function () {
              expect(res.getStatus()).to.equal(200);
              expect(res.status).to.equal(200);
              expect(res.getHeader("Content-Type")).to.equal("application/json");
              expect(res.headers["content-type"]).to.equal("application/json");
              expect(res.getBody().total).to.equal(2);
              expect(bru.getVar("stamp")).to.equal("at-https://example.com");
            });
            test("fails", function () { expect(res.body.total).to.equal(3); });
            """],
            phase: .test, requestName: "Sample", state: &state, request: &request, response: makeResponse(body: petsBody)
        )
        #expect(post.error == nil)
        #expect(post.tests.map(\.passed) == [true, false])
        #expect(state.collectionVariables.first { $0.key == "first" }?.effectiveValue == "Rex")

        let unsupported = ScriptRunner.run(
            scripts: ["bru.sleep(10);"], phase: .preRequest, requestName: "Sample", state: &state, request: &request
        )
        #expect(unsupported.error?.contains("bru.sleep is not supported yet") == true)
    }
}

// MARK: - Choosing the importer

@Suite struct ImportRouting {
    func write(_ text: String, _ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apiplayground-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func picksTheRightImporter() throws {
        let postman = try write(sampleCollectionV21, "pets.json")
        let insomniaJSON = try write(insomniaV4, "insomnia.json")
        let insomniaYAML = try write(insomniaV5, "orders.yaml")
        defer {
            for url in [postman, insomniaJSON, insomniaYAML] { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        #expect(collections(try Importer.importFile(at: postman).documents).first?.0.name == "Pet Store")
        #expect(collections(try Importer.importFile(at: postman).documents).first?.0.postmanID == "abc-123")
        #expect(collections(try Importer.importFile(at: insomniaJSON).documents).first?.0.postmanID == "wrk_1")
        #expect(collections(try Importer.importFile(at: insomniaYAML).documents).first?.0.name == "Orders")
    }

    @Test func refusesWhatNothingRecognises() throws {
        let json = try write("{\"hello\": 1}", "other.json")
        let yaml = try write("openapi: 3.0.0\ninfo:\n  title: x\n", "spec.yaml")
        let text = try write("just words", "notes.json")
        defer {
            for url in [json, yaml, text] { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        #expect(throws: Importer.ImportError.notRecognised(isJSON: true)) { try Importer.importFile(at: json) }
        #expect(throws: Importer.ImportError.notRecognised(isJSON: false)) { try Importer.importFile(at: yaml) }
        #expect(throws: Importer.ImportError.notRecognised(isJSON: false)) { try Importer.importFile(at: text) }
    }

    @Test func readsAZipHoldingSeveralKinds() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("apiplayground-mixed-\(UUID().uuidString)")
        let content = dir.appendingPathComponent("content")
        try fm.createDirectory(at: content.appendingPathComponent("shop"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data(sampleCollectionV21.utf8).write(to: content.appendingPathComponent("pets.json"))
        try Data(insomniaV5.utf8).write(to: content.appendingPathComponent("orders.yaml"))
        try Data(#"{ "version": "1", "name": "Zipped Shop", "type": "collection" }"#.utf8).write(to: content.appendingPathComponent("shop/bruno.json"))
        try Data("meta {\n  name: Ping\n}\n\nget {\n  url: https://example.com/ping\n}\n".utf8).write(to: content.appendingPathComponent("shop/ping.bru"))
        try Data("{\"version\": 1}".utf8).write(to: content.appendingPathComponent("other.json"))

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = content
        zip.arguments = ["-qr", dir.appendingPathComponent("all.zip").path, "."]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)

        let batch = try Importer.importFile(at: dir.appendingPathComponent("all.zip"))
        let found = collections(batch.documents)
        #expect(Set(found.map(\.0.name)) == ["Pet Store", "Orders", "Zipped Shop"])
        // A collection unpacked from a zip has no lasting place to be recognised by.
        #expect(found.first { $0.0.name == "Zipped Shop" }?.0.postmanID == nil)
        #expect(batch.skipped.count == 1)
        #expect(batch.skipped.first?.hasPrefix("other.json") == true)
    }
}

private func settings(_ documents: [ImportedDocument]) -> [ImportedSettings] {
    documents.compactMap { if case .settings(let settings) = $0 { return settings } else { return nil } }
}

@Suite struct ImportedAppSettings {
    @Test func insomniaCookiesComeAcrossFromBothFormats() throws {
        let v4 = """
        {"_type": "export", "__export_format": 4, "resources": [
          {"_id": "wrk_1", "_type": "workspace", "name": "Shop"},
          {"_id": "req_1", "_type": "request", "parentId": "wrk_1", "name": "List", "method": "GET", "url": "https://shop.test/items"},
          {"_id": "jar_1", "_type": "cookie_jar", "parentId": "wrk_1", "name": "Default Jar", "cookies": [
            {"key": "session", "value": "abc", "domain": "shop.test", "path": "/", "hostOnly": true, "secure": true, "httpOnly": true, "expires": "2099-01-01T00:00:00.000Z"},
            {"key": "theme", "value": "dark", "domain": ".shop.test", "path": "/account"},
            {"key": "", "value": "ignored", "domain": "shop.test"}
          ]}
        ]}
        """
        let found = try #require(settings(try InsomniaImporter.importDocuments(data: Data(v4.utf8))).first)
        #expect(found.source == "Shop")
        #expect(found.cookies.count == 2)
        let session = found.cookies[0]
        #expect(session.name == "session" && session.value == "abc" && session.domain == "shop.test")
        #expect(session.hostOnly && session.secure && session.httpOnly)
        #expect(session.expires == ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z"))
        let theme = found.cookies[1]
        #expect(theme.domain == "shop.test" && !theme.hostOnly && theme.path == "/account" && theme.expires == nil)

        let v5 = """
        type: collection.insomnia.rest/5.0
        name: Shop
        collection:
          - name: List
            url: https://shop.test/items
            method: GET
        cookieJar:
          name: Default Jar
          cookies:
            - key: session
              value: xyz
              domain: shop.test
              path: /
              expires: Infinity
        """
        let newer = try #require(settings(try InsomniaImporter.importDocuments(data: Data(v5.utf8))).first)
        #expect(newer.cookies.map(\.value) == ["xyz"])
        #expect(newer.cookies[0].expires == nil)
    }

    @Test func aBrunoFolderBringsItsCertificatesAndProxy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bruno-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        {"version": "1", "name": "Billing", "type": "collection",
         "clientCertificates": {"enabled": true, "certs": [
            {"domain": "api.billing.test", "type": "cert", "certFilePath": "certs/client.pem", "keyFilePath": "/keys/client.key", "passphrase": "open"},
            {"domain": "*.pfx.test", "type": "pfx", "pfxFilePath": "certs/bundle.p12", "passphrase": ""},
            {"domain": "", "certFilePath": "x.pem"}
         ]},
         "proxy": {"enabled": true, "protocol": "http", "hostname": "proxy.corp.test", "port": 3128,
                   "auth": {"enabled": true, "username": "me", "password": "pw"}, "bypassProxy": "localhost"}}
        """.write(to: root.appendingPathComponent("bruno.json"), atomically: true, encoding: .utf8)
        try "meta {\n  name: Ping\n  type: http\n  seq: 1\n}\n\nget {\n  url: https://api.billing.test/ping\n}\n"
            .write(to: root.appendingPathComponent("Ping.bru"), atomically: true, encoding: .utf8)

        let found = try #require(settings(try BrunoImporter.importFolder(at: root)).first)
        #expect(found.source == "Billing")
        #expect(found.certificates.count == 2)
        let first = found.certificates[0]
        #expect(first.rule.host == "api.billing.test")
        #expect(first.rule.certificatePath == root.appendingPathComponent("certs/client.pem").standardizedFileURL.path)
        #expect(first.rule.keyPath == "/keys/client.key")
        #expect(first.passphrase == "open")
        let second = found.certificates[1]
        #expect(second.rule.certificatePath.hasSuffix("certs/bundle.p12") && second.rule.keyPath.isEmpty && second.passphrase == nil)
        let proxy = try #require(found.proxy)
        #expect(proxy.enabled && proxy.url == "http://proxy.corp.test:3128" && proxy.username == "me" && proxy.password == "pw" && proxy.bypass == "localhost")
    }

    @Test func aBrunoExportFileBringsItsProxyInTheNewerShape() throws {
        let export = """
        {"name": "Billing", "version": "1", "items": [],
         "brunoConfig": {"proxy": {"inherit": false, "disabled": false,
            "config": {"protocol": "socks5", "hostname": "127.0.0.1", "port": "1080", "auth": {"disabled": true, "username": "x"}}}}}
        """
        let found = try #require(settings(try BrunoImporter.importDocuments(data: Data(export.utf8))).first)
        #expect(found.proxy?.url == "socks5://127.0.0.1:1080")
        #expect(found.proxy?.username == "")
        #expect(found.certificates.isEmpty)
    }

    @Test func aProxyThatIsOffOrInheritedIsLeftBehind() throws {
        for proxy in [#"{"enabled": false, "hostname": "p.test", "port": 1}"#, #"{"enabled": "global", "hostname": "p.test"}"#,
                      #"{"inherit": true, "config": {"hostname": "p.test"}}"#] {
            let export = #"{"name": "A", "items": [], "brunoConfig": {"proxy": \#(proxy)}}"#
            #expect(settings(try BrunoImporter.importDocuments(data: Data(export.utf8))).isEmpty)
        }
    }
}
