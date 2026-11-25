import APIEngine
import AppKit
import SwiftUI

struct RequestEditorView: View {
    @Environment(AppModel.self) private var model
    let requestID: UUID

    enum Tab: String, CaseIterable, Identifiable {
        case params = "Params", headers = "Headers", body = "Body", auth = "Auth", tests = "Tests", scripts = "Scripts"
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
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)
                .padding(.top, 14)

            // The command bar: method, address and Send in one rounded strip.
            HStack(spacing: 0) {
                // A WebSocket has no HTTP method to choose.
                let method = model.isWebSocket(requestID) ? "WS" : request.wrappedValue.method.uppercased()
                Menu {
                    ForEach(methodChoices(request.wrappedValue.method), id: \.self) { choice in
                        Button(choice) { request.wrappedValue.method = choice }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(method)
                            .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Theme.method(method))
                    .padding(.horizontal, 13)
                    .frame(height: 40)
                    .background(Theme.method(method).opacity(0.13))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(method == "WS")
                .help(method == "WS" ? "This address opens a WebSocket" : "HTTP method")

                Rectangle().fill(Theme.stroke).frame(width: 1)

                TextField("https://api.example.com/path", text: request.url)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .onSubmit {
                        if model.isWebSocket(requestID) { model.connectSocket(requestID) } else { model.send(requestID) }
                    }

                primaryAction
                    .padding(.trailing, 6)
            }
            .frame(height: 40)
            .background(Theme.raised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.stroke))
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            ThemedTabBar(tabs: Tab.allCases.map { tabItem($0, request.wrappedValue) }, selection: $tab)

