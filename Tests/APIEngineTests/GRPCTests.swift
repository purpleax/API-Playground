import Foundation
import Testing
@testable import APIEngine

// MARK: - Building descriptors by hand

private func part(_ build: (inout ProtoWriter) -> Void) -> Data {
    var writer = ProtoWriter()
    build(&writer)
    return writer.data
}

private func field(_ name: String, _ number: Int, _ type: ProtoType, repeated: Bool = false, typeName: String? = nil, oneof: Int? = nil, optional: Bool = false) -> Data {
    part { w in
        w.string(1, name)
        w.varintField(3, UInt64(number))
        w.varintField(4, repeated ? 3 : 1)
        w.varintField(5, UInt64(type.rawValue))
        if let typeName { w.string(6, typeName) }
        if let oneof { w.varintField(9, UInt64(oneof)) }
        if optional { w.varintField(17, 1) }
    }
}

private func message(_ name: String, _ fields: [Data], nested: [Data] = [], mapEntry: Bool = false) -> Data {
    part { w in
        w.string(1, name)
        for f in fields { w.bytes(2, f) }
        for n in nested { w.bytes(3, n) }
        if mapEntry { w.bytes(7, part { $0.varintField(7, 1) }) }
    }
}

/// A schema that uses every kind of field.
private func everythingSchema() throws -> ProtoSchema {
    let file = part { w in
        w.string(1, "everything.proto")
        w.string(2, "test")
        w.bytes(4, message("Everything", [
            field("a_double", 1, .double), field("a_float", 2, .float),
            field("an_int64", 3, .int64), field("a_uint64", 4, .uint64),
            field("an_int32", 5, .int32), field("a_fixed64", 6, .fixed64),
            field("a_fixed32", 7, .fixed32), field("a_bool", 8, .bool),
            field("a_string", 9, .string), field("some_bytes", 12, .bytes),
            field("a_uint32", 13, .uint32), field("a_colour", 14, .enumeration, typeName: ".test.Colour"),
            field("an_sfixed32", 15, .sfixed32), field("an_sfixed64", 16, .sfixed64),
            field("an_sint32", 17, .sint32), field("an_sint64", 18, .sint64),
            field("child", 20, .message, typeName: ".test.Everything.Child"),
            field("numbers", 21, .int32, repeated: true),
            field("names", 22, .string, repeated: true),
            field("children", 23, .message, repeated: true, typeName: ".test.Everything.Child"),
            field("counts", 24, .message, repeated: true, typeName: ".test.Everything.CountsEntry"),
            field("by_text", 25, .string, oneof: 0), field("by_number", 26, .int32, oneof: 0),
            field("maybe", 27, .int32, oneof: 1, optional: true),
            field("when", 28, .message, typeName: ".google.protobuf.Timestamp"),
            field("wait", 29, .message, typeName: ".google.protobuf.Duration"),
            field("wrapped", 30, .message, typeName: ".google.protobuf.StringValue"),
        ], nested: [
            message("Child", [field("label", 1, .string)]),
            message("CountsEntry", [field("key", 1, .string), field("value", 2, .int32)], mapEntry: true),
        ]))
        w.bytes(5, part { e in
            e.string(1, "Colour")
            e.bytes(2, part { $0.string(1, "COLOUR_UNSET"); $0.varintField(2, 0) })
            e.bytes(2, part { $0.string(1, "RED"); $0.varintField(2, 1) })
        })
        w.bytes(6, part { s in
            s.string(1, "Things")
            s.bytes(2, part { $0.string(1, "Get"); $0.string(2, ".test.Everything"); $0.string(3, ".test.Everything") })
            s.bytes(2, part { $0.string(1, "Watch"); $0.string(2, ".test.Everything"); $0.string(3, ".test.Everything"); $0.varintField(6, 1) })
        })
        w.string(12, "proto3")
    }
    let wellKnown = part { w in
        w.string(1, "google/protobuf/well_known.proto")
        w.string(2, "google.protobuf")
        w.bytes(4, message("Timestamp", [field("seconds", 1, .int64), field("nanos", 2, .int32)]))
        w.bytes(4, message("Duration", [field("seconds", 1, .int64), field("nanos", 2, .int32)]))
        w.bytes(4, message("StringValue", [field("value", 1, .string)]))
        w.string(12, "proto3")
    }
    var schema = ProtoSchema()
    try schema.add(fileDescriptor: file)
    try schema.add(fileDescriptor: wellKnown)
    return schema
}

