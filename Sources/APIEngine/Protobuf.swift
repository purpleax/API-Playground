import Foundation

public struct ProtobufError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - The wire format

/// Reads protobuf's wire format: a run of numbered fields, each a varint, a fixed-size
/// number, or a length followed by that many bytes.
struct ProtoReader {
    let data: Data
    var position: Int

    init(_ data: Data) {
        self.data = data
        position = data.startIndex
    }

    var isAtEnd: Bool { position >= data.endIndex }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while position < data.endIndex {
            let byte = data[position]
            position += 1
            if shift < 64 { result |= UInt64(byte & 0x7F) << shift }
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 70 { break }
        }
        throw ProtobufError("The message ends in the middle of a number.")
    }

    mutating func tag() throws -> (field: Int, wire: Int) {
        let value = try varint()
        return (Int(value >> 3), Int(value & 7))
    }

    mutating func bytes() throws -> Data {
        let length = Int(try varint())
        guard length >= 0, position + length <= data.endIndex else {
            throw ProtobufError("A field says it is longer than the message that holds it.")
        }
        defer { position += length }
        return data.subdata(in: position..<(position + length))
    }

    mutating func fixed32() throws -> UInt32 {
        guard position + 4 <= data.endIndex else { throw ProtobufError("The message ends in the middle of a number.") }
        defer { position += 4 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[position + $1]) << (8 * UInt32($1)) }
    }

    mutating func fixed64() throws -> UInt64 {
        guard position + 8 <= data.endIndex else { throw ProtobufError("The message ends in the middle of a number.") }
        defer { position += 8 }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[position + $1]) << (8 * UInt64($1)) }
    }

    mutating func skip(wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: _ = try fixed64()
        case 2: _ = try bytes()
        case 5: _ = try fixed32()
        default: throw ProtobufError("The message uses a field encoding (\(wire)) that is not supported.")
        }
    }
}

struct ProtoWriter {
    var data = Data()

    mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    mutating func tag(_ field: Int, wire: Int) {
        varint(UInt64(field) << 3 | UInt64(wire))
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        tag(field, wire: 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func varintField(_ field: Int, _ value: UInt64) {
        tag(field, wire: 0)
        varint(value)
    }

    mutating func fixed32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }

    mutating func fixed64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
    }
}

// MARK: - Descriptors

public enum ProtoType: Int, Sendable {
    case double = 1, float, int64, uint64, int32, fixed64, fixed32, bool, string, group, message, bytes, uint32, enumeration, sfixed32, sfixed64, sint32, sint64

    var wire: Int {
        switch self {
        case .double, .fixed64, .sfixed64: return 1
        case .float, .fixed32, .sfixed32: return 5
        case .string, .bytes, .message, .group: return 2
        default: return 0
        }
    }

    /// The name used in a .proto file.
    public var label: String {
        switch self {
        case .enumeration: return "enum"
        default: return String(describing: self)
        }
    }
}

public struct ProtoField: Equatable, Sendable {
    public var name: String
    public var jsonName: String
    public var number: Int
    public var type: ProtoType
    /// The full name of the message or enum, such as `helloworld.HelloReply`, for those types.
    public var typeName: String
    public var repeated: Bool
    /// The position of the oneof this field belongs to, if any.
    public var oneofIndex: Int?
    /// True when "not set" is different from the default value.
    public var hasPresence: Bool
}

public struct ProtoMessage: Equatable, Sendable {
    public var fullName: String
    public var fields: [ProtoField]
    /// True for the hidden message that stands behind a `map<K, V>` field.
    public var isMapEntry: Bool
}

public struct ProtoEnum: Equatable, Sendable {
    public var fullName: String
    public var values: [(name: String, number: Int)]

    public static func == (a: ProtoEnum, b: ProtoEnum) -> Bool {
        a.fullName == b.fullName && a.values.map(\.name) == b.values.map(\.name) && a.values.map(\.number) == b.values.map(\.number)
    }
}