            switch tab {
            case .params:
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Query parameters").sectionTitle()
                        KeyValueEditor(items: request.params, hidesSecrets: model.secretsHidden)
                        if !request.wrappedValue.pathVariables.isEmpty {
                            Text("Path variables").sectionTitle()
                            Text("Each replaces the matching :name part of the URL.")
                                .foregroundStyle(Theme.textSecondary)
                            KeyValueEditor(items: request.pathVariables, allowsAdding: false)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .headers:
                ScrollView {
                    KeyValueEditor(items: request.headers, hidesSecrets: model.secretsHidden)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .body:
                BodyEditor(requestBody: request.body, requestID: requestID)
            case .auth:
                ScrollView {
                    AuthEditor(auth: request.auth, inherited: model.effectiveAuth(requestID), hidesSecrets: model.secretsHidden, requestID: requestID)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .tests:
                ScrollView {
                    TestsEditor(assertions: request.assertions, extractions: request.extractions)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .scripts:
                ScriptsEditor(preRequest: request.preRequestScript, tests: request.testScript)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Send for an HTTP request, Stop while one is in progress, and Connect or Disconnect for a WebSocket.
    @ViewBuilder
    private var primaryAction: some View {
        if model.isWebSocket(requestID) {
            let state = model.sockets[requestID]?.state ?? .disconnected
            if state == .disconnected {
                Button {
                    model.connectSocket(requestID)
                } label: {
                    Label("Connect", systemImage: "bolt.horizontal.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Open the WebSocket (⌘↩)")
            } else {
                Button(role: .destructive) {
                    model.disconnectSocket(requestID)
                } label: {
                    Label("Disconnect", systemImage: "xmark")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        } else if case .sending = model.responses[requestID] {
            Button(role: .destructive) {
                model.cancel(requestID)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Stop this request. An open event stream keeps the events it received.")
        } else {
            Button {
                model.send(requestID)
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .help("Send the request (⌘↩)")
        }
    }

    private func methodChoices(_ current: String) -> [String] {
        Self.methods.contains(current) ? Self.methods : Self.methods + [current]
    }

    private func tabItem(_ tab: Tab, _ request: RequestItem) -> TabItem<Tab> {
        func count(_ number: Int) -> String? { number > 0 ? String(number) : nil }
        switch tab {
        case .params:
            return TabItem(id: tab, title: tab.rawValue, badge: count(request.params.filter(\.enabled).count))
        case .headers:
            return TabItem(id: tab, title: tab.rawValue, badge: count(request.headers.filter(\.enabled).count))
        case .body:
            return TabItem(id: tab, title: tab.rawValue, badge: request.body == .none ? nil : "•")
        case .tests:
            return TabItem(id: tab, title: tab.rawValue, badge: count(request.assertions.filter(\.enabled).count))
        case .scripts:
            let hasScripts = !request.preRequestScript.isEmpty || !request.testScript.isEmpty
            return TabItem(id: tab, title: tab.rawValue, badge: hasScripts ? "JS" : nil, badgeColor: hasScripts ? Theme.warning : nil)
        default:
            return TabItem(id: tab, title: tab.rawValue)
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
    @Environment(AppModel.self) private var model
    @Binding var requestBody: APIEngine.Body
    let requestID: UUID

    private static let contentTypes: [(label: String, value: String?)] = [
        ("JSON", "application/json"), ("XML", "application/xml"), ("Text", "text/plain"),
        ("HTML", "text/html"), ("No Content-Type", nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MenuPicker(title: BodyKind(requestBody).rawValue, selection: Binding(
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
                    MenuPicker(title: Self.choices(including: contentType).first { $0.value == contentType }?.label ?? "Content type", selection: Binding(
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
                if case .graphQL = requestBody {
                    if model.fetchingSchema { ProgressView().controlSize(.small) }
                    Button {
                        if model.schemas[requestID] != nil { model.showingSchema = requestID } else { model.fetchSchema(requestID) }
                    } label: {
                        Label("Schema", systemImage: "list.bullet.indent")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.fetchingSchema)
                    .help("Ask the server to describe its schema, then browse its types and fields")
                    if model.schemas[requestID] != nil {
                        IconButton(systemImage: "arrow.clockwise", help: "Fetch the schema again") { model.fetchSchema(requestID) }
                    }
                }
            }
            .padding(12)

            switch requestBody {
            case .none:
                Text("This request has no body.")
                    .foregroundStyle(Theme.textSecondary)
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
                        Text("Query").font(.caption).foregroundStyle(Theme.textSecondary).padding(.horizontal, 12).padding(.top, 6)
                        CodeTextView(text: Binding(
                            get: { query },
                            set: { requestBody = .graphQL(query: $0, variables: variables) }
                        ))
                    }
                    .frame(minHeight: 80)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Variables (JSON)").font(.caption).foregroundStyle(Theme.textSecondary).padding(.horizontal, 12).padding(.top, 6)
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
                    .textFieldStyle(ThemedTextFieldStyle())
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
                        .toggleStyle(ThemedCheckboxStyle())
                    TextField("Name", text: $field.key)
                        .frame(minWidth: 90, idealWidth: 160)
                    TextField(field.isFile ? "Path to file" : "Value", text: $field.value)
                    Toggle("File", isOn: $field.isFile)
                        .toggleStyle(PillToggleStyle())
                        .help("Send the contents of a file")
                    Button {
                        fields.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("Remove")
                }
                .textFieldStyle(ThemedTextFieldStyle())
                .font(.system(.body, design: .monospaced))
                .opacity(field.enabled ? 1 : 0.5)
            }
            Button {
                fields.append(FormField())
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(GhostButtonStyle())
        }
    }
}

// MARK: - Auth

private enum AuthKind: String, CaseIterable, Identifiable {
    case inherit = "Inherit from parent", none = "No auth", basic = "Basic", bearer = "Bearer token", apiKey = "API key", oauth2 = "OAuth 2"
    var id: String { rawValue }

    init(_ auth: Auth) {
        switch auth {
        case .inherit: self = .inherit
        case .none: self = .none
        case .basic: self = .basic
        case .bearer: self = .bearer
        case .apiKey: self = .apiKey
        case .oauth2: self = .oauth2
        }
    }

    var empty: Auth {
        switch self {
        case .inherit: return .inherit
        case .none: return .none
        case .basic: return .basic(username: "", password: "")
        case .bearer: return .bearer(token: "")
        case .apiKey: return .apiKey(key: "", value: "", placement: .header)
        case .oauth2: return .oauth2(OAuth2Config())
        }
    }
}

private struct AuthEditor: View {
    @Binding var auth: Auth
    /// What "inherit" resolves to for this request.
    let inherited: Auth
    var hidesSecrets = false
    let requestID: UUID

    /// A field for a secret part of the auth settings: dots while secrets are hidden,
    /// unless the value is only a {{variable}}, which reveals nothing.
    @ViewBuilder
    private func secretField(_ title: String, _ text: Binding<String>) -> some View {
        if hidesSecrets && !text.wrappedValue.contains("{{") {
            SecureField(title, text: text)
        } else {
            TextField(title, text: text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuPicker(title: AuthKind(auth).rawValue, selection: Binding(
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
                    .foregroundStyle(Theme.textSecondary)
            case .none:
                Text("No auth is sent with this request.")
                    .foregroundStyle(Theme.textSecondary)
            case .basic(let username, let password):
                Form {
                    TextField("Username", text: Binding(get: { username }, set: { auth = .basic(username: $0, password: password) }))
                    secretField("Password", Binding(get: { password }, set: { auth = .basic(username: username, password: $0) }))
                }
            case .bearer(let token):
                Form {
                    secretField("Token", Binding(get: { token }, set: { auth = .bearer(token: $0) }))
                }
            case .apiKey(let key, let value, let placement):
                Form {
                    TextField("Name", text: Binding(get: { key }, set: { auth = .apiKey(key: $0, value: value, placement: placement) }))
                    secretField("Value", Binding(get: { value }, set: { auth = .apiKey(key: key, value: $0, placement: placement) }))
                    MenuPicker(title: placement == .header ? "Send in a header" : "Send in a query parameter", selection: Binding(get: { placement }, set: { auth = .apiKey(key: key, value: value, placement: $0) })) {
                        Text("Header").tag(APIKeyPlacement.header)
                        Text("Query parameter").tag(APIKeyPlacement.query)
                    }
                }
            case .oauth2(let config):
                OAuth2Editor(config: Binding(get: { config }, set: { auth = .oauth2($0) }), requestID: requestID, hidesSecrets: hidesSecrets)
            }
            if auth != .inherit, auth != Auth.none {
                Text("Use a {{variable}} for the secret part and mark that variable as secret, so it stays out of files.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.system(.body, design: .monospaced))
        .textFieldStyle(ThemedTextFieldStyle())
    }

    static func summary(_ auth: Auth) -> String {
        switch auth {
        case .inherit, .none: return "no auth"
        case .basic(let username, _): return "Basic auth as \(username.isEmpty ? "an empty username" : username)"
        case .bearer: return "a Bearer token"
        case .apiKey(let key, _, let placement):
            return "API key \(key) in the \(placement == .header ? "headers" : "query")"
        case .oauth2(let config): return "OAuth 2 (\(config.grant.label.lowercased()))"
        }
    }
}

// MARK: - Scripts

private struct ScriptsEditor: View {
    @Binding var preRequest: String
    @Binding var tests: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scripts are JavaScript and use Postman's pm object. Collection and folder scripts run first.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .padding(12)
            Divider()
            VSplitView {
                section("Before the request is sent", $preRequest)
                section("After the response arrives", $tests)
            }
        }
    }

    private func section(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(Theme.textSecondary).padding(.horizontal, 12).padding(.top, 6)
            CodeTextView(text: text)
        }
        .frame(minHeight: 80)
    }
}
