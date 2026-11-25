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
        .defaultSize(width: 1360, height: 840)
        .windowStyle(.hiddenTitleBar)
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
            CommandGroup(after: .sidebar) {
                Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    withAnimation(.snappy(duration: 0.2)) { model.sidebarVisible.toggle() }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                Button("Theme…") { model.showingAppearance = true }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Picker("Colour Theme", selection: Binding(get: { model.paletteID }, set: { model.paletteID = $0 })) {
                    ForEach(Palette.all) { palette in
                        Text(palette.name).tag(palette.id)
                    }
                }
                Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.appearance = $0 })) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
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
        AppModel.shared.appearance.apply()
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
        VStack(spacing: 0) {
            TopBar(importingPostman: $importingPostman)
            HStack(spacing: 0) {
                if model.sidebarVisible {
                    SidebarView()
                        .frame(width: 276)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .leading))
                    Rectangle().fill(Theme.stroke).frame(width: 1)
                }
                detail
                    .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.canvas)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selection, model.request(id) != nil {
            HSplitView {
                RequestEditorView(requestID: id)
                    .card()
                    .padding(.leading, 10)
                    .padding(.trailing, 5)
                    .padding(.vertical, 10)
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                ResponseView(requestID: id)
                    .card()
                    .padding(.leading, 5)
                    .padding(.trailing, 10)
                    .padding(.vertical, 10)
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            .id(id)
            .background(Theme.canvas)
        } else {
            EmptyState(
                systemImage: "bolt.horizontal.fill",
                title: "Nothing selected",
                detail: "Pick a request from the sidebar, or bring in a Postman collection to get started."
            ) {
                Button("Import Postman Files…") { importingPostman = true }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                Button("New Request") { model.newRequestInCurrentCollection() }
                    .buttonStyle(SecondaryButtonStyle(large: true))
            }
            .background(Theme.canvas)
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
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .ignoresSafeArea(.container, edges: .top)
        // Colours are read when a view is built, so a new theme rebuilds the window's content.
        .id(model.paletteID)
        .sheet(isPresented: $model.showingAppearance) {
            AppearanceView()
                .environment(model)
                .themedSheet()
                .id(model.paletteID)
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
                .themedSheet()
        }
        .sheet(item: $model.editingSequence) { reference in
            SequenceEditorView(reference: reference)
                .environment(model)
                .themedSheet()
        }
        .sheet(isPresented: $model.showingEnvironments) {
            EnvironmentsView()
                .environment(model)
                .themedSheet()
        }
        .sheet(isPresented: Binding(
            get: { model.runner != nil },
            set: { isShown in
                if !isShown { model.closeRunner() }
            }
        )) {
            RunnerView()
                .environment(model)
                .themedSheet()
        }
        .sheet(item: $model.notice) { notice in
            NoticeView(title: notice.title, message: notice.message) { model.notice = nil }
                .themedSheet()
        }
    }
}

/// The custom bar across the top of the window, in place of a standard toolbar.
struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Binding var importingPostman: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Room for the window's close, minimise and zoom buttons.
            Color.clear.frame(width: 70, height: 1)
            IconButton(systemImage: "sidebar.left", active: !model.sidebarVisible, help: model.sidebarVisible ? "Hide the sidebar" : "Show the sidebar") {
                withAnimation(.snappy(duration: 0.2)) { model.sidebarVisible.toggle() }
            }
            LogoMark(size: 22)
            Text("API Playground")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(model.workspaceName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.raised, in: Capsule())
                .help(model.vaultURL == nil ? "Working in the Scratch Pad" : "Working in a Local Vault folder")

            Spacer(minLength: 12)

            if let session = model.mock {
                Button {
                    model.mockTarget = session.collectionID
                    model.showingMock = true
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.success).frame(width: 7, height: 7)
                            .shadow(color: Theme.success, radius: 4)
                        Text("Mock :\(String(session.port))")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.success)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.success.opacity(0.12), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("The mock server is running. Click to see its routes and requests.")
            }

            environmentMenu

            IconButton(systemImage: "paintpalette", help: "Choose a colour theme") {
                model.showingAppearance = true
            }
            IconButton(systemImage: "slider.horizontal.3", help: "Edit environments and global variables") {
                model.showingEnvironments = true
            }
            IconButton(systemImage: model.hideSecrets ? "eye.slash.fill" : "eye", active: model.hideSecrets,
                       help: "Hide secrets: mask tokens, keys and passwords on screen. Requests still send the real values.") {
                model.hideSecrets.toggle()
            }
            IconButton(systemImage: "square.and.arrow.down", help: "Import Postman collections and environments") {
                importingPostman = true
            }
        }
        .padding(.trailing, 12)
        .frame(height: 48)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }

    private var environmentMenu: some View {
        Menu {
            Button {
                model.activeEnvironmentID = nil
            } label: {
                if model.activeEnvironmentID == nil { Label("No Environment", systemImage: "checkmark") } else { Text("No Environment") }
            }
            if !model.environments.isEmpty { Divider() }
            ForEach(model.environments) { environment in
                Button {
                    model.activeEnvironmentID = environment.id
                } label: {
                    if model.activeEnvironmentID == environment.id {
                        Label(environment.name, systemImage: "checkmark")
                    } else {
                        Text(environment.name)
                    }
                }
            }
            Divider()
            Button("Edit Environments…") { model.showingEnvironments = true }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.activeEnvironment == nil ? Theme.textTertiary : Theme.accent)
                    .frame(width: 7, height: 7)
                Text(model.activeEnvironment?.name ?? "No Environment")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The environment whose variables fill in {{placeholders}}")
    }
}
