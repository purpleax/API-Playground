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

/// An editable list of variables, each of which can be marked secret.
struct VariableEditor: View {
    @Binding var variables: [Variable]
    /// When true, values of variables whose name suggests a secret are shown as dots too.
    var hidesSecrets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($variables) { $variable in
                HStack(spacing: 6) {
                    Toggle("Enabled", isOn: $variable.enabled)
                        .labelsHidden()
                        .toggleStyle(ThemedCheckboxStyle())
                    TextField("Name", text: $variable.key)
                        .frame(width: 150)
                    if variable.secret {
                        SecureField("Value", text: $variable.value)
                    } else if hidesSecrets && Redactor.isSensitiveName(variable.key) {
                        SecureField("Shared value", text: $variable.value)
                        SecureField("This Mac only", text: Binding(
                            get: { variable.currentValue ?? "" },
                            set: { variable.currentValue = $0.isEmpty ? nil : $0 }
                        ))
                    } else {
                        TextField("Shared value", text: $variable.value)
                        TextField("This Mac only", text: Binding(
                            get: { variable.currentValue ?? "" },
                            set: { variable.currentValue = $0.isEmpty ? nil : $0 }
                        ))
                        .help("Used in place of the shared value on this Mac. Never saved to the workspace.")
                    }
                    Toggle(isOn: $variable.secret) {
                        Image(systemName: variable.secret ? "lock.fill" : "lock.open")
                            .accessibilityLabel("Secret")
                    }
                    .toggleStyle(PillToggleStyle())
                    .help("Secret values are kept in the Keychain, not in files")
                    Button {
                        variables.removeAll { $0.id == variable.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("Remove")
                }
                .textFieldStyle(ThemedTextFieldStyle())
                .font(.system(.body, design: .monospaced))
                .opacity(variable.enabled ? 1 : 0.5)
            }
            Button {
                variables.append(Variable())
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(GhostButtonStyle())
        }
    }
}

/// The sheet for editing environments and global variables.
struct EnvironmentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// nil means the globals are selected.
    @State private var selected: UUID?
    @State private var draft = APIEnvironment()
    @State private var globalsDraft: [Variable] = []

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        SelectableRow(isSelected: selected == nil) {
                            selected = nil
                        } content: {
                            Image(systemName: "globe").foregroundStyle(Theme.info)
                            Text("Globals").font(.system(size: 13, weight: .medium))
                        }
                        Text("Environments")
                            .sectionTitle()
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                        if model.environments.isEmpty {
                            Text("None yet. An environment is a set of values you switch between in the top bar, such as staging and production.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10)
                        }
                        ForEach(model.environments) { environment in
                            SelectableRow(isSelected: selected == environment.id) {
                                selected = environment.id
                            } content: {
                                Circle()
                                    .fill(model.activeEnvironmentID == environment.id ? Theme.accent : Theme.textTertiary)
                                    .frame(width: 7, height: 7)
                                Text(environment.name)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(minWidth: 180, maxWidth: 240)
                .background(Theme.chrome)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("A \"This Mac only\" value replaces the shared value here and is never saved to the workspace.")
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                        Text("A collection's own variables, such as its base address, are not here: right-click the collection in the sidebar and choose Variables….")
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                        if selected == nil {
                            Text("Globals").font(.system(size: 17, weight: .bold))
                            Text("Available to every request. A collection or environment variable with the same name wins.")
                                .foregroundStyle(Theme.textSecondary)
                            VariableEditor(variables: $globalsDraft, hidesSecrets: model.secretsHidden)
                        } else {
                            TextField("Environment name", text: $draft.name)
                                .textFieldStyle(ThemedTextFieldStyle())
                                .font(.headline)
                            VariableEditor(variables: $draft.variables, hidesSecrets: model.secretsHidden)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 420)
            }
            Divider()
            HStack {
                Button {
                    commit()
                    let environment = APIEnvironment()
                    model.saveEnvironment(environment)
                    selected = environment.id
                } label: {
                    Label("New Environment", systemImage: "plus")
                }
                Button("Delete", role: .destructive) {
                    if let id = selected {
                        selected = nil
                        model.deleteEnvironment(id)
                    }
                }
                .disabled(selected == nil)
                Spacer()
                Button("Done") {
                    commit()
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 940, height: 520)
        .onAppear {
            globalsDraft = model.globals
            selected = model.activeEnvironmentID
            load(selected)
        }
        .onChange(of: selected) { old, new in
            commit(old)
            load(new)
        }
    }

    private func load(_ id: UUID?) {
        if let id, let environment = model.environments.first(where: { $0.id == id }) {
            draft = environment
        }
    }

    /// Saves the edits for the environment that was showing.
    private func commit(_ id: UUID?? = nil) {
        let target = id ?? selected
        if let target {
            if draft.id == target, model.environments.contains(where: { $0.id == target }) {
                model.saveEnvironment(draft)
            }
        } else {
            model.saveGlobals(globalsDraft)
        }
    }
}

/// The sheet for editing one collection's own variables. They are not an environment:
/// they always apply to the collection's requests, whichever environment is chosen.
struct CollectionVariablesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let collectionID: UUID

    @State private var draft: [Variable] = []

    private var name: String {
        model.collections.first { $0.id == collectionID }?.name ?? "Collection"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Variables for \(name)").font(.system(size: 17, weight: .bold))
                    Text("Used by every request in this collection, such as the address they all start with. They apply whichever environment is chosen; an environment variable with the same name wins.")
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("A \"This Mac only\" value replaces the shared value here and is never saved to the workspace.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                    VariableEditor(variables: $draft, hidesSecrets: model.secretsHidden)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    model.saveVariables(draft, forCollection: collectionID)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 760, height: 420)
        .onAppear {
            draft = model.collections.first { $0.id == collectionID }?.variables ?? []
        }
    }
}
