import Foundation

/// Where a gRPC server is: `grpc://localhost:50051` without TLS, `grpcs://api.example.com` with it.
public struct GRPCTarget: Equatable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var tls: Bool

    public init(host: String, port: Int, tls: Bool) {
        self.host = host
        self.port = port
        self.tls = tls
    }

    /// Reads an address. `http://` and `https://` are accepted as well, and an address with
    /// no scheme is taken to have no TLS.
    public init?(_ address: String) {
        var rest = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var tls = false
        for (scheme, secure) in [("grpcs://", true), ("https://", true), ("grpc://", false), ("http://", false)] where rest.lowercased().hasPrefix(scheme) {
            rest = String(rest.dropFirst(scheme.count))
            tls = secure
            break
        }
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
        guard !rest.isEmpty, !rest.contains(" "), !rest.contains("://") else { return nil }
        var host = rest
        var port = tls ? 443 : 80
        // "[::1]:50051" keeps its brackets; "host:50051" splits at the last colon.
        if let colon = rest.lastIndex(of: ":"), !rest[colon...].contains("]") {
            guard let number = Int(rest[rest.index(after: colon)...]), (1...65535).contains(number) else { return nil }
            host = String(rest[..<colon])
            port = number
        }
        guard !host.isEmpty else { return nil }
        self.init(host: host, port: port, tls: tls)
    }

    /// The address as libcurl is given it.
    public var baseURL: String { "\(tls ? "https" : "http")://\(host):\(port)" }

    public var display: String { "\(tls ? "grpcs" : "grpc")://\(host):\(port)" }
}

public struct GRPCError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum GRPCStatus {
    public static let names = [
        "OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED", "NOT_FOUND", "ALREADY_EXISTS",
        "PERMISSION_DENIED", "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION", "ABORTED", "OUT_OF_RANGE",
        "UNIMPLEMENTED", "INTERNAL", "UNAVAILABLE", "DATA_LOSS", "UNAUTHENTICATED",
    ]

    public static func name(_ code: Int) -> String {
        names.indices.contains(code) ? names[code] : "STATUS_\(code)"
    }
}

public struct GRPCResult: Sendable {
    /// The gRPC status code: 0 is OK.
    public var status: Int
    public var statusMessage: String
    /// Each message the server sent, still as protobuf bytes.
    public var messages: [Data]
    /// The response's headers followed by its trailers.
    public var headers: [HTTPHeader]
    public var timings: HTTPTimings
    public var remoteAddress: String?
    public var wireLog: [WireLogEntry]
    public var wasCancelled: Bool

    public var statusName: String { GRPCStatus.name(status) }
}

/// Splits a gRPC body into messages as it arrives. Each is one flag byte, a four-byte
/// length, and that many bytes.
final class GRPCFrameParser: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ chunk: Data) throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var messages: [Data] = []
        while buffer.count >= 5 {
            let start = buffer.startIndex
            let length = (1...4).reduce(0) { $0 << 8 | Int(buffer[start + $1]) }
            guard buffer.count >= 5 + length else { break }
            guard buffer[start] == 0 else {
                throw GRPCError("The server compressed its reply, which is not supported. Ask it for uncompressed messages.")
            }
            messages.append(buffer.subdata(in: (start + 5)..<(start + 5 + length)))
            buffer.removeSubrange(start..<(start + 5 + length))
        }
        return messages
    }

    var leftover: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }
}

/// Calls gRPC methods over HTTP/2 with libcurl.
///
/// Every request message is sent before any reply is read. That covers unary and
/// server-streaming calls fully, and client-streaming and two-way calls whose messages
/// are all known in advance; it cannot hold a conversation that reacts to replies.
public struct GRPCClient: Sendable {
    public var http = HTTPClient()

    public init() {}

    public init(http: HTTPClient) {
        self.http = http
    }

    public static func frame(_ message: Data) -> Data {
        var out = Data([0])
        let length = UInt32(message.count)
        out.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        out.append(message)
        return out
    }

