import Foundation

/// Whose version of something to keep: this Mac's, or the one being merged in.
public enum MergeSide: String, Sendable {
    case ours, theirs
}

/// One value that both sides changed in different ways.
public struct JSONConflict: Identifiable, Equatable, Sendable {
    /// Where the value is, as names a person can follow: `["headers", "Accept", "value"]`.
    public var path: [String]
    /// The three versions, as text. Nil means the value is absent on that side.
    public var base: String?
    public var ours: String?
    public var theirs: String?

    public var id: String { path.joined(separator: "\u{1F}") }
    public var label: String { path.isEmpty ? "Whole file" : path.joined(separator: " › ") }
}

/// A three-way merge of JSON that works on values rather than lines of text, so two
/// people changing different fields of one request never collide.
public enum JSONMerge {
    public struct Result: Sendable {
        public var merged: Data
        /// Every conflict found. Those without a choice were settled in favour of `ours`.
        public var conflicts: [JSONConflict]
    }

    /// - Parameters:
    ///   - base: The version both sides started from, or nil when both added the file.
    ///   - choices: Which side to keep for each conflict, by conflict id.
    public static func merge(base: Data?, ours: Data, theirs: Data, choices: [String: MergeSide] = [:]) throws -> Result {
        let baseValue = try base.map(parse)
        var merger = Merger(choices: choices)
        let merged = merger.merge(baseValue, try parse(ours), try parse(theirs), path: []) ?? NSNull()
        return Result(merged: try serialise(merged), conflicts: merger.conflicts)
    }

    static func parse(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Writes JSON the way the workspace store does, so merged files look like saved ones.
    static func serialise(_ value: Any) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
        data.append(0x0A)
        return data
    }

    static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a as NSObject, let b as NSObject): return a.isEqual(b)
        default: return false
        }
    }

    static func display(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
        return data.map { prettyJSONColons(String(decoding: $0, as: UTF8.self)) } ?? "\(value)"
    }

    private static func prettyJSONColons(_ text: String) -> String {
        text.replacingOccurrences(of: "\" : ", with: "\": ")
    }

    /// Merges two lists of names: keeps our order, drops what they removed, and puts what
    /// they added after the item it followed on their side.
    static func mergeList(base: [String], ours: [String], theirs: [String]) -> [String] {
        let inBase = Set(base), inOurs = Set(ours), inTheirs = Set(theirs)
        var result = ours.filter { !(inBase.contains($0) && !inTheirs.contains($0)) }
        for (index, item) in theirs.enumerated() where !inBase.contains(item) && !inOurs.contains(item) {
            var position = 0
            for previous in theirs[..<index].reversed() {
                if let found = result.firstIndex(of: previous) {
                    position = found + 1
                    break
                }
            }
            result.insert(item, at: min(position, result.count))
        }
        return result
    }

    private struct Merger {
        var choices: [String: MergeSide]
        var conflicts: [JSONConflict] = []

        /// Returns the merged value, or nil when the value should be absent.
        mutating func merge(_ base: Any?, _ ours: Any?, _ theirs: Any?, path: [String]) -> Any? {
            if JSONMerge.equal(ours, theirs) { return ours }
            if JSONMerge.equal(ours, base) { return theirs }
            if JSONMerge.equal(theirs, base) { return ours }

            if let o = ours as? [String: Any], let t = theirs as? [String: Any] {
                let b = base as? [String: Any] ?? [:]
                var merged: [String: Any] = [:]
                for key in Set(o.keys).union(t.keys).union(b.keys).sorted() {
                    if let value = merge(b[key], o[key], t[key], path: path + [key]) {
                        merged[key] = value
                    }
                }
                return merged
            }

            if let o = ours as? [Any], let t = theirs as? [Any] {
                let b = base as? [Any] ?? []
                if let os = o as? [String], let ts = t as? [String], let bs = b as? [String] {
                    return JSONMerge.mergeList(base: bs, ours: os, theirs: ts)
                }
                if let merged = mergeKeyed(b, o, t, path: path) { return merged }
            }

            let conflict = JSONConflict(
                path: path, base: JSONMerge.display(base), ours: JSONMerge.display(ours), theirs: JSONMerge.display(theirs)
            )
            conflicts.append(conflict)
            return choices[conflict.id] == .theirs ? theirs : ours
        }

        /// Merges lists of objects that can be told apart by an `id` or a unique `key`,
        /// matching items across the three versions even when they have moved.
        private mutating func mergeKeyed(_ base: [Any], _ ours: [Any], _ theirs: [Any], path: [String]) -> [Any]? {
            for field in ["id", "key"] {
                guard let b = Self.index(base, by: field), let o = Self.index(ours, by: field), let t = Self.index(theirs, by: field)
                else { continue }
                // Everything from both sides, in our order, so a removal on one side can
                // still be compared with a change on the other.
                let order = JSONMerge.mergeList(base: [], ours: o.order, theirs: t.order)
                var merged: [Any] = []
                for identity in order {
                    let sample = o.items[identity] ?? t.items[identity] ?? b.items[identity] ?? [:]
                    let name = field == "key" ? identity : (sample["name"] as? String ?? sample["key"] as? String ?? String(identity.prefix(8)))
                    if let value = merge(b.items[identity], o.items[identity], t.items[identity], path: path + [name.isEmpty ? "(unnamed)" : name]) {
                        merged.append(value)
                    }
                }
                return merged
            }
            return nil
        }

        private static func index(_ array: [Any], by field: String) -> (order: [String], items: [String: [String: Any]])? {
            var order: [String] = []
            var items: [String: [String: Any]] = [:]
            for element in array {
                guard let object = element as? [String: Any], let identity = object[field] as? String, items[identity] == nil
                else { return nil }
                order.append(identity)
                items[identity] = object
            }
            return (order, items)
        }
    }
}