public struct ProtoMethod: Equatable, Identifiable, Sendable {
    public var name: String
    /// The service's full name, such as `helloworld.Greeter`.
    public var service: String
    public var inputType: String
    public var outputType: String
    public var clientStreaming: Bool
    public var serverStreaming: Bool

    /// `helloworld.Greeter/SayHello`: what goes in the request path.
    public var id: String { "\(service)/\(name)" }

    public var kind: String {
        switch (clientStreaming, serverStreaming) {
        case (false, false): return "Unary"
        case (false, true): return "Server streaming"
        case (true, false): return "Client streaming"
        case (true, true): return "Two-way streaming"
        }
    }
}

public struct ProtoService: Equatable, Identifiable, Sendable {
    public var fullName: String
    public var methods: [ProtoMethod]
    public var id: String { fullName }
}

/// The messages, enums and services a server describes, read from file descriptors.
public struct ProtoSchema: Equatable, Sendable {
    public private(set) var messages: [String: ProtoMessage] = [:]
    public private(set) var enums: [String: ProtoEnum] = [:]
    public private(set) var services: [ProtoService] = []
    /// The .proto files read so far, and the files those import.
    public private(set) var files: Set<String> = []
    public private(set) var dependencies: Set<String> = []
    /// The file descriptors as they were given, so the schema can be saved.
    private var descriptors: [Data] = []

    public init() {}

    /// Files that are imported by a file already read, but have not been read themselves.
    public var missingFiles: [String] { dependencies.subtracting(files).sorted() }

    public func method(_ id: String) -> ProtoMethod? {
        services.flatMap(\.methods).first { $0.id == id }
    }

    /// Adds everything declared in one serialised `FileDescriptorProto`.
    public mutating func add(fileDescriptor data: Data) throws {
        var reader = ProtoReader(data)
        var name = ""
        var package = ""
        var syntax = "proto2"
        var messageData: [Data] = []
        var enumData: [Data] = []
        var serviceData: [Data] = []
        var imports: [String] = []
        while !reader.isAtEnd {
            let (field, wire) = try reader.tag()
            switch (field, wire) {
            case (1, 2): name = String(decoding: try reader.bytes(), as: UTF8.self)
            case (2, 2): package = String(decoding: try reader.bytes(), as: UTF8.self)
            case (3, 2): imports.append(String(decoding: try reader.bytes(), as: UTF8.self))
            case (4, 2): messageData.append(try reader.bytes())
            case (5, 2): enumData.append(try reader.bytes())
            case (6, 2): serviceData.append(try reader.bytes())
            case (12, 2): syntax = String(decoding: try reader.bytes(), as: UTF8.self)
            default: try reader.skip(wire: wire)
            }
        }
        guard !files.contains(name) || name.isEmpty else { return }
        files.insert(name)
        descriptors.append(data)
        dependencies.formUnion(imports)
        let proto3 = syntax == "proto3"
        for data in messageData { try addMessage(data, scope: package, proto3: proto3) }
        for data in enumData { try addEnum(data, scope: package) }
        for data in serviceData { try addService(data, package: package) }
    }

    private static func join(_ scope: String, _ name: String) -> String {
        scope.isEmpty ? name : "\(scope).\(name)"
    }

