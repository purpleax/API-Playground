import Foundation

/// Keeps variables' "current values": values used on this Mac only. They live in one file
/// outside the workspace, so they are never shared or committed.
public struct LocalValueStore: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    private func load() -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }

    /// The current values for one collection, environment or the globals, by variable name.
    public func values(owner: String) -> [String: String] {
        load()[owner] ?? [:]
    }

    /// Replaces the current values for one owner. An empty dictionary removes the owner.
    public func set(_ values: [String: String], owner: String) {
        var all = load()
        if all[owner] == nil && values.isEmpty { return }
        all[owner] = values.isEmpty ? nil : values
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(all).write(to: file, options: .atomic)
    }
}
