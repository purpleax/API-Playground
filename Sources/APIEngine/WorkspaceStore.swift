import Foundation

/// Reads and writes a workspace as plain files, one per request, folder and environment.
///
/// Layout:
///
///     workspace.json
///     globals.json
///     environments/<name>.env.json
///     collections/<name>/collection.json
///     collections/<name>/<request>.request.json
///     collections/<name>/<folder>/folder.json
///
/// Scratch Pad, Local Vault and Git Sync all use this layout; only `root` differs.
public struct WorkspaceStore: Sendable {
    public let root: URL
    public let secrets: any SecretStore
    /// Where this-Mac-only "current values" are kept. Nil means they are not kept at all.
    public let localValues: LocalValueStore?

    public init(root: URL, secrets: any SecretStore, localValues: LocalValueStore? = nil) {
        self.root = root
        self.secrets = secrets
        self.localValues = localValues
    }

    private var collectionsDir: URL { root.appendingPathComponent("collections", isDirectory: true) }
    private var environmentsDir: URL { root.appendingPathComponent("environments", isDirectory: true) }
    private var fm: FileManager { .default }

    // MARK: Files on disk

    private struct WorkspaceFile: Codable {
        var formatVersion: Int
    }

    private struct CollectionFile: Codable {
        var formatVersion: Int
        var id: UUID
        var name: String
        var description: String?
        var auth: Auth?
        var variables: [Variable]?
        var preRequestScript: String?
        var testScript: String?
        var postmanID: String?
        var order: [String]?
    }

    private struct FolderFile: Codable {
        var id: UUID
        var name: String
        var description: String?
        var auth: Auth?
        var preRequestScript: String?
        var testScript: String?
        var order: [String]?
    }

    private struct GlobalsFile: Codable {
        var variables: [Variable]
    }

    private static let requestSuffix = ".request.json"
    private static let environmentSuffix = ".env.json"

