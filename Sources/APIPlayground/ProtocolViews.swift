import APIEngine
import SwiftUI

// MARK: - Server-sent events

/// The events of a `text/event-stream` response, newest at the bottom.
struct EventListView: View {
    let events: [ServerSentEvent]
    var redactor: Redactor?
    /// True while the stream is still open.
    var isLive = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Chip(text: event.event, color: event.event == "message" ? Theme.info : Theme.violet)
                                if let id = event.lastEventID {
                                    Text("id \(id)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                Spacer()
                                Text(event.received.formatted(date: .omitted, time: .standard))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Text(redactor?.redact(event.data) ?? event.data)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                        .id(event.id)
                    }
                    if isLive {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Listening for events…")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 6)
                        .id("live")
                    }
                }
                .padding(12)
            }
            .onChange(of: events.count) {
                // Follow the stream as it grows.
                if isLive, let last = events.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .overlay {
            if events.isEmpty && !isLive {
                EmptyState(systemImage: "dot.radiowaves.left.and.right", title: "No events", detail: "The stream closed without sending any.")
            }
        }
    }
}

// MARK: - Cookies

/// A list of cookies, each with its domain, path and expiry.
struct CookieRows: View {
    let cookies: [Cookie]
    var redactor: Redactor?
    var onDelete: ((Cookie) -> Void)?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cookies.enumerated()), id: \.element.id) { index, cookie in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(cookie.name)
                                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.Syntax.key.color)
                            if cookie.secure { Chip(text: "Secure", color: Theme.success, mono: false) }
                            if cookie.httpOnly { Chip(text: "HttpOnly", color: Theme.info, mono: false) }
                        }
                        // Cookie values are often session secrets, so they are masked whenever secrets are hidden.
                        Text(redactor == nil ? cookie.value : Redactor.mask)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Text("\(cookie.hostOnly ? "" : ".")\(cookie.domain)\(cookie.path) · \(cookie.expires.map { "expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "kept until cleared")")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    if let onDelete {
                        Button {
                            onDelete(cookie)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(GhostButtonStyle())
                        .help("Remove this cookie")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(index.isMultiple(of: 2) ? Color.clear : Theme.raised.opacity(0.45))
            }
        }
    }
}

/// The sheet that shows every stored cookie for the workspace.
struct CookieManagerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cookies").font(.system(size: 17, weight: .bold))
                Text("Cookies that servers set are sent back on later requests to the same site. They are kept on this Mac, outside the workspace.")
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
            Rectangle().fill(Theme.stroke).frame(height: 1)

            ScrollView {
                CookieRows(cookies: model.cookieJar.cookies, redactor: model.secretsHidden ? Redactor() : nil) { cookie in
                    var jar = model.cookieJar
                    jar.cookies.removeAll { $0.id == cookie.id }
                    model.setCookies(jar)
                }
                .padding(.vertical, 6)
            }
            .overlay {
                if model.cookieJar.cookies.isEmpty {
                    Text("No cookies stored").foregroundStyle(Theme.textTertiary)
                }
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack {
                Button("Clear All", role: .destructive) { model.setCookies(CookieJar()) }
                    .disabled(model.cookieJar.cookies.isEmpty)
                Spacer()
                Button("Done") { model.showingCookies = false }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 480)
    }
}

// MARK: - GraphQL schema

/// A browser for a GraphQL schema: types on the left, the chosen type's fields on the right.
struct SchemaView: View {
    @Environment(AppModel.self) private var model
    let schema: GraphQLSchema
    @State private var selected: String?
    @State private var filter = ""

    private var roots: [(label: String, name: String)] {
        [("Query", schema.queryType), ("Mutation", schema.mutationType), ("Subscription", schema.subscriptionType)]
            .compactMap { pair in pair.1.map { (pair.0, $0) } }
    }

