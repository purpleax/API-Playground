import Foundation
import Testing
@testable import APIEngine

func makeResponse(status: Int = 200, statusText: String = "OK", headers: [HTTPHeader] = [HTTPHeader(name: "Content-Type", value: "application/json")], body: String = "{}", seconds: Double = 0.123) -> HTTPResponse {
    var timings = HTTPTimings()
    timings.total = seconds
    return HTTPResponse(
        status: status, statusText: statusText, httpVersion: "HTTP/1.1", headers: headers,
        body: Data(body.utf8), timings: timings, remoteAddress: nil, wireLog: []
    )
}

let petsBody = """
{ "total": 2, "ok": true, "none": null, "pets": [ { "id": 1, "name": "Rex", "tags": ["a", "b"] }, { "id": 2, "name": "Milo" } ], "meta": { "next page": "/pets?page=2" } }
"""

@Suite struct JSONPaths {
    let root = try! JSONSerialization.jsonObject(with: Data(petsBody.utf8))

    @Test func lookups() {
        func text(_ path: String) -> String? { JSONPath.lookup(path, in: root).map(JSONPath.text) }
        #expect(text("$.total") == "2")
        #expect(text("total") == "2")
        #expect(text("$.ok") == "true")
        #expect(text("$.none") == "null")
        #expect(text("$.pets[0].name") == "Rex")
        #expect(text("pets[1].id") == "2")
        #expect(text("$.pets[-1].name") == "Milo")
        #expect(text("$.pets[0].tags") == "[\"a\",\"b\"]")
        #expect(text("$.meta[\"next page\"]") == "/pets?page=2")
        #expect(text("$.pets[5].name") == nil)
        #expect(text("$.missing") == nil)
        #expect(text("$.total.deeper") == nil)
        #expect(text("$..bad") == nil)
    }
}

@Suite struct Assertions {
    let response = makeResponse(body: petsBody)

    func check(_ kind: ValueSource.Kind, _ path: String = "", _ op: AssertionOperator, _ expected: String = "") -> TestResult {
        Assertion(source: ValueSource(kind: kind, path: path), op: op, expected: expected).evaluate(response, expected: expected)
    }

    @Test func passingChecks() {
        #expect(check(.status, "", .equals, "200").passed)
        #expect(check(.status, "", .lessThan, "300").passed)
        #expect(check(.header, "content-type", .contains, "json").passed)
        #expect(check(.header, "X-Missing", .notExists).passed)
        #expect(check(.json, "$.pets[0].name", .equals, "Rex").passed)
        #expect(check(.json, "$.total", .equals, "2.0").passed)
        #expect(check(.json, "$.total", .greaterThan, "1").passed)
        #expect(check(.json, "$.pets[1].name", .matches, "^M.*o$").passed)
        #expect(check(.json, "$.pets", .exists).passed)
        #expect(check(.body, "", .contains, "Milo").passed)
        #expect(check(.body, "", .notContains, "Felix").passed)
        #expect(check(.time, "", .lessThan, "500").passed)
        #expect(check(.status, "", .notEquals, "404").passed)
    }

    @Test func failingChecksExplainWhy() {
        let status = check(.status, "", .equals, "201")
        #expect(!status.passed)
        #expect(status.name == "Status equals 201")
        #expect(status.message == "was 200")

        let missing = check(.json, "$.nope", .equals, "x")
        #expect(!missing.passed)
        #expect(missing.message == "was missing")

        #expect(!check(.json, "$.pets[0].name", .lessThan, "5").passed)
        #expect(check(.body, "", .matches, "([").message == "the pattern is not valid")
        #expect(check(.json, "$.nope", .exists).name == "$.nope exists")
    }
}

@Suite struct Scripts {
    func run(_ script: String, phase: ScriptPhase = .test, state: inout RunState, request: inout ScriptRequest, response: HTTPResponse? = makeResponse(body: petsBody)) -> ScriptOutcome {
        ScriptRunner.run(scripts: [script], phase: phase, requestName: "Sample", state: &state, request: &request, response: response)
    }

