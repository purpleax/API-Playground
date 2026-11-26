import APIEngine
import AppIntents
import Foundation

// Actions for the Shortcuts app. They run inside API Playground, on the open workspace.

struct RequestEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Request")
    static let defaultQuery = RequestQuery()

    var id: UUID
    var name: String
    var detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }
}

struct RequestQuery: EntityStringQuery {
    @MainActor
    private func all() -> [RequestEntity] {
        AppModel.shared.collections.flatMap { collection in
            collection.allRequests.filter { !$0.isGRPC }.map {
                RequestEntity(id: $0.id, name: $0.name, detail: "\(collection.name)  ·  \($0.method) \($0.url)")
            }
        }
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [RequestEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [RequestEntity] {
        all().filter { FuzzyMatch.score(string, in: "\($0.name) \($0.detail)") != nil }
    }

    @MainActor
    func suggestedEntities() async throws -> [RequestEntity] {
        all()
    }
}

struct CollectionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Collection")
    static let defaultQuery = CollectionQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct CollectionQuery: EntityStringQuery {
    @MainActor
    private func all() -> [CollectionEntity] {
        AppModel.shared.collections.map { CollectionEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [CollectionEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [CollectionEntity] {
        all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [CollectionEntity] {
        all()
    }
}

struct EnvironmentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Environment")
    static let defaultQuery = EnvironmentQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct EnvironmentQuery: EntityStringQuery {
    @MainActor
    private func all() -> [EnvironmentEntity] {
        AppModel.shared.environments.map { EnvironmentEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [EnvironmentEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [EnvironmentEntity] {
        all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [EnvironmentEntity] {
        all()
    }
}

/// Why an action could not finish, in words Shortcuts shows to the user.
struct ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    var message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

struct SendRequestIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Request"
    static let description = IntentDescription(
        "Sends a request from the open workspace and returns the response body. Its scripts and tests run as they do in the app.",
        categoryName: "Requests"
    )

    @Parameter(title: "Request")
    var request: RequestEntity

    @Parameter(title: "Environment", description: "The environment to send it in. Leave empty to use the one that is active in the app.")
    var environment: EnvironmentEntity?

    @Parameter(title: "Fail on an Error Status", description: "Stop the shortcut when the server answers with a 4xx or 5xx status, or a test fails.", default: false)
    var failOnError: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$request)") {
            \.$environment
            \.$failOnError
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let result = await AppModel.shared.sendAndWait(request.id, environmentID: environment?.id) else {
            throw ShortcutError(message: "\"\(request.name)\" is no longer in the workspace.")
        }
        guard let response = result.response else {
            throw ShortcutError(message: result.error ?? "\"\(request.name)\" did not get a response.")
        }
        if failOnError, response.status >= 400 || !result.passed {
            let failed = result.failedTests.map(\.name).joined(separator: ", ")
            throw ShortcutError(message: "\(request.name): \(response.status) \(response.statusText)" + (failed.isEmpty ? "" : ". Failed: \(failed)"))
        }
        let body = response.text ?? "\(response.body.count) bytes of binary data"
        let time = String(format: "%.0f ms", response.timings.total * 1000)
        return .result(value: body, dialog: "\(response.status) \(response.statusText) in \(time)")
    }
}

struct RunCollectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Collection"
    static let description = IntentDescription(
        "Runs every request in a collection in order and returns whether everything passed.",
        categoryName: "Requests"
    )

    @Parameter(title: "Collection")
    var collection: CollectionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$collection)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let results = await AppModel.shared.runAndWait(collectionID: collection.id)
        guard !results.isEmpty else {
            throw ShortcutError(message: "\"\(collection.name)\" has no requests to run.")
        }
        let passed = results.filter(\.passed).count
        return .result(value: passed == results.count, dialog: "\(passed) of \(results.count) requests passed in \(collection.name)")
    }
}

struct StartMockServerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Mock Server"
    static let description = IntentDescription(
        "Starts a mock server that answers with a collection's pinned responses, and returns its address.",
        categoryName: "Mock Servers"
    )

    @Parameter(title: "Collection")
    var collection: CollectionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start a mock server for \(\.$collection)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let session = await AppModel.shared.startMockAndWait(collectionID: collection.id) else {
            throw ShortcutError(message: "The mock server for \"\(collection.name)\" could not be started.")
        }
        return .result(value: session.url, dialog: "The mock server for \(collection.name) is running at \(session.url)")
    }
}

struct StopMockServerIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Mock Server"
    static let description = IntentDescription("Stops the mock server, if one is running.", categoryName: "Mock Servers")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let wasRunning = AppModel.shared.mock != nil
        AppModel.shared.stopMock()
        return .result(dialog: wasRunning ? "The mock server has stopped" : "No mock server was running")
    }
}

struct SetEnvironmentIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Environment"
    static let description = IntentDescription(
        "Chooses the environment whose variables fill in requests. Leave it empty for no environment.",
        categoryName: "Requests"
    )

    @Parameter(title: "Environment")
    var environment: EnvironmentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Use the environment \(\.$environment)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.activeEnvironmentID = environment?.id
        return .result(dialog: environment.map { "Using \($0.name)" } ?? "Using no environment")
    }
}

struct PlaygroundShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendRequestIntent(),
            phrases: ["Send a request with \(.applicationName)", "Send \(\.$request) with \(.applicationName)"],
            shortTitle: "Send Request", systemImageName: "paperplane.fill"
        )
        AppShortcut(
            intent: RunCollectionIntent(),
            phrases: ["Run a collection with \(.applicationName)", "Run \(\.$collection) with \(.applicationName)"],
            shortTitle: "Run Collection", systemImageName: "play.fill"
        )
        AppShortcut(
            intent: StartMockServerIntent(),
            phrases: ["Start a mock server with \(.applicationName)"],
            shortTitle: "Start Mock Server", systemImageName: "server.rack"
        )
        AppShortcut(
            intent: StopMockServerIntent(),
            phrases: ["Stop the mock server in \(.applicationName)"],
            shortTitle: "Stop Mock Server", systemImageName: "stop.fill"
        )
    }
}
