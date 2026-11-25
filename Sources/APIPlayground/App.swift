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
        WindowGroup("API Playground") {
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
                Button("Environments…") { model.showingEnvironments = true }
                    .keyboardShortcut("e")
            }
        }
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

    var body: some View {
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
                Button {
                    importingPostman = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import Postman collections and environments")
            }
        }
        .fileImporter(isPresented: $importingPostman, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importPostmanFiles(urls) }
        }
        .sheet(isPresented: $model.showingEnvironments) {
            EnvironmentsView()
                .environment(model)
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }
}