    func run(_ script: String, response: HTTPResponse? = makeResponse(body: petsBody)) -> ScriptOutcome {
        var state = RunState()
        var request = ScriptRequest(method: "GET", url: "https://example.com/pets")
        return run(script, state: &state, request: &request, response: response)
    }

    @Test func typicalPostmanTestsPass() {
        let outcome = run("""
        pm.test("Status code is 200", function () {
            pm.response.to.have.status(200);
        });
        pm.test("Status text and helpers", () => {
            pm.response.to.have.status("OK");
            pm.response.to.be.ok;
            pm.response.to.be.success;
            pm.response.to.not.be.error;
            pm.response.to.be.json;
            pm.response.to.have.header("Content-Type");
            pm.response.to.have.header("content-type", "application/json");
            pm.expect(pm.response.code).to.be.oneOf([200, 201]);
            pm.expect(pm.response.responseTime).to.be.below(500);
            pm.expect(pm.response.headers.get("Content-Type")).to.include("json");
        });
        pm.test("Body has pets", function () {
            const data = pm.response.json();
            pm.expect(data.total).to.eql(2);
            pm.expect(data.pets).to.be.an("array").that.has.lengthOf(2);
            pm.expect(data.pets[0]).to.have.property("name", "Rex");
            pm.expect(data.pets[0]).to.have.property("tags").that.includes("a");
            pm.expect(data.pets[0]).to.deep.equal({ id: 1, name: "Rex", tags: ["a", "b"] });
            pm.expect(data.pets[0]).to.include({ name: "Rex" });
            pm.expect(data).to.have.all.keys("total", "ok", "none", "pets", "meta");
            pm.expect(data.ok).to.be.true;
            pm.expect(data.none).to.be.null;
            pm.expect(data.missing).to.be.undefined;
            pm.expect(data.pets[1].name).to.match(/^Mi/).and.to.be.a("string");
            pm.expect(data.total).to.be.above(1).and.below(3);
            pm.expect(data.pets.map(p => p.id)).to.have.members([2, 1]);
            pm.expect([]).to.be.empty;
            pm.expect(data.pets).to.not.be.empty;
            pm.expect(pm.response.text()).to.include("Milo");
        });
        """)
        #expect(outcome.error == nil)
        #expect(outcome.tests.map(\.name) == ["Status code is 200", "Status text and helpers", "Body has pets"])
        for test in outcome.tests {
            #expect(test.passed, "\(test.name): \(test.message ?? "")")
        }
    }

    @Test func failuresCarryAMessageAndLaterTestsStillRun() {
        let outcome = run("""
        pm.test("wrong status", () => pm.response.to.have.status(201));
        pm.test("wrong value", () => pm.expect(pm.response.json().total).to.equal(3));
        pm.test("negated", () => pm.expect("abc").to.not.include("b"));
        pm.test("custom message", () => pm.expect(1, "count").to.equal(2));
        pm.test("throws", () => { throw new Error("boom"); });
        pm.test("still runs", () => {});
        pm.test.skip("skipped", () => { throw new Error("never"); });
        """)
        #expect(outcome.error == nil)
        #expect(outcome.tests.map(\.passed) == [false, false, false, false, false, true, true])
        #expect(outcome.tests[0].message == "expected the response to have status 201 (was 200 OK)")
        #expect(outcome.tests[1].message == "expected 2 to equal 3")
        #expect(outcome.tests[2].message == "expected \"abc\" not to include \"b\"")
        #expect(outcome.tests[3].message == "count: expected 1 to equal 2")
        #expect(outcome.tests[4].message == "boom")
        #expect(outcome.tests[6].skipped)
    }