    private mutating func addMessage(_ data: Data, scope: String, proto3: Bool) throws {
        var reader = ProtoReader(data)
        var name = ""
        var fieldData: [Data] = []
        var nested: [Data] = []
        var nestedEnums: [Data] = []
        var isMapEntry = false
        while !reader.isAtEnd {
            let (field, wire) = try reader.tag()
            switch (field, wire) {
            case (1, 2): name = String(decoding: try reader.bytes(), as: UTF8.self)
            case (2, 2): fieldData.append(try reader.bytes())
            case (3, 2): nested.append(try reader.bytes())
            case (4, 2): nestedEnums.append(try reader.bytes())
            case (7, 2):
                var options = ProtoReader(try reader.bytes())
                while !options.isAtEnd {
                    let (option, optionWire) = try options.tag()
                    if option == 7, optionWire == 0 { isMapEntry = try options.varint() != 0 } else { try options.skip(wire: optionWire) }
                }
            default: try reader.skip(wire: wire)
            }
        }
        let fullName = Self.join(scope, name)
        messages[fullName] = ProtoMessage(fullName: fullName, fields: try fieldData.map { try Self.field($0, proto3: proto3) }, isMapEntry: isMapEntry)
        for data in nested { try addMessage(data, scope: fullName, proto3: proto3) }
        for data in nestedEnums { try addEnum(data, scope: fullName) }
    }

    private static func field(_ data: Data, proto3: Bool) throws -> ProtoField {
        var reader = ProtoReader(data)
        var name = ""
        var jsonName: String?
        var number = 0
        var label = 1
        var type = ProtoType.string
        var typeName = ""
        var oneofIndex: Int?
        var proto3Optional = false
        while !reader.isAtEnd {
            let (field, wire) = try reader.tag()
            switch (field, wire) {
            case (1, 2): name = String(decoding: try reader.bytes(), as: UTF8.self)
            case (3, 0): number = Int(try reader.varint())
            case (4, 0): label = Int(try reader.varint())
            case (5, 0): type = ProtoType(rawValue: Int(try reader.varint())) ?? .bytes
            case (6, 2): typeName = String(decoding: try reader.bytes(), as: UTF8.self)
            case (9, 0): oneofIndex = Int(try reader.varint())
            case (10, 2): jsonName = String(decoding: try reader.bytes(), as: UTF8.self)
            case (17, 0): proto3Optional = try reader.varint() != 0
            default: try reader.skip(wire: wire)
            }
        }
        if typeName.hasPrefix(".") { typeName.removeFirst() }
        let repeated = label == 3
        return ProtoField(
            name: name, jsonName: jsonName ?? camelCase(name), number: number, type: type, typeName: typeName,
            repeated: repeated, oneofIndex: proto3Optional ? nil : oneofIndex,
            hasPresence: !repeated && (type == .message || oneofIndex != nil || proto3Optional || !proto3)
        )
    }

    /// `user_id` becomes `userId`, the name protobuf's JSON form uses.
    static func camelCase(_ name: String) -> String {
        var out = ""
        var upper = false
        for ch in name {
            if ch == "_" {
                upper = true
            } else {
                out += upper ? ch.uppercased() : String(ch)
                upper = false
            }
        }
        return out
    }

    private mutating func addEnum(_ data: Data, scope: String) throws {
        var reader = ProtoReader(data)
        var name = ""
        var values: [(String, Int)] = []
        while !reader.isAtEnd {
            let (field, wire) = try reader.tag()
            switch (field, wire) {
            case (1, 2): name = String(decoding: try reader.bytes(), as: UTF8.self)
            case (2, 2):
                var value = ProtoReader(try reader.bytes())
                var valueName = ""
                var number = 0
                while !value.isAtEnd {
                    let (valueField, valueWire) = try value.tag()
                    switch (valueField, valueWire) {
                    case (1, 2): valueName = String(decoding: try value.bytes(), as: UTF8.self)
                    case (2, 0): number = Int(Int32(truncatingIfNeeded: try value.varint()))
                    default: try value.skip(wire: valueWire)
                    }
                }
                values.append((valueName, number))
            default: try reader.skip(wire: wire)
            }
        }
        let fullName = Self.join(scope, name)
        enums[fullName] = ProtoEnum(fullName: fullName, values: values.map { (name: $0.0, number: $0.1) })
    }

