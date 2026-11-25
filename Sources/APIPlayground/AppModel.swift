import APIEngine
import AppKit
import Observation
import SwiftUI

/// The result of sending one request.
enum ResponseState {
    case sending
    case finished(RequestRunResult)
}

/// A mock server that is running for one collection.
struct MockSession {
    var collectionID: UUID
    var collectionName: String
    var port: UInt16
    var routes: [MockRoute]
    var hits: [MockHit] = []
    /// The variable pointed at the mock, such as "baseUrl", when the collection's URLs share one.
    var baseVariable: String?
    /// The environment made to redirect requests to the mock, and the one that was active before.
    var environmentID: UUID?
    var previousEnvironmentID: UUID?

    var url: String { "http://127.0.0.1:\(port)" }
}

/// Which demo sequence is open in the editor.
struct SequenceReference: Identifiable, Equatable {
    var collectionID: UUID
    var sequenceID: UUID
    var id: UUID { sequenceID }
}

/// A demo being presented: the steps, and which one is showing.
struct PresentationState {
    var title: String
    var steps: [DemoStep]
    var index = 0

    var step: DemoStep? { steps.indices.contains(index) ? steps[index] : nil }
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

    var appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .dark {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            appearance.apply()
        }
    }
    var sidebarVisible = true

    /// Masks secrets everywhere they are displayed. Requests are still sent with real values.
    var hideSecrets = UserDefaults.standard.bool(forKey: "hideSecrets") {
        didSet { UserDefaults.standard.set(hideSecrets, forKey: "hideSecrets") }
    }
    /// The name of the pinned response on screen for a request, when one is showing instead of a live response.
    var pinnedShown: [UUID: String] = [:]
    var mock: MockSession?
    var showingMock = false
    /// The collection the Mock Server panel offers to start a mock for.
    var mockTarget: UUID?
    private var mockServer: MockServer?
    var editingSequence: SequenceReference?
    var presentation: PresentationState?
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
            removeLeftoverMockEnvironment()
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
        if mock?.collectionID == collection.id { refreshMock() }
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
        // Remove the temporary mock environment rather than leaving it behind in the workspace.
        stopMock()
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
        pinnedShown[result.requestID] = nil
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

    // MARK: Hiding secrets

    /// Secrets are always hidden while presenting, whatever the setting.
    var secretsHidden: Bool { hideSecrets || presentation != nil }

    /// The redactor for a request's views, or nil when secrets are being shown.
    func redactor(for requestID: UUID) -> Redactor? {
        guard secretsHidden, let index = collectionIndex(containingRequest: requestID) else { return nil }
        let resolver = resolver(forCollection: index)
        // The request's own key-like headers and parameters, which a server may echo back.
        let request = collections[index].request(id: requestID)
        let own = ((request?.headers ?? []) + (request?.params ?? []))
            .filter { Redactor.isSensitiveName($0.key) }
            .map { resolver.resolve($0.value).string }
        return Redactor(
            variables: globals + collections[index].variables + (activeEnvironment?.variables ?? []),
            auths: [collections[index].effectiveAuth(forRequest: requestID)],
            resolver: resolver,
            extra: own
        )
    }

    /// The request as it would be sent now, for showing its real URL and body.
    func preview(_ requestID: UUID) -> PreparedRequest? {
        guard let index = collectionIndex(containingRequest: requestID), let request = collections[index].request(id: requestID) else { return nil }
        return try? RequestBuilder.prepare(
            request, auth: collections[index].effectiveAuth(forRequest: requestID), resolver: resolver(forCollection: index)
        )
    }

    // MARK: Pinned responses

    /// Saves the response on screen with the request, to show again later or serve from a mock.
    func pinResponse(_ requestID: UUID) {
        guard case .finished(let result) = responses[requestID], let response = result.response,
              pinnedShown[requestID] == nil, var request = request(requestID) else { return }
        let base = "\(response.status) \(response.statusText)".trimmingCharacters(in: .whitespaces)
        request.examples.append(SavedResponse(name: uniqueName(base, among: request.examples.map(\.name)), pinning: response))
        update(request)
    }

    func showPinned(_ requestID: UUID, _ example: SavedResponse) {
        guard let request = request(requestID) else { return }
        var result = RequestRunResult(requestID: requestID)
        result.prepared = PreparedRequest(method: request.method, url: request.url)
        result.response = example.asResponse
        responses[requestID] = .finished(result)
        pinnedShown[requestID] = example.name
    }

    func removePinned(_ requestID: UUID, name: String) {
        guard var request = request(requestID) else { return }
        request.examples.removeAll { $0.name == name }
        update(request)
        if pinnedShown[requestID] == name {
            pinnedShown[requestID] = nil
            responses[requestID] = nil
        }
    }

    // MARK: Mock server

    /// Removes the temporary environment of a mock that was running when the app last quit
    /// without stopping it, and goes back to the environment that was active before.
    private func removeLeftoverMockEnvironment() {
        let defaults = UserDefaults.standard
        guard mock == nil, let leftover = defaults.string(forKey: "mockEnvironment").flatMap(UUID.init(uuidString:)) else { return }
        let previous = defaults.string(forKey: "mockPreviousEnvironment").flatMap(UUID.init(uuidString:))
        defaults.removeObject(forKey: "mockEnvironment")
        defaults.removeObject(forKey: "mockPreviousEnvironment")
        guard environments.contains(where: { $0.id == leftover }) else { return }
        let wasActive = activeEnvironmentID == leftover
        deleteEnvironment(leftover)
        if wasActive, environments.contains(where: { $0.id == previous }) {
            activeEnvironmentID = previous
        }
    }

    func startMock(collectionID: UUID) {
        guard let collection = collections.first(where: { $0.id == collectionID }) else { return }
        stopMock()
        let routes = MockServer.routes(for: collection)
        let server = MockServer(routes: routes)
        server.onHit { hit in
            Task { @MainActor in
                AppModel.shared.mock?.hits.insert(hit, at: 0)
                if let count = AppModel.shared.mock?.hits.count, count > 200 {
                    AppModel.shared.mock?.hits.removeLast(count - 200)
                }
            }
        }
        Task {
            do {
                let port = try await server.start()
                mockServer = server
                var session = MockSession(
                    collectionID: collectionID, collectionName: collection.name, port: port, routes: routes,
                    baseVariable: MockServer.baseVariable(of: collection), previousEnvironmentID: activeEnvironmentID
                )
                // Point the collection at the mock with a temporary environment, leaving the user's own untouched.
                if let variable = session.baseVariable {
                    var variables = activeEnvironment?.variables ?? []
                    variables.removeAll { $0.key == variable }
                    variables.append(Variable(key: variable, value: session.url))
                    let environment = APIEnvironment(name: uniqueName("Mock: \(collection.name)", among: environments.map(\.name)), variables: variables)
                    saveEnvironment(environment)
                    // Remembered on disk, so it can be removed at the next launch if the app is force-quit.
                    UserDefaults.standard.set(environment.id.uuidString, forKey: "mockEnvironment")
                    UserDefaults.standard.set(activeEnvironmentID?.uuidString, forKey: "mockPreviousEnvironment")
                    activeEnvironmentID = environment.id
                    session.environmentID = environment.id
                }
                mock = session
            } catch {
                show("Could not start the mock server", error)
            }
        }
    }

    func stopMock() {
        mockServer?.stop()
        mockServer = nil
        guard let session = mock else { return }
        if let id = session.environmentID {
            let wasActive = activeEnvironmentID == id
            deleteEnvironment(id)
            if wasActive, environments.contains(where: { $0.id == session.previousEnvironmentID }) {
                activeEnvironmentID = session.previousEnvironmentID
            }
            UserDefaults.standard.removeObject(forKey: "mockEnvironment")
            UserDefaults.standard.removeObject(forKey: "mockPreviousEnvironment")
        }
        mock = nil
    }

    /// Reloads the mock's routes after pinned responses change.
    func refreshMock() {
        guard let session = mock, let collection = collections.first(where: { $0.id == session.collectionID }) else { return }
        let routes = MockServer.routes(for: collection)
        guard routes != session.routes else { return }
        let server = MockServer(routes: routes)
        server.onHit { hit in
            Task { @MainActor in AppModel.shared.mock?.hits.insert(hit, at: 0) }
        }
        mockServer?.stop()
        mockServer = nil
        Task {
            // Reuse the port, so the environment that points at the mock stays valid.
            for _ in 0..<20 {
                if let port = try? await server.start(port: session.port) {
                    mockServer = server
                    mock?.routes = routes
                    mock?.port = port
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            notice = Notice(title: "The mock server stopped", message: "It could not be restarted on port \(session.port). Start it again from the Mock Server panel.")
            stopMock()
        }
    }

    // MARK: Demo sequences

    func newSequence(in collectionID: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        var sequence = DemoSequence(name: uniqueName("New Demo", among: collections[index].sequences.map(\.name)))
        // Start with every request in order: removing steps is quicker than adding them.
        sequence.steps = collections[index].allRequests.map { DemoStep(requestID: $0.id) }
        collections[index].sequences.append(sequence)
        expanded.insert(collectionID)
        save(collections[index])
        editingSequence = SequenceReference(collectionID: collectionID, sequenceID: sequence.id)
    }

    func sequence(_ reference: SequenceReference) -> DemoSequence? {
        collections.first { $0.id == reference.collectionID }?.sequences.first { $0.id == reference.sequenceID }
    }

    func updateSequence(_ sequence: DemoSequence, in collectionID: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }),
              let position = collections[index].sequences.firstIndex(where: { $0.id == sequence.id }) else { return }
        collections[index].sequences[position] = sequence
        scheduleSave(collectionID)
    }

    func deleteSequence(_ reference: SequenceReference) {
        guard let index = collections.firstIndex(where: { $0.id == reference.collectionID }) else { return }
        collections[index].sequences.removeAll { $0.id == reference.sequenceID }
        save(collections[index])
        if editingSequence == reference { editingSequence = nil }
    }

    // MARK: Presenting

    func present(_ reference: SequenceReference) {
        guard let sequence = sequence(reference) else { return }
        let steps = sequence.steps.filter { request($0.requestID) != nil }
        guard !steps.isEmpty else {
            notice = Notice(title: "Nothing to present", message: "\"\(sequence.name)\" has no steps yet.")
            return
        }
        editingSequence = nil
        presentation = PresentationState(title: sequence.name, steps: steps)
        selection = steps[0].requestID
    }

    /// Presents the selected request on its own.
    func presentSelection() {
        guard let id = selection, let request = request(id) else { return }
        presentation = PresentationState(title: request.name, steps: [DemoStep(requestID: id)])
    }

    func presentationMove(by offset: Int) {
        guard var state = presentation else { return }
        let next = state.index + offset
        guard state.steps.indices.contains(next) else { return }
        state.index = next
        presentation = state
        selection = state.steps[next].requestID
    }

    func stopPresenting() {
        presentation = nil
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
