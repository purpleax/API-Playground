import APIEngine
import AppKit
import SwiftUI

/// A monospaced text area backed by NSTextView, which stays fast with large response bodies.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var fontSize: CGFloat = 12

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
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
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.drawsBackground = false
        scrollView.drawsBackground = false
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        if textView.font?.pointSize != fontSize {
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView

        init(_ parent: CodeTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// Shows text that cannot be edited.
struct ReadOnlyCode: View {
    let text: String
    var fontSize: CGFloat = 12

    var body: some View {
        CodeTextView(text: .constant(text), isEditable: false, fontSize: fontSize)
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
                        .toggleStyle(.checkbox)
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
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .opacity(item.enabled ? 1 : 0.5)
            }
            if allowsAdding {
                Button {
                    items.append(KeyValue())
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
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
                        .toggleStyle(.checkbox)
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
                    .toggleStyle(.button)
                    .help("Secret values are kept in the Keychain, not in files")
                    Button {
                        variables.removeAll { $0.id == variable.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .opacity(variable.enabled ? 1 : 0.5)
            }
            Button {
                variables.append(Variable())
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderless)
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
                List(selection: $selected) {
                    Label("Globals", systemImage: "globe").tag(UUID?.none)
                    Section("Environments") {
                        ForEach(model.environments) { environment in
                            Text(environment.name).tag(UUID?.some(environment.id))
                        }
                    }
                }
                .frame(minWidth: 170, maxWidth: 240)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("A \"This Mac only\" value replaces the shared value here and is never saved to the workspace.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if selected == nil {
                            Text("Globals").font(.headline)
                            Text("Available to every request. A collection or environment variable with the same name wins.")
                                .foregroundStyle(.secondary)
                            VariableEditor(variables: $globalsDraft, hidesSecrets: model.secretsHidden)
                        } else {
                            TextField("Environment name", text: $draft.name)
                                .textFieldStyle(.roundedBorder)
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
