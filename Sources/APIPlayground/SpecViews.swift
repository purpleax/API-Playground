import APIEngine
import SwiftUI

/// An API spec: its text on the left, and what the text means on the right.
struct SpecView: View {
    @Environment(AppModel.self) private var model
    let file: String

    private enum Tab: Hashable { case routes, problems }

    @State private var tab = Tab.routes
    @State private var document: OpenAPIDocument?
    /// False until the text has been read once, so nothing is said about it before then.
    @State private var analysed = false
    @State private var readError: String?
    @State private var issues: [LintIssue] = []
    @State private var reveal: CodeTextView.RevealRequest?
    @State private var server = ""
    @State private var banner: String?
    @State private var confirmingDelete = false

    private var text: String { model.spec(file)?.text ?? "" }

    private var isJSON: Bool { file.lowercased().hasSuffix(".json") }

    /// The servers a route can be sent to: the spec's own, and the mock while one runs.
    private var servers: [String] {
        var list = document?.servers ?? []
        // A spec that names no host is sent to the address filled in on its collection.
        if document?.needsHost == true, let address = model.baseAddress(ofCollectionForSpec: file), !address.isEmpty, !list.contains(address) {
            if list.isEmpty { list = [address] } else { list[0] = address }
        }
        if let mock = model.mock, mock.collectionID == model.collection(forSpec: file)?.id { list.insert(mock.url, at: 0) }
        return list
    }

    private var chosenServer: String {
        servers.contains(server) ? server : (servers.first ?? "")
    }