    private var visibleTypes: [GraphQLType] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let rootNames = Set(roots.map(\.name))
        return schema.types.filter { type in
            !rootNames.contains(type.name) && (query.isEmpty || type.name.lowercased().contains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Schema").font(.system(size: 17, weight: .bold))
                Chip(text: "\(schema.types.count) types", color: Theme.accent, mono: false)
                Spacer()
                TextField("Filter types", text: $filter)
                    .textFieldStyle(ThemedTextFieldStyle())
                    .frame(width: 200)
            }
            .padding(14)
            Rectangle().fill(Theme.stroke).frame(height: 1)

            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !roots.isEmpty {
                            Text("Entry points").sectionTitle().padding(.horizontal, 10).padding(.vertical, 4)
                            ForEach(roots, id: \.name) { root in
                                row(root.name, kind: root.label.uppercased(), color: Theme.accent)
                            }
                        }
                        Text("Types").sectionTitle().padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                        ForEach(visibleTypes) { type in
                            row(type.name, kind: type.kind, color: Self.color(type.kind))
                        }
                    }
                    .padding(8)
                }
                .frame(minWidth: 230, maxWidth: 300)
                .background(Theme.chrome)

                ScrollView {
                    if let type = schema.type(named: selected) {
                        detail(type)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(minWidth: 380)
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack {
                Spacer()
                Button("Done") { model.showingSchema = nil }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 820, height: 560)
        .onAppear { selected = selected ?? schema.queryType ?? schema.types.first?.name }
    }

    private func row(_ name: String, kind: String, color: Color) -> some View {
        SelectableRow(isSelected: selected == name) {
            selected = name
        } content: {
            Text(name)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(kind.replacingOccurrences(of: "_", with: " "))
                .font(.system(size: 8.5, weight: .heavy))
                .tracking(0.5)
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func detail(_ type: GraphQLType) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(type.name).font(.system(size: 18, weight: .bold, design: .monospaced))
                Chip(text: type.kind.replacingOccurrences(of: "_", with: " "), color: Self.color(type.kind), mono: false)
            }
            if !type.description.isEmpty {
                Text(type.description).foregroundStyle(Theme.textSecondary)
            }
            ForEach(type.fields) { field in
                VStack(alignment: .leading, spacing: 3) {
                    Text(field.signature)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Theme.Syntax.key.color)
                        .textSelection(.enabled)
                    if !field.description.isEmpty {
                        Text(field.description)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
            if !type.enumValues.isEmpty {
                FlowText(values: type.enumValues)
            }
            if type.fields.isEmpty && type.enumValues.isEmpty {
                Text("This type has no fields.").foregroundStyle(Theme.textTertiary)
            }
        }
    }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "OBJECT": return Theme.info
        case "INPUT_OBJECT": return Theme.warning
        case "ENUM": return Theme.violet
        case "SCALAR": return Theme.success
        default: return Theme.textSecondary
        }
    }
}

/// Enum values as a column of chips.
private struct FlowText: View {
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(values, id: \.self) { value in
                Chip(text: value, color: Theme.violet)
            }
        }
    }
}

// MARK: - WebSocket

/// The conversation pane shown in place of the response for a WebSocket request.
struct WebSocketView: View {
    @Environment(AppModel.self) private var model
    let requestID: UUID
    @State private var draft = ""

    var body: some View {
        let session = model.sockets[requestID] ?? SocketSession()
        let redactor = model.redactor(for: requestID)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.color(session.state))
                        .frame(width: 7, height: 7)
                        .shadow(color: Self.color(session.state), radius: session.state == .connected ? 4 : 0)
                    Text(Self.label(session.state))
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Self.color(session.state))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Self.color(session.state).opacity(0.14), in: Capsule())
                Chip(text: "WebSocket", color: Theme.accentAlt, mono: false)
                let count = session.messages.filter { $0.direction != .system }.count
                if count > 0 {
                    Chip(text: count == 1 ? "1 message" : "\(count) messages", filled: false, mono: false)
                }
                Spacer()
                IconButton(systemImage: "trash", help: "Clear the message log") { model.clearSocketLog(requestID) }
            }
            .frame(height: 32)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            Rectangle().fill(Theme.stroke).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(session.messages) { message in
                            MessageRow(message: message, redactor: redactor)
                                .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: session.messages.count) {
                    if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .overlay {
                if session.messages.isEmpty {
                    EmptyState(systemImage: "bolt.horizontal.circle", title: "Not connected", detail: "Click Connect to open the WebSocket, then send messages below.")
                }
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(alignment: .bottom, spacing: 8) {
                CodeTextView(text: $draft)
                    .frame(height: 84)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius).strokeBorder(Theme.stroke))
                Button {
                    model.sendSocketMessage(requestID, text: draft)
                } label: {
                    Label("Send", systemImage: "arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(session.state != .connected || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send this message. {{variables}} are filled in.")
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // The message being composed is saved with the request, as its body.
            if case .raw(let text, _) = model.request(requestID)?.body { draft = text }
        }
        .onChange(of: draft) {
            guard var request = model.request(requestID) else { return }
            let body: APIEngine.Body = draft.isEmpty ? .none : .raw(text: draft, contentType: nil)
            if request.body != body {
                request.body = body
                model.update(request)
            }
        }
    }

    static func color(_ state: SocketSession.State) -> Color {
        switch state {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .disconnected: return Theme.textSecondary
        }
    }

    static func label(_ state: SocketSession.State) -> String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        }
    }

    private struct MessageRow: View {
        let message: WebSocketMessage
        let redactor: Redactor?

        var body: some View {
            if message.direction == .system {
                Text(message.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 2)
            } else {
                let sent = message.direction == .sent
                let color = sent ? Theme.info : Theme.success
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: sent ? "arrow.up" : "arrow.down")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(color)
                        .frame(width: 20, height: 20)
                        .background(color.opacity(0.15), in: Circle())
                        .accessibilityLabel(sent ? "Sent" : "Received")
                    Text(redactor?.redact(shown) ?? shown)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(message.date.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(9)
                .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
        }

        /// JSON messages are indented for reading.
        private var shown: String {
            LineDiff.prettyJSON(Data(message.text.utf8)) ?? message.text
        }
    }
}

