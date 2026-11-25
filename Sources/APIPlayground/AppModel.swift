import APIEngine
import AppKit
import Observation
import SwiftUI

/// The result of sending one request.
enum ResponseState {
    case sending
    case done(HTTPResponse, PreparedRequest)
    case failed(String)
}

struct Notice: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// Everything the window shows: the open workspace, the selection and the latest responses.
@MainActor
@Observable
final class AppModel {
    /// The app has one workspace open at a time, shared by the window and the app delegate.
    static let shared = AppModel()

    private(set) var store: WorkspaceStore
    private let history: HistoryStore
    private let client = HTTPClient()

    var collections: [APICollection] = []
    var environments: [APIEnvironment] = []
    var globals: [Variable] = []

    /// The selected request.
    var selection: UUID?
    var activeEnvironmentID: UUID? {
        didSet { UserDefaults.standard.set(activeEnvironmentID?.uuidString, forKey: "activeEnvironment") }
    }
    var expanded: Set<UUID> = []
    var responses: [UUID: ResponseState] = [:]
    /// Bumped after each send so the history list reloads.
    var historyVersion = 0
    var notice: Notice?
    var showingEnvironments = false

    private var saveTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: Workspace location

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("API Playground", isDirectory: true)
    }

    static var scratchPadURL: URL { supportDirectory.appendingPathComponent("Scratch Pad", isDirectory: true) }

    /// The Local Vault folder, or nil when the Scratch Pad is in use.
    private(set) var vaultURL: URL?

    var workspaceName: String {
        vaultURL.map { $0.lastPathComponent } ?? "Scratch Pad"
    }

    init() {
        let vault = UserDefaults.standard.string(forKey: "vaultPath").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let usableVault = vault.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        vaultURL = usableVault
        store = WorkspaceStore(root: usableVault ?? Self.scratchPadURL, secrets: KeychainSecretStore())
        history = HistoryStore(root: Self.supportDirectory.appendingPathComponent("History", isDirectory: true))
        reload()
    }

    func openVault(_ url: URL?) {
        flushSaves()
        vaultURL = url
        UserDefaults.standard.set(url?.path, forKey: "vaultPath")
        store = WorkspaceStore(root: url ?? Self.scratchPadURL, secrets: KeychainSecretStore())
        selection = nil
        responses = [:]
        reload()
    }

    func reload() {
        do {
            try store.prepare()
            collections = try store.loadCollections()
            environments = try store.loadEnvironments()
            globals = try store.loadGlobals()
            expanded.formUnion(collections.map(\.id))
            let saved = UserDefaults.standard.string(forKey: "activeEnvironment").flatMap(UUID.init(uuidString:))
            activeEnvironmentID = environments.contains { $0.id == saved } ? saved : nil
        } catch {
            show("Could not open the workspace", error)
        }
    }

    private func show(_ title: String, _ error: Error) {
        notice = Notice(title: title, message: error.localizedDescription)
    }

    // MARK: Lookup

    var activeEnvironment: APIEnvironment? {
        environments.first { $0.id == activeEnvironmentID }
    }

    func collectionIndex(containingRequest id: UUID) -> Int? {
        collections.firstIndex { $0.request(id: id) != nil }
    }

    func request(_ id: UUID) -> RequestItem? {
        for collection in collections {
            if let request = collection.request(id: id) { return request }
        }
        return nil
    }

    func effectiveAuth(_ id: UUID) -> Auth {
        guard let index = collectionIndex(containingRequest: id) else { return .none }
        return collections[index].effectiveAuth(forRequest: id)
    }

    func resolver(forCollection index: Int) -> VariableResolver {
        VariableResolver(
            globals: globals,
            collection: collections[index].variables,
            environment: activeEnvironment?.variables ?? []
        )
    }

    // MARK: Editing

    func update(_ request: RequestItem) {
        guard let index = collectionIndex(containingRequest: request.id) else { return }
        collections[index].updateRequest(request)
        scheduleSave(collections[index].id)
    }

    func newCollection() {
        let collection = APICollection(name: uniqueName("New Collection", among: collections.map(\.name)))
        collections.append(collection)
        expanded.insert(collection.id)
        save(collection)
    }

    func newRequest(in collectionID: UUID, folder: UUID? = nil, request: RequestItem = RequestItem()) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[index].append(.request(request), toFolder: folder)
        expanded.insert(collectionID)
        if let folder { expanded.insert(folder) }
        selection = request.id
        save(collections[index])
    }

    /// Adds a request next to the selected one, or to the first collection, creating one if needed.
    func newRequestInCurrentCollection(_ request: RequestItem = RequestItem()) {
        if collections.isEmpty { newCollection() }
        let index = selection.flatMap(collectionIndex(containingRequest:)) ?? 0
        newRequest(in: collections[index].id, request: request)
    }

    func newFolder(in collectionID: UUID, parent: UUID? = nil) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        let folder = Folder()
        collections[index].append(.folder(folder), toFolder: parent)
        expanded.insert(folder.id)
        save(collections[index])
    }

    func deleteNode(_ id: UUID, in collectionID: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[index].removeNode(id: id)
        if let selection, request(selection) == nil { self.selection = nil }
        save(collections[index])
    }

    func deleteCollection(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        collections.removeAll { $0.id == id }
        if let selection, request(selection) == nil { self.selection = nil }
        do { try store.deleteCollection(id: id) } catch { show("Could not delete the collection", error) }
    }

    func renameCollection(_ id: UUID, to name: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        collections[index].name = name
        save(collections[index])
    }

    private func uniqueName(_ base: String, among names: [String]) -> String {
        guard names.contains(base) else { return base }
        var counter = 2
        while names.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    // MARK: Saving

    private func save(_ collection: APICollection) {
        saveTasks[collection.id]?.cancel()
        saveTasks[collection.id] = nil
        do { try store.save(collection) } catch { show("Could not save \(collection.name)", error) }
    }

    /// Saves shortly after the last edit, so typing does not write a file per keystroke.
    private func scheduleSave(_ collectionID: UUID) {
        saveTasks[collectionID]?.cancel()
        saveTasks[collectionID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            if let collection = self.collections.first(where: { $0.id == collectionID }) {
                self.save(collection)
            }
        }
    }

    func flushSaves() {
        for id in Array(saveTasks.keys) {
            if let collection = collections.first(where: { $0.id == id }) { save(collection) }
        }
    }

    // MARK: Environments

    func saveEnvironment(_ environment: APIEnvironment) {
        if let index = environments.firstIndex(where: { $0.id == environment.id }) {
            environments[index] = environment
        } else {
            environments.append(environment)
        }
        do { try store.save(environment) } catch { show("Could not save \(environment.name)", error) }
    }

    func deleteEnvironment(_ id: UUID) {
        environments.removeAll { $0.id == id }
        if activeEnvironmentID == id { activeEnvironmentID = nil }
        do { try store.deleteEnvironment(id: id) } catch { show("Could not delete the environment", error) }
    }

    func saveGlobals(_ variables: [Variable]) {
        globals = variables
        do { try store.saveGlobals(variables) } catch { show("Could not save globals", error) }
    }

    // MARK: Sending

    func send(_ id: UUID) {
        guard let index = collectionIndex(containingRequest: id), let request = collections[index].request(id: id) else { return }
        let prepared: PreparedRequest
        do {
            prepared = try RequestBuilder.prepare(
                request, auth: collections[index].effectiveAuth(forRequest: id), resolver: resolver(forCollection: index)
            )
        } catch {
            responses[id] = .failed(error.localizedDescription)
            return
        }

        responses[id] = .sending
        Task {
            do {
                let response = try await client.send(prepared)
                responses[id] = .done(response, prepared)
                try? history.record(HistoryEntry(request: prepared, response: response), requestID: id)
                historyVersion += 1
            } catch {
                responses[id] = .failed(error.localizedDescription)
            }
        }
    }

    func historyEntries(_ id: UUID) -> [HistoryEntry] {
        history.entries(requestID: id)
    }

    // MARK: Importing

    func importPostmanFiles(_ urls: [URL]) {
        var lines: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let document = try PostmanImporter.importDocument(data: Data(contentsOf: url))
                lines.append(contentsOf: add(document))
            } catch {
                lines.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        notice = Notice(title: "Import finished", message: lines.joined(separator: "\n"))
    }

    /// Adds an imported document to the workspace and returns lines for the import report.
    private func add(_ document: PostmanDocument) -> [String] {
        switch document {
        case .collection(var collection, let report):
            var verb = "Imported"
            // Importing a newer export of the same Postman collection updates it in place.
            if let postmanID = collection.postmanID,
               let index = collections.firstIndex(where: { $0.postmanID == postmanID }) {
                collection.id = collections[index].id
                collections[index] = collection
                verb = "Updated"
            } else {
                collections.append(collection)
            }
            expanded.insert(collection.id)
            save(collection)
            if let selection, request(selection) == nil { self.selection = nil }

            var lines = ["\(verb) collection \"\(collection.name)\": \(report.requests) requests, \(report.folders) folders, \(report.examples) examples, \(report.variables) variables."]
            if report.scriptsPreserved > 0 {
                lines.append("\(report.scriptsPreserved) scripts were kept but will not run yet.")
            }
            lines.append(contentsOf: report.warnings)
            return lines

        case .environment(var environment, let isGlobals, let report):
            if isGlobals {
                var merged = globals
                for variable in environment.variables {
                    merged.removeAll { $0.key == variable.key }
                    merged.append(variable)
                }
                saveGlobals(merged)
                return ["Imported \(report.variables) global variables."]
            }
            var verb = "Imported"
            if let index = environments.firstIndex(where: {
                ($0.postmanID != nil && $0.postmanID == environment.postmanID) || $0.name == environment.name
            }) {
                environment.id = environments[index].id
                verb = "Updated"
            }
            saveEnvironment(environment)
            if activeEnvironmentID == nil { activeEnvironmentID = environment.id }
            return ["\(verb) environment \"\(environment.name)\": \(report.variables) variables."]
        }
    }

    func importCurlFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            notice = Notice(title: "Nothing to import", message: "The clipboard has no text.")
            return
        }
        do {
            let request = try CurlImporter.importCommand(text.trimmingCharacters(in: .whitespacesAndNewlines))
            newRequestInCurrentCollection(request)
        } catch {
            show("Could not import from the clipboard", error)
        }
    }
}
