import Foundation

/// Reads a file or folder exported from another API client, working out which one it came
/// from: Postman, Insomnia or Bruno.
public enum Importer {

    public static func importFile(at url: URL) throws -> ImportBatch {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var batch = ImportBatch()
        if isDirectory.boolValue {
            batch.documents = try BrunoImporter.importFolder(at: url)
            return batch
        }

        switch url.pathExtension.lowercased() {
        case "bru":
            batch.documents = try BrunoImporter.importRequestFile(at: url)
        case "zip":
            try importArchive(at: url, into: &batch)
        default:
            let data = try Data(contentsOf: url)
            if let documents = try other(data) {
                batch.documents = documents
            } else {
                PostmanImporter.add(data, name: url.lastPathComponent, to: &batch)
                // A lone file that nothing recognises is an error, not something to skip quietly.
                if batch.documents.isEmpty {
                    guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw ImportError.notRecognised(isJSON: false) }
                    if batch.skipped.contains(where: { $0.contains("Collection v2.0 or v2.1") }) { return batch }
                    throw ImportError.notRecognised(isJSON: true)
                }
            }
        }
        return batch
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case notRecognised(isJSON: Bool)

        public var errorDescription: String? {
            switch self {
            case .notRecognised(true):
                return "The file is not a Postman, Insomnia or Bruno export."
            case .notRecognised(false):
                return "The file is not a Postman, Insomnia or Bruno export: it is neither JSON nor YAML that one of them writes."
            }
        }
    }

    /// Insomnia's and Bruno's documents in a file, or nil when it is neither's.
    private static func other(_ data: Data) throws -> [ImportedDocument]? {
        if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if BrunoImporter.recognises(json: root) { return try BrunoImporter.importDocuments(data: data) }
            // Checked on the parsed JSON first, so a large Postman file is not read twice.
            let isInsomnia = root["_type"] as? String == "export" || (root["__export_format"] != nil && root["resources"] != nil)
                || (root["type"] as? String)?.contains(".insomnia.rest/") == true
            return isInsomnia ? try InsomniaImporter.importDocuments(data: data) : nil
        }
        if (try? JSONSerialization.jsonObject(with: data)) != nil { return nil }
        // Not JSON, so it may be YAML, which only Insomnia writes.
        guard let text = String(data: data, encoding: .utf8), let root = try? SpecParser.parse(text).root,
              InsomniaImporter.recognises(root) else { return nil }
        return try InsomniaImporter.importDocuments(root: root)
    }

    /// Reads a zip: Postman's "Export Data", a zipped Bruno collection, or a set of export files.
    private static func importArchive(at url: URL, into batch: inout ImportBatch) throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-qq", "-o", url.path, "-d", temp.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw PostmanImportError.unreadableArchive }

        // Resolve paths first: the temp folder is reached through a symlink (/var -> /private/var).
        let rootPath = temp.resolvingSymlinksInPath().path
        let all = (fm.enumerator(at: temp, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .map { $0.resolvingSymlinksInPath() }
            .filter { !$0.path.contains("/__MACOSX/") }
            .sorted { $0.path < $1.path }

        // Bruno collections are folders; everything inside one belongs to it.
        var brunoRoots: [URL] = []
        for file in all where ["bruno.json", "collection.bru", "opencollection.yml", "opencollection.yaml"].contains(file.lastPathComponent) {
            let folder = file.deletingLastPathComponent()
            if !brunoRoots.contains(where: { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }) { brunoRoots.append(folder) }
        }
        for folder in brunoRoots {
            for document in (try? BrunoImporter.importFolder(at: folder)) ?? [] {
                // The folder was unpacked somewhere temporary, so its place cannot identify it later.
                if case .collection(var collection, let report) = document {
                    collection.postmanID = nil
                    batch.documents.append(.collection(collection, report))
                } else if case .settings(var settings) = document {
                    // Certificate files inside the zip are gone once it is tidied away.
                    let before = settings.certificates.count
                    settings.certificates.removeAll { $0.rule.certificatePath.hasPrefix(rootPath) || $0.rule.keyPath.hasPrefix(rootPath) }
                    if settings.certificates.count < before {
                        batch.skipped.append("client certificates in “\(settings.source)”: their files are inside the zip. Unzip it and import the folder to bring them over.")
                    }
                    if !settings.isEmpty { batch.documents.append(.settings(settings)) }
                } else {
                    batch.documents.append(document)
                }
            }
        }

        for file in all where ["json", "yaml", "yml"].contains(file.pathExtension.lowercased()) {
            if brunoRoots.contains(where: { file.path.hasPrefix($0.path + "/") }) { continue }
            let name = String(file.path.dropFirst(rootPath.count + 1))
            guard let data = try? Data(contentsOf: file) else { continue }
            do {
                if let documents = try other(data) {
                    batch.documents.append(contentsOf: documents)
                } else if file.pathExtension.lowercased() == "json" {
                    PostmanImporter.add(data, name: name, to: &batch)
                }
            } catch {
                batch.skipped.append("\(name): \(error.localizedDescription)")
            }
        }
    }
}