/// What a file in a workspace holds, worked out from its name and content.
public struct WorkspaceFileInfo: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case request = "Request"
        case folder = "Folder"
        case collection = "Collection"
        case environment = "Environment"
        case globals = "Global variables"
        case settings = "Workspace settings"
        case spec = "Spec"
        case ruleset = "Lint ruleset"
        case other = "File"
    }

    public var kind: Kind
    /// The name the item has in the app, when the file says.
    public var name: String?
    public var path: String

    /// - Parameter versions: Contents to look for a name in, most preferred first.
    public init(path: String, versions: [Data?] = []) {
        self.path = path
        let file = (path as NSString).lastPathComponent
        if file.hasSuffix(".request.json") {
            kind = .request
        } else if file == "folder.json" {
            kind = .folder
        } else if file == "collection.json" {
            kind = .collection
        } else if file.hasSuffix(".env.json") {
            kind = .environment
        } else if path == "globals.json" {
            kind = .globals
        } else if path == "workspace.json" {
            kind = .settings
        } else if path == "specs/" + WorkspaceStore.rulesetFile {
            kind = .ruleset
        } else if path.hasPrefix("specs/"), WorkspaceStore.specExtensions.contains((file as NSString).pathExtension.lowercased()) {
            kind = .spec
        } else {
            kind = .other
        }
        name = kind == .spec ? (file as NSString).deletingPathExtension : nil
        guard kind != .other, kind != .globals, kind != .settings, kind != .spec, kind != .ruleset else { return }
        for data in versions {
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let found = object["name"] as? String, !found.isEmpty {
                name = found
                break
            }
        }
    }

    public var title: String {
        switch kind {
        case .globals, .settings, .ruleset: return kind.rawValue
        case .other: return path
        default: return name ?? (path as NSString).lastPathComponent
        }
    }

    /// The folders the file sits in, for telling apart items with the same name.
    public var location: String {
        var parts = path.split(separator: "/").map(String.init)
        if parts.first == "collections" || parts.first == "environments" { parts.removeFirst() }
        if !parts.isEmpty { parts.removeLast() }
        if kind == .folder || kind == .collection, !parts.isEmpty { parts.removeLast() }
        return parts.joined(separator: " / ")
    }
}

/// A file both sides changed, which a merge could not settle by itself.
public struct FileConflict: Identifiable, Equatable, Sendable {
    public var path: String
    public var base: Data?
    public var ours: Data?
    public var theirs: Data?
    public var info: WorkspaceFileInfo
    /// The values to choose between. Empty when the choice is for the file as a whole.
    public var fields: [JSONConflict]
    /// Why the whole file has to be chosen, when it does.
    public var wholeFileReason: String?