@Suite struct ProtobufMessages {
    @Test func descriptorsAreRead() throws {
        let schema = try everythingSchema()
        #expect(schema.services.map(\.fullName) == ["test.Things"])
        #expect(schema.services[0].methods.map(\.id) == ["test.Things/Get", "test.Things/Watch"])
        #expect(schema.services[0].methods.map(\.kind) == ["Unary", "Server streaming"])
        #expect(schema.method("test.Things/Get")?.inputType == "test.Everything")
        #expect(schema.messages["test.Everything.CountsEntry"]?.isMapEntry == true)
        #expect(schema.enums["test.Colour"]?.values.map(\.name) == ["COLOUR_UNSET", "RED"])
        let fields = try #require(schema.messages["test.Everything"]?.fields)
        #expect(fields.first { $0.name == "an_int64" }?.jsonName == "anInt64")
        #expect(fields.first { $0.name == "maybe" }?.hasPresence == true)
        #expect(fields.first { $0.name == "maybe" }?.oneofIndex == nil)
        #expect(fields.first { $0.name == "by_text" }?.oneofIndex == 0)
        #expect(fields.first { $0.name == "a_string" }?.hasPresence == false)
    }

    @Test func aKnownMessageHasTheBytesTheSpecGives() throws {
        // The protobuf documentation's own example: field 1 set to 150 is 08 96 01.
        var schema = ProtoSchema()
        try schema.add(fileDescriptor: part { w in
            w.string(1, "t.proto")
            w.bytes(4, message("Test1", [field("a", 1, .int32)]))
            w.string(12, "proto3")
        })
        let json = ProtoJSON(schema: schema)
        #expect(try json.encode(json: #"{"a": 150}"#, as: "Test1") == Data([0x08, 0x96, 0x01]))
        #expect(try json.decode(Data([0x08, 0x96, 0x01]), as: "Test1").jsonText(pretty: false) == #"{"a":150}"#)
        // A negative int32 takes ten bytes.
        #expect(try json.encode(json: #"{"a": -1}"#, as: "Test1").count == 11)
        #expect(try json.decode(try json.encode(json: #"{"a": -1}"#, as: "Test1"), as: "Test1")["a"]?.double == -1)
    }

    @Test func everyKindOfFieldSurvivesARoundTrip() throws {
        let json = ProtoJSON(schema: try everythingSchema())
        let text = """
        {
          "aDouble": 1.5, "aFloat": -0.25,
          "anInt64": "-9007199254740993", "aUint64": "18446744073709551615",
          "anInt32": -42, "aFixed64": "7", "aFixed32": 4294967295, "aBool": true,
          "aString": "héllo ✓", "someBytes": "AAEC/w==",
          "aUint32": 4000000000, "aColour": "RED",
          "anSfixed32": -5, "anSfixed64": "-6", "anSint32": -7, "anSint64": "-8",
          "child": {"label": "one"},
          "numbers": [1, -2, 300],
          "names": ["a", ""],
          "children": [{"label": "x"}, {"label": ""}],
          "counts": {"apples": 3, "pears": 0},
          "byNumber": 9,
          "maybe": 0,
          "when": "2024-01-01T00:00:00.500Z",
          "wait": "-1.500s",
          "wrapped": "inside"
        }
        """
        let bytes = try json.encode(json: text, as: "test.Everything")
        let back = try json.decode(bytes, as: "test.Everything")
        let expected = try SpecParser.parse(text).root
        // Compare value by value: the decoded form writes whole numbers without a fraction.
        for entry in expected.entries {
            let got = try #require(back[entry.key], "missing \(entry.key)")
            #expect(got.jsonText(pretty: false) == entry.node.jsonText(pretty: false), "\(entry.key)")
        }
        // The oneof member that was not chosen is left out; an explicitly set optional zero is kept.
        #expect(back["byText"] == nil)
        #expect(back["maybe"]?.double == 0)
        #expect(back.entries.map(\.key).prefix(3) == ["aDouble", "aFloat", "anInt64"])
    }

