import APIEngine
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.collections) { collection in
                DisclosureGroup(isExpanded: expansion(collection.id)) {
                    ForEach(collection.items) { node in
                        NodeView(node: node, collectionID: collection.id)
                    }
                } label: {
                    if renaming == collection.id {
                        TextField("Name", text: $renameText)
                            .onSubmit {
                                model.renameCollection(collection.id, to: renameText)
                                renaming = nil
                            }
                    } else {
                        Label(collection.name, systemImage: "shippingbox")
                            .fontWeight(.medium)
                    }
                }
                .contextMenu {
                    Button("New Request") { model.newRequest(in: collection.id) }
                    Button("New Folder") { model.newFolder(in: collection.id) }
                    Button("Rename") {
                        renameText = collection.name
                        renaming = collection.id
                    }
                    Divider()
                    Button("Delete Collection", role: .destructive) { model.deleteCollection(collection.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.collections.isEmpty {
                Text("No collections yet")
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("New Request") { model.newRequestInCurrentCollection() }
                    Button("New Collection") { model.newCollection() }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .padding(8)
        }
    }

    private func expansion(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { model.expanded.contains(id) },
            set: { isOpen in
                if isOpen { model.expanded.insert(id) } else { model.expanded.remove(id) }
            }
        )
    }
}

/// One folder or request in the tree. Folders contain more of these.
struct NodeView: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let collectionID: UUID

    var body: some View {
        switch node {
        case .request(let request):
            HStack(spacing: 6) {
                MethodBadge(method: request.method)
                Text(request.name)
                    .lineLimit(1)
            }
            .tag(request.id)
            .contextMenu {
                Button("Delete Request", role: .destructive) { model.deleteNode(request.id, in: collectionID) }
            }
        case .folder(let folder):
            DisclosureGroup(isExpanded: Binding(
                get: { model.expanded.contains(folder.id) },
                set: { isOpen in
                    if isOpen { model.expanded.insert(folder.id) } else { model.expanded.remove(folder.id) }
                }
            )) {
                ForEach(folder.items) { child in
                    NodeView(node: child, collectionID: collectionID)
                }
            } label: {
                Label(folder.name, systemImage: "folder")
            }
            .contextMenu {
                Button("New Request") { model.newRequest(in: collectionID, folder: folder.id) }
                Button("New Folder") { model.newFolder(in: collectionID, parent: folder.id) }
                Divider()
                Button("Delete Folder", role: .destructive) { model.deleteNode(folder.id, in: collectionID) }
            }
        }
    }
}

struct MethodBadge: View {
    let method: String

    static func color(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return .green
        case "POST": return .orange
        case "PUT": return .blue
        case "PATCH": return .purple
        case "DELETE": return .red
        default: return .gray
        }
    }

    var body: some View {
        Text(method.uppercased().prefix(5))
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(Self.color(method))
            .frame(width: 38, alignment: .leading)
    }
}
