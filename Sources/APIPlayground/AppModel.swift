import APIEngine
import AppKit
import AuthenticationServices
import CryptoKit
import Observation
import SwiftUI

/// What is known about a response that is still arriving.
struct LiveStream {
    var status: Int?
    var headers: [HTTPHeader] = []
    var events: [ServerSentEvent] = []
    var bytes = 0

    var isEventStream: Bool {
        headers.contains { $0.name.lowercased() == "content-type" && $0.value.lowercased().contains("text/event-stream") }
    }
}

/// A WebSocket conversation for one request.
struct SocketSession {
    enum State { case disconnected, connecting, connected }
    var state: State = .disconnected
    var messages: [WebSocketMessage] = []
}

/// Parses an event stream as it arrives. The HTTP callbacks run off the main thread, so it locks.
private final class StreamParser: @unchecked Sendable {
    private var parser = ServerSentEventParser()
    private let lock = NSLock()

    func feed(_ chunk: Data) -> [ServerSentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return parser.feed(chunk)
    }
}

/// Tells the sign-in sheet which window to appear over.
private final class SignInAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

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
    let executor = RequestExecutor(tokens: OAuth2TokenStore(secrets: AppModel.secrets))

    /// Responses that are still arriving, by request.
    var live: [UUID: LiveStream] = [:]
    var cancelFlags: [UUID: CancellationFlag] = [:]
    /// What each gRPC server has said about its services, by address.
    var grpcSchemas: [String: ProtoSchema] = [:]
    /// Requests whose server is being asked to describe itself.
    var grpcLoading: Set<UUID> = []
    /// The last thing to tell the user about a gRPC request's schema.
    var grpcNotes: [UUID: GRPCNote] = [:]
    /// Cookies servers have set in this workspace. Kept beside the app's private data, not in the workspace.
    var cookieJar = CookieJar()
    var showingCookies = false
    var schemas: [UUID: GraphQLSchema] = [:]
    /// The request whose GraphQL schema is on screen.
    var showingSchema: UUID?
    var fetchingSchema = false
    var sockets: [UUID: SocketSession] = [:]
    private var socketClients: [UUID: WebSocketClient] = [:]
    /// Bumped when an OAuth 2 token changes, so its status redraws.
    var tokenVersion = 0
    var fetchingToken = false
    private var signInSession: ASWebAuthenticationSession?
    private let signInAnchor = SignInAnchor()

    var collections: [APICollection] = []
    var environments: [APIEnvironment] = []
    var globals: [Variable] = []

    /// The selected request.
    var selection: UUID? {
        didSet { if selection != nil { selectedSpec = nil } }
    }
    /// The API specs in the workspace, and the file name of the one being edited.
    var specs: [SpecFile] = []
    var selectedSpec: String?
    /// The workspace's lint ruleset, as text.
    var ruleset = ""
    var showingRuleset = false
    /// Routes sent straight from a spec, by spec file and operation.
    var specRuns: [String: SpecRun] = [:]
    @ObservationIgnored var specSaveTasks: [String: Task<Void, Never>] = [:]
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

    /// The workspace's Git repository, or nil when its folder is not one.
    var git: GitState?
    /// What Git is doing right now, such as "Pulling…". Nil when idle.
    var gitBusy: String?
    var gitBanner: GitBanner?
    var showingGit = false
    var showingClone = false
    /// A remote that asked for a sign-in, and what to try again once it is given.
    var gitSignIn: GitSignIn?
    /// The conflicts of a merge that is waiting for choices.
    var mergeSession: MergeSession?
    @ObservationIgnored var gitRefreshTask: Task<Void, Never>?

    var appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .dark {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            appearance.apply()
        }
    }
    var sidebarVisible = true
    /// The id of the colour theme in use.
    var paletteID = Palette.named(UserDefaults.standard.string(forKey: "palette")).id {
        didSet {
            UserDefaults.standard.set(paletteID, forKey: "palette")
            Theme.palette = Palette.named(paletteID)
        }
    }
    var showingAppearance = false

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
        Theme.palette = Palette.named(UserDefaults.standard.string(forKey: "palette"))
        history = HistoryStore(root: Self.supportDirectory.appendingPathComponent("History", isDirectory: true))
        reload()
    }

    func openVault(_ url: URL?) {
        flushSaves()
        vaultURL = url
        UserDefaults.standard.set(url?.path, forKey: "vaultPath")
        store = WorkspaceStore(root: url ?? Self.scratchPadURL, secrets: Self.secrets, localValues: Self.localValues)
        selection = nil
        selectedSpec = nil
        specRuns = [:]
        responses = [:]
        git = nil
        mergeSession = nil
        reload()
    }

    func reload() {
        do {
            try store.prepare()
            collections = try store.loadCollections()
            environments = try store.loadEnvironments()
            globals = try store.loadGlobals()
            specs = try store.loadSpecs()
            ruleset = store.loadRuleset()
            if let selectedSpec, spec(selectedSpec) == nil { self.selectedSpec = nil }
            expanded.formUnion(collections.map(\.id))
            let saved = UserDefaults.standard.string(forKey: "activeEnvironment").flatMap(UUID.init(uuidString:))
            activeEnvironmentID = environments.contains { $0.id == saved } ? saved : nil
            removeLeftoverMockEnvironment()
            loadCookies()
            if let selection, request(selection) == nil { self.selection = nil }
            refreshGit()
        } catch {
            show("Could not open the workspace", error)
        }
    }

    func show(_ title: String, _ error: Error) {
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
        refreshGit()
    }

    func renameCollection(_ id: UUID, to name: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        collections[index].name = name
        save(collections[index])
    }

    func uniqueName(_ base: String, among names: [String]) -> String {
        guard names.contains(base) else { return base }
        var counter = 2
        while names.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    // MARK: Saving

    func save(_ collection: APICollection) {
        saveTasks[collection.id]?.cancel()
        saveTasks[collection.id] = nil
        if mock?.collectionID == collection.id { refreshMock() }
        do { try store.save(collection) } catch { show("Could not save \(collection.name)", error) }
        refreshGit()
    }

    /// Writes any edits still waiting to be saved, so the files on disk are current.
    func flushPendingSaves() {
        flushSpecSaves()
        for id in Array(saveTasks.keys) {
            if let collection = collections.first(where: { $0.id == id }) { save(collection) }
        }
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
        flushSpecSaves()
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
        refreshGit()
    }

    func deleteEnvironment(_ id: UUID) {
        environments.removeAll { $0.id == id }
        if activeEnvironmentID == id { activeEnvironmentID = nil }
        do { try store.deleteEnvironment(id: id) } catch { show("Could not delete the environment", error) }
        refreshGit()
    }

    func saveGlobals(_ variables: [Variable]) {
        globals = variables
        do { try store.saveGlobals(variables) } catch { show("Could not save globals", error) }
        refreshGit()
    }

    // MARK: Sending

    private func runState(forCollection index: Int) -> RunState {
        var state = RunState(
            globals: globals,
            collectionVariables: collections[index].variables,
            environment: activeEnvironment?.variables ?? []
        )
        state.cookies = cookieJar
        return state
    }

    // MARK: Cookies

    private var cookieFile: URL {
        // One jar per workspace, named by a stable hash of the workspace's location.
        let digest = SHA256.hash(data: Data(store.root.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return Self.supportDirectory.appendingPathComponent("Cookies/\(digest).json")
    }

    private func loadCookies() {
        let data = try? Data(contentsOf: cookieFile)
        cookieJar = data.flatMap { try? JSONDecoder().decode(CookieJar.self, from: $0) } ?? CookieJar()
        cookieJar.removeExpired()
    }

    func setCookies(_ jar: CookieJar) {
        cookieJar = jar
        try? FileManager.default.createDirectory(at: cookieFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(jar).write(to: cookieFile, options: .atomic)
    }

    /// Saves what a run changed: variables set by scripts or extractions, and cookies.
    /// Only the run's own changes are applied, so requests in progress at the same time
    /// do not overwrite each other.
    private func keep(_ state: RunState, since initial: RunState, collectionID: UUID) {
        let cookies = RunState.merge(cookieJar, from: initial.cookies, to: state.cookies)
        if cookies != cookieJar { setCookies(cookies) }

        let newGlobals = RunState.merge(globals, from: initial.globals, to: state.globals)
        if newGlobals != globals { saveGlobals(newGlobals) }

        if let index = collections.firstIndex(where: { $0.id == collectionID }) {
            let variables = RunState.merge(collections[index].variables, from: initial.collectionVariables, to: state.collectionVariables)
            if variables != collections[index].variables {
                collections[index].variables = variables
                save(collections[index])
            }
        }
        if var environment = activeEnvironment {
            let variables = RunState.merge(environment.variables, from: initial.environment, to: state.environment)
            if variables != environment.variables {
                environment.variables = variables
                saveEnvironment(environment)
            }
        }
    }

    func record(_ result: RequestRunResult) {
        pinnedShown[result.requestID] = nil
        responses[result.requestID] = .finished(result)
        if let prepared = result.prepared, let response = result.response {
            try? history.record(HistoryEntry(request: prepared, response: response), requestID: result.requestID)
            historyVersion += 1
        }
    }

    func send(_ id: UUID) {
        guard let index = collectionIndex(containingRequest: id), let request = collections[index].request(id: id) else { return }
        if case .sending = responses[id] { return }
        if request.isGRPC {
            sendGRPC(id)
            return
        }
        let collection = collections[index]
        let initial = runState(forCollection: index)
        responses[id] = .sending
        live[id] = LiveStream()
        let flag = CancellationFlag()
        cancelFlags[id] = flag

        // Show the status and any server-sent events while the response is still open.
        let parser = StreamParser()
        let handlers = HTTPStreamHandlers(
            onHeaders: { status, headers in
                Task { @MainActor in
                    AppModel.shared.live[id]?.status = status
                    AppModel.shared.live[id]?.headers = headers
                }
            },
            onData: { chunk in
                let events = parser.feed(chunk)
                Task { @MainActor in
                    AppModel.shared.live[id]?.bytes += chunk.count
                    AppModel.shared.live[id]?.events += events
                }
            }
        )
        Task {
            var state = initial
            let result = await executor.run(request, in: collection, state: &state, handlers: handlers, cancellation: flag)
            keep(state, since: initial, collectionID: collection.id)
            cancelFlags[id] = nil
            live[id] = nil
            record(result)
        }
    }

    /// Stops a request that is in progress. An open event stream keeps the events it had.
    func cancel(_ id: UUID) {
        cancelFlags[id]?.cancel()
    }

    // MARK: GraphQL

    func fetchSchema(_ id: UUID) {
        guard let prepared = preview(id), !fetchingSchema else { return }
        fetchingSchema = true
        Task {
            defer { fetchingSchema = false }
            do {
                let response = try await executor.client.send(GraphQL.introspectionRequest(from: prepared))
                schemas[id] = try GraphQL.parseSchema(response.body)
                showingSchema = id
            } catch {
                show("Could not load the schema", error)
            }
        }
    }

    // MARK: OAuth 2

    func oauthToken(_ id: UUID) -> OAuth2Token? {
        _ = tokenVersion
        return executor.tokens?.token(for: id)
    }

    func clearOAuthToken(_ id: UUID) {
        executor.tokens?.clear(id)
        tokenVersion += 1
    }

    /// Fetches a new token: directly for the automatic grants, or through a browser sign-in.
    func getOAuthToken(_ config: OAuth2Config, requestID: UUID) {
        guard let index = collectionIndex(containingRequest: requestID), !fetchingToken else { return }
        let resolver = resolver(forCollection: index)
        if config.grant.isAutomatic {
            fetchingToken = true
            executor.tokens?.clear(config.id)
            Task {
                defer {
                    fetchingToken = false
                    tokenVersion += 1
                }
                do {
                    _ = try await executor.accessToken(for: config, resolver: resolver)
                } catch {
                    show("Could not get a token", error)
                }
            }
            return
        }

        do {
            let pkce = OAuth2.pkce()
            let state = UUID().uuidString
            let url = try OAuth2.authorizationURL(config, resolver: resolver, state: state, codeChallenge: config.usePKCE ? pkce.challenge : nil)
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "apiplayground") { callback, error in
                Task { @MainActor in
                    let model = AppModel.shared
                    model.signInSession = nil
                    guard let callback else {
                        // Closing the sign-in window is not an error worth a message.
                        if let error, (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                            model.show("Sign-in did not complete", error)
                        }
                        return
                    }
                    model.fetchingToken = true
                    defer {
                        model.fetchingToken = false
                        model.tokenVersion += 1
                    }
                    do {
                        let code = try OAuth2.code(fromCallback: callback, expectedState: state)
                        let request = try OAuth2.tokenRequest(config, resolver: resolver, code: code, codeVerifier: config.usePKCE ? pkce.verifier : nil)
                        let token = try OAuth2.parseToken(try await model.executor.client.send(request))
                        model.executor.tokens?.save(token, for: config.id)
                    } catch {
                        model.show("Could not get a token", error)
                    }
                }
            }
            session.presentationContextProvider = signInAnchor
            signInSession = session
            session.start()
        } catch {
            show("Could not start sign-in", error)
        }
    }

    // MARK: WebSockets

    /// Whether a request's address, with variables filled in, is a WebSocket address.
    func isWebSocket(_ id: UUID) -> Bool {
        guard let index = collectionIndex(containingRequest: id), let request = collections[index].request(id: id) else { return false }
        if WebSocketClient.isWebSocketURL(request.url) { return true }
        guard request.url.contains("{{") else { return false }
        return WebSocketClient.isWebSocketURL(resolver(forCollection: index).resolve(request.url).string)
    }

    func connectSocket(_ id: UUID) {
        guard let prepared = preview(id), let url = URL(string: prepared.url) else {
            sockets[id, default: SocketSession()].messages.append(WebSocketMessage(direction: .system, text: "The address is not valid."))
            return
        }
        disconnectSocket(id)
        var headers = prepared.headers.filter { $0.name.caseInsensitiveCompare("User-Agent") != .orderedSame }
        // The handshake is an HTTP request, so stored cookies apply. Match them as http or https.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = url.scheme?.lowercased() == "wss" ? "https" : "http"
        if prepared.header("Cookie") == nil, let httpURL = components?.url, let cookies = cookieJar.header(for: httpURL) {
            headers.append(HTTPHeader(name: "Cookie", value: cookies))
        }
        let client = WebSocketClient { event in
            Task { @MainActor in AppModel.shared.handleSocket(event, for: id) }
        }
        socketClients[id] = client
        var session = sockets[id] ?? SocketSession()
        session.state = .connecting
        session.messages.append(WebSocketMessage(direction: .system, text: "Connecting to \(redactor(for: id)?.url(prepared.url) ?? prepared.url)"))
        sockets[id] = session
        client.connect(url: url, headers: headers)
    }

    private func handleSocket(_ event: WebSocketEvent, for id: UUID) {
        var session = sockets[id] ?? SocketSession()
        switch event {
        case .connected(let subprotocol):
            session.state = .connected
            session.messages.append(WebSocketMessage(direction: .system, text: subprotocol.map { "Connected, using \($0)" } ?? "Connected"))
        case .message(let message):
            session.messages.append(message)
        case .closed(let code, let reason):
            session.state = .disconnected
            let detail = reason.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""
            session.messages.append(WebSocketMessage(direction: .system, text: "Closed (\(code))\(detail)"))
            socketClients[id] = nil
        case .failed(let message):
            session.state = .disconnected
            session.messages.append(WebSocketMessage(direction: .system, text: "Disconnected: \(message)"))
            socketClients[id] = nil
        }
        // Keep the log from growing without limit on a busy socket.
        if session.messages.count > 2000 { session.messages.removeFirst(session.messages.count - 2000) }
        sockets[id] = session
    }

    func disconnectSocket(_ id: UUID) {
        socketClients[id]?.close()
    }

    func sendSocketMessage(_ id: UUID, text: String) {
        guard let client = socketClients[id], sockets[id]?.state == .connected, let index = collectionIndex(containingRequest: id) else { return }
        let resolved = resolver(forCollection: index).resolve(text).string
        sockets[id]?.messages.append(WebSocketMessage(direction: .sent, text: resolved))
        Task {
            do {
                try await client.send(resolved)
            } catch {
                sockets[id]?.messages.append(WebSocketMessage(direction: .system, text: "Could not send: \(error.localizedDescription)"))
            }
        }
    }

    func clearSocketLog(_ id: UUID) {
        sockets[id]?.messages = []
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
            keep(state, since: initial, collectionID: collectionID)
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
        var own = ((request?.headers ?? []) + (request?.params ?? []))
            .filter { Redactor.isSensitiveName($0.key) }
            .map { resolver.resolve($0.value).string }
        // An OAuth 2 token is as secret as any other, wherever a server echoes it.
        if case .oauth2(let config) = collections[index].effectiveAuth(forRequest: requestID), let token = executor.tokens?.token(for: config.id) {
            own.append(token.accessToken)
            if let refresh = token.refreshToken { own.append(refresh) }
        }
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

    /// Imports exports from Postman, Insomnia and Bruno: files, zips and Bruno collection folders.
    func importFiles(_ urls: [URL]) {
        var lines: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let batch = try Importer.importFile(at: url)
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
    private func add(_ document: ImportedDocument) -> [String] {
        switch document {
        case .collection(var collection, let report):
            var verb = "Imported"
            // Importing a newer export of the same collection updates it in place.
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

        case .spec(let name, let text):
            // A spec that came with a collection, such as an Insomnia design document.
            let isJSON = text.drop(while: \.isWhitespace).first == "{"
            let spec = SpecFile(file: store.newSpecFileName(for: name, extension: isJSON ? "json" : "yaml"), text: text)
            do {
                try store.save(spec)
                specs.append(spec)
                specs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return ["Imported API spec \"\(spec.name)\"."]
            } catch {
                return ["The API spec \"\(name)\" could not be saved: \(error.localizedDescription)"]
            }

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
            return ["\(verb) environment \"\(environment.name)\": \(Self.count(report.variables, "variable"))."] + report.warnings
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