    var body: some View {
        HSplitView {
            editor
                .card()
                .padding(.leading, 10)
                .padding(.trailing, 5)
                .padding(.vertical, 10)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            preview
                .card()
                .padding(.leading, 5)
                .padding(.trailing, 10)
                .padding(.vertical, 10)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .task(id: Analysis.Key(text: text, ruleset: model.ruleset)) {
            // Wait for a pause in typing before reading the whole document again.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let (text, ruleset) = (text, model.ruleset)
            let result = await Task.detached { Analysis(text: text, ruleset: ruleset) }.value
            guard !Task.isCancelled else { return }
            analysed = true
            document = result.document
            readError = result.readError
            issues = result.issues
        }
        .confirmationDialog("Delete “\(file)”?", isPresented: $confirmingDelete) {
            Button("Delete Spec", role: .destructive) { model.deleteSpec(file) }
        } message: {
            Text("The spec file is removed from the workspace. A collection made from it is kept.")
        }
    }

    // MARK: Editor

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(Theme.accent)
                Text(file)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let document {
                    Chip(text: document.isSwagger2 ? "Swagger \(document.specVersion)" : "OpenAPI \(document.specVersion)")
                }
                Spacer()
                IconButton(systemImage: "checklist", help: "Edit the lint rules for this workspace") { model.showingRuleset = true }
                IconButton(systemImage: "trash", help: "Delete this spec") { confirmingDelete = true }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            CodeTextView(
                text: Binding(get: { text }, set: { model.updateSpec(file, text: $0) }),
                syntax: isJSON ? .json : .yaml,
                reveal: reveal
            )
        }
    }

    // MARK: Preview

    private var worst: LintSeverity? { issues.map(\.severity).min() }

    private func color(_ severity: LintSeverity) -> Color {
        switch severity {
        case .error: return Theme.danger
        case .warning: return Theme.warning
        case .info: return Theme.info
        case .hint: return Theme.textSecondary
        }
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(document?.title ?? (analysed ? "Not an API spec yet" : " "))
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    if let document, !document.version.isEmpty {
                        Text("Version \(document.version)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Button("Mock Server…") { model.mockSpec(file) }
                    .disabled(document == nil)
                    .help("Serve this spec's example responses from this Mac")
                Button(model.collection(forSpec: file) == nil ? "Make Collection" : "Update Collection") {
                    banner = model.generateCollection(fromSpec: file)?.message
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(document == nil)
                .help("Make a request for each route, with example values and the documented responses")
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if let banner {
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(Theme.success).frame(width: 7, height: 7).padding(.top, 5)
                    Text(banner)
                        .font(.system(size: 12.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let collection = model.collection(forSpec: file), let first = collection.allRequests.first {
                        if let document, model.needsAddress(collection, for: document) {
                            Button("Set Address…") { model.editVariables(ofCollection: collection.id) }
                                .buttonStyle(SecondaryButtonStyle())
                                .help("Set {{baseUrl}}, the address every request in the collection starts with")
                        }
                        Button("Show It") { model.selection = first.id }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    IconButton(systemImage: "xmark", help: "Dismiss") { self.banner = nil }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.success.opacity(0.12))
            }

            HStack {
                ThemedTabBar(tabs: [
                    TabItem(id: Tab.routes, title: "Routes", badge: document.map { "\($0.operations.count)" }),
                    TabItem(id: Tab.problems, title: "Problems", badge: issues.isEmpty ? nil : "\(issues.count)", badgeColor: worst.map(color)),
                ], selection: $tab)
                Spacer()
                if tab == .routes, !servers.isEmpty {
                    MenuPicker(title: chosenServer, selection: Binding(get: { chosenServer }, set: { server = $0 })) {
                        ForEach(servers, id: \.self) { url in
                            Text(url == model.mock?.url ? "Mock server (\(url))" : url).tag(url)
                        }
                    }
                    .help("The server routes are sent to")
                    .padding(.trailing, 12)
                }
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)

            switch tab {
            case .routes: routes
            case .problems: problems
            }
        }
    }

    @ViewBuilder
    private var routes: some View {
        if let document {
            if document.operations.isEmpty {
                EmptyState(systemImage: "point.3.connected.trianglepath.dotted", title: "No routes yet", detail: "Add a path under “paths:” and it appears here, ready to send.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(groups(of: document), id: \.name) { group in
                            if !group.name.isEmpty {
                                Text(group.name).sectionTitle()
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                            }
                            ForEach(group.operations) { operation in
                                RouteRow(
                                    operation: operation,
                                    run: model.specRuns[AppModel.runKey(file, operation)],
                                    canSend: !chosenServer.isEmpty,
                                    show: { reveal = CodeTextView.RevealRequest(line: operation.line) },
                                    send: { model.sendRoute(operation, of: document, specFile: file, baseURL: chosenServer) }
                                )
                            }
                        }
                    }
                    .padding(10)
                }
            }
        } else if !analysed {
            Color.clear
        } else {
            EmptyState(
                systemImage: "doc.questionmark",
                title: "This cannot be read as an API spec",
                detail: readError ?? "Start the document with “openapi: 3.0.3”, an “info” section and some “paths”."
            )
        }
    }

    private func groups(of document: OpenAPIDocument) -> [(name: String, operations: [OpenAPIOperation])] {
        var order: [String] = []
        var byTag: [String: [OpenAPIOperation]] = [:]
        for operation in document.operations {
            let tag = operation.tags.first ?? ""
            if !order.contains(tag) { order.append(tag) }
            byTag[tag, default: []].append(operation)
        }
        // Untagged routes first, then tags in the order the document lists them.
        let listed = document.tags.filter { order.contains($0) }
        let sorted = (order.contains("") ? [""] : []) + listed + order.filter { !$0.isEmpty && !listed.contains($0) }
        return sorted.map { ($0, byTag[$0] ?? []) }
    }

    @ViewBuilder
    private var problems: some View {
        if issues.isEmpty {
            EmptyState(systemImage: "checkmark.seal.fill", title: "No problems found", detail: "The spec passes every rule in use.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(issues) { issue in
                        SelectableRow(isSelected: false) {
                            if issue.line > 0 { reveal = CodeTextView.RevealRequest(line: issue.line) }
                        } content: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: symbol(issue.severity))
                                    .font(.system(size: 12))
                                    .foregroundStyle(color(issue.severity))
                                    .frame(width: 16)
                                    .padding(.top, 1)
                                    .accessibilityLabel(issue.severity.label)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.message)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Theme.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text([issue.rule, issue.path].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 6)
                                if issue.line > 0 {
                                    Text("Line \(issue.line)")
                                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private func symbol(_ severity: LintSeverity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .hint: return "lightbulb.fill"
        }
    }
}

/// What a spec's text means, worked out away from the main thread.
private struct Analysis: Sendable {
    struct Key: Hashable {
        var text: String
        var ruleset: String
    }

    var document: OpenAPIDocument?
    var readError: String?
    var issues: [LintIssue]

    init(text: String, ruleset: String) {
        issues = SpecLinter.lint(text, ruleset: ruleset)
        do {
            document = try OpenAPIDocument(text: text)
        } catch {
            readError = error.localizedDescription
        }
    }
}

/// One route in the preview: what it is, a button to send it, and the last reply.
private struct RouteRow: View {
    let operation: OpenAPIOperation
    let run: SpecRun?
    let canSend: Bool
    let show: () -> Void
    let send: () -> Void
    @State private var expanded = false
    @State private var hovering = false

    private var response: HTTPResponse? { run?.result?.response }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Button(action: show) {
                    HStack(spacing: 9) {
                        MethodBadge(method: operation.method)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(operation.path)
                                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .strikethrough(operation.deprecated)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if operation.title != operation.id {
                                Text(operation.title)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show this route in the spec")

                if operation.deprecated { Chip(text: "deprecated", color: Theme.warning) }
                if run?.isRunning == true {
                    ProgressView().controlSize(.small)
                } else if let result = run?.result {
                    Button {
                        expanded.toggle()
                    } label: {
                        if let response {
                            Chip(text: "\(response.status)", color: statusColor(response.status))
                        } else {
                            Chip(text: "failed", color: Theme.danger)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(result.error ?? "Show or hide the reply")
                }
                IconButton(systemImage: "play.fill", tint: Theme.accent, help: canSend ? "Send this route to the chosen server" : "The spec lists no server to send to", action: {
                    expanded = true
                    send()
                })
                .disabled(!canSend || run?.isRunning == true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if expanded, let result = run?.result {
                reply(result)
            }
        }
        .background(hovering || expanded ? Theme.raised.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        .onHover { hovering = $0 }
    }

    private func statusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: return Theme.success
        case 300..<400: return Theme.info
        case 400..<500: return Theme.warning
        default: return Theme.danger
        }
    }

    @ViewBuilder
    private func reply(_ result: RequestRunResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = result.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
            }
            if let response {
                HStack(spacing: 10) {
                    Text(result.prepared?.url ?? "")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(response.timings.total < 1 ? String(format: "%.0f ms", response.timings.total * 1000) : String(format: "%.2f s", response.timings.total))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(response.body.count), countStyle: .file))
                }
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                ForEach(Array(result.tests.enumerated()), id: \.offset) { _, test in
                    Label(test.name + (test.message.map { ": \($0)" } ?? ""), systemImage: test.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(test.passed ? Theme.success : Theme.danger)
                }
                let body = response.text ?? "\(response.body.count) bytes that are not text"
                if !body.isEmpty {
                    ReadOnlyCode(text: String(body.prefix(20_000)), fontSize: 11.5)
                        .frame(height: 150)
                        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
    }
}

// MARK: - Lint rules

/// The workspace's lint ruleset, beside a list of the rules that are built in.
struct RulesetView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    static let starter = """
    # Keep the built-in rules, then adjust them or add your own.
    extends: spectral:oas
    rules:
      # Switch a built-in rule off, or change how serious it is.
      info-contact: off
      operation-description: error

      # A rule of your own: where to look (given), and what must hold (then).
      paths-kebab-case:
        description: Paths should be lowercase words joined by hyphens.
        severity: warn
        given: $.paths[*]~
        then:
          function: pattern
          functionOptions:
            match: '^(/([a-z0-9-]+|\\{[^}]+\\}))+$'

    """

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Lint Rules").font(.system(size: 17, weight: .bold))
                Text("These rules check every spec in this workspace. With no ruleset, the built-in rules are used as they are. The ruleset is a Spectral ruleset, saved as specs/.spectral.yaml.")
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            Rectangle().fill(Theme.stroke).frame(height: 1)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Ruleset").sectionTitle()
                        Spacer()
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Start from an Example") { text = Self.starter }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    CodeTextView(text: $text, syntax: .yaml)
                        .background(Theme.canvas)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Theme.stroke).frame(width: 1)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Built-in rules").sectionTitle()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            ForEach(SpecLinter.builtInRules) { rule in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(rule.severity == .error ? Theme.danger : Theme.warning)
                                            .frame(width: 6, height: 6)
                                            .accessibilityLabel(rule.severity.label)
                                        Text(rule.name)
                                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                    Text(rule.summary)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Text("Functions for your own rules: \(SpecLinter.functions.joined(separator: ", ")).")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    }
                }
                .frame(width: 320)
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel") { model.showingRuleset = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveRuleset(text)
                    model.showingRuleset = false
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("s")
            }
            .padding(12)
        }
        .frame(width: 880, height: 600)
        .onAppear { text = model.ruleset }
    }
}