// MARK: - OAuth 2

/// The OAuth 2 settings in a request's Auth tab, with the token's status and a button to get one.
struct OAuth2Editor: View {
    @Environment(AppModel.self) private var model
    @Binding var config: OAuth2Config
    let requestID: UUID
    var hidesSecrets = false

    @ViewBuilder
    private func field(_ title: String, _ text: Binding<String>, secret: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 118, alignment: .trailing)
            // A value that is only a {{variable}} reveals nothing, so it stays readable.
            if secret && hidesSecrets && !text.wrappedValue.contains("{{") {
                SecureField(title, text: text).labelsHidden()
            } else {
                TextField(title, text: text).labelsHidden()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Grant type")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 118, alignment: .trailing)
                MenuPicker(title: config.grant.label, selection: $config.grant) {
                    ForEach(OAuth2Grant.allCases, id: \.self) { grant in
                        Text(grant.label).tag(grant)
                    }
                }
            }
            if config.grant == .authorizationCode {
                field("Authorization URL", $config.authURL)
            }
            field("Token URL", $config.tokenURL)
            field("Client ID", $config.clientID)
            field("Client secret", $config.clientSecret, secret: true)
            if config.grant == .password {
                field("Username", $config.username)
                field("Password", $config.password, secret: true)
            }
            field("Scope", $config.scope)
            field("Header prefix", $config.headerPrefix)

            HStack(spacing: 14) {
                Color.clear.frame(width: 118, height: 1)
                Toggle(isOn: $config.clientAuthInBody) { Text("Client details in body") }
                    .toggleStyle(PillToggleStyle())
                    .help("Send the client ID and secret in the form body instead of a Basic auth header")
                if config.grant == .authorizationCode {
                    Toggle(isOn: $config.usePKCE) { Text("PKCE") }
                        .toggleStyle(PillToggleStyle())
                        .help("Protect the sign-in with a one-time code challenge. Leave on unless the provider rejects it.")
                }
            }
            .padding(.top, 2)

            tokenStatus
                .padding(.top, 8)

            if config.grant == .authorizationCode {
                Text("Register this redirect address with the provider: \(OAuth2.redirectURI)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 12.5, design: .monospaced))
        .textFieldStyle(ThemedTextFieldStyle())
    }

    @ViewBuilder
    private var tokenStatus: some View {
        let token = model.oauthToken(config.id)
        HStack(spacing: 10) {
            if let token {
                let expired = token.isExpired()
                Label(Self.describe(token), systemImage: expired ? "clock.badge.exclamationmark" : "checkmark.seal.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(expired ? Theme.warning : Theme.success)
            } else {
                Label(config.grant.isAutomatic ? "No token yet. One is fetched when the request is sent." : "No token yet",
                      systemImage: "key")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if model.fetchingToken {
                ProgressView().controlSize(.small)
            }
            if token != nil {
                Button("Clear") { model.clearOAuthToken(config.id) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Button(config.grant.isAutomatic ? "Get Token" : "Sign In…") {
                model.getOAuthToken(config, requestID: requestID)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.fetchingToken)
        }
        .padding(12)
        .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.stroke))
    }

    static func describe(_ token: OAuth2Token) -> String {
        guard let expiresAt = token.expiresAt else { return "Token ready" }
        if token.isExpired() {
            return token.refreshToken == nil ? "Token expired" : "Token expired. It is refreshed on the next request."
        }
        let minutes = Int(expiresAt.timeIntervalSinceNow / 60)
        return minutes >= 60 ? "Token ready, expires in \(minutes / 60) h \(minutes % 60) min" : "Token ready, expires in \(max(1, minutes)) min"
    }
}
