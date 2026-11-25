import Foundation
import Testing
@testable import APIEngine

private let petstore = """
openapi: 3.0.3
info:
  title: Pet Store
  version: 1.0.0
  description: Pets, mostly.
  contact:
    name: API Team
servers:
  - url: https://{region}.example.com/v1
    variables:
      region:
        default: eu
tags:
  - name: pets
security:
  - token: []
paths:
  /pets:
    get:
      operationId: listPets
      summary: List pets
      description: Every pet, newest first.
      tags: [pets]
      parameters:
        - name: limit
          in: query
          schema: { type: integer, default: 20 }
        - name: X-Trace
          in: header
          required: true
          schema: { type: string }
      responses:
        '200':
          description: A list of pets
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/Pet'
    post:
      operationId: addPet
      summary: Add a pet
      description: Adds one pet.
      tags: [pets]
      security: []
      requestBody:
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/Pet'
      responses:
        '201':
          description: Created
          content:
            application/json:
              example: { id: 7, name: Rex }
        '400':
          description: Bad input
  /pets/{petId}:
    parameters:
      - name: petId
        in: path
        required: true
        schema: { type: integer }
        example: 42
    get:
      operationId: getPet
      description: One pet.
      tags: [pets]
      responses:
        '200':
          description: The pet
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Pet'
components:
  securitySchemes:
    token:
      type: http
      scheme: bearer
  schemas:
    Pet:
      type: object
      properties:
        id:
          type: integer
          readOnly: true
        name:
          type: string
          example: Rex
        tag:
          type: string
          enum: [dog, cat]
        born:
          type: string
          format: date
        owner:
          $ref: '#/components/schemas/Owner'
    Owner:
      type: object
      properties:
        email: { type: string, format: email }
        pets:
          type: array
          items:
            $ref: '#/components/schemas/Pet'
"""

@Suite struct SpecParsing {
    func parse(_ text: String) throws -> SpecNode {
        try SpecParser.parse(text).root
    }

    @Test func blockMapsAndListsKeepTheirOrderAndLines() throws {
        let root = try parse("""
        # A comment
        zebra: 1
        apple:
          - one
          - name: two   # trailing comment
            size: 2.50
        empty:
        """)
        #expect(root.entries.map(\.key) == ["zebra", "apple", "empty"])
        #expect(root.entries[1].line == 3)
        #expect(root["apple"]?.items[0].string == "one")
        #expect(root["apple"]?.items[1]["name"]?.string == "two")
        #expect(root["apple"]?.items[1]["size"]?.string == "2.50")
        #expect(root["apple"]?.items[1]["size"]?.double == 2.5)
        #expect(root["apple"]?.items[1]["size"]?.line == 6)
        #expect(root["empty"]?.isNull == true)
    }

    @Test func aListMayStartAtItsKeysIndent() throws {
        let root = try parse("""
        tags:
        - a
        - b
        after: true
        """)
        #expect(root["tags"]?.items.compactMap(\.string) == ["a", "b"])
        #expect(root["after"]?.bool == true)
    }

    @Test func quotedTextAndPlainTextAreTold​Apart() throws {
        let root = try parse("""
        a: "yes: \\"quoted\\"\\n"
        b: 'it''s'
        c: http://example.com/a#b
        d: '200'
        e: 200
        f: ~
        "g h": no # comment
        """)
        #expect(root["a"]?.value == .string("yes: \"quoted\"\n"))
        #expect(root["b"]?.value == .string("it's"))
        #expect(root["c"]?.value == .string("http://example.com/a#b"))
        #expect(root["d"]?.value == .string("200"))
        #expect(root["e"]?.value == .number(200, "200"))
        #expect(root["f"]?.isNull == true)
        #expect(root["g h"]?.value == .string("no"))
    }

    @Test func blockTextKeepsOrFoldsItsLines() throws {
        let root = try parse("""
        literal: |
          one
            two

          three
        folded: >-
          one
          two

          three
        next: 1
        """)
        #expect(root["literal"]?.string == "one\n  two\n\nthree\n")
        #expect(root["folded"]?.string == "one two\nthree")
        #expect(root["next"]?.double == 1)
    }

