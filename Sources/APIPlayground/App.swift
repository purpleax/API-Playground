import APIEngine
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct APIPlaygroundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @State private var importingPostman = false

    var body: some Scene {
        // One window: the app has a single workspace open at a time. A WindowGroup would
        // open an extra window each time a file is opened with the app.
        Window("API Playground", id: "main") {
            ContentView(importingPostman: $importingPostman)
                .environment(model)
                .frame(minWidth: 900, minHeight: 520)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.flushSaves()
                }
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Request") { model.newRequestInCurrentCollection() }
                    .keyboardShortcut("n")
                Button("New Collection") { model.newCollection() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Import Postman Files…") { importingPostman = true }
                    .keyboardShortcut("o")
                Button("Import cURL from Clipboard") { model.importCurlFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Divider()
                Button("Open Local Vault…") { chooseVault() }
                Button("Use Scratch Pad") { model.openVault(nil) }
                    .disabled(model.vaultURL == nil)
            }
            CommandMenu("Request") {
                Button("Send") {
                    if let id = model.selection { model.send(id) }
                }
                .keyboardShortcut(.return)
                .disabled(model.selection == nil)
                Button("Run Collection") {
                    if let id = model.selection, let index = model.collectionIndex(containingRequest: id) {
                        model.startRun(collectionID: model.collections[index].id)
                    }
                }
                .keyboardShortcut("r")
                .disabled(model.selection == nil)
                Divider()
                Button("Environments…") { model.showingEnvironments = true }
                    .keyboardShortcut("e")
            }
            CommandMenu("Demo") {
                Button(model.presentation == nil ? "Present Request" : "Stop Presenting") {
                    if model.presentation == nil { model.presentSelection() } else { model.stopPresenting() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.presentation == nil && model.selection == nil)
                Toggle("Hide Secrets", isOn: Binding(get: { model.hideSecrets }, set: { model.hideSecrets = $0 }))
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Button("New Demo…") {
                    if let id = currentCollectionID { model.newSequence(in: id) }
                }
                .disabled(currentCollectionID == nil)
                Button("Mock Server…") {
                    model.mockTarget = model.mock?.collectionID ?? currentCollectionID
                    model.showingMock = true
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model.mock == nil && currentCollectionID == nil)
            }
        }
    }

    /// The collection of the selected request, or the only collection when there is just one.
    private var currentCollectionID: UUID? {
        if let id = model.selection, let index = model.collectionIndex(containingRequest: id) {
            return model.collections[index].id
        }
        return model.collections.count == 1 ? model.collections[0].id : nil
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder to keep collections and environments in."
        if panel.runModal() == .OK, let url = panel.url {
            model.openVault(url)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the app is run as a bare executable rather than from an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Postman files dropped on the app icon, or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.importPostmanFiles(urls)
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Binding var importingPostman: Bool

    @ViewBuilder
    private var workspace: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 420)
        } detail: {
            if let id = model.selection, model.request(id) != nil {
                HSplitView {
                    RequestEditorView(requestID: id)
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    ResponseView(requestID: id)
                        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                }
                .id(id)
            } else {
                ContentUnavailableView {
                    Label("No Request Selected", systemImage: "arrow.left.arrow.right")
                } description: {
                    Text("Select a request, or import a Postman collection to get started.")
                } actions: {
                    Button("Import Postman Files…") { importingPostman = true }
                    Button("New Request") { model.newRequestInCurrentCollection() }
                }
            }
        }
        .navigationTitle(model.workspaceName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Environment", selection: $model.activeEnvironmentID) {
                    Text("No Environment").tag(UUID?.none)
                    ForEach(model.environments) { environment in
                        Text(environment.name).tag(UUID?.some(environment.id))
                    }
                }
                .frame(minWidth: 160)
                .help("The environment whose variables fill in {{placeholders}}")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showingEnvironments = true
                } label: {
                    Label("Environments", systemImage: "slider.horizontal.3")
                }
                .help("Edit environments and global variables")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $model.hideSecrets) {
                    Label("Hide Secrets", systemImage: model.hideSecrets ? "eye.slash.fill" : "eye")
                }
                .help("Mask tokens, keys and passwords on screen. Requests still send the real values.")
            }
            if let session = model.mock {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.mockTarget = session.collectionID
                        model.showingMock = true
                    } label: {
                        Label("Mock on port \(String(session.port))", systemImage: "server.rack")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                    }
                    .help("The mock server is running. Click to see its routes and requests.")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importingPostman = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import Postman collections and environments")
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.presentation != nil {
                PresentationView()
            } else {
                workspace
            }
        }
        .fileImporter(isPresented: $importingPostman, allowedContentTypes: [.json, .zip], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importPostmanFiles(urls) }
        }
        .task {
            await model.windowDidAppear()
        }
        .sheet(isPresented: $model.showingMock) {
            MockView(collectionID: model.mockTarget)
                .environment(model)
        }
        .sheet(item: $model.editingSequence) { reference in
            SequenceEditorView(reference: reference)
                .environment(model)
        }
        .sheet(isPresented: $model.showingEnvironments) {
            EnvironmentsView()
                .environment(model)
        }
        .sheet(isPresented: Binding(
            get: { model.runner != nil },
            set: { isShown in
                if !isShown { model.closeRunner() }
            }
        )) {
            RunnerView()
                .environment(model)
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }
}
