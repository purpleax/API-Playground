import Foundation

/// One past response to a request.
public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var method: String
    public var url: String
    public var status: Int
    public var headers: [HTTPHeader]
    public var body: Data
    public var timings: HTTPTimings

    public init(id: UUID = UUID(), date: Date = Date(), request: PreparedRequest, response: HTTPResponse) {
        self.id = id
        self.date = date
        self.method = request.method
        self.url = request.url
        self.status = response.status
        self.headers = response.headers
        self.body = response.body
        self.timings = response.timings
    }

    public var text: String? {
        String(data: body, encoding: .utf8)
    }
}

/// Keeps recent responses for each request. History lives outside the workspace,
/// so it never ends up in a Git repository.
public struct HistoryStore: Sendable {
    public let root: URL
    public var limitPerRequest: Int

    public init(root: URL, limitPerRequest: Int = 20) {
        self.root = root
        self.limitPerRequest = limitPerRequest
    }

    private func directory(_ requestID: UUID) -> URL {
        root.appendingPathComponent(requestID.uuidString, isDirectory: true)
    }

    public func record(_ entry: HistoryEntry, requestID: UUID) throws {
        let dir = directory(requestID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // File names sort by time, so the oldest entries are easy to find and remove.
        let stamp = String(format: "%017.6f", entry.date.timeIntervalSince1970)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(entry).write(to: dir.appendingPathComponent("\(stamp)-\(entry.id.uuidString).json"), options: .atomic)

        let files = try files(in: dir)
        for old in files.dropLast(limitPerRequest) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// Newest first.
    public func entries(requestID: UUID) -> [HistoryEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let files = (try? files(in: directory(requestID))) ?? []
        return files.reversed().compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? decoder.decode(HistoryEntry.self, from: $0) }
        }
    }

    public func clear(requestID: UUID) {
        try? FileManager.default.removeItem(at: directory(requestID))
    }

    private func files(in dir: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Diff

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case same, removed, added }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum LineDiff {
    /// Compares two texts line by line.
    public static func diff(old: String, new: String) -> [DiffLine] {
        let oldLines = old.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let newLines = new.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var result: [DiffLine] = []
        var i = 0
        var j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) {
                result.append(DiffLine(kind: .removed, text: oldLines[i]))
                i += 1
            } else if j < newLines.count, inserted.contains(j) {
                result.append(DiffLine(kind: .added, text: newLines[j]))
                j += 1
            } else {
                if j < newLines.count { result.append(DiffLine(kind: .same, text: newLines[j])) }
                i += 1
                j += 1
            }
        }
        return result
    }

    /// Re-indents JSON so that two responses differing only in layout compare as equal.
    public static func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
              )
        else { return nil }
        return String(data: pretty, encoding: .utf8).map(tightenColons)
    }

    /// JSONSerialization writes `"key" : value`. The usual style has no space before the colon.
    static func tightenColons(_ json: String) -> String {
        json.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> String in
            let indent = line.prefix { $0 == " " }
            var rest = line.dropFirst(indent.count)
            guard rest.first == "\"" else { return String(line) }
            // Walk to the closing quote of the key, skipping escaped characters.
            var key = "\""
            rest = rest.dropFirst()
            while let c = rest.first {
                key.append(c)
                rest = rest.dropFirst()
                if c == "\\", let escaped = rest.first {
                    key.append(escaped)
                    rest = rest.dropFirst()
                } else if c == "\"" {
                    break
                }
            }
            guard rest.hasPrefix(" : ") else { return String(line) }
            return indent + key + ": " + rest.dropFirst(3)
        }
        .joined(separator: "\n")
    }
}