    @Test func variablesAreReadAndWrittenByScope() {
        var state = RunState(
            globals: [Variable(key: "g", value: "global"), Variable(key: "shared", value: "from-globals")],
            collectionVariables: [Variable(key: "shared", value: "from-collection"), Variable(key: "gone", value: "x")],
            environment: [Variable(key: "token", value: "old"), Variable(key: "secret", value: "s1", secret: true),
                          Variable(key: "off", value: "hidden", enabled: false)]
        )
        var request = ScriptRequest(method: "GET", url: "{{base}}/pets")
        let outcome = run("""
        pm.test("reads", () => {
            pm.expect(pm.environment.get("token")).to.equal("old");
            pm.expect(pm.environment.has("off")).to.be.false;
            pm.expect(pm.variables.get("shared")).to.equal("from-collection");
            pm.expect(pm.variables.get("g")).to.equal("global");
            pm.expect(pm.variables.get("nope")).to.be.undefined;
            pm.expect(pm.variables.replaceIn("{{g}}/{{nope}}")).to.equal("global/{{nope}}");
        });
        pm.environment.set("token", pm.response.json().pets[0].name);
        pm.environment.set("created", { id: 7 });
        pm.environment.set("secret", "s2");
        pm.collectionVariables.unset("gone");
        pm.globals.set("count", 3);
        pm.variables.set("temp", "local");
        """, state: &state, request: &request)

        #expect(outcome.error == nil)
        #expect(outcome.tests.first?.passed == true, "\(outcome.tests.first?.message ?? "")")

        // A script's value is a current value: the shared value in the file stays as it was.
        let token = state.environment.first { $0.key == "token" }
        #expect(token?.value == "old")
        #expect(token?.currentValue == "Rex")
        #expect(state.environment.first { $0.key == "created" }?.effectiveValue == "{\"id\":7}")
        // A secret has no separate current value; its value is already kept locally.
        #expect(state.environment.first { $0.key == "secret" }?.value == "s2")
        // A disabled variable is untouched.
        #expect(state.environment.first { $0.key == "off" } == Variable(key: "off", value: "hidden", enabled: false))
        #expect(!state.collectionVariables.contains { $0.key == "gone" })
        #expect(state.globals.first { $0.key == "count" }?.effectiveValue == "3")
        #expect(state.locals == ["temp": "local"])
        #expect(state.resolver.resolve("{{token}} {{temp}} {{shared}}").string == "Rex local from-collection")
    }

    @Test func preRequestScriptsCanChangeHeadersAndBody() {
        var state = RunState()
        var request = ScriptRequest(method: "POST", url: "https://example.com", headers: [.init(key: "X-Old", value: "1"), .init(key: "Accept", value: "*/*")], body: "{}")
        let outcome = run("""
        pm.request.headers.add({ key: "X-Signature", value: btoa("user:pass") });
        pm.request.headers.upsert({ key: "accept", value: "application/json" });
        pm.request.headers.remove("x-old");
        pm.request.body.raw = JSON.stringify({ at: 1 });
        console.log("method", pm.request.method, pm.request.url.getHost(), { a: 1 });
        console.warn("careful");
        pm.environment.set("decoded", atob("dXNlcjpwYXNz"));
        """, phase: .preRequest, state: &state, request: &request, response: nil)

        #expect(outcome.error == nil)
        #expect(request.headers == [.init(key: "Accept", value: "application/json"), .init(key: "X-Signature", value: "dXNlcjpwYXNz")])
        #expect(request.body == "{\"at\":1}")
        #expect(outcome.logs == ["method POST example.com {\"a\":1}", "warn: careful"])
        #expect(state.environment.first?.effectiveValue == "user:pass")
    }

    @Test func legacyApiStillWorks() {
        var state = RunState()
        var request = ScriptRequest(method: "GET", url: "https://example.com")
        let outcome = run("""
        var data = JSON.parse(responseBody);
        tests["Status is 200"] = responseCode.code === 200;
        tests["Has three pets"] = data.pets.length === 3;
        postman.setEnvironmentVariable("first", data.pets[0].name);
        """, state: &state, request: &request)
        #expect(outcome.error == nil)
        #expect(outcome.tests == [TestResult(name: "Status is 200", passed: true), TestResult(name: "Has three pets", passed: false)])
        #expect(state.environment.first?.effectiveValue == "Rex")
    }