    public var id: String { path }

    /// True once enough choices have been made to settle the file.
    public func isSettled(fields choices: [String: MergeSide], file: MergeSide?) -> Bool {
        wholeFileReason != nil ? file != nil : fields.allSatisfy { choices[$0.id] != nil }
    }
}

public enum WorkspaceMerge {
    enum Analysis {
        /// The two sides fit together. This is the result.
        case clean(Data)
        /// Both sides added different items under one file name. Both are kept.
        case keepBoth(ours: Data, theirs: Data)
        case conflict(FileConflict)
    }

    static func analyse(path: String, base: Data?, ours: Data?, theirs: Data?) -> Analysis {
        let info = WorkspaceFileInfo(path: path, versions: [ours, theirs, base])
        func whole(_ reason: String) -> Analysis {
            .conflict(FileConflict(path: path, base: base, ours: ours, theirs: theirs, info: info, fields: [], wholeFileReason: reason))
        }
        guard let ours else { return whole("You deleted this, and the other side changed it.") }
        guard let theirs else { return whole("You changed this, and the other side deleted it.") }
        guard path.hasSuffix(".json") else { return whole("This file cannot be merged value by value.") }

        // Two different items that happen to share a file name are not one item edited twice.
        if base == nil, let ourID = identity(ours), let theirID = identity(theirs), ourID != theirID {
            let file = (path as NSString).lastPathComponent
            if file.hasSuffix(".request.json") || file.hasSuffix(".env.json") {
                return .keepBoth(ours: ours, theirs: theirs)
            }
            return whole("Both sides added a different item with this name.")
        }

        do {
            let result = try JSONMerge.merge(base: base, ours: ours, theirs: theirs)
            if result.conflicts.isEmpty { return .clean(result.merged) }
            return .conflict(FileConflict(
                path: path, base: base, ours: ours, theirs: theirs, info: info, fields: result.conflicts, wholeFileReason: nil
            ))
        } catch {
            return whole("One version of this file is damaged and cannot be read.")
        }
    }

    private static func identity(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
    }

    /// The content a conflicted file should end up with, or nil when it should be deleted.
    static func resolution(of conflict: FileConflict, fields: [String: MergeSide], file: MergeSide?) throws -> Data? {
        guard conflict.isSettled(fields: fields, file: file) else {
            throw GitError("“\(conflict.info.title)” still needs a choice.")
        }
        if conflict.wholeFileReason != nil {
            return file == .theirs ? conflict.theirs : conflict.ours
        }
        guard let ours = conflict.ours, let theirs = conflict.theirs else { return conflict.ours ?? conflict.theirs }
        return try JSONMerge.merge(base: conflict.base, ours: ours, theirs: theirs, choices: fields).merged
    }
}

extension GitRepository {
    /// Settles every conflicted file that can be merged value by value, and returns the
    /// ones that need a person to choose.
    public func mergeConflicts() throws -> [FileConflict] {
        var remaining: [FileConflict] = []
        for raw in try rawConflicts() {
            switch WorkspaceMerge.analyse(path: raw.path, base: raw.base, ours: raw.ours, theirs: raw.theirs) {
            case .clean(let merged):
                try settle(raw.path, content: merged)
            case .keepBoth(let ours, let theirs):
                try settle(raw.path, content: ours)
                try settle(freePath(beside: raw.path), content: theirs)
            case .conflict(let conflict):
                remaining.append(conflict)
            }
        }
        return remaining
    }

    /// Settles one conflicted file using the choices made for it.
    public func resolve(_ conflict: FileConflict, fields: [String: MergeSide] = [:], file: MergeSide? = nil) throws {
        try settle(conflict.path, content: try WorkspaceMerge.resolution(of: conflict, fields: fields, file: file))
    }

    /// A file name next to `path` that is not in use: `get-users-2.request.json`.
    private func freePath(beside path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let file = (path as NSString).lastPathComponent
        let suffix = [".request.json", ".env.json"].first { file.hasSuffix($0) } ?? ""
        let stem = String(file.dropLast(suffix.count))
        var counter = 2
        while true {
            let candidate = (directory as NSString).appendingPathComponent("\(stem)-\(counter)\(suffix)")
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) { return candidate }
            counter += 1
        }
    }
}