    private mutating func addService(_ data: Data, package: String) throws {
        var reader = ProtoReader(data)
        var name = ""
        var methodData: [Data] = []
        while !reader.isAtEnd {
            let (field, wire) = try reader.tag()
            switch (field, wire) {
            case (1, 2): name = String(decoding: try reader.bytes(), as: UTF8.self)
            case (2, 2): methodData.append(try reader.bytes())
            default: try reader.skip(wire: wire)
            }
        }
        let fullName = Self.join(package, name)
        let methods = try methodData.map { data -> ProtoMethod in
            var method = ProtoReader(data)
            var result = ProtoMethod(name: "", service: fullName, inputType: "", outputType: "", clientStreaming: false, serverStreaming: false)
            while !method.isAtEnd {
                let (field, wire) = try method.tag()
                switch (field, wire) {
                case (1, 2): result.name = String(decoding: try method.bytes(), as: UTF8.self)
                case (2, 2): result.inputType = String(String(decoding: try method.bytes(), as: UTF8.self).drop { $0 == "." })
                case (3, 2): result.outputType = String(String(decoding: try method.bytes(), as: UTF8.self).drop { $0 == "." })
                case (5, 0): result.clientStreaming = try method.varint() != 0
                case (6, 0): result.serverStreaming = try method.varint() != 0
                default: try method.skip(wire: wire)
                }
            }
            return result
        }
        services.removeAll { $0.fullName == fullName }
        services.append(ProtoService(fullName: fullName, methods: methods))
        services.sort { $0.fullName < $1.fullName }
    }

    // MARK: Saving and loading

    /// Everything read so far as a `FileDescriptorSet`, the form `protoc --descriptor_set_out`
    /// and `buf build -o` write. It can be saved and read back with `init(fileDescriptorSet:)`.
    public var fileDescriptorSet: Data {
        var writer = ProtoWriter()
        for descriptor in descriptors { writer.bytes(1, descriptor) }
        return writer.data
    }

    public init(fileDescriptorSet data: Data) throws {
        var reader = ProtoReader(data)
        while !reader.isAtEnd {
            let (field, wire) = try reader.tag()
            if field == 1, wire == 2 { try add(fileDescriptor: try reader.bytes()) } else { try reader.skip(wire: wire) }
        }
        guard !descriptors.isEmpty else { throw ProtobufError("This file holds no protobuf descriptions.") }
    }
}

// MARK: - Messages as JSON

/// Converts between protobuf messages and their JSON form, using a schema read at run time.
///
/// Timestamps, durations and the wrapper types use their special JSON forms. `Struct`,
/// `Value` and `Any` are shown as the plain messages they are.
public struct ProtoJSON: Sendable {
    public var schema: ProtoSchema

    public init(schema: ProtoSchema) {
        self.schema = schema
    }

    private static let wrappers: Set<String> = [
        "google.protobuf.DoubleValue", "google.protobuf.FloatValue", "google.protobuf.Int64Value",
        "google.protobuf.UInt64Value", "google.protobuf.Int32Value", "google.protobuf.UInt32Value",
        "google.protobuf.BoolValue", "google.protobuf.StringValue", "google.protobuf.BytesValue",
    ]

    private func message(_ name: String) throws -> ProtoMessage {
        guard let message = schema.messages[name] else {
            throw ProtobufError("The server's description does not include the message type “\(name)”.")
        }
        return message
    }

    // MARK: Decoding