    @Test func errorsAreReportedWithALine() {
        let thrown = run("var a = 1;\nundefinedFunction();")
        #expect(thrown.error?.contains("undefinedFunction") == true)
        #expect(thrown.error?.contains("line 2") == true)

        let syntax = run("this is not javascript")
        #expect(syntax.error != nil)

        let unsupported = run("pm.sendRequest('https://example.com', function () {});")
        #expect(unsupported.error?.contains("pm.sendRequest is not supported yet") == true)

        let library = run("const moment = require('moment');")
        #expect(library.error?.contains("require('moment') is not supported yet") == true)
    }

    @Test func scriptsRunInOrderEachInItsOwnScope() {
        var state = RunState()
        var request = ScriptRequest(method: "GET", url: "https://example.com")
        let outcome = ScriptRunner.run(
            scripts: ["const x = 1; pm.variables.set('order', 'a');", "  ", "const x = 2; pm.variables.set('order', pm.variables.get('order') + 'b');"],
            phase: .preRequest, requestName: "Sample", state: &state, request: &request
        )
        #expect(outcome.error == nil)
        #expect(state.locals["order"] == "ab")
    }

    @Test func skipRequest() {
        var state = RunState()
        var request = ScriptRequest(method: "GET", url: "https://example.com")
        #expect(run("pm.execution.skipRequest();", phase: .preRequest, state: &state, request: &request, response: nil).skipRequest)
    }
}

@Suite struct Executor {
    func withServer<T>(_ work: (String) async throws -> T) async throws -> T {
        let server = try EchoServer()
        try await server.start()
        defer { server.stop() }
        return try await work("http://127.0.0.1:\(server.port)")
    }