    @Test func missingFieldsAreShownWithTheirDefaults() throws {
        let json = ProtoJSON(schema: try everythingSchema())
        let empty = try json.decode(Data(), as: "test.Everything")
        #expect(empty["aString"]?.string == "")
        #expect(empty["anInt64"]?.value == .string("0"))
        #expect(empty["aBool"]?.bool == false)
        #expect(empty["aColour"]?.string == "COLOUR_UNSET")
        #expect(empty["numbers"]?.isList == true)
        #expect(empty["counts"]?.isMap == true)
        // Messages, oneof members and optional fields have no default to show.
        #expect(empty["child"] == nil)
        #expect(empty["byText"] == nil)
        #expect(empty["maybe"] == nil)
    }

    @Test func packedAndUnpackedListsAreBothRead() throws {
        let json = ProtoJSON(schema: try everythingSchema())
        let unpacked = part { w in
            w.varintField(21, 1)
            w.varintField(21, 2)
        }
        let packed = part { w in w.bytes(21, Data([1, 2])) }
        #expect(try json.decode(unpacked, as: "test.Everything")["numbers"]?.items.compactMap(\.double) == [1, 2])
        #expect(try json.decode(packed, as: "test.Everything")["numbers"]?.items.compactMap(\.double) == [1, 2])
        // Fields the schema does not know are skipped, not fatal.
        let unknown = part { w in
            w.string(99, "?")
            w.varintField(5, 3)
        }
        #expect(try json.decode(unknown, as: "test.Everything")["anInt32"]?.double == 3)
    }

    @Test func mistakesInAMessageAreExplained() throws {
        let json = ProtoJSON(schema: try everythingSchema())
        func message(_ text: String) -> String {
            do {
                _ = try json.encode(json: text, as: "test.Everything")
                return "no error"
            } catch {
                return error.localizedDescription
            }
        }
        #expect(message(#"{"nope": 1}"#).hasPrefix("test.Everything has no field “nope”. Its fields are: aDouble,"))
        #expect(message(#"{"anInt32": "x"}"#) == "anInt32: expected a whole number that fits int32, but found \"x\".")
        #expect(message(#"{"anInt32": 3000000000}"#).contains("fits int32"))
        #expect(message(#"{"child": {"label": 5, "extra": 1}}"#).hasPrefix("child: test.Everything.Child has no field “extra”."))
        #expect(message(#"{"children": {"label": "x"}}"#) == "children: expected a list, written with [ ].")
        #expect(message(#"{"aColour": "BLUE"}"#).contains("one of COLOUR_UNSET, RED"))
        #expect(message(#"{"byText": "a", "byNumber": 1}"#).contains("cannot both be set"))
        #expect(message(#"{"when": "yesterday"}"#).contains("not a valid timestamp"))
        #expect(message(#"{"aString": "#).hasPrefix("The message is not valid JSON."))
        // The .proto names are accepted as well as the JSON ones, and null means "leave out".
        #expect(message(#"{"an_int32": 1, "child": null}"#) == "no error")
    }

    @Test func aTemplateHasEveryFieldReadyToFillIn() throws {
        let json = ProtoJSON(schema: try everythingSchema())
        let template = json.template(for: "test.Everything")
        #expect(template["aString"]?.string == "")
        #expect(template["aColour"]?.string == "COLOUR_UNSET")
        #expect(template["child"]?["label"]?.string == "")
        #expect(template["numbers"]?.items.count == 1)
        #expect(template["counts"]?["key"]?.double == 0)
        #expect(template["byText"] != nil)
        #expect(template["byNumber"] == nil)
        #expect(template["when"]?.string == "2024-01-01T00:00:00Z")
        // A template is itself a valid message.
        _ = try json.encode(template, as: "test.Everything")
    }

