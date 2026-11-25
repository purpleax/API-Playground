import APIEngine
import AppKit
import Observation
import SwiftUI

/// The result of sending one request.
enum ResponseState {
    case sending
    case finished(RequestRunResult)
}

/// One request in a folder or collection run.
struct RunnerRow: Identifiable {
    let id: UUID
    var name: String
    var method: String
    var isRunning = false
    var result: RequestRunResult?
}

/// A run of every request in a folder or collection, in order.
struct RunnerSession: Identifiable {
    let id = UUID()
    var title: String
    var collectionID: UUID
    var folderID: UUID?
    var rows: [RunnerRow]
    var isRunning = false
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
    private let executor = RequestExecutor()

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
    var runner: RunnerSession?
    private var runnerTask: Task<Void, Never>?

    private var saveTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: Workspace location

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The test build names a different folder, so it never shares data with the real app.
        let folder = Bundle.main.object(forInfoDictionaryKey: "APSupportFolderName") as? String ?? "API Playground"
        return base.appendingPathComponent(folder, isDirectory: true)
    }

    /// The test build keeps its secrets apart from the real app's.
    static var secrets: KeychainSecretStore {
        let isTest = Bundle.main.bundleIdentifier?.hasSuffix(".test") ?? false
        return KeychainSecretStore(service: isTest ? "com.apiplayground.secrets.test" : "com.apiplayground.secrets")
    }

    /// Current values are kept beside the app's other private data, never in a workspace.
    static var localValues: LocalValueStore {
        LocalValueStore(file: supportDirectory.appendingPathComponent("Local Values.json"))
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
        store = WorkspaceStore(root: usableVault ?? Self.scratchPadURL, secrets: Self.secrets, localValues: Self.localValues)
        history = HistoryStore(root: Self.supportDirectory.appendingPathComponent("History", isDirectory: true))
        reload()
    }

    func openVault(_ url: URL?) {
        flushSaves()
        vaultURL = url
        UserDefaults.standard.set(url?.path, forKey: "vaultPath")
        store = WorkspaceStore(root: url ?? Self.scratchPadURL, secrets: Self.secrets, localValues: Self.localValues)
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

    private func runState(forCollection index: Int) -> RunState {
        RunState(
            globals: globals,
            collectionVariables: collections[index].variables,
            environment: activeEnvironment?.variables ?? []
        )
    }

    /// Saves the variables that scripts or extractions changed during a run.
    private func keep(_ state: RunState, collectionID: UUID) {
        if state.globals != globals { saveGlobals(state.globals) }
        if let index = collections.firstIndex(where: { $0.id == collectionID }),
           collections[index].variables != state.collectionVariables {
            collections[index].variables = state.collectionVariables
            save(collections[index])
        }
        if var environment = activeEnvironment, environment.variables != state.environment {
            environment.variables = state.environment
            saveEnvironment(environment)
        }
    }

    private func record(_ result: RequestRunResult) {
        responses[result.requestID] = .finished(result)
        if let prepared = result.prepared, let response = result.response {
            try? history.record(HistoryEntry(request: prepared, response: response), requestID: result.requestID)
            historyVersion += 1
        }
    }

    func send(_ id: UUID) {
        guard let index = collectionIndex(containingRequest: id), let request = collections[index].request(id: id) else { return }
        let collection = collections[index]
        let initial = runState(forCollection: index)
        responses[id] = .sending
        Task {
            var state = initial
            let result = await executor.run(request, in: collection, state: &state)
            keep(state, collectionID: collection.id)
            record(result)
        }
    }

    // MARK: Running a folder or collection

    func startRun(collectionID: UUID, folderID: UUID? = nil) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        runnerTask?.cancel()
        let collection = collections[index]
        let requests = collection.requests(inFolder: folderID)
        let folderName = folderID.flatMap { id in requests.first.flatMap { collection.folders(containingRequest: $0.id).first { $0.id == id }?.name } }
        var session = RunnerSession(
            title: folderName.map { "\(collection.name) / \($0)" } ?? collection.name,
            collectionID: collectionID,
            folderID: folderID,
            rows: requests.map { RunnerRow(id: $0.id, name: $0.name, method: $0.method) }
        )
        session.isRunning = !requests.isEmpty
        runner = session
        let sessionID = session.id
        let initial = runState(forCollection: index)

        runnerTask = Task {
            // One set of variables for the whole run, so a value saved by one request reaches the next.
            var state = initial
            for (position, request) in requests.enumerated() {
                guard !Task.isCancelled, runner?.id == sessionID else { break }
                runner?.rows[position].isRunning = true
                let result = await executor.run(request, in: collection, state: &state)
                guard runner?.id == sessionID else { break }
                runner?.rows[position].isRunning = false
                runner?.rows[position].result = result
                record(result)
            }
            keep(state, collectionID: collectionID)
            if runner?.id == sessionID { runner?.isRunning = false }
        }
    }

    func stopRun() {
        runnerTask?.cancel()
        runner?.isRunning = false
    }

    func closeRunner() {
        runnerTask?.cancel()
        runner = nil
    }

    func historyEntries(_ id: UUID) -> [HistoryEntry] {
        history.entries(requestID: id)
    }

    // MARK: Importing

    private var windowReady = false
    private var pendingNotice: Notice?

    func windowDidAppear() async {
        try? await Task.sleep(for: .milliseconds(500))
        windowReady = true
        if let pendingNotice {
            notice = pendingNotice
            self.pendingNotice = nil
        }
    }

    func importPostmanFiles(_ urls: [URL]) {
        var lines: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let batch = try PostmanImporter.importFile(at: url)
                for document in batch.documents {
                    lines.append(contentsOf: add(document))
                }
                lines.append(contentsOf: batch.skipped.map { "Skipped \($0)" })
                if batch.documents.isEmpty && batch.skipped.isEmpty {
                    lines.append("\(url.lastPathComponent): nothing to import.")
                }
            } catch {
                lines.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let report = Notice(title: "Import finished", message: lines.joined(separator: "\n"))
        // SwiftUI drops an alert set before the window exists, which happens when files are
        // opened at launch. Hold the report until the window is up.
        if windowReady {
            notice = report
        } else {
            pendingNotice = report
        }
    }

    /// Adds an imported document to the workspace and returns lines for the import report.
    private func add(_ document: PostmanDocument) -> [String] {
        switch document {
        case .collection(var collection, let report):
            var verb = "Imported"
            // Importing a newer export of the same Postman collection updates it in place.
            if let postmanID = collection.postmanID,
               let index = collections.firstIndex(where: { $0.postmanID == postmanID }) {
                // Requests keep their ids, and so their history, when their name and place are unchanged.
                collection = collection.adoptingIdentities(from: collections[index])
                collections[index] = collection
                verb = "Updated"
            } else {
                collections.append(collection)
            }
            expanded.insert(collection.id)
            save(collection)
            if let selection, request(selection) == nil { self.selection = nil }

            var lines = ["\(verb) collection \"\(collection.name)\": \(Self.count(report.requests, "request")), \(Self.count(report.folders, "folder")), \(Self.count(report.examples, "example")), \(Self.count(report.variables, "variable"))."]
            if report.scriptsPreserved > 0 {
                lines.append("\(Self.count(report.scriptsPreserved, "script")) imported.")
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
                return ["Imported \(Self.count(report.variables, "global variable"))."]
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
            return ["\(verb) environment \"\(environment.name)\": \(Self.count(report.variables, "variable"))."]
        }
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
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
