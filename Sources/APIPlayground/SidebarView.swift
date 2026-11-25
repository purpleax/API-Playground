import APIEngine
import SwiftUI

/// The collection tree, with a filter field above it.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Filter requests", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !filter.isEmpty {
                    Button {
                        filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the filter")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if filter.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(model.collections) { collection in
                            collectionSection(collection)
                        }
                        specsSection
                    } else {
                        filteredResults
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .overlay {
                if model.collections.isEmpty, model.specs.isEmpty {
                    Text("No collections yet")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(spacing: 8) {
                Button {
                    model.newRequestInCurrentCollection()
                } label: {
                    Label("New Request", systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                IconButton(systemImage: "doc.badge.plus", help: "New API spec") { model.newSpec() }
                IconButton(systemImage: "shippingbox", help: "New collection") { model.newCollection() }
            }
            .padding(10)
        }
        .background(Theme.chrome)
    }

    // MARK: Tree

    @ViewBuilder
    private func collectionSection(_ collection: APICollection) -> some View {
        let isOpen = model.expanded.contains(collection.id)
        SidebarRow(depth: 0, isSelected: false) {
            toggle(collection.id)
        } content: {
            Chevron(isOpen: isOpen)
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.gradient)
                .frame(width: 14, height: 14)
                .overlay(
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                )
            if renaming == collection.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .onSubmit {
                        model.renameCollection(collection.id, to: renameText)
                        renaming = nil
                    }
            } else {
                Text(collection.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(collection.allRequests.count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .contextMenu {
            Button("Run Collection") { model.startRun(collectionID: collection.id) }
            Button("New Demo…") { model.newSequence(in: collection.id) }
            Button("Mock Server…") {
                model.mockTarget = collection.id
                model.showingMock = true
            }
            Divider()
            Button("New Request") { model.newRequest(in: collection.id) }
            Button("New Folder") { model.newFolder(in: collection.id) }
            Button("Rename") {
                renameText = collection.name
                renaming = collection.id
            }
            Divider()
            Button("Delete Collection", role: .destructive) { model.deleteCollection(collection.id) }
        }

        if isOpen {
            ForEach(collection.items) { node in
                NodeView(node: node, collectionID: collection.id, depth: 1)
            }
            ForEach(collection.sequences) { sequence in
                let reference = SequenceReference(collectionID: collection.id, sequenceID: sequence.id)
                SidebarRow(depth: 1, isSelected: false) {
                    model.editingSequence = reference
                } content: {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.violet)
                        .frame(width: 42)
                    Text(sequence.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("DEMO")
                        .font(.system(size: 8.5, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(Theme.violet)
                }
                .help("Demo sequence: click to edit")
                .contextMenu {
                    Button("Present") { model.present(reference) }
                    Button("Edit") { model.editingSequence = reference }
                    Divider()
                    Button("Delete Demo", role: .destructive) { model.deleteSequence(reference) }
                }
            }
        }
    }

    /// The workspace's API specs, under the collections.
    @ViewBuilder
    private var specsSection: some View {
        if !model.specs.isEmpty {
            Text("Specs").sectionTitle()
                .padding(.leading, 8)
                .padding(.top, 14)
                .padding(.bottom, 3)
            ForEach(model.specs) { spec in
                SidebarRow(depth: 0, isSelected: model.selectedSpec == spec.file) {
                    model.selection = nil
                    model.selectedSpec = spec.file
                } content: {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 14)
                    Text(spec.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text((spec.file as NSString).pathExtension.uppercased())
                        .font(.system(size: 8.5, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                }
                .contextMenu {
                    Button(model.collection(forSpec: spec.file) == nil ? "Make Collection" : "Update Collection") {
                        if let made = model.generateCollection(fromSpec: spec.file) {
                            model.notice = Notice(title: "Collection ready", message: made.message)
                        }
                    }
                    Button("Mock Server…") { model.mockSpec(spec.file) }
                    Divider()
                    Button("Delete Spec", role: .destructive) { model.deleteSpec(spec.file) }
                }
            }
        }
    }

    /// Every request whose name, method or URL contains the filter text.
    @ViewBuilder
    private var filteredResults: some View {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = model.collections.flatMap { collection in
            collection.allRequests
                .filter { "\($0.method) \($0.name) \($0.url)".lowercased().contains(query) }
                .map { (collection: collection, request: $0) }
        }
        if matches.isEmpty {
            Text("No requests match")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textTertiary)
                .padding(10)
        }
        ForEach(matches, id: \.request.id) { match in
            SidebarRow(depth: 0, isSelected: model.selection == match.request.id) {
                model.selection = match.request.id
            } content: {
                MethodBadge(method: match.request.method)
                VStack(alignment: .leading, spacing: 1) {
                    Text(match.request.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(match.collection.name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func toggle(_ id: UUID) {
        withAnimation(.snappy(duration: 0.18)) {
            if model.expanded.contains(id) { model.expanded.remove(id) } else { model.expanded.insert(id) }
        }
    }
}

/// One folder or request in the tree. Folders contain more of these.
struct NodeView: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let collectionID: UUID
    let depth: Int

    var body: some View {
        switch node {
        case .request(let request):
            SidebarRow(depth: depth, isSelected: model.selection == request.id) {
                model.selection = request.id
            } content: {
                MethodBadge(method: WebSocketClient.isWebSocketURL(request.url) ? "WS" : request.method)
                Text(request.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(model.selection == request.id ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contextMenu {
                Button("Send") {
                    model.selection = request.id
                    model.send(request.id)
                }
                Divider()
                Button("Delete Request", role: .destructive) { model.deleteNode(request.id, in: collectionID) }
            }
        case .folder(let folder):
            let isOpen = model.expanded.contains(folder.id)
            SidebarRow(depth: depth, isSelected: false) {
                withAnimation(.snappy(duration: 0.18)) {
                    if isOpen { model.expanded.remove(folder.id) } else { model.expanded.insert(folder.id) }
                }
            } content: {
                Chevron(isOpen: isOpen)
                Image(systemName: isOpen ? "folder.fill" : "folder")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.info)
                Text(folder.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contextMenu {
                Button("Run Folder") { model.startRun(collectionID: collectionID, folderID: folder.id) }
                Divider()
                Button("New Request") { model.newRequest(in: collectionID, folder: folder.id) }
                Button("New Folder") { model.newFolder(in: collectionID, parent: folder.id) }
                Divider()
                Button("Delete Folder", role: .destructive) { model.deleteNode(folder.id, in: collectionID) }
            }
            if isOpen {
                ForEach(folder.items) { child in
                    NodeView(node: child, collectionID: collectionID, depth: depth + 1)
                }
            }
        }
    }
}

private struct Chevron: View {
    let isOpen: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(Theme.textTertiary)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .frame(width: 10)
    }
}

/// A clickable row with a hover highlight, and an accent bar when selected.
private struct SidebarRow<Content: View>: View {
    let depth: Int
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) { content }
                .padding(.leading, 8 + CGFloat(depth) * 14)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.smallRadius)
                        .fill(isSelected ? Theme.accent.opacity(0.13) : (hovering ? Theme.raised : .clear))
                )
                .overlay(alignment: .leading) {
                    if isSelected {
                        Capsule()
                            .fill(Theme.gradient)
                            .frame(width: 3, height: 16)
                            .padding(.leading, 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