    @Test func flowValuesAndJSONAreRead() throws {
        let yaml = try parse("a: [1, two, {x: y}]\nb: { c: d, e: [ ] }")
        #expect(yaml["a"]?.items.count == 3)
        #expect(yaml["a"]?.items[2]["x"]?.string == "y")
        #expect(yaml["b"]?["e"]?.isList == true)

        let json = try parse("""
        {
        \t"name": "caf\\u00e9 \\ud83d\\ude00",
        \t"list": [true, null, -1.5e2],
        \t"nested": {"a": {"b": "c"}}
        }
        """)
        #expect(json["name"]?.string == "café 😀")
        #expect(json["list"]?.items[2].double == -150)
        #expect(json["nested"]?["a"]?["b"]?.line == 4)
    }

    @Test func anchorsAliasesAndMergesAreFollowed() throws {
        let root = try parse("""
        base: &base
          type: object
          size: 1
        copy: *base
        bigger:
          <<: *base
          size: 2
        """)
        #expect(root["copy"]?["type"]?.string == "object")
        #expect(root["bigger"]?["size"]?.double == 2)
        #expect(root["bigger"]?["type"]?.string == "object")
    }

    @Test func mistakesAreReportedWithTheirLine() throws {
        #expect(throws: SpecParseError.self) { try self.parse("a: [1, 2") }
        do {
            _ = try parse("a:\n  b: 1\n c: 2")
            Issue.record("Expected an error")
        } catch let error as SpecParseError {
            #expect(error.line == 3)
        }
        let repeated = try SpecParser.parse("a: 1\nb: 2\na: 3")
        #expect(repeated.problems == [SpecProblem(message: "The key “a” appears more than once.", line: 3)])
    }

    @Test func valuesAreWrittenBackAsJSONInOrder() throws {
        let root = try parse("b: 1\na: [x, 2.0, true, null]\nc: {}")
        #expect(root.jsonText(pretty: false) == #"{"b":1,"a":["x",2.0,true,null],"c":{}}"#)
        #expect(root.jsonText().contains("\n  \"b\": 1,\n"))
    }
}

@Suite struct OpenAPIReading {
    @Test func theDocumentsRoutesAreListedInOrder() throws {
        let document = try OpenAPIDocument(text: petstore)
        #expect(document.title == "Pet Store")
        #expect(document.version == "1.0.0")
        #expect(document.servers == ["https://eu.example.com/v1"])
        #expect(document.operations.map(\.id) == ["GET /pets", "POST /pets", "GET /pets/{petId}"])
        #expect(document.operations[0].title == "List pets")
        #expect(document.operations[2].title == "getPet")
        #expect(document.operations[0].line == 19)
    }

    @Test func examplesComeFromSchemasWhenNoneAreGiven() throws {
        let document = try OpenAPIDocument(text: petstore)
        let add = document.operations[1]
        // The request leaves out the read-only id; a self-referencing schema stops instead of looping.
        let body = try #require(add.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(body.example.utf8)) as? [String: Any])
        #expect(sent["id"] == nil)
        #expect(sent["name"] as? String == "Rex")
        #expect(sent["tag"] as? String == "dog")
        #expect(sent["born"] as? String == "2024-01-01")
        #expect((sent["owner"] as? [String: Any])?["email"] as? String == "user@example.com")

        // A response includes the read-only id, and a given example is used as it is.
        let listed = try #require(document.operations[0].responses[0].example)
        let pets = try #require(try JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [[String: Any]])
        #expect(pets.first?["id"] as? Int == 0)
        #expect(add.responses[0].example == "{\n  \"id\": 7,\n  \"name\": \"Rex\"\n}")
    }

