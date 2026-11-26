import APIEngine
import SwiftUI

/// One thing the command palette can do or open.
struct PaletteItem: Identifiable {
    let id: String
    var title: String
    var detail: String = ""
    var systemImage: String
    /// The kind of item, shown at the right: "Request", "Environment" and so on.
    var kind: String
    /// A method to show as a coloured badge, for requests.
    var method: String?
    let run: () -> Void
}

extension AppModel {
    /// Everything the palette offers right now: every request, then the actions that apply.
    func paletteItems(importFiles: @escaping () -> Void) -> [PaletteItem] {
        var items: [PaletteItem] = []

        for collection in collections {
            for request in collection.allRequests {
                let folders = collection.folders(containingRequest: request.id).map(\.name)
                let method = request.isGRPC ? "GRPC" : request.method.uppercased()
                items.append(PaletteItem(
                    id: "request-\(request.id)", title: request.name,
                    detail: ([collection.name] + folders).joined(separator: " / ") + (request.url.isEmpty ? "" : "  ·  \(request.url)"),
                    systemImage: "arrow.up.right", kind: "Request", method: method
                ) { [weak self] in
                    guard let self else { return }
                    self.expanded.insert(collection.id)
                    for folder in collection.folders(containingRequest: request.id) { self.expanded.insert(folder.id) }
                    self.selection = request.id
                })
            }
        }
        for spec in specs {
            items.append(PaletteItem(id: "spec-\(spec.file)", title: spec.name, detail: "API spec", systemImage: "doc.text", kind: "Spec") { [weak self] in
                self?.selectedSpec = spec.file
            })
        }

        func action(_ title: String, _ image: String, detail: String = "", kind: String = "Action", _ run: @escaping () -> Void) {
            items.append(PaletteItem(id: "action-\(kind)-\(title)", title: title, detail: detail, systemImage: image, kind: kind, run: run))
        }

        if let id = selection, let request = request(id) {
            let isSocket = isWebSocket(id)
            action(isSocket ? "Connect" : "Send Request", "paperplane.fill", detail: request.name) { [weak self] in
                if isSocket { self?.connectSocket(id) } else { self?.send(id) }
            }
            if canExport(id) {
                action("Copy as cURL", "terminal", detail: request.name) { [weak self] in self?.copySnippet(id, language: .curl) }
                action("Copy as Code…", "curlybraces", detail: request.name) { [weak self] in self?.showingSnippet = id }
                action("Repeat Request…", "repeat", detail: "Send it many times and measure the response time") { [weak self] in self?.openRepeat(id) }
            }
            if !environments.isEmpty {
                action("Compare Across Environments…", "arrow.left.arrow.right", detail: request.name) { [weak self] in self?.openComparison(id) }
            }
            action("Present Request", "play.rectangle", detail: request.name) { [weak self] in self?.presentSelection() }
        }

        action("New Request", "plus") { [weak self] in self?.newRequestInCurrentCollection() }
        action("New gRPC Request", "plus") { [weak self] in self?.newGRPCRequest() }
        action("New Collection", "folder.badge.plus") { [weak self] in self?.newCollection() }
        action("New API Spec", "doc.badge.plus") { [weak self] in self?.newSpec() }
        action("Import…", "square.and.arrow.down", detail: "From Postman, Insomnia or Bruno", importFiles)
        action("Import cURL from Clipboard", "doc.on.clipboard") { [weak self] in self?.importCurlFromClipboard() }

        for collection in collections {
            action("Run \(collection.name)", "play.fill", detail: "Run every request in order", kind: "Run") { [weak self] in
                self?.startRun(collectionID: collection.id)
            }
            if mock?.collectionID != collection.id {
                action("Start Mock Server for \(collection.name)", "server.rack", kind: "Mock") { [weak self] in
                    self?.startMock(collectionID: collection.id)
                }
            }
            for sequence in collection.sequences {
                action("Present \(sequence.name)", "play.rectangle.fill", detail: collection.name, kind: "Demo") { [weak self] in
                    self?.present(SequenceReference(collectionID: collection.id, sequenceID: sequence.id))
                }
            }
        }
        if let session = mock {
            action("Stop Mock Server", "stop.fill", detail: "\(session.collectionName) on port \(session.port)", kind: "Mock") { [weak self] in self?.stopMock() }
        }

        for environment in environments where environment.id != activeEnvironmentID {
            action("Use \(environment.name)", "circle.grid.2x1", kind: "Environment") { [weak self] in
                self?.activeEnvironmentID = environment.id
            }
        }
        if activeEnvironmentID != nil {
            action("Use No Environment", "circle.dashed", kind: "Environment") { [weak self] in self?.activeEnvironmentID = nil }
        }
        action("Edit Environments…", "slider.horizontal.3") { [weak self] in self?.showingEnvironments = true }
        action("Cookies…", "circle.hexagongrid") { [weak self] in self?.showingCookies = true }
        action("Proxy and Certificates…", "person.badge.key") { [weak self] in self?.showingClientCertificates = true }
        action(hideSecrets ? "Show Secrets" : "Hide Secrets", hideSecrets ? "eye" : "eye.slash") { [weak self] in self?.hideSecrets.toggle() }
        action(sidebarVisible ? "Hide Sidebar" : "Show Sidebar", "sidebar.left") { [weak self] in self?.sidebarVisible.toggle() }

        if git != nil {
            action("Git Sync…", "arrow.triangle.branch", kind: "Git") { [weak self] in self?.showingGit = true }
            if git?.remoteURL != nil {
                action("Pull", "arrow.down", kind: "Git") { [weak self] in Task { await self?.pull() } }
                action("Push", "arrow.up", kind: "Git") { [weak self] in Task { await self?.push() } }
            }
        }
        action("Clone a Repository…", "arrow.down.doc", kind: "Git") { [weak self] in self?.showingClone = true }

        for palette in Palette.all where palette.id != paletteID {
            action("\(palette.name) Theme", "paintpalette", kind: "Theme") { [weak self] in self?.paletteID = palette.id }
        }
        for appearance in AppAppearance.allCases where appearance != self.appearance {
            action("\(appearance.title) Appearance", "circle.lefthalf.filled", kind: "Theme") { [weak self] in self?.appearance = appearance }
        }
        return items
    }
}

