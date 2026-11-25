import APIEngine
import AppKit
import Foundation

/// One route sent straight from a spec's preview.
struct SpecRun {
    var isRunning = false
    var result: RequestRunResult?
}

extension AppModel {
    static let specTemplate = """
    openapi: 3.0.3
    info:
      title: New API
      version: 1.0.0
      description: Describe what this API does.
      contact:
        name: Your name
    servers:
      - url: http://localhost:8080
    tags:
      - name: example
    paths:
      /hello:
        get:
          operationId: sayHello
          summary: Say hello
          description: Returns a greeting.
          tags: [example]
          responses:
            '200':
              description: A greeting
              content:
                application/json:
                  example:
                    message: Hello

    """

    func spec(_ file: String) -> SpecFile? {
        specs.first { $0.file == file }
    }

    private func sortSpecs() {
        specs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func newSpec() {
        let spec = SpecFile(file: store.newSpecFileName(for: "new-api"), text: Self.specTemplate)
        do {
            try store.save(spec)
            specs.append(spec)
            sortSpecs()
            selection = nil
            selectedSpec = spec.file
            refreshGit()
        } catch {
            show("Could not create the spec", error)
        }
    }

    /// Copies spec files into the workspace. The originals are left where they are.
    func importSpecs(_ urls: [URL]) {
        var problems: [String] = []
        var last: String?
        for url in urls {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                // Refuse files that are not specs, rather than filling the list with them.
                _ = try OpenAPIDocument(text: text)
                var ext = url.pathExtension.lowercased()
                if !WorkspaceStore.specExtensions.contains(ext) { ext = "yaml" }
                let spec = SpecFile(file: store.newSpecFileName(for: url.deletingPathExtension().lastPathComponent, extension: ext), text: text)
                try store.save(spec)
                specs.append(spec)
                last = spec.file
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        sortSpecs()
        if let last {
            selection = nil
            selectedSpec = last
        }
        refreshGit()
        if !problems.isEmpty {
            notice = Notice(title: "Some files were not imported", message: problems.joined(separator: "\n"))
        }
    }

    func chooseSpecsToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.yaml, .json]
        panel.prompt = "Import"
        panel.message = "Choose OpenAPI or Swagger files. They are copied into this workspace."
        if panel.runModal() == .OK { importSpecs(panel.urls) }
    }

    /// Changes a spec's text, and saves it shortly after the last edit.
    func updateSpec(_ file: String, text: String) {
        guard let index = specs.firstIndex(where: { $0.file == file }), specs[index].text != text else { return }
        specs[index].text = text
        specSaveTasks[file]?.cancel()
        specSaveTasks[file] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveSpecNow(file)
        }
    }

    private func saveSpecNow(_ file: String) {
        specSaveTasks[file]?.cancel()
        specSaveTasks[file] = nil
        guard let spec = spec(file) else { return }
        do { try store.save(spec) } catch { show("Could not save \(spec.file)", error) }
        refreshGit()
    }

    func flushSpecSaves() {
        for file in Array(specSaveTasks.keys) { saveSpecNow(file) }
    }

    func deleteSpec(_ file: String) {
        specSaveTasks[file]?.cancel()
        specSaveTasks[file] = nil
        do { try store.deleteSpec(file: file) } catch { show("Could not delete \(file)", error) }
        specs.removeAll { $0.file == file }
        if selectedSpec == file { selectedSpec = nil }
        refreshGit()
    }

    func saveRuleset(_ text: String) {
        guard text != ruleset else { return }
        ruleset = text
        do { try store.saveRuleset(text) } catch { show("Could not save the lint ruleset", error) }
        refreshGit()
    }

    // MARK: Generating

    func collection(forSpec file: String) -> APICollection? {
        collections.first { $0.specFile == file }
    }

    /// Makes a collection from a spec, or brings the one made earlier up to date.
    /// - Returns: The collection's id and a sentence saying what happened, or nil when the spec cannot be read.
    @discardableResult
    func generateCollection(fromSpec file: String) -> (id: UUID, message: String)? {
        guard let spec = spec(file) else { return nil }
        let document: OpenAPIDocument
        do {
            document = try OpenAPIDocument(text: spec.text)
        } catch {
            show("The spec could not be read", error)
            return nil
        }
        var collection = document.collection(specFile: file)
        let count = collection.allRequests.count
        let requests = "\(count) \(count == 1 ? "request" : "requests")"
        let message: String
        if let index = collections.firstIndex(where: { $0.specFile == file }) {
            let old = collections[index]
            // Requests keep their ids, and so their history, when their name and place are unchanged.
            collection = collection.adoptingIdentities(from: old)
            // Values someone has filled in, such as a token, are kept.
            collection.variables = collection.variables.map { variable in
                guard variable.key != OpenAPIDocument.baseVariable, let kept = old.variables.first(where: { $0.key == variable.key }) else { return variable }
                return kept
            }
            collections[index] = collection
            message = "Updated the collection “\(collection.name)” from this spec: \(requests)."
        } else {
            collection.name = uniqueName(collection.name, among: collections.map(\.name))
            collections.append(collection)
            message = "Made the collection “\(collection.name)” from this spec: \(requests), each with its documented responses as examples."
        }
        expanded.insert(collection.id)
        save(collection)
        return (collection.id, message)
    }

    /// Opens the mock server sheet for a spec's collection, making the collection first if need be.
    func mockSpec(_ file: String) {
        guard let generated = generateCollection(fromSpec: file) else { return }
        mockTarget = generated.id
        showingMock = true
    }

    // MARK: Sending a route from the preview

    static func runKey(_ file: String, _ operation: OpenAPIOperation) -> String { "\(file)|\(operation.id)" }

    /// Sends one of a spec's routes to a server, without needing a collection.
    func sendRoute(_ operation: OpenAPIOperation, of document: OpenAPIDocument, specFile: String, baseURL: String) {
        let key = Self.runKey(specFile, operation)
        if specRuns[key]?.isRunning == true { return }
        specRuns[key] = SpecRun(isRunning: true, result: specRuns[key]?.result)

        var template = document.collection()
        let existing = collection(forSpec: specFile)
        // Use values filled in on the generated collection, such as a token.
        template.variables = template.variables.map { variable in
            if variable.key == OpenAPIDocument.baseVariable { return Variable(key: variable.key, value: baseURL) }
            return existing?.variables.first { $0.key == variable.key } ?? variable
        }
        let request = document.request(for: operation)
        template.items = [.request(request)]
        let collection = template

        var state = RunState(globals: globals, collectionVariables: collection.variables, environment: activeEnvironment?.variables ?? [])
        state.cookies = cookieJar
        Task {
            let result = await executor.run(request, in: collection, state: &state)
            specRuns[key] = SpecRun(isRunning: false, result: result)
        }
    }
}