    @Test func aCollectionIsMadeWithARequestForEachOperation() throws {
        let document = try OpenAPIDocument(text: petstore)
        let collection = document.collection(specFile: "petstore.yaml")
        #expect(collection.name == "Pet Store")
        #expect(collection.specFile == "petstore.yaml")
        #expect(collection.auth == .bearer(token: "{{bearerToken}}"))
        #expect(collection.variables.map(\.key) == ["baseUrl", "bearerToken"])
        #expect(collection.variables[0].value == "https://eu.example.com/v1")
        #expect(collection.items.map(\.name) == ["pets"])

        let requests = collection.allRequests
        #expect(requests.map(\.url) == ["{{baseUrl}}/pets", "{{baseUrl}}/pets", "{{baseUrl}}/pets/:petId"])
        let list = requests[0]
        #expect(list.params == [KeyValue(key: "limit", value: "20", enabled: false)])
        #expect(list.headers.map(\.key) == ["X-Trace", "Accept"])
        #expect(list.assertions.first?.expected == "200")
        #expect(list.auth == .inherit)

        let add = requests[1]
        #expect(add.auth == .none)
        #expect(add.headers.first == KeyValue(key: "Content-Type", value: "application/json"))
        #expect(add.examples.map(\.status) == [201, 400])
        #expect(requests[2].pathVariables == [KeyValue(key: "petId", value: "42")])
    }

    @Test func theCollectionsExamplesAnswerAsAMock() throws {
        let collection = try OpenAPIDocument(text: petstore).collection()
        let routes = MockServer.routes(for: collection)
        let reply = MockServer.reply(method: "GET", target: "/pets/9", headers: [:], routes: routes)
        #expect(reply.status == 200)
        let pet = try #require(try JSONSerialization.jsonObject(with: reply.body) as? [String: Any])
        #expect(pet["name"] as? String == "Rex")
        #expect(MockServer.reply(method: "POST", target: "/pets", headers: [:], routes: routes).status == 201)
    }

    @Test func generatingAgainKeepsEachRequestsIdentity() throws {
        let first = try OpenAPIDocument(text: petstore).collection()
        let changed = petstore.replacingOccurrences(of: "Every pet, newest first.", with: "All of them.")
        let second = try OpenAPIDocument(text: changed).collection().adoptingIdentities(from: first)
        #expect(second.id == first.id)
        #expect(second.allRequests.map(\.id) == first.allRequests.map(\.id))
        #expect(second.allRequests[0].description == "All of them.")
    }

    @Test func swagger2IsRead() throws {
        let document = try OpenAPIDocument(text: """
        {
          "swagger": "2.0",
          "info": {"title": "Old API", "version": "1"},
          "host": "api.example.com", "basePath": "/v2", "schemes": ["https"],
          "paths": {
            "/things": {
              "post": {
                "parameters": [{"in": "body", "name": "body", "schema": {"$ref": "#/definitions/Thing"}}],
                "responses": {"200": {"description": "ok", "schema": {"$ref": "#/definitions/Thing"}}}
              }
            }
          },
          "definitions": {"Thing": {"type": "object", "properties": {"n": {"type": "integer"}}}}
        }
        """)
        #expect(document.servers == ["https://api.example.com/v2"])
        #expect(document.operations[0].body?.example == "{\n  \"n\": 0\n}")
        #expect(document.operations[0].responses[0].contentType == "application/json")
    }

    @Test func textThatIsNotASpecIsRefused() {
        #expect(throws: OpenAPIError.self) { try OpenAPIDocument(text: "name: something else") }
        #expect(throws: OpenAPIError.self) { try OpenAPIDocument(text: "openapi: [") }
    }
}

@Suite struct SpecLinting {
    func rules(_ text: String, ruleset: String = "") -> [String] {
        SpecLinter.lint(text, ruleset: ruleset).map(\.rule)
    }

    @Test func aTidySpecHasNothingToReport() {
        #expect(SpecLinter.lint(petstore) == [])
    }

    @Test func syntaxMistakesAreTheOnlyFinding() {
        let issues = SpecLinter.lint("openapi: 3.0.0\ninfo: [")
        #expect(issues.map(\.rule) == ["parser"])
        #expect(issues[0].line == 2)
        #expect(issues[0].severity == .error)
    }

