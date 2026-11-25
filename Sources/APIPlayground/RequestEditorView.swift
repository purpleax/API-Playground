import APIEngine
import AppKit
import SwiftUI

struct RequestEditorView: View {
    @Environment(AppModel.self) private var model
    let requestID: UUID

    enum Tab: String, CaseIterable, Identifiable {
        case params = "Params", headers = "Headers", body = "Body", auth = "Auth", scripts = "Scripts"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .params

    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    private var request: Binding<RequestItem> {
        Binding(
            get: { model.request(requestID) ?? RequestItem(id: requestID) },
            set: { model.update($0) }
        )
    }

    var body: some View {
        let request = request
        VStack(alignment: .leading, spacing: 0) {
            TextField("Request name", text: request.name)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)

            HStack(spacing: 8) {
                Picker("Method", selection: request.method) {
                    ForEach(methodChoices(request.wrappedValue.method), id: \.self) { method in
                        Text(method).tag(method)
                    }
                }
                .labelsHidden()
                .frame(width: 104)

                TextField("https://api.example.com/path", text: request.url)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { model.send(requestID) }

                Button("Send") { model.send(requestID) }
                    .buttonStyle(.borderedProminent)
                    .help("Send the request (⌘↩)")
            }
            .padding(12)

            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(title(tab, request.wrappedValue)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            switch tab {
            case .params:
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Query parameters").font(.headline)
                        KeyValueEditor(items: request.params)
                        if !request.wrappedValue.pathVariables.isEmpty {
                            Text("Path variables").font(.headline)
                            Text("Each replaces the matching :name part of the URL.")
                                .foregroundStyle(.secondary)
                            KeyValueEditor(items: request.pathVariables, allowsAdding: false)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .headers:
                ScrollView {
                    KeyValueEditor(items: request.headers)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .body:
                BodyEditor(requestBody: request.body)
            case .auth:
                ScrollView {
                    AuthEditor(auth: request.auth, inherited: model.effectiveAuth(requestID))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .scripts:
                ScriptsView(request: request.wrappedValue)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func methodChoices(_ current: String) -> [String] {
        Self.methods.contains(current) ? Self.methods : Self.methods + [current]
    }

    private func title(_ tab: Tab, _ request: RequestItem) -> String {
        switch tab {
        case .params:
            let count = request.params.filter(\.enabled).count
            return count > 0 ? "Params (\(count))" : "Params"
        case .headers:
            let count = request.headers.filter(\.enabled).count
            return count > 0 ? "Headers (\(count))" : "Headers"
        default:
            return tab.rawValue
        }
    }
}

// MARK: - Body

private enum BodyKind: String, CaseIterable, Identifiable {
    case none = "None", raw = "Raw", urlEncoded = "Form", formData = "Multipart", graphQL = "GraphQL", file = "File"
    var id: String { rawValue }

    init(_ body: APIEngine.Body) {
        switch body {
        case .none: self = .none
        case .raw: self = .raw
        case .urlEncoded: self = .urlEncoded
        case .formData: self = .formData
        case .graphQL: self = .graphQL
        case .file: self = .file
        }
    }

    var empty: APIEngine.Body {
        switch self {
        case .none: return .none
        case .raw: return .raw(text: "", contentType: "application/json")
        case .urlEncoded: return .urlEncoded(fields: [])
        case .formData: return .formData(fields: [])
        case .graphQL: return .graphQL(query: "", variables: "")
        case .file: return .file(path: "")
        }
    }
}

private struct BodyEditor: View {
    @Binding var requestBody: APIEngine.Body

    private static let contentTypes: [(label: String, value: String?)] = [
        ("JSON", "application/json"), ("XML", "application/xml"), ("Text", "text/plain"),
        ("HTML", "text/html"), ("No Content-Type", nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Body type", selection: Binding(
                    get: { BodyKind(requestBody) },
                    set: { kind in
                        if kind != BodyKind(requestBody) { requestBody = kind.empty }
                    }
                )) {
                    ForEach(BodyKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()

                if case .raw(let text, let contentType) = requestBody {
                    Picker("Content type", selection: Binding(
                        get: { contentType },
                        set: { requestBody = .raw(text: text, contentType: $0) }
                    )) {
                        ForEach(Self.choices(including: contentType), id: \.value) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
            }
            .padding(12)

            switch requestBody {
            case .none:
                Text("This request has no body.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                Spacer()
            case .raw(let text, let contentType):
                Divider()
                CodeTextView(text: Binding(
                    get: { text },
                    set: { requestBody = .raw(text: $0, contentType: contentType) }
                ))
            case .urlEncoded(let fields):
                ScrollView {
                    KeyValueEditor(items: Binding(
                        get: { fields },
                        set: { requestBody = .urlEncoded(fields: $0) }
                    ))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .formData(let fields):
                ScrollView {
                    FormFieldEditor(fields: Binding(
                        get: { fields },
                        set: { requestBody = .formData(fields: $0) }
                    ))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .graphQL(let query, let variables):
                Divider()
                VSplitView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Query").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 6)
                        CodeTextView(text: Binding(
                            get: { query },
                            set: { requestBody = .graphQL(query: $0, variables: variables) }
                        ))
                    }
                    .frame(minHeight: 80)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Variables (JSON)").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 6)
                        CodeTextView(text: Binding(
                            get: { variables },
                            set: { requestBody = .graphQL(query: query, variables: $0) }
                        ))
                    }
                    .frame(minHeight: 60)
                }
            case .file(let path):
                HStack {
                    TextField("Path to file", text: Binding(
                        get: { path },
                        set: { requestBody = .file(path: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url {
                            requestBody = .file(path: url.path)
                        }
                    }
                }
                .padding(.horizontal, 12)
                Spacer()
            }
        }
    }

    /// The standard choices, plus the current value when it is not one of them.
    private static func choices(including current: String?) -> [(label: String, value: String?)] {
        if contentTypes.contains(where: { $0.value == current }) { return contentTypes }
        return contentTypes + [(current ?? "", current)]
    }
}

private struct FormFieldEditor: View {
    @Binding var fields: [FormField]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($fields) { $field in
                HStack(spacing: 6) {
                    Toggle("Enabled", isOn: $field.enabled)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    TextField("Name", text: $field.key)
                        .frame(minWidth: 90, idealWidth: 160)
                    TextField(field.isFile ? "Path to file" : "Value", text: $field.value)
                    Toggle("File", isOn: $field.isFile)
                        .toggleStyle(.button)
                        .help("Send the contents of a file")
                    Button {
                        fields.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .opacity(field.enabled ? 1 : 0.5)
            }
            Button {
                fields.append(FormField())
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Auth

private enum AuthKind: String, CaseIterable, Identifiable {
    case inherit = "Inherit from parent", none = "No auth", basic = "Basic", bearer = "Bearer token", apiKey = "API key"
    var id: String { rawValue }

    init(_ auth: Auth) {
        switch auth {
        case .inherit: self = .inherit
        case .none: self = .none
        case .basic: self = .basic
        case .bearer: self = .bearer
        case .apiKey: self = .apiKey
        }
    }

    var empty: Auth {
        switch self {
        case .inherit: return .inherit
        case .none: return .none
        case .basic: return .basic(username: "", password: "")
        case .bearer: return .bearer(token: "")
        case .apiKey: return .apiKey(key: "", value: "", placement: .header)
        }
    }
}

private struct AuthEditor: View {
    @Binding var auth: Auth
    /// What "inherit" resolves to for this request.
    let inherited: Auth

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Type", selection: Binding(
                get: { AuthKind(auth) },
                set: { kind in
                    if kind != AuthKind(auth) { auth = kind.empty }
                }
            )) {
                ForEach(AuthKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .fixedSize()

            switch auth {
            case .inherit:
                Text("Uses the parent's setting: \(Self.summary(inherited)).")
                    .foregroundStyle(.secondary)
            case .none:
                Text("No auth is sent with this request.")
                    .foregroundStyle(.secondary)
            case .basic(let username, let password):
                Form {
                    TextField("Username", text: Binding(get: { username }, set: { auth = .basic(username: $0, password: password) }))
                    TextField("Password", text: Binding(get: { password }, set: { auth = .basic(username: username, password: $0) }))
                }
            case .bearer(let token):
                Form {
                    TextField("Token", text: Binding(get: { token }, set: { auth = .bearer(token: $0) }))
                }
            case .apiKey(let key, let value, let placement):
                Form {
                    TextField("Name", text: Binding(get: { key }, set: { auth = .apiKey(key: $0, value: value, placement: placement) }))
                    TextField("Value", text: Binding(get: { value }, set: { auth = .apiKey(key: key, value: $0, placement: placement) }))
                    Picker("Send in", selection: Binding(get: { placement }, set: { auth = .apiKey(key: key, value: value, placement: $0) })) {
                        Text("Header").tag(APIKeyPlacement.header)
                        Text("Query parameter").tag(APIKeyPlacement.query)
                    }
                }
            }
            if auth != .inherit, auth != Auth.none {
                Text("Use a {{variable}} for the secret part and mark that variable as secret, so it stays out of files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(.body, design: .monospaced))
    }

    static func summary(_ auth: Auth) -> String {
        switch auth {
        case .inherit, .none: return "no auth"
        case .basic(let username, _): return "Basic auth as \(username.isEmpty ? "an empty username" : username)"
        case .bearer: return "a Bearer token"
        case .apiKey(let key, _, let placement):
            return "API key \(key) in the \(placement == .header ? "headers" : "query")"
        }
    }
}

// MARK: - Scripts

private struct ScriptsView: View {
    let request: RequestItem

    var body: some View {
        if request.preRequestScript.isEmpty && request.testScript.isEmpty {
            VStack {
                Text("This request has no scripts.")
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Label("Scripts are kept from the import but do not run yet.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .padding(12)
                Divider()
                VSplitView {
                    if !request.preRequestScript.isEmpty {
                        section("Pre-request", request.preRequestScript)
                    }
                    if !request.testScript.isEmpty {
                        section("Tests", request.testScript)
                    }
                }
            }
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 6)
            ReadOnlyCode(text: text)
        }
        .frame(minHeight: 60)
    }
}
