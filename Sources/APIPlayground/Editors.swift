import APIEngine
import AppKit
import SwiftUI

/// How a code view colours its text.
enum CodeSyntax {
    /// JSON, and anything JSON-like: keys, strings, numbers, true/false/null and {{variables}}.
    case json
    /// JavaScript, for scripts.
    case script
    /// The wire log: sent lines, received lines and notes.
    case log
    /// YAML, for API specs and lint rulesets.
    case yaml
    case plain
}

/// Colours code in place. It only changes text attributes, so the cursor and undo are unaffected.
enum Highlighter {
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are fixed, so a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let punctuation = regex(#"[{}\[\],:]"#)
    private static let number = regex(#"(?<![\w"'.])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?(?![\w"'])"#)
    private static let literal = regex(#"\b(?:true|false|null|undefined)\b"#)
    private static let doubleQuoted = regex(#""(?:[^"\\\n]|\\.)*""#)
    private static let singleQuoted = regex(#"'(?:[^'\\\n]|\\.)*'"#)
    private static let template = regex(#"`(?:[^`\\]|\\.)*`"#)
    private static let variable = regex(#"\{\{[^}\n]+\}\}"#)
    private static let keyword = regex(#"\b(?:const|let|var|function|return|if|else|for|while|new|typeof|throw|try|catch|of|in)\b"#)
    private static let comment = regex(#"//[^\n]*"#)
    private static let logLine = regex(#"^([><*]) .*$"#, [.anchorsMatchLines])
    private static let yamlKey = regex(#"^[ \t]*(?:- +)*((?:"[^"\n]*"|'[^'\n]*'|[^\s#:"'\-\[{][^:#\n]*?))(?=:(?:\s|$))"#, [.anchorsMatchLines])
    private static let yamlComment = regex(#"(?:^|(?<=\s))#[^\n]*"#, [.anchorsMatchLines])
    private static let yamlDash = regex(#"^[ \t]*((?:- +)+|-$)"#, [.anchorsMatchLines])
    private static let yamlPunctuation = regex(#"[{}\[\]]|(?<=: )[|>][+-]?$"#, [.anchorsMatchLines])
    private static let yamlNumber = regex(#"(?<=[:\-,\[] )-?\d+(?:\.\d+)?(?=\s*(?:$|[,\]}#]))"#, [.anchorsMatchLines])
    private static let yamlLiteral = regex(#"(?<=[:\-,\[] )(?:true|false|null|~)(?=\s*(?:$|[,\]}#]))"#, [.anchorsMatchLines])

    /// Above this size the text is left one colour, so huge responses stay fast.
    private static let limit = 400_000

    static func apply(to storage: NSTextStorage, syntax: CodeSyntax, font: NSFont) {
        let text = storage.string as NSString
        let whole = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes([.font: font, .foregroundColor: Theme.Syntax.plain], range: whole)
        guard syntax != .plain, text.length <= limit else { return }

        func paint(_ expression: NSRegularExpression, _ color: NSColor) {
            expression.enumerateMatches(in: storage.string, range: whole) { match, _, _ in
                if let range = match?.range { storage.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }

        switch syntax {
        case .plain:
            break
        case .log:
            logLine.enumerateMatches(in: storage.string, range: whole) { match, _, _ in
                guard let match else { return }
                let color: NSColor
                switch text.substring(with: match.range(at: 1)) {
                case ">": color = Theme.Syntax.sent
                case "<": color = Theme.Syntax.received
                default: color = Theme.Syntax.comment
                }
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        case .yaml:
            paint(yamlPunctuation, Theme.Syntax.punctuation)
            paint(yamlNumber, Theme.Syntax.number)
            paint(yamlLiteral, Theme.Syntax.keyword)
            paint(doubleQuoted, Theme.Syntax.string)
            paint(singleQuoted, Theme.Syntax.string)
            yamlDash.enumerateMatches(in: storage.string, range: whole) { match, _, _ in
                if let range = match?.range(at: 1) { storage.addAttribute(.foregroundColor, value: Theme.Syntax.punctuation, range: range) }
            }
            yamlKey.enumerateMatches(in: storage.string, range: whole) { match, _, _ in
                if let range = match?.range(at: 1) { storage.addAttribute(.foregroundColor, value: Theme.Syntax.key, range: range) }
            }
            paint(variable, Theme.Syntax.variable)
            paint(yamlComment, Theme.Syntax.comment)
        case .json, .script:
            paint(punctuation, Theme.Syntax.punctuation)
            paint(number, Theme.Syntax.number)
            paint(literal, Theme.Syntax.keyword)
            if syntax == .script {
                paint(keyword, Theme.Syntax.keyword)
                paint(singleQuoted, Theme.Syntax.string)
                paint(template, Theme.Syntax.string)
            }
            // Strings go on last so numbers and punctuation inside them take the string's colour.
            doubleQuoted.enumerateMatches(in: storage.string, range: whole) { match, _, _ in
                guard let range = match?.range else { return }
                // A string followed by a colon is an object key.
                var next = range.location + range.length
                while next < text.length, text.character(at: next) == 0x20 || text.character(at: next) == 0x09 { next += 1 }
                let isKey = syntax == .json && next < text.length && text.character(at: next) == 0x3A
                storage.addAttribute(.foregroundColor, value: isKey ? Theme.Syntax.key : Theme.Syntax.string, range: range)
            }
            if syntax == .script { paint(comment, Theme.Syntax.comment) }
            paint(variable, Theme.Syntax.variable)
        }
    }
}

/// A monospaced, syntax-coloured text area backed by NSTextView, which stays fast with large response bodies.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var fontSize: CGFloat = 12
    var syntax: CodeSyntax = .json
    /// A line to select and scroll to. Give a new request each time, even for the same line.
    var reveal: RevealRequest?

    /// A request to show one line of the text.
    struct RevealRequest: Equatable {
        /// 1-based.
        var line: Int
        var token = UUID()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    fileprivate var font: NSFont {
        .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // Substitutions would corrupt JSON: straight quotes must stay straight.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.drawsBackground = false
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(Theme.accent).withAlphaComponent(0.28)]
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        textView.string = text
        restyle(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        let fontChanged = textView.font?.pointSize != fontSize
        if textView.string != text {
            textView.string = text
            restyle(textView)
        } else if fontChanged {
            restyle(textView)
        }
        if let reveal, reveal.token != context.coordinator.lastReveal {
            context.coordinator.lastReveal = reveal.token
            let string = textView.string as NSString
            var location = 0
            var line = 1
            while line < reveal.line, location < string.length {
                location = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
                line += 1
            }
            guard line == reveal.line, location <= string.length else { return }
            var range = string.lineRange(for: NSRange(location: min(location, string.length), length: 0))
            // Leave the line break out of the selection.
            while range.length > 0, [0x0A, 0x0D].contains(string.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }
    }

    fileprivate func restyle(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        Highlighter.apply(to: storage, syntax: syntax, font: font)
        textView.font = font
        // New typing starts plain rather than inheriting the colour beside the cursor.
        textView.typingAttributes = [.font: font, .foregroundColor: Theme.Syntax.plain]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        var lastReveal: UUID?

        init(_ parent: CodeTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            if let storage = textView.textStorage {
                Highlighter.apply(to: storage, syntax: parent.syntax, font: parent.font)
            }
        }
    }
}

/// Shows text that cannot be edited.
struct ReadOnlyCode: View {
    let text: String
    var fontSize: CGFloat = 12
    var syntax: CodeSyntax = .json

    var body: some View {
        CodeTextView(text: .constant(text), isEditable: false, fontSize: fontSize, syntax: syntax)
    }
}

/// An editable list of name/value rows with an on/off switch each.
struct KeyValueEditor: View {
    @Binding var items: [KeyValue]
    var keyTitle = "Name"
    var valueTitle = "Value"
    var allowsAdding = true
    /// When true, values of rows whose name suggests a secret are shown as dots.
    var hidesSecrets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($items) { $item in
                HStack(spacing: 6) {
                    Toggle("Enabled", isOn: $item.enabled)
                        .labelsHidden()
                        .toggleStyle(ThemedCheckboxStyle())
                    TextField(keyTitle, text: $item.key)
                        .frame(minWidth: 90, idealWidth: 160)
                    // A value that is only a {{variable}} reveals nothing, so it stays readable.
                    if hidesSecrets && Redactor.isSensitiveName(item.key) && !item.value.contains("{{") {
                        SecureField(valueTitle, text: $item.value)
                    } else {
                        TextField(valueTitle, text: $item.value)
                    }
                    Button {
                        items.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("Remove")
                }
                .textFieldStyle(ThemedTextFieldStyle())
                .font(.system(.body, design: .monospaced))
                .opacity(item.enabled ? 1 : 0.5)
            }
            if allowsAdding {
                Button {
                    items.append(KeyValue())
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }
}

/// The sheet for every variable. There are two kinds and no more: the global variables,
/// which every collection's requests can use, and each collection's own.
struct VariablesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Scope: Hashable {
        case globals
        case collection(UUID)
    }

    @State private var selected = Scope.globals
    /// What `rows` holds at the moment, which is what a save writes back to.
    @State private var loaded: Scope?
    @State private var rows: [Variable] = []

    private static let nameWidth: CGFloat = 200
    private static let valueWidth: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Variables").font(.system(size: 17, weight: .bold))
                Text("Write {{name}} in a request and it is replaced with the variable's value.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HSplitView {
                list
                    .frame(minWidth: 200, maxWidth: 250)
                    .background(Theme.chrome)
                table
                    .frame(minWidth: 520)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    save()
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 980, height: 560)
        .onAppear {
            if let id = model.variablesCollection, model.collections.contains(where: { $0.id == id }) {
                // Asked for from a collection: start on that collection.
                selected = .collection(id)
            } else if let request = model.selection, let index = model.collectionIndex(containingRequest: request) {
                selected = .collection(model.collections[index].id)
            } else if let first = model.collections.first {
                selected = .collection(first.id)
            } else {
                selected = .globals
            }
            model.variablesCollection = nil
            load(selected)
        }
        .onChange(of: selected) { _, new in
            guard new != loaded else { return }
            save()
            load(new)
        }
        .onDisappear { save() }
    }

    // MARK: Parts

    private func heading(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).sectionTitle()
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                heading("Global", "Used by every collection.")
                SelectableRow(isSelected: selected == .globals) {
                    selected = .globals
                } content: {
                    Image(systemName: "globe").foregroundStyle(Theme.info).frame(width: 16)
                    Text("Global variables").font(.system(size: 13))
                }
                heading("Collection", "Used by that collection only.")
                if model.collections.isEmpty {
                    Text("No collections yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 10)
                }
                ForEach(model.collections) { collection in
                    SelectableRow(isSelected: selected == .collection(collection.id)) {
                        selected = .collection(collection.id)
                    } content: {
                        Image(systemName: "folder").foregroundStyle(Theme.textSecondary).frame(width: 16)
                        Text(collection.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                    }
                }
            }
            .padding(8)
        }
    }

    private var title: String {
        switch selected {
        case .globals: return "Global variables"
        case .collection(let id): return model.collections.first { $0.id == id }?.name ?? "Collection"
        }
    }

    private var caption: String {
        switch selected {
        case .globals:
            return "Every collection's requests can use these. If a collection has a variable of its own with the same name, the collection's is used."
        case .collection:
            return "Only this collection's requests use these. A variable here is used in place of a global one with the same name."
        }
    }

    private var table: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 17, weight: .bold))
                Text(caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                grid
                Button {
                    rows.append(Variable())
                } label: {
                    Label("Add Variable", systemImage: "plus")
                }
                .buttonStyle(GhostButtonStyle())
                if !model.unusedEnvironments.isEmpty {
                    leftovers.padding(.top, 14)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Color.clear.frame(width: 16, height: 1)
                columnTitle("Variable").frame(width: Self.nameWidth, alignment: .leading)
                columnTitle("Value").frame(width: Self.valueWidth, alignment: .leading)
                Color.clear.frame(width: 1, height: 1)
            }
            ForEach(rows) { row in
                // Reached by its id, not its place in the list, so removing a row cannot
                // leave a control reading a place that is no longer there.
                let entry = rowBinding(row.id)
                GridRow {
                    Toggle("Use this variable", isOn: entry.enabled)
                        .labelsHidden()
                        .toggleStyle(ThemedCheckboxStyle())
                        .help("Untick to leave this variable out without deleting it")
                    TextField("name", text: entry.key)
                        .frame(width: Self.nameWidth)
                    valueField(entry).frame(width: Self.valueWidth)
                    HStack(spacing: 4) {
                        Toggle(isOn: Binding(get: { row.isLocalOnly }, set: { entry.wrappedValue.isLocalOnly = $0 })) {
                            Image(systemName: "laptopcomputer").accessibilityLabel("This Mac only")
                        }
                        .toggleStyle(PillToggleStyle())
                        .disabled(row.secret)
                        .help("Keep this value on this Mac only. It is not saved to the workspace, so it is not shared and stays out of Git.")
                        Toggle(isOn: Binding(get: { row.secret }, set: { entry.wrappedValue.setSecret($0) })) {
                            Image(systemName: row.secret ? "lock.fill" : "lock.open").accessibilityLabel("Secret")
                        }
                        .toggleStyle(PillToggleStyle())
                        .help("Secret: kept in the Keychain, not in a file, and masked on screen")
                        Button {
                            let id = row.id
                            rows.removeAll { $0.id == id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(GhostButtonStyle())
                        .help("Remove this variable")
                    }
                }
                .opacity(row.enabled ? 1 : 0.5)
            }
        }
        .textFieldStyle(ThemedTextFieldStyle())
        .font(.system(.body, design: .monospaced))
    }

    /// Environments left in the workspace by an earlier version of the app. They are not used
    /// any more, and each can be added to a collection or deleted.
    private var leftovers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Environments from an earlier version").sectionTitle()
            Text("Environments are no longer used. Add each one's variables to the collection it was for, or delete it.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.unusedEnvironments) { environment in
                HStack(spacing: 10) {
                    Text(environment.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text("\(environment.variables.count) \(environment.variables.count == 1 ? "variable" : "variables")")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Menu("Add to a Collection") {
                        ForEach(model.collections) { collection in
                            Button(collection.name) { adopt(environment, into: collection.id) }
                        }
                    }
                    .fixedSize()
                    .disabled(model.collections.isEmpty)
                    Button("Delete", role: .destructive) { model.deleteEnvironment(environment.id) }
                        .buttonStyle(GhostButtonStyle())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
        }
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
    }

    @ViewBuilder
    private func valueField(_ row: Binding<Variable>) -> some View {
        let text = Binding(get: { row.wrappedValue.shownValue }, set: { row.wrappedValue.shownValue = $0 })
        if row.wrappedValue.secret || (model.secretsHidden && Redactor.isSensitiveName(row.wrappedValue.key)) {
            SecureField("value", text: text)
        } else {
            TextField("value", text: text)
        }
    }

    private func rowBinding(_ id: UUID) -> Binding<Variable> {
        Binding(
            get: { rows.first { $0.id == id } ?? Variable() },
            set: { new in
                if let index = rows.firstIndex(where: { $0.id == id }) { rows[index] = new }
            }
        )
    }

    // MARK: Loading and saving

    private func load(_ scope: Scope) {
        switch scope {
        case .collection(let id): rows = model.collections.first { $0.id == id }?.variables ?? []
        case .globals: rows = model.globals
        }
        loaded = scope
    }

    /// Writes the rows back to where they came from, if they have changed.
    private func save() {
        guard let loaded else { return }
        // A row that was added and left blank is not a variable.
        rows.removeAll { $0.key.isEmpty && $0.shownValue.isEmpty }
        switch loaded {
        case .collection(let id):
            model.saveVariables(rows, forCollection: id)
        case .globals:
            if rows != model.globals { model.saveGlobals(rows) }
        }
    }

    /// Adds a leftover environment's variables to a collection, and shows them if that
    /// collection is the one on screen.
    private func adopt(_ environment: APIEnvironment, into collectionID: UUID) {
        save()
        model.adopt(environment, into: collectionID)
        if let loaded { load(loaded) }
    }
}

/// Asks which collection an imported environment's variables should be added to. A
/// collection has one set of variables, so an environment from Postman or another app
/// joins a collection instead of standing on its own.
struct EnvironmentDestinationView: View {
    @Environment(AppModel.self) private var model
    let pending: PendingEnvironment

    @State private var choice: EnvironmentDestination = .newCollection

    var body: some View {
        let count = pending.environment.variables.count
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add “\(pending.environment.name)” to which collection?")
                    .font(.system(size: 17, weight: .bold))
                Text("This environment has \(count) \(count == 1 ? "variable" : "variables"). They are added to the collection's own variables, and one with the same name is replaced.")
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.collections) { collection in
                        SelectableRow(isSelected: choice == .collection(collection.id)) {
                            choice = .collection(collection.id)
                        } content: {
                            Image(systemName: "folder").foregroundStyle(Theme.textSecondary).frame(width: 16)
                            Text(collection.name).font(.system(size: 13)).lineLimit(1)
                        }
                    }
                    SelectableRow(isSelected: choice == .newCollection) {
                        choice = .newCollection
                    } content: {
                        Image(systemName: "plus").foregroundStyle(Theme.textSecondary).frame(width: 16)
                        Text("A new collection named “\(pending.environment.name)”").font(.system(size: 13)).lineLimit(1)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 260)
            Divider()
            HStack {
                Button("Don’t Import It") { model.resolvePendingEnvironment(.skip) }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Add") { model.resolvePendingEnvironment(choice) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520)
        .onAppear {
            if let suggested = model.suggestedCollectionForImport { choice = .collection(suggested) }
        }
    }
}