    @Test func runsScriptsAssertionsAndExtractionsAroundTheRequest() async throws {
        try await withServer { base in
            let request = RequestItem(
                name: "Create",
                method: "POST",
                url: "{{base}}/items",
                headers: [KeyValue(key: "X-Folder", value: "{{fromFolder}}")],
                body: .raw(text: "{\"n\": \"{{name}}\"}", contentType: "application/json"),
                preRequestScript: "pm.variables.set('name', 'Rex'); pm.request.headers.add({ key: 'X-Added', value: 'yes' });",
                testScript: """
                pm.test("echoed", () => {
                    const echo = pm.response.json();
                    pm.expect(echo.headers["x-added"]).to.equal("yes");
                    pm.expect(echo.headers["x-folder"]).to.equal("folder-ran");
                    pm.expect(pm.request.url.toString()).to.include("/items");
                    pm.expect(pm.environment.get("savedPath")).to.equal("/items");
                });
                pm.test("fails", () => pm.response.to.have.status(500));
                """,
                assertions: [
                    Assertion(source: ValueSource(kind: .status), op: .equals, expected: "200"),
                    Assertion(source: ValueSource(kind: .json, path: "$.body"), op: .contains, expected: "{{name}}"),
                    Assertion(source: ValueSource(kind: .json, path: "$.method"), op: .equals, expected: "GET"),
                    Assertion(source: ValueSource(kind: .status), op: .equals, expected: "999", enabled: false),
                ],
                extractions: [
                    Extraction(variable: "savedPath", source: ValueSource(kind: .json, path: "$.path")),
                    Extraction(variable: "missing", source: ValueSource(kind: .json, path: "$.nope")),
                ]
            )
            let folder = Folder(name: "F", preRequestScript: "pm.variables.set('fromFolder', 'folder-ran');", items: [.request(request)])
            let collection = APICollection(name: "C", testScript: "pm.test('collection test', () => {});", items: [.folder(folder)])

            var state = RunState(environment: [Variable(key: "base", value: base)])
            let result = await RequestExecutor().run(request, in: collection, state: &state)

            #expect(result.error == nil)
            #expect(result.scriptError == nil)
            #expect(result.response?.status == 200)
            #expect(result.tests.map(\.name) == [
                "Save $.nope as missing",
                "Status equals 200", "$.body contains Rex", "$.method equals GET",
                "collection test", "echoed", "fails",
            ])
            #expect(result.tests.map(\.passed) == [false, true, true, false, true, true, false], "\(result.tests)")
            #expect(!result.passed)
            #expect(result.failedTests.count == 3)
            #expect(state.environment.first { $0.key == "savedPath" }?.currentValue == "/items")
        }
    }

    @Test func chainingCarriesAValueToTheNextRequest() async throws {
        try await withServer { base in
            let login = RequestItem(name: "Login", url: "{{base}}/login", extractions: [
                Extraction(variable: "token", source: ValueSource(kind: .header, path: "X-Echo")),
            ])
            let next = RequestItem(name: "Use", url: "{{base}}/me", headers: [KeyValue(key: "X-Token", value: "{{token}}")],
                                   assertions: [Assertion(source: ValueSource(kind: .json, path: "$.headers.x-token"), op: .equals, expected: "yes")])
            let collection = APICollection(name: "C", items: [.request(login), .request(next)])

            var state = RunState(environment: [Variable(key: "base", value: base)])
            let executor = RequestExecutor()
            #expect(await executor.run(login, in: collection, state: &state).passed)
            let second = await executor.run(next, in: collection, state: &state)
            #expect(second.passed, "\(second.tests)")
        }
    }

    @Test func preRequestErrorStopsBeforeSending() async throws {
        let request = RequestItem(name: "Bad", url: "http://127.0.0.1:1/", preRequestScript: "nope();")
        var state = RunState()
        let result = await RequestExecutor().run(request, in: APICollection(items: [.request(request)]), state: &state)
        #expect(result.error?.hasPrefix("Pre-request script:") == true)
        #expect(result.prepared == nil)
        #expect(!result.passed)
    }

    @Test func testScriptErrorKeepsTheResponse() async throws {
        try await withServer { base in
            let request = RequestItem(name: "R", url: "\(base)/x", testScript: "pm.test('first', () => {}); nope();")
            var state = RunState()
            let result = await RequestExecutor().run(request, in: APICollection(items: [.request(request)]), state: &state)
            #expect(result.response?.status == 200)
            #expect(result.error == nil)
            #expect(result.scriptError?.contains("nope") == true)
            #expect(result.tests.map(\.name) == ["first"])
            #expect(!result.passed)
        }
    }

    @Test func skippedAndFailedRequests() async throws {
        let skip = RequestItem(name: "Skip", url: "http://127.0.0.1:1/", preRequestScript: "pm.execution.skipRequest();")
        var state = RunState()
        let skipped = await RequestExecutor().run(skip, in: APICollection(items: [.request(skip)]), state: &state)
        #expect(skipped.skipped)
        #expect(skipped.response == nil)

        let dead = RequestItem(name: "Dead", url: "http://127.0.0.1:1/")
        let failed = await RequestExecutor(options: HTTPOptions(timeout: 5)).run(dead, in: APICollection(items: [.request(dead)]), state: &state)
        #expect(failed.error != nil)
        #expect(!failed.passed)
    }

    @Test func requestsAndFoldersHelpers() {
        let a = RequestItem(name: "a"), b = RequestItem(name: "b"), c = RequestItem(name: "c")
        let inner = Folder(name: "inner", items: [.request(b)])
        let outer = Folder(name: "outer", items: [.request(a), .folder(inner)])
        let collection = APICollection(items: [.folder(outer), .request(c)])
        #expect(collection.requests(inFolder: nil).map(\.name) == ["a", "b", "c"])
        #expect(collection.requests(inFolder: outer.id).map(\.name) == ["a", "b"])
        #expect(collection.requests(inFolder: inner.id).map(\.name) == ["b"])
        #expect(collection.folders(containingRequest: b.id).map(\.name) == ["outer", "inner"])
        #expect(collection.folders(containingRequest: c.id).isEmpty)
    }

    @Test func assertionsAndExtractionsRoundTripThroughFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apiplayground-p2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root, secrets: InMemorySecretStore())
        let collection = APICollection(name: "T", items: [.request(RequestItem(
            name: "R",
            assertions: [Assertion(source: ValueSource(kind: .header, path: "X-A"), op: .exists, expected: "")],
            extractions: [Extraction(variable: "v", source: ValueSource(kind: .json, path: "$.a"), scope: .collection)]
        ))])
        try store.save(collection)
        #expect(try store.loadCollections() == [collection])
    }
}