    /// The JSON form of a message's bytes, with fields in the order the schema declares them.
    public func decode(_ data: Data, as typeName: String) throws -> SpecNode {
        if typeName == "google.protobuf.Timestamp" || typeName == "google.protobuf.Duration" {
            let (seconds, nanos) = try secondsAndNanos(data)
            return SpecNode(.string(typeName.hasSuffix("Timestamp") ? Self.timestamp(seconds, nanos) : Self.duration(seconds, nanos)))
        }
        let message = try message(typeName)
        var single: [Int: SpecNode] = [:]
        var repeated: [Int: [SpecNode]] = [:]
        let byNumber = Dictionary(uniqueKeysWithValues: message.fields.map { ($0.number, $0) })

        var reader = ProtoReader(data)
        while !reader.isAtEnd {
            let (number, wire) = try reader.tag()
            guard let field = byNumber[number] else {
                try reader.skip(wire: wire)
                continue
            }
            if field.repeated, wire == 2, field.type.wire != 2 {
                // Packed: many numbers in one length-delimited field.
                var packed = ProtoReader(try reader.bytes())
                while !packed.isAtEnd { repeated[number, default: []].append(try scalar(&packed, field)) }
            } else if wire == field.type.wire {
                let value = try scalar(&reader, field)
                if field.repeated { repeated[number, default: []].append(value) } else { single[number] = value }
            } else {
                try reader.skip(wire: wire)
            }
        }

        if Self.wrappers.contains(typeName) {
            return single[1] ?? defaultValue(message.fields[0])
        }

        var entries: [SpecEntry] = []
        for field in message.fields {
            if field.repeated {
                let values = repeated[field.number] ?? []
                if field.type == .message, schema.messages[field.typeName]?.isMapEntry == true {
                    // Map entries are {key, value} messages; JSON shows them as one object.
                    entries.append(SpecEntry(key: field.jsonName, node: SpecNode(.map(values.map {
                        SpecEntry(key: $0["key"]?.string ?? "", node: $0["value"] ?? SpecNode(.null))
                    }))))
                } else {
                    entries.append(SpecEntry(key: field.jsonName, node: SpecNode(.list(values))))
                }
            } else if let value = single[field.number] {
                entries.append(SpecEntry(key: field.jsonName, node: value))
            } else if !field.hasPresence {
                entries.append(SpecEntry(key: field.jsonName, node: defaultValue(field)))
            }
        }
        return SpecNode(.map(entries))
    }

    private func defaultValue(_ field: ProtoField) -> SpecNode {
        switch field.type {
        case .string, .bytes: return SpecNode(.string(""))
        case .bool: return SpecNode(.bool(false))
        case .int64, .uint64, .fixed64, .sfixed64, .sint64: return SpecNode(.string("0"))
        case .enumeration: return SpecNode(.string(schema.enums[field.typeName]?.values.first { $0.number == 0 }?.name ?? "0"))
        case .message, .group: return SpecNode(.null)
        default: return SpecNode(.number(0, "0"))
        }
    }