    @Test func aSchemaCanBeSavedAndReadBack() throws {
        let schema = try everythingSchema()
        let restored = try ProtoSchema(fileDescriptorSet: schema.fileDescriptorSet)
        #expect(restored.services == schema.services)
        #expect(restored.messages == schema.messages)
        #expect(throws: ProtobufError.self) { try ProtoSchema(fileDescriptorSet: Data()) }
    }
}

@Suite struct GRPCBasics {
    @Test func addressesAreRead() {
        #expect(GRPCTarget("grpc://localhost:50051") == GRPCTarget(host: "localhost", port: 50051, tls: false))
        #expect(GRPCTarget("grpcs://api.example.com") == GRPCTarget(host: "api.example.com", port: 443, tls: true))
        #expect(GRPCTarget("https://api.example.com:8443/ignored") == GRPCTarget(host: "api.example.com", port: 8443, tls: true))
        #expect(GRPCTarget("127.0.0.1:9000") == GRPCTarget(host: "127.0.0.1", port: 9000, tls: false))
        #expect(GRPCTarget("grpc://[::1]:9000") == GRPCTarget(host: "[::1]", port: 9000, tls: false))
        #expect(GRPCTarget("grpc://host:notaport") == nil)
        #expect(GRPCTarget("  ") == nil)
        #expect(GRPCTarget("grpcs://x:1")?.display == "grpcs://x:1")
    }

    @Test func messagesAreFramedAndSplitAcrossChunks() throws {
        let framed = GRPCClient.frame(Data([1, 2, 3])) + GRPCClient.frame(Data()) + GRPCClient.frame(Data([9]))
        #expect(framed.prefix(5) == Data([0, 0, 0, 0, 3]))
        let parser = GRPCFrameParser()
        var messages: [Data] = []
        // Fed two bytes at a time, as a slow network would deliver it.
        for start in stride(from: 0, to: framed.count, by: 2) {
            messages += try parser.feed(framed.subdata(in: start..<min(start + 2, framed.count)))
        }
        #expect(messages == [Data([1, 2, 3]), Data(), Data([9])])
        #expect(parser.leftover == 0)
        #expect(throws: GRPCError.self) { try GRPCFrameParser().feed(Data([1, 0, 0, 0, 0])) }
    }

    @Test func statusCodesHaveNames() {
        #expect(GRPCStatus.name(0) == "OK")
        #expect(GRPCStatus.name(5) == "NOT_FOUND")
        #expect(GRPCStatus.name(16) == "UNAUTHENTICATED")
        #expect(GRPCStatus.name(99) == "STATUS_99")
    }
}

// MARK: - Against a real server

/// The test server in Tests/Support, run with Node. These tests are skipped where Node is not installed.
private final class TestServer {
    static let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }

    let process = Process()
    let target: GRPCTarget

    init(arguments: [String] = []) throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/grpc-test-server.js")
        process.executableURL = URL(fileURLWithPath: try #require(Self.node))
        process.arguments = [script.path, "0"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // The server prints its port once it is listening.
        var text = ""
        while !text.contains("\n") {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            text += String(decoding: chunk, as: UTF8.self)
        }
        let port = try #require(Int(text.replacingOccurrences(of: "PORT ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)))
        target = GRPCTarget(host: "127.0.0.1", port: port, tls: false)
    }

    deinit {
        process.terminate()
    }
}

@Suite(.enabled(if: TestServer.node != nil, "Node is needed to run the test gRPC server"))
struct GRPCCalls {
    let client = GRPCClient()

    @Test func aServerDescribesItselfThroughReflection() async throws {
        let server = try TestServer()
        let schema = try await client.reflect(server.target)
        #expect(schema.services.map(\.fullName) == ["demo.Greeter"])
        #expect(schema.services[0].methods.map(\.name) == ["SayHello", "Countdown", "Collect", "Fail"])
        #expect(schema.services[0].methods.map(\.kind) == ["Unary", "Server streaming", "Client streaming", "Unary"])
        // The imported timestamp file was not sent with the service, so it had to be asked for.
        #expect(schema.files == ["demo.proto", "google/protobuf/timestamp.proto"])
        #expect(schema.messages["google.protobuf.Timestamp"] != nil)
    }