    /// - Parameters:
    ///   - method: The full method name, such as `helloworld.Greeter/SayHello`.
    ///   - messages: The request messages, as protobuf bytes.
    ///   - metadata: Extra headers, such as `authorization`.
    ///   - onMessage: Called with each reply as it arrives, on any thread.
    public func call(
        _ target: GRPCTarget, method: String, messages: [Data], metadata: [HTTPHeader] = [],
        options: HTTPOptions = HTTPOptions(), onMessage: (@Sendable (Data) -> Void)? = nil, cancellation: CancellationFlag? = nil
    ) async throws -> GRPCResult {
        var headers = [
            HTTPHeader(name: "content-type", value: "application/grpc"),
            HTTPHeader(name: "te", value: "trailers"),
            HTTPHeader(name: "grpc-accept-encoding", value: "identity"),
            HTTPHeader(name: "user-agent", value: "grpc-apiplayground/0.1"),
        ]
        let reserved = Set(headers.map(\.name) + ["host", "content-length", "accept-encoding"])
        headers += metadata.filter { !reserved.contains($0.name.lowercased()) }.map { HTTPHeader(name: $0.name.lowercased(), value: $0.value) }

        var options = options
        options.followRedirects = false
        options.version = target.tls ? .http2 : .http2PriorKnowledge
        let request = PreparedRequest(
            method: "POST", url: "\(target.baseURL)/\(method.drop { $0 == "/" })",
            headers: headers, body: messages.reduce(into: Data()) { $0.append(Self.frame($1)) }
        )

        let parser = GRPCFrameParser()
        let failure = FailureBox()
        let handlers = HTTPStreamHandlers(onData: { chunk in
            do {
                for message in try parser.feed(chunk) { onMessage?(message) }
            } catch {
                failure.set(error)
            }
        })
        // The frames are parsed a second time below, from the whole body, to return them.
        let response: HTTPResponse
        do {
            response = try await http.send(request, options: options, handlers: handlers, cancellation: cancellation)
        } catch let error as HTTPClientError {
            throw GRPCError(Self.explain(error, target: target))
        }
        if let error = failure.error { throw error }

        let contentType = response.header("content-type") ?? ""
        guard response.status == 200, contentType.lowercased().hasPrefix("application/grpc") else {
            throw GRPCError("\(target.display) did not answer as a gRPC server: it sent HTTP \(response.status)\(contentType.isEmpty ? "" : " with \(contentType)"). Check the address and port.")
        }
        let replies = try GRPCFrameParser().feed(response.body)

        var status = 2
        var statusMessage = "The server ended the call without saying how it went."
        if let code = response.header("grpc-status").flatMap({ Int($0) }) {
            status = code
            statusMessage = response.header("grpc-message")?.removingPercentEncoding ?? response.header("grpc-message") ?? ""
        } else if response.wasCancelled {
            status = 1
            statusMessage = "Stopped before the server finished."
        }
        return GRPCResult(
            status: status, statusMessage: statusMessage, messages: replies, headers: response.headers,
            timings: response.timings, remoteAddress: response.remoteAddress, wireLog: response.wireLog, wasCancelled: response.wasCancelled
        )
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?
        func set(_ error: Error) {
            lock.lock()
            if stored == nil { stored = error }
            lock.unlock()
        }
        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private static func explain(_ error: HTTPClientError, target: GRPCTarget) -> String {
        let hint = target.tls
            ? "If the server does not use TLS, use grpc:// in place of grpcs://."
            : "If the server uses TLS, use grpcs:// in place of grpc://."
        // 7: could not connect. 16: HTTP/2 framing. 35: TLS handshake. 52: empty reply. 56: receive failure.
        switch error.code {
        case 7: return "Could not connect to \(target.display). Check that the server is running and the port is right."
        case 16, 35, 52, 56, 92: return "\(target.display) did not speak gRPC as expected (\(error.message)). \(hint)"
        default: return error.message
        }
    }

    // MARK: Reflection

    private static let reflectionServices = ["grpc.reflection.v1.ServerReflection", "grpc.reflection.v1alpha.ServerReflection"]

    private enum ReflectionRequest {
        case listServices
        case fileContainingSymbol(String)
        case fileByName(String)

        var data: Data {
            var writer = ProtoWriter()
            switch self {
            case .listServices: writer.string(7, "*")
            case .fileContainingSymbol(let symbol): writer.string(4, symbol)
            case .fileByName(let name): writer.string(3, name)
            }
            return writer.data
        }
    }

    private struct ReflectionReply {
        var services: [String] = []
        var descriptors: [Data] = []
        var error: String?

        init(_ data: Data) throws {
            var reader = ProtoReader(data)
            while !reader.isAtEnd {
                let (field, wire) = try reader.tag()
                switch (field, wire) {
                case (4, 2):
                    var inner = ProtoReader(try reader.bytes())
                    while !inner.isAtEnd {
                        let (innerField, innerWire) = try inner.tag()
                        if innerField == 1, innerWire == 2 { descriptors.append(try inner.bytes()) } else { try inner.skip(wire: innerWire) }
                    }
                case (6, 2):
                    var inner = ProtoReader(try reader.bytes())
                    while !inner.isAtEnd {
                        let (innerField, innerWire) = try inner.tag()
                        guard innerField == 1, innerWire == 2 else {
                            try inner.skip(wire: innerWire)
                            continue
                        }
                        var service = ProtoReader(try inner.bytes())
                        while !service.isAtEnd {
                            let (serviceField, serviceWire) = try service.tag()
                            if serviceField == 1, serviceWire == 2 {
                                services.append(String(decoding: try service.bytes(), as: UTF8.self))
                            } else {
                                try service.skip(wire: serviceWire)
                            }
                        }
                    }
                case (7, 2):
                    var inner = ProtoReader(try reader.bytes())
                    while !inner.isAtEnd {
                        let (innerField, innerWire) = try inner.tag()
                        if innerField == 2, innerWire == 2 { error = String(decoding: try inner.bytes(), as: UTF8.self) } else { try inner.skip(wire: innerWire) }
                    }
                default:
                    try reader.skip(wire: wire)
                }
            }
        }
    }

    /// Asks a server to describe its services, using gRPC server reflection.
    public func reflect(_ target: GRPCTarget, metadata: [HTTPHeader] = [], options: HTTPOptions = HTTPOptions()) async throws -> ProtoSchema {
        for service in Self.reflectionServices {
            let method = "\(service)/ServerReflectionInfo"
            func ask(_ requests: [ReflectionRequest]) async throws -> (status: Int, message: String, replies: [ReflectionReply]) {
                let result = try await call(target, method: method, messages: requests.map(\.data), metadata: metadata, options: options)
                return (result.status, result.statusMessage, try result.messages.map { try ReflectionReply($0) })
            }

            let listed = try await ask([.listServices])
            // Unimplemented: this server has the other version of the reflection service, or none.
            if listed.status == 12 { continue }
            guard listed.status == 0 else {
                throw GRPCError("The server refused to describe itself: \(GRPCStatus.name(listed.status))\(listed.message.isEmpty ? "" : " (\(listed.message))").")
            }
            let names = listed.replies.flatMap(\.services).filter { !$0.hasPrefix("grpc.reflection.") }
            guard !names.isEmpty else {
                throw GRPCError("The server answered, but lists no services of its own.")
            }

            var schema = ProtoSchema()
            let files = try await ask(names.map { .fileContainingSymbol($0) })
            for reply in files.replies {
                for descriptor in reply.descriptors { try schema.add(fileDescriptor: descriptor) }
            }
            // Fetch any imported files the server did not send along.
            for _ in 0..<8 {
                let missing = schema.missingFiles
                if missing.isEmpty { break }
                let more = try await ask(missing.map { .fileByName($0) })
                let before = schema.files.count
                for reply in more.replies {
                    for descriptor in reply.descriptors { try schema.add(fileDescriptor: descriptor) }
                }
                if schema.files.count == before { break }
            }
            guard !schema.services.isEmpty else {
                throw GRPCError("The server listed its services but did not send their descriptions.")
            }
            return schema
        }
        throw GRPCError("This server does not offer reflection, so its services cannot be listed. Load a descriptor set file for it instead (made with “protoc --descriptor_set_out” or “buf build -o”).")
    }
}