/// A search box over everything in the workspace and everything the app can do, opened with ⌘K.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    let importFiles: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @State private var items: [PaletteItem] = []
    @FocusState private var focused: Bool

    /// The items that match what was typed, best first. With nothing typed, requests come first as listed.
    private var matches: [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(items.prefix(60)) }
        let scored: [(PaletteItem, Int)] = items.compactMap { item in
            // The name counts for more than the detail line beneath it.
            if let score = FuzzyMatch.score(trimmed, in: item.title) { return (item, score + 50) }
            if let score = FuzzyMatch.score(trimmed, in: "\(item.method ?? "") \(item.title) \(item.detail) \(item.kind)") { return (item, score) }
            return nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(60).map(\.0)
    }

    var body: some View {
        let matches = matches
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { close() }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Go to a request, or type a command", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.text)
                        .focused($focused)
                        .onSubmit { run(matches) }
                        .onKeyPress(.downArrow) { move(1, in: matches) }
                        .onKeyPress(.upArrow) { move(-1, in: matches) }
                        .onKeyPress(.escape) {
                            close()
                            return .handled
                        }
                    Text("esc")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.stroke))
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
                Rectangle().fill(Theme.stroke).frame(height: 1)

                if matches.isEmpty {
                    Text("Nothing matches \"\(query)\"")
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.vertical, 28)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                                    Button {
                                        highlighted = index
                                        run(matches)
                                    } label: {
                                        row(item, isHighlighted: index == highlighted)
                                    }
                                    .buttonStyle(.plain)
                                    .id(item.id)
                                }
                            }
                            .padding(6)
                        }
                        .frame(height: min(380, CGFloat(matches.count) * 44 + 12))
                        .onChange(of: highlighted) { _, new in
                            if matches.indices.contains(new) { proxy.scrollTo(matches[new].id) }
                        }
                    }
                }
            }
            .frame(width: 640)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
            .padding(.top, 90)
        }
        .onAppear {
            items = model.paletteItems(importFiles: importFiles)
            focused = true
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func row(_ item: PaletteItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            if let method = item.method {
                MethodBadge(method: method)
                    .frame(width: 52, alignment: .leading)
            } else {
                Image(systemName: item.systemImage)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isHighlighted ? Theme.accent : Theme.textSecondary)
                    .frame(width: 52, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(item.kind)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            if isHighlighted {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(isHighlighted ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func move(_ offset: Int, in matches: [PaletteItem]) -> KeyPress.Result {
        guard !matches.isEmpty else { return .handled }
        highlighted = (highlighted + offset + matches.count) % matches.count
        return .handled
    }

    private func run(_ matches: [PaletteItem]) {
        guard matches.indices.contains(highlighted) else { return }
        let item = matches[highlighted]
        close()
        item.run()
    }

    private func close() {
        model.showingPalette = false
    }
}

/// What the menu-bar item shows: the mock server's state, and controls to start and stop it.
struct MockMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true

    var body: some View {
        if let session = model.mock {
            Text("Mock server: \(session.collectionName)")
            Text(session.url)
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.url, forType: .string)
            }
            Button("Stop Mock Server") { model.stopMock() }
        } else {
            Text("No mock server is running")
        }
        Divider()
        if model.collections.isEmpty {
            Text("No collections to mock")
        } else {
            Menu(model.mock == nil ? "Start Mock Server" : "Switch Mock Server To") {
                ForEach(model.collections) { collection in
                    Button(collection.name) { model.startMock(collectionID: collection.id) }
                        .disabled(model.mock?.collectionID == collection.id)
                }
            }
        }
        Divider()
        Button("Open API Playground") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Hide This Menu Bar Item") { showMenuBarItem = false }
        Divider()
        Button("Quit API Playground") { NSApp.terminate(nil) }
    }
}