    @Test func missingPartsAreReportedWhereTheyBelong() {
        let issues = SpecLinter.lint("""
        openapi: 3.0.3
        info:
          title: Thin
        paths:
          /things/{id}/:
            get:
              tags: [stuff]
              responses:
                '500':
                  description: Oops
          /query?x=1:
            get:
              operationId: a b
              description: d
              tags: [stuff]
              responses:
                '200': { description: ok }
            post:
              operationId: a b
              description: d
              tags: [stuff]
              responses:
                '200': { description: ok }
        """)
        func lines(_ rule: String) -> [Int] { issues.filter { $0.rule == rule }.map(\.line) }
        #expect(lines("oas3-schema") == [2])
        #expect(lines("info-contact") == [2])
        #expect(lines("info-description") == [2])
        #expect(lines("oas3-api-servers") == [1])
        #expect(lines("path-keys-no-trailing-slash") == [5])
        #expect(lines("path-params") == [6])
        #expect(lines("operation-operationId") == [6])
        #expect(lines("operation-description") == [6])
        #expect(lines("operation-success-response") == [8])
        #expect(lines("operation-tag-defined") == [7, 15, 21])
        #expect(lines("path-not-include-query") == [11])
        #expect(lines("operation-operationId-valid-in-url") == [13, 19])
        #expect(lines("operation-operationId-unique") == [19])
        #expect(issues.first { $0.rule == "path-params" }?.severity == .error)
        #expect(issues.first { $0.rule == "path-params" }?.path == "paths./things/{id}/.get")
    }

    @Test func referencesEnumsAndUnusedPartsAreChecked() {
        let issues = SpecLinter.lint("""
        openapi: 3.0.3
        info: { title: T, version: '1', description: d, contact: { name: n } }
        servers: [{ url: 'https://example.com/' }]
        paths: {}
        components:
          schemas:
            Used:
              type: string
              enum: [a, 1, a]
            Holder:
              description: has <script>alert(1)</script>
              properties:
                enum: { type: string }
                one:
                  $ref: '#/components/schemas/Used'
                  description: sibling
                two:
                  $ref: '#/components/schemas/Missing'
                three:
                  example: { $ref: 'not a real reference' }
        """)
        func lines(_ rule: String) -> [Int] { issues.filter { $0.rule == rule }.map(\.line) }
        #expect(lines("oas3-server-trailing-slash") == [3])
        #expect(lines("typed-enum") == [9])
        #expect(lines("duplicated-entry-in-enum") == [9])
        #expect(lines("no-script-tags-in-markdown") == [11])
        #expect(lines("no-$ref-siblings") == [15])
        #expect(lines("invalid-ref") == [18])
        #expect(lines("oas3-unused-component") == [10])
    }

    @Test func aRulesetCanSwitchRulesOffAndChangeSeverity() {
        let thin = "openapi: 3.0.3\ninfo: { title: T, version: '1' }\npaths: {}"
        #expect(Set(rules(thin)) == ["info-contact", "info-description", "oas3-api-servers"])

        let adjusted = SpecLinter.lint(thin, ruleset: """
        extends: spectral:oas
        rules:
          info-contact: off
          info-description: error
          oas3-api-servers: { severity: hint }
        """)
        #expect(adjusted.map(\.rule).sorted() == ["info-description", "oas3-api-servers"])
        #expect(adjusted.first { $0.rule == "info-description" }?.severity == .error)
        #expect(adjusted.first { $0.rule == "oas3-api-servers" }?.severity == .hint)

        // Without "extends", a ruleset stands alone.
        #expect(rules(thin, ruleset: "rules: {}") == [])
        // Extending with everything off, then switching one rule on.
        #expect(rules(thin, ruleset: "extends: [[spectral:oas, off]]\nrules:\n  info-contact: warn") == ["info-contact"])
    }