    private func scalar(_ reader: inout ProtoReader, _ field: ProtoField) throws -> SpecNode {
        func number(_ value: Double) -> SpecNode {
            guard value.isFinite else { return SpecNode(.string(value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity"))) }
            return SpecNode(.number(value, value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)))
        }
        func integer<T: BinaryInteger>(_ value: T) -> SpecNode { SpecNode(.number(Double(value), String(value))) }
        /// 64-bit numbers are written as text, because JSON numbers cannot hold them all exactly.
        func long<T: BinaryInteger>(_ value: T) -> SpecNode { SpecNode(.string(String(value))) }

        switch field.type {
        case .double: return number(Double(bitPattern: try reader.fixed64()))
        case .float: return number(Double(Float(bitPattern: try reader.fixed32())))
        case .int64: return long(Int64(bitPattern: try reader.varint()))
        case .uint64: return long(try reader.varint())
        case .int32: return integer(Int32(truncatingIfNeeded: try reader.varint()))
        case .uint32: return integer(UInt32(truncatingIfNeeded: try reader.varint()))
        case .fixed64: return long(try reader.fixed64())
        case .fixed32: return integer(try reader.fixed32())
        case .sfixed64: return long(Int64(bitPattern: try reader.fixed64()))
        case .sfixed32: return integer(Int32(bitPattern: try reader.fixed32()))
        case .sint32:
            let raw = UInt32(truncatingIfNeeded: try reader.varint())
            return integer(Int32(bitPattern: (raw >> 1) ^ (0 &- (raw & 1))))
        case .sint64:
            let raw = try reader.varint()
            return long(Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1))))
        case .bool: return SpecNode(.bool(try reader.varint() != 0))
        case .string: return SpecNode(.string(String(decoding: try reader.bytes(), as: UTF8.self)))
        case .bytes: return SpecNode(.string(try reader.bytes().base64EncodedString()))
        case .enumeration:
            let value = Int(Int32(truncatingIfNeeded: try reader.varint()))
            if let name = schema.enums[field.typeName]?.values.first(where: { $0.number == value })?.name { return SpecNode(.string(name)) }
            return SpecNode(.number(Double(value), String(value)))
        case .message: return try decode(try reader.bytes(), as: field.typeName)
        case .group: throw ProtobufError("The field “\(field.name)” is a group, which is not supported.")
        }
    }

    private func secondsAndNanos(_ data: Data) throws -> (Int64, Int32) {
        var reader = ProtoReader(data)
        var seconds: Int64 = 0
        var nanos: Int32 = 0
        while !reader.isAtEnd {
            let (field, wire) = try reader.tag()
            switch (field, wire) {
            case (1, 0): seconds = Int64(bitPattern: try reader.varint())
            case (2, 0): nanos = Int32(truncatingIfNeeded: try reader.varint())
            default: try reader.skip(wire: wire)
            }
        }
        return (seconds, nanos)
    }

    private static func fraction(_ nanos: Int32) -> String {
        guard nanos != 0 else { return "" }
        var digits = String(format: "%09d", abs(Int(nanos)))
        while digits.hasSuffix("000") { digits.removeLast(3) }
        return "." + digits
    }

    static func timestamp(_ seconds: Int64, _ nanos: Int32) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds))) + fraction(nanos) + "Z"
    }

    static func duration(_ seconds: Int64, _ nanos: Int32) -> String {
        let negative = seconds < 0 || nanos < 0
        return "\(negative ? "-" : "")\(abs(seconds))\(fraction(nanos))s"
    }

    // MARK: Encoding

    /// A message's bytes, from its JSON form.
    public func encode(json text: String, as typeName: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let node: SpecNode
        do {
            node = trimmed.isEmpty ? SpecNode(.map([])) : try SpecParser.parse(trimmed).root
        } catch let error as SpecParseError {
            throw ProtobufError("The message is not valid JSON. \(error.localizedDescription)")
        }
        return try encode(node, as: typeName, path: "")
    }

    public func encode(_ node: SpecNode, as typeName: String, path: String = "") throws -> Data {
        func fail(_ text: String) -> ProtobufError {
            ProtobufError(path.isEmpty ? text : "\(path): \(text)")
        }
        if typeName == "google.protobuf.Timestamp" || typeName == "google.protobuf.Duration" {
            guard let text = node.string else { throw fail("expected text such as \(typeName.hasSuffix("Timestamp") ? "“2024-01-01T00:00:00Z”" : "“1.5s”").") }
            guard let (seconds, nanos) = typeName.hasSuffix("Timestamp") ? Self.parseTimestamp(text) : Self.parseDuration(text) else {
                throw fail("“\(text)” is not a valid \(typeName.hasSuffix("Timestamp") ? "timestamp" : "duration").")
            }
            var writer = ProtoWriter()
            if seconds != 0 { writer.varintField(1, UInt64(bitPattern: seconds)) }
            if nanos != 0 { writer.varintField(2, UInt64(bitPattern: Int64(nanos))) }
            return writer.data
        }
        let message = try message(typeName)
        var writer = ProtoWriter()
        if Self.wrappers.contains(typeName) {
            try write(node, message.fields[0], to: &writer, path: path)
            return writer.data
        }
        guard node.isMap else { throw fail("expected an object for \(typeName).") }
        var seenOneofs: [Int: String] = [:]
        for entry in node.entries {
            guard let field = message.fields.first(where: { $0.jsonName == entry.key || $0.name == entry.key }) else {
                let known = message.fields.map(\.jsonName).joined(separator: ", ")
                throw fail("\(typeName) has no field “\(entry.key)”. Its fields are: \(known.isEmpty ? "none" : known).")
            }
            if entry.node.isNull { continue }
            let here = path.isEmpty ? entry.key : "\(path).\(entry.key)"
            if let oneof = field.oneofIndex {
                if let other = seenOneofs[oneof] { throw fail("“\(other)” and “\(entry.key)” cannot both be set: only one of them may be.") }
                seenOneofs[oneof] = entry.key
            }
            if field.repeated {
                if field.type == .message, let mapEntry = schema.messages[field.typeName], mapEntry.isMapEntry {
                    guard entry.node.isMap else { throw ProtobufError("\(here): expected an object of keys and values.") }
                    for pair in entry.node.entries {
                        var inner = ProtoWriter()
                        try write(SpecNode(.string(pair.key)), mapEntry.fields[0], to: &inner, path: here)
                        try write(pair.node, mapEntry.fields[1], to: &inner, path: "\(here).\(pair.key)")
                        writer.bytes(field.number, inner.data)
                    }
                } else {
                    guard entry.node.isList else { throw ProtobufError("\(here): expected a list, written with [ ].") }
                    for (index, item) in entry.node.items.enumerated() {
                        try write(item, field, to: &writer, path: "\(here)[\(index)]")
                    }
                }
            } else {
                try write(entry.node, field, to: &writer, path: here)
            }
        }
        return writer.data
    }

    private func write(_ node: SpecNode, _ field: ProtoField, to writer: inout ProtoWriter, path: String) throws {
        func fail(_ expected: String) -> ProtobufError {
            ProtobufError("\(path): expected \(expected), but found \(node.jsonText(pretty: false).prefix(40)).")
        }
        /// A whole number, given as a JSON number or as text.
        func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            if case .number(let value, let raw) = node.value {
                if let exact = T(raw) { return exact }
                if value == value.rounded(), let exact = T(exactly: value) { return exact }
            } else if case .string(let text) = node.value, let exact = T(text) {
                return exact
            }
            throw fail("a whole number that fits \(field.type.label)")
        }
        func double() throws -> Double {
            if let value = node.double { return value }
            switch node.string {
            case "NaN": return .nan
            case "Infinity": return .infinity
            case "-Infinity": return -.infinity
            default:
                if let text = node.string, let value = Double(text) { return value }
                throw fail("a number")
            }
        }

        switch field.type {
        case .double:
            writer.tag(field.number, wire: 1)
            writer.fixed64(try double().bitPattern)
        case .float:
            writer.tag(field.number, wire: 5)
            writer.fixed32(Float(try double()).bitPattern)
        case .int64:
            writer.varintField(field.number, UInt64(bitPattern: try integer(Int64.self)))
        case .uint64:
            writer.varintField(field.number, try integer(UInt64.self))
        case .int32:
            writer.varintField(field.number, UInt64(bitPattern: Int64(try integer(Int32.self))))
        case .uint32:
            writer.varintField(field.number, UInt64(try integer(UInt32.self)))
        case .fixed64:
            writer.tag(field.number, wire: 1)
            writer.fixed64(try integer(UInt64.self))
        case .sfixed64:
            writer.tag(field.number, wire: 1)
            writer.fixed64(UInt64(bitPattern: try integer(Int64.self)))
        case .fixed32:
            writer.tag(field.number, wire: 5)
            writer.fixed32(try integer(UInt32.self))
        case .sfixed32:
            writer.tag(field.number, wire: 5)
            writer.fixed32(UInt32(bitPattern: try integer(Int32.self)))
        case .sint32:
            let value = try integer(Int32.self)
            writer.varintField(field.number, UInt64(UInt32(bitPattern: (value << 1) ^ (value >> 31))))
        case .sint64:
            let value = try integer(Int64.self)
            writer.varintField(field.number, UInt64(bitPattern: (value << 1) ^ (value >> 63)))
        case .bool:
            guard let flag = node.bool ?? (node.string == "true" ? true : node.string == "false" ? false : nil) else { throw fail("true or false") }
            writer.varintField(field.number, flag ? 1 : 0)
        case .string:
            guard let text = node.string else { throw fail("text in quotes") }
            writer.string(field.number, text)
        case .bytes:
            guard case .string(let text) = node.value, let data = Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")) else {
                throw fail("base64 text")
            }
            writer.bytes(field.number, data)
        case .enumeration:
            let values = schema.enums[field.typeName]?.values ?? []
            if case .string(let name) = node.value {
                guard let value = values.first(where: { $0.name == name }) else {
                    throw fail("one of \(values.map(\.name).joined(separator: ", "))")
                }
                writer.varintField(field.number, UInt64(bitPattern: Int64(value.number)))
            } else {
                writer.varintField(field.number, UInt64(bitPattern: Int64(try integer(Int32.self))))
            }
        case .message:
            writer.bytes(field.number, try encode(node, as: field.typeName, path: path))
        case .group:
            throw ProtobufError("\(path): groups are not supported.")
        }
    }

    static func parseTimestamp(_ text: String) -> (Int64, Int32)? {
        // Split off the fraction, which the date formatter does not read to nine places.
        var main = text
        var nanos: Int32 = 0
        if let dot = text.firstIndex(of: ".") {
            let afterDot = text[text.index(after: dot)...]
            let digits = afterDot.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            nanos = Int32(digits + String(repeating: "0", count: 9 - digits.count)) ?? 0
            main = String(text[..<dot]) + afterDot.dropFirst(digits.count)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: main) else { return nil }
        return (Int64(date.timeIntervalSince1970.rounded(.down)), nanos)
    }

    static func parseDuration(_ text: String) -> (Int64, Int32)? {
        guard text.hasSuffix("s"), let value = Double(text.dropLast()) else { return nil }
        let seconds = value.rounded(.towardZero)
        return (Int64(seconds), Int32(((value - seconds) * 1_000_000_000).rounded()))
    }

    // MARK: Templates

    /// A message of this type with every field present and empty, to start a request from.
    public func template(for typeName: String, depth: Int = 0) -> SpecNode {
        if typeName == "google.protobuf.Timestamp" { return SpecNode(.string("2024-01-01T00:00:00Z")) }
        if typeName == "google.protobuf.Duration" { return SpecNode(.string("0s")) }
        guard let message = schema.messages[typeName] else { return SpecNode(.map([])) }
        if Self.wrappers.contains(typeName) { return value(message.fields[0], depth: depth) }
        var entries: [SpecEntry] = []
        var usedOneofs = Set<Int>()
        for field in message.fields {
            // Only the first member of a oneof can be set at once.
            if let oneof = field.oneofIndex, !usedOneofs.insert(oneof).inserted { continue }
            if field.repeated {
                if field.type == .message, let entry = schema.messages[field.typeName], entry.isMapEntry {
                    entries.append(SpecEntry(key: field.jsonName, node: SpecNode(.map(depth < 3 ? [SpecEntry(key: "key", node: value(entry.fields[1], depth: depth + 1))] : []))))
                } else {
                    entries.append(SpecEntry(key: field.jsonName, node: SpecNode(.list(depth < 3 ? [value(field, depth: depth + 1)] : []))))
                }
            } else if field.type != .message || depth < 3 {
                entries.append(SpecEntry(key: field.jsonName, node: value(field, depth: depth + 1)))
            }
        }
        return SpecNode(.map(entries))
    }

    private func value(_ field: ProtoField, depth: Int) -> SpecNode {
        switch field.type {
        case .message: return template(for: field.typeName, depth: depth)
        case .enumeration: return SpecNode(.string(schema.enums[field.typeName]?.values.first?.name ?? ""))
        default: return defaultValue(field)
        }
    }
}
