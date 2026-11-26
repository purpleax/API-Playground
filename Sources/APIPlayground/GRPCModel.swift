import APIEngine
import AppKit
import Foundation

/// Something to tell the user about a gRPC request's schema.
struct GRPCNote: Equatable {
    var text: String
    var isError = false
}

extension AppModel {
    private static var grpcCacheDirectory: URL {
        supportDirectory.appendingPathComponent("gRPC Schemas", isDirectory: true)
    }

    private static func cacheFile(for target: GRPCTarget) -> URL {
        let name = target.display.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return grpcCacheDirectory.appendingPathComponent(String(name) + ".protoset")
    }

    func newGRPCRequest() {
        newRequestInCurrentCollection(RequestItem(
            name: "New gRPC Request", method: "GRPC", url: "grpc://localhost:50051",
            body: .raw(text: "{}", contentType: "application/json"),
            assertions: [Assertion(source: ValueSource(kind: .status), op: .equals, expected: "0")],
            grpcMethod: ""
        ))
    }

    /// The server a gRPC request is addressed to, with variables filled in.
    func grpcTarget(_ id: UUID) -> GRPCTarget? {
        guard let index = collectionIndex(containingRequest: id), let request = collections[index].request(id: id) else { return nil }
        return GRPCTarget(resolver(forCollection: index).resolve(request.url).string)
    }

    /// What is known about a request's server: from this session, or saved from an earlier one.
    func grpcSchema(_ id: UUID) -> ProtoSchema? {
        guard let target = grpcTarget(id) else { return nil }
        if let schema = grpcSchemas[target.display] { return schema }
        guard let data = try? Data(contentsOf: Self.cacheFile(for: target)), let schema = try? ProtoSchema(fileDescriptorSet: data) else { return nil }
        // Remember it after this pass, because views call this while they are being drawn.
        Task { @MainActor in if self.grpcSchemas[target.display] == nil { self.grpcSchemas[target.display] = schema } }
        return schema
    }

    private func keep(_ schema: ProtoSchema, for target: GRPCTarget) {
        grpcSchemas[target.display] = schema
        try? FileManager.default.createDirectory(at: Self.grpcCacheDirectory, withIntermediateDirectories: true)
        try? schema.fileDescriptorSet.write(to: Self.cacheFile(for: target), options: .atomic)
    }

    /// The metadata a gRPC request sends: its own headers, and its auth.
    private func grpcMetadata(_ request: RequestItem, collectionIndex index: Int) -> [HTTPHeader] {
        var stand = request
        stand.url = "http://grpc.invalid"
        stand.method = "POST"
        stand.body = .none
        stand.params = []
        let auth = collections[index].effectiveAuth(forRequest: request.id)
        let prepared = try? RequestBuilder.prepare(stand, auth: auth, resolver: resolver(forCollection: index))
        let unwanted: Set<String> = ["user-agent", "accept", "accept-encoding", "content-type", "content-length", "host", "cookie"]
        return (prepared?.headers ?? []).filter { !unwanted.contains($0.name.lowercased()) }
    }

    private static func count(_ schema: ProtoSchema) -> String {
        let methods = schema.services.reduce(0) { $0 + $1.methods.count }
        return "\(methods) \(methods == 1 ? "method" : "methods") in \(schema.services.count) \(schema.services.count == 1 ? "service" : "services")"
    }

    /// Asks the request's server to describe its services.
    @discardableResult
    func loadGRPCSchema(_ id: UUID) async -> ProtoSchema? {
        guard let index = collectionIndex(containingRequest: id), let request = collections[index].request(id: id) else { return nil }
        guard let target = grpcTarget(id) else {
            grpcNotes[id] = GRPCNote(text: "The address is not valid. Use grpc://host:port, or grpcs:// for a server with TLS.", isError: true)
            return nil
        }
        guard !grpcLoading.contains(id) else { return nil }
        grpcLoading.insert(id)
        defer { grpcLoading.remove(id) }
        let metadata = grpcMetadata(request, collectionIndex: index)
        do {
            let schema = try await GRPCClient().reflect(target, metadata: metadata, options: executor.options(for: target.baseURL))
            keep(schema, for: target)
            grpcNotes[id] = GRPCNote(text: "\(target.display) described \(Self.count(schema)).")
            return schema
        } catch {
            grpcNotes[id] = GRPCNote(text: error.localizedDescription, isError: true)
            return nil
        }
    }

    /// Reads the services from a descriptor set file, for a server that does not offer reflection.
    func chooseGRPCDescriptor(_ id: UUID) {
        guard let target = grpcTarget(id) else {
            grpcNotes[id] = GRPCNote(text: "Enter the server's address first, so the file can be remembered for it.", isError: true)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Load"
        panel.message = "Choose a descriptor set: a file made with “protoc --include_imports --descriptor_set_out=FILE” or “buf build -o FILE”."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let schema = try ProtoSchema(fileDescriptorSet: try Data(contentsOf: url))
            guard !schema.services.isEmpty else { throw ProtobufError("The file describes messages but no services.") }
            keep(schema, for: target)
            grpcNotes[id] = GRPCNote(text: "\(url.lastPathComponent) describes \(Self.count(schema)).")
        } catch {
            grpcNotes[id] = GRPCNote(text: "\(url.lastPathComponent) could not be used: \(error.localizedDescription) A .proto file must be compiled to a descriptor set first.", isError: true)
        }
    }

    /// Chooses the method a request calls, and starts its message from a template if it has none.
    func setGRPCMethod(_ id: UUID, to method: ProtoMethod) {
        guard var request = request(id), let schema = grpcSchema(id) else { return }
        request.grpcMethod = method.id
        var isBlank = true
        if case .raw(let text, _) = request.body {
            let stripped = text.filter { !$0.isWhitespace }
            isBlank = stripped.isEmpty || stripped == "{}"
        }
        if isBlank {
            request.body = .raw(text: ProtoJSON(schema: schema).template(for: method.inputType).jsonText(), contentType: "application/json")
        }
        if request.name == "New gRPC Request" { request.name = method.name }
        update(request)
    }

    /// Replaces the message with one that has every field of the method's input, ready to fill in.
    func fillGRPCExample(_ id: UUID) {
        guard var request = request(id), let schema = grpcSchema(id), let method = schema.method(request.grpcMethod ?? "") else { return }
        var template = ProtoJSON(schema: schema).template(for: method.inputType)
        // A client stream sends a list of messages.
        if method.clientStreaming { template = SpecNode(.list([template])) }
        request.body = .raw(text: template.jsonText(), contentType: "application/json")
        update(request)
    }

    /// What a server offers, for the request engine: from this session, from the copy
    /// saved earlier, or by asking the server.
    func schema(for target: GRPCTarget, metadata: [HTTPHeader]) async throws -> ProtoSchema {
        if let schema = grpcSchemas[target.display] { return schema }
        if let data = try? Data(contentsOf: Self.cacheFile(for: target)), let schema = try? ProtoSchema(fileDescriptorSet: data) {
            grpcSchemas[target.display] = schema
            return schema
        }
        let schema = try await GRPCClient().reflect(target, metadata: metadata, options: executor.options(for: target.baseURL))
        keep(schema, for: target)
        return schema
    }
}