    @Test func theOlderReflectionServiceIsTriedToo() async throws {
        let server = try TestServer(arguments: ["alpha"])
        let schema = try await client.reflect(server.target)
        #expect(schema.services.map(\.fullName) == ["demo.Greeter"])
    }

    @Test func aUnaryCallSendsJSONAndReadsJSON() async throws {
        let server = try TestServer()
        let json = ProtoJSON(schema: try await client.reflect(server.target))
        let request = try json.encode(json: #"{"name": "Guy", "times": 3}"#, as: "demo.HelloRequest")
        let result = try await client.call(
            server.target, method: "demo.Greeter/SayHello", messages: [request],
            metadata: [HTTPHeader(name: "X-Token", value: "abc")]
        )
        #expect(result.status == 0)
        #expect(result.statusName == "OK")
        #expect(result.messages.count == 1)
        let reply = try json.decode(result.messages[0], as: "demo.HelloReply")
        #expect(reply.jsonText(pretty: false) == #"{"message":"Hello, Guy","count":"3","mood":"HAPPY","tags":["abc"],"scores":{"a":1},"sentAt":"2024-01-01T00:00:00.500Z"}"#)
        #expect(result.headers.contains { $0.name.lowercased() == "grpc-status" })
        #expect(result.timings.total > 0)
    }

    @Test func aServerStreamArrivesMessageByMessage() async throws {
        let server = try TestServer()
        let json = ProtoJSON(schema: try await client.reflect(server.target))
        let seen = Counter()
        let result = try await client.call(
            server.target, method: "demo.Greeter/Countdown",
            messages: [try json.encode(json: #"{"times": 3}"#, as: "demo.HelloRequest")],
            onMessage: { _ in seen.add() }
        )
        #expect(result.status == 0)
        #expect(try result.messages.map { try json.decode($0, as: "demo.HelloReply")["message"]?.string } == ["3", "2", "1"])
        #expect(seen.value == 3)
    }

    @Test func aClientStreamSendsEveryMessage() async throws {
        let server = try TestServer()
        let json = ProtoJSON(schema: try await client.reflect(server.target))
        let requests = try ["a", "b", "c"].map { try json.encode(json: #"{"name": "\#($0)"}"#, as: "demo.HelloRequest") }
        let result = try await client.call(server.target, method: "demo.Greeter/Collect", messages: requests)
        let reply = try json.decode(try #require(result.messages.first), as: "demo.HelloReply")
        #expect(reply["message"]?.string == "a+b+c")
        #expect(reply["count"]?.string == "3")
    }

    @Test func aFailedCallReportsItsStatus() async throws {
        let server = try TestServer()
        let failed = try await client.call(server.target, method: "demo.Greeter/Fail", messages: [Data()])
        #expect(failed.status == 5)
        #expect(failed.statusName == "NOT_FOUND")
        #expect(failed.statusMessage == "No such pet: 100% gone")
        #expect(failed.messages.isEmpty)

        let missing = try await client.call(server.target, method: "demo.Greeter/Nope", messages: [Data()])
        #expect(missing.status == 12)
    }

    @Test func aServerThatIsNotThereIsExplained() async throws {
        // Start a server to get a free port, then stop it.
        var server: TestServer? = try TestServer()
        let target = try #require(server?.target)
        server = nil
        try await Task.sleep(for: .milliseconds(200))
        do {
            _ = try await client.call(target, method: "demo.Greeter/SayHello", messages: [Data()])
            Issue.record("Expected an error")
        } catch let error as GRPCError {
            #expect(error.message.hasPrefix("Could not connect to grpc://127.0.0.1:"))
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// gRPC requests run through the same executor as HTTP ones, so scripts, saved values,
/// checks and the runner treat them alike.
@Suite(.enabled(if: TestServer.node != nil, "Node is needed to run the test gRPC server"))
struct GRPCThroughTheExecutor {
    private func collection(_ request: RequestItem) -> APICollection {
        APICollection(name: "Greeter", auth: .none, items: [.request(request)])
    }

    @Test func scriptsSavedValuesAndChecksRunAroundACall() async throws {
        let server = try TestServer()
        let request = RequestItem(
            name: "Say hello", method: "GRPC", url: "{{address}}",
            headers: [KeyValue(key: "X-Token", value: "{{token}}")],
            body: .raw(text: #"{"name": "{{who}}", "times": 2}"#, contentType: "application/json"),
            preRequestScript: #"pm.environment.set("who", "Ada");"#,
            testScript: #"pm.test("greets by name", () => pm.expect(pm.response.json().message).to.eql("Hello, Ada"));"#,
            assertions: [Assertion(source: ValueSource(kind: .status), op: .equals, expected: "0")],
            extractions: [Extraction(variable: "greeting", source: ValueSource(kind: .json, path: "$.message"))],
            grpcMethod: "demo.Greeter/SayHello"
        )
        var state = RunState(environment: [
            Variable(key: "address", value: server.target.display), Variable(key: "token", value: "t-1"),
        ])
        let result = await RequestExecutor().run(request, in: collection(request), state: &state)
        #expect(result.error == nil)
        #expect(result.scriptError == nil)
        #expect(result.tests.count == 2)
        #expect(result.passed)
        #expect(result.response?.httpVersion == "gRPC")
        #expect(result.response?.text?.contains(#""tags": ["#) == true)
        #expect(result.response?.text?.contains("t-1") == true)
        #expect(result.prepared?.url == "\(server.target.display)/demo.Greeter/SayHello")
        #expect(state.resolver.resolve("{{greeting}}").string == "Hello, Ada")
    }

    @Test func aServerStreamIsHandedOverAsEvents() async throws {
        let server = try TestServer()
        let request = RequestItem(
            name: "Countdown", method: "GRPC", url: server.target.display,
            body: .raw(text: #"{"times": 3}"#, contentType: "application/json"),
            grpcMethod: "demo.Greeter/Countdown"
        )
        final class Collected: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            var started = false
            func add(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
            var events: [ServerSentEvent] { lock.lock(); defer { lock.unlock() }; return ServerSentEventParser.events(in: data) }
        }
        let collected = Collected()
        var state = RunState()
        let result = await RequestExecutor().run(
            request, in: collection(request), state: &state,
            handlers: HTTPStreamHandlers(onHeaders: { _, _ in collected.started = true }, onData: { collected.add($0) })
        )
        #expect(result.error == nil)
        #expect(collected.started)
        #expect(collected.events.count == 3)
        #expect(collected.events.first?.data.contains(#""message":"3""#) == true)
    }

    @Test func mistakesComeBackAsTheReasonTheCallWasNotMade() async throws {
        let server = try TestServer()
        var state = RunState()
        var request = RequestItem(name: "No method", method: "GRPC", url: server.target.display, grpcMethod: "")
        var result = await RequestExecutor().run(request, in: collection(request), state: &state)
        #expect(result.error == "Choose a method to call.")

        request.grpcMethod = "demo.Greeter/SayHello"
        request.body = .raw(text: "[1, 2]", contentType: nil)
        result = await RequestExecutor().run(request, in: collection(request), state: &state)
        #expect(result.error?.contains("takes one message") == true)

        request.url = "not an address"
        result = await RequestExecutor().run(request, in: collection(request), state: &state)
        #expect(result.error?.contains("address is not valid") == true)
    }

    @Test func aSavedSchemaIsUsedInsteadOfAskingTheServer() async throws {
        let server = try TestServer()
        let schema = try await GRPCClient().reflect(server.target)
        var executor = RequestExecutor()
        final class Count: @unchecked Sendable { var asked = 0 }
        let count = Count()
        executor.grpcSchema = { _, _ in
            count.asked += 1
            return schema
        }
        let request = RequestItem(
            name: "Say hello", method: "GRPC", url: server.target.display,
            body: .raw(text: #"{"name": "Bo"}"#, contentType: nil), grpcMethod: "demo.Greeter/SayHello"
        )
        var state = RunState()
        let result = await executor.run(request, in: collection(request), state: &state)
        #expect(result.response?.status == 0)
        #expect(count.asked == 1)
    }
}