    private func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    /// Creates the workspace folders if they are missing.
    public func prepare() throws {
        try fm.createDirectory(at: collectionsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: environmentsDir, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("workspace.json")
        if !fm.fileExists(atPath: marker.path) {
            try encode(WorkspaceFile(formatVersion: currentFormatVersion), to: marker)
        }
    }

    // MARK: Secrets

    /// Moves secret values into the secret store and blanks them, ready to write to a file.
    private func stripSecrets(_ variables: [Variable], owner: String) -> [Variable] {
        var current: [String: String] = [:]
        for variable in variables where !variable.secret {
            if let value = variable.currentValue, !value.isEmpty { current[variable.key] = value }
        }
        localValues?.set(current, owner: owner)

        return variables.map { variable in
            guard variable.secret else { return variable }
            secrets.set(variable.value, for: "\(owner)/\(variable.key)")
            var copy = variable
            copy.value = ""
            return copy
        }
    }

    private func fillSecrets(_ variables: [Variable], owner: String) -> [Variable] {
        let current = localValues?.values(owner: owner) ?? [:]
        return variables.map { variable in
            guard variable.secret else {
                var copy = variable
                copy.currentValue = current[variable.key]
                return copy
            }
            var copy = variable
            copy.value = secrets.get("\(owner)/\(variable.key)") ?? ""
            return copy
        }
    }

    // MARK: Collections

    public func loadCollections() throws -> [APICollection] {
        var result: [APICollection] = []
        for dir in try subdirectories(of: collectionsDir) {
            let file = dir.appendingPathComponent("collection.json")
            guard fm.fileExists(atPath: file.path) else { continue }
            let meta = try decode(CollectionFile.self, from: file)
            result.append(APICollection(
                id: meta.id,
                name: meta.name,
                description: meta.description ?? "",
                auth: meta.auth ?? .none,
                variables: fillSecrets(meta.variables ?? [], owner: meta.id.uuidString),
                preRequestScript: meta.preRequestScript ?? "",
                testScript: meta.testScript ?? "",
                postmanID: meta.postmanID,
                items: try loadItems(in: dir, order: meta.order ?? [])
            ))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ collection: APICollection) throws {
        try prepare()
        // Write the whole tree to a temporary folder, then swap it in, so a failed
        // save never leaves a half-written collection.
        let temp = collectionsDir.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        do {
            let order = try writeItems(collection.items, into: temp)
            try encode(CollectionFile(
                formatVersion: currentFormatVersion,
                id: collection.id,
                name: collection.name,
                description: collection.description,
                auth: collection.auth,
                variables: stripSecrets(collection.variables, owner: collection.id.uuidString),
                preRequestScript: collection.preRequestScript,
                testScript: collection.testScript,
                postmanID: collection.postmanID,
                order: order
            ), to: temp.appendingPathComponent("collection.json"))

            if let existing = try collectionDirectory(id: collection.id) {
                try fm.removeItem(at: existing)
            }
            let target = uniqueURL(in: collectionsDir, base: Self.slug(collection.name), suffix: "")
            try fm.moveItem(at: temp, to: target)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    public func deleteCollection(id: UUID) throws {
        if let dir = try collectionDirectory(id: id) {
            try fm.removeItem(at: dir)
        }
    }

    private func collectionDirectory(id: UUID) throws -> URL? {
        for dir in try subdirectories(of: collectionsDir) {
            let file = dir.appendingPathComponent("collection.json")
            if let meta = try? decode(CollectionFile.self, from: file), meta.id == id {
                return dir
            }
        }
        return nil
    }

    private func writeItems(_ items: [Node], into dir: URL) throws -> [String] {
        var order: [String] = []
        var used = Set<String>()
        for node in items {
            var base = Self.slug(node.name)
            var counter = 2
            while used.contains(base) {
                base = "\(Self.slug(node.name))-\(counter)"
                counter += 1
            }
            used.insert(base)

            switch node {
            case .request(let request):
                let name = base + Self.requestSuffix
                try encode(request, to: dir.appendingPathComponent(name))
                order.append(name)
            case .folder(let folder):
                let sub = dir.appendingPathComponent(base, isDirectory: true)
                try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                let childOrder = try writeItems(folder.items, into: sub)
                try encode(FolderFile(
                    id: folder.id,
                    name: folder.name,
                    description: folder.description,
                    auth: folder.auth,
                    preRequestScript: folder.preRequestScript,
                    testScript: folder.testScript,
                    order: childOrder
                ), to: sub.appendingPathComponent("folder.json"))
                order.append(base)
            }
        }
        return order
    }

    private func loadItems(in dir: URL, order: [String]) throws -> [Node] {
        let contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        var available: [String: URL] = [:]
        for url in contents {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if fm.fileExists(atPath: url.appendingPathComponent("folder.json").path) {
                    available[name] = url
                }
            } else if name.hasSuffix(Self.requestSuffix) {
                available[name] = url
            }
        }

        // Follow the saved order, then pick up anything added by hand or by a merge.
        var names = order.filter { available[$0] != nil }
        let listed = Set(names)
        names += available.keys.filter { !listed.contains($0) }.sorted()

        var nodes: [Node] = []
        for name in names {
            guard let url = available[name] else { continue }
            if name.hasSuffix(Self.requestSuffix) {
                nodes.append(.request(try decode(RequestItem.self, from: url)))
            } else {
                let meta = try decode(FolderFile.self, from: url.appendingPathComponent("folder.json"))
                nodes.append(.folder(Folder(
                    id: meta.id,
                    name: meta.name,
                    description: meta.description ?? "",
                    auth: meta.auth ?? .inherit,
                    preRequestScript: meta.preRequestScript ?? "",
                    testScript: meta.testScript ?? "",
                    items: try loadItems(in: url, order: meta.order ?? [])
                )))
            }
        }
        return nodes
    }

    // MARK: Environments

    public func loadEnvironments() throws -> [APIEnvironment] {
        guard fm.fileExists(atPath: environmentsDir.path) else { return [] }
        var result: [APIEnvironment] = []
        for url in try fm.contentsOfDirectory(at: environmentsDir, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasSuffix(Self.environmentSuffix) {
            var environment = try decode(APIEnvironment.self, from: url)
            environment.variables = fillSecrets(environment.variables, owner: environment.id.uuidString)
            result.append(environment)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ environment: APIEnvironment) throws {
        try prepare()
        if let existing = try environmentFile(id: environment.id) {
            try fm.removeItem(at: existing)
        }
        var copy = environment
        copy.variables = stripSecrets(environment.variables, owner: environment.id.uuidString)
        let target = uniqueURL(in: environmentsDir, base: Self.slug(environment.name), suffix: Self.environmentSuffix)
        try encode(copy, to: target)
    }

    public func deleteEnvironment(id: UUID) throws {
        if let file = try environmentFile(id: id) {
            try fm.removeItem(at: file)
        }
        localValues?.set([:], owner: id.uuidString)
    }

    private func environmentFile(id: UUID) throws -> URL? {
        guard fm.fileExists(atPath: environmentsDir.path) else { return nil }
        for url in try fm.contentsOfDirectory(at: environmentsDir, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasSuffix(Self.environmentSuffix) {
            if let environment = try? decode(APIEnvironment.self, from: url), environment.id == id {
                return url
            }
        }
        return nil
    }

    // MARK: Globals

    public func loadGlobals() throws -> [Variable] {
        let file = root.appendingPathComponent("globals.json")
        guard fm.fileExists(atPath: file.path) else { return [] }
        return fillSecrets(try decode(GlobalsFile.self, from: file).variables, owner: "globals")
    }

    public func saveGlobals(_ variables: [Variable]) throws {
        try prepare()
        try encode(
            GlobalsFile(variables: stripSecrets(variables, owner: "globals")),
            to: root.appendingPathComponent("globals.json")
        )
    }

    // MARK: Helpers

    private func subdirectories(of dir: URL) throws -> [URL] {
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
    }

    private func uniqueURL(in dir: URL, base: String, suffix: String) -> URL {
        var candidate = dir.appendingPathComponent(base + suffix)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(counter)\(suffix)")
            counter += 1
        }
        return candidate
    }

    /// A file-system-safe version of a name: lowercase letters, digits and hyphens.
    static func slug(_ name: String) -> String {
        var out = ""
        var lastWasHyphen = true
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.isEmpty { return "untitled" }
        return String(out.prefix(80))
    }
}