    @Test func customRulesRun() {
        let ruleset = """
        rules:
          paths-kebab-case:
            description: Paths must be kebab-case.
            message: "{{property}} is not kebab-case"
            severity: error
            given: $.paths[*]~
            then:
              function: pattern
              functionOptions:
                match: "^(/[a-z0-9-{}]+)+$"
          operation-summary:
            description: Operations need a short summary.
            given: $.paths[*][get,post]
            then:
              field: summary
              function: truthy
          summary-length:
            given: $..summary
            then:
              function: length
              functionOptions: { max: 10 }
          version-format:
            given: $.info
            then:
              - field: version
                function: pattern
                functionOptions: { match: '/^\\d+\\.\\d+\\.\\d+$/' }
              - field: license
                function: defined
          response-codes:
            given: $.paths.*.*.responses
            then:
              field: "@key"
              function: enumeration
              functionOptions: { values: ['200', '404'] }
          unknown-function:
            given: $
            then: { function: schema }
        """
        let issues = SpecLinter.lint("""
        openapi: 3.0.3
        info:
          title: T
          version: v1
        paths:
          /Pet_Store:
            get:
              summary: A very long summary indeed
              responses:
                '200': { description: ok }
                '418': { description: teapot }
          /pets/{pet-id}:
            get:
              responses:
                '200': { description: ok }
        """, ruleset: ruleset)
        func found(_ rule: String) -> [LintIssue] { issues.filter { $0.rule == rule } }
        #expect(found("paths-kebab-case").map(\.line) == [6])
        #expect(found("paths-kebab-case").first?.message == "/Pet_Store is not kebab-case")
        #expect(found("paths-kebab-case").first?.severity == .error)
        #expect(found("summary-length").map(\.line) == [8])
        #expect(found("version-format").map(\.message) == ["“license” must be defined.", "“version” must match the pattern /^\\d+\\.\\d+\\.\\d+$/."])
        #expect(found("response-codes").map(\.line) == [11])
        // A path this linter cannot follow, and a function it does not have, are said so once each.
        let notes = found("ruleset").map(\.message)
        #expect(notes.count == 2)
        #expect(notes.contains { $0.contains("operation-summary") && $0.contains("not supported") })
        #expect(notes.contains { $0.contains("unknown-function") && $0.contains("schema") })
    }

    @Test func pathsSelectWhatTheySay() throws {
        let root = try SpecParser.parse("a:\n  b: [1, {c: 2}]\n  c: 3\nd: {c: 4}").root
        func values(_ path: String) -> [String]? { SpecPath.select(path, in: root)?.map { $0.node.string ?? "?" } }
        #expect(values("$.a.c") == ["3"])
        #expect(values("$['d']['c']") == ["4"])
        #expect(values("$.a.b[0]") == ["1"])
        #expect(values("$..c") == ["2", "3", "4"])
        #expect(values("$.*~") == ["a", "d"])
        #expect(values("$.a.b[?(@.c)]") == nil)
    }
}

@Suite struct SpecStorage {
    @Test func specsAndTheRulesetAreKeptAsWritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spec-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkspaceStore(root: dir, secrets: InMemorySecretStore())
        try store.prepare()
        #expect(try store.loadSpecs() == [])

        let file = store.newSpecFileName(for: "Pet Store")
        #expect(file == "pet-store.yaml")
        try store.save(SpecFile(file: file, text: petstore))
        #expect(store.newSpecFileName(for: "Pet Store") == "pet-store-2.yaml")
        try store.saveRuleset("extends: spectral:oas\n")

        let loaded = try store.loadSpecs()
        #expect(loaded.map(\.name) == ["pet-store"])
        #expect(loaded[0].text == petstore)
        #expect(store.loadRuleset() == "extends: spectral:oas\n")

        // A collection remembers the spec it came from.
        try store.save(try OpenAPIDocument(text: petstore).collection(specFile: file))
        #expect(try store.loadCollections().first?.specFile == file)

        try store.saveRuleset("  ")
        #expect(store.loadRuleset() == "")
        try store.deleteSpec(file: file)
        #expect(try store.loadSpecs() == [])
    }

    @Test func specFilesAreNamedInGitChanges() {
        #expect(WorkspaceFileInfo(path: "specs/pet-store.yaml").kind == .spec)
        #expect(WorkspaceFileInfo(path: "specs/pet-store.yaml").title == "pet-store")
        #expect(WorkspaceFileInfo(path: "specs/.spectral.yaml").title == "Lint ruleset")
    }
}
