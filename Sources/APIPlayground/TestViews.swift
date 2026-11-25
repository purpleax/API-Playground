import APIEngine
import SwiftUI

extension ValueSource.Kind {
    var title: String {
        switch self {
        case .status: return "Status"
        case .header: return "Header"
        case .json: return "JSON value"
        case .body: return "Body text"
        case .time: return "Time (ms)"
        }
    }

    var pathPrompt: String? {
        switch self {
        case .header: return "Header name"
        case .json: return "$.items[0].id"
        default: return nil
        }
    }
}

/// Picks what to read from the response: a kind, and a header name or JSON path where needed.
private struct SourcePicker: View {
    @Binding var source: ValueSource

    var body: some View {
        Picker("Read from", selection: $source.kind) {
            ForEach(ValueSource.Kind.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .labelsHidden()
        .fixedSize()
        if let prompt = source.kind.pathPrompt {
            TextField(prompt, text: $source.path)
                .frame(minWidth: 110)
        }
    }
}

/// Edits a request's no-code checks and the values it saves for later requests.
struct TestsEditor: View {
    @Binding var assertions: [Assertion]
    @Binding var extractions: [Extraction]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Checks").font(.headline)
            Text("Each check runs against the response and shows as a test result.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach($assertions) { $assertion in
                    HStack(spacing: 6) {
                        Toggle("Enabled", isOn: $assertion.enabled)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        SourcePicker(source: $assertion.source)
                        Picker("Comparison", selection: $assertion.op) {
                            ForEach(AssertionOperator.allCases, id: \.self) { op in
                                Text(op.label).tag(op)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        if assertion.op.needsValue {
                            TextField("Expected", text: $assertion.expected)
                                .frame(minWidth: 70)
                        }
                        Spacer(minLength: 0)
                        Button {
                            assertions.removeAll { $0.id == assertion.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .opacity(assertion.enabled ? 1 : 0.5)
                }
                Button {
                    assertions.append(Assertion())
                } label: {
                    Label("Add Check", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            Text("Save from response").font(.headline)
            Text("Copies a value into a variable, so the next request can use it as {{name}}.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach($extractions) { $extraction in
                    HStack(spacing: 6) {
                        Toggle("Enabled", isOn: $extraction.enabled)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        SourcePicker(source: $extraction.source)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField("Variable name", text: $extraction.variable)
                            .frame(minWidth: 90)
                        Picker("Scope", selection: $extraction.scope) {
                            ForEach(VariableScopeKind.allCases, id: \.self) { scope in
                                Text(scope.label).tag(scope)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Spacer(minLength: 0)
                        Button {
                            extractions.removeAll { $0.id == extraction.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .opacity(extraction.enabled ? 1 : 0.5)
                }
                Button {
                    extractions.append(Extraction())
                } label: {
                    Label("Add Saved Value", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

/// The outcome of one request's checks and scripts.
struct TestResultsView: View {
    let result: RequestRunResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = result.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if let error = result.scriptError {
                Label("Script error: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if result.skipped {
                Label("A pre-request script skipped this request.", systemImage: "forward.end")
                    .foregroundStyle(.secondary)
            }
            if result.tests.isEmpty && result.error == nil && result.scriptError == nil && !result.skipped {
                Text("This request has no checks or test scripts. Add them in the request's Tests and Scripts tabs.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(result.tests.enumerated()), id: \.offset) { _, test in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: test.skipped ? "minus.circle" : (test.passed ? "checkmark.circle.fill" : "xmark.circle.fill"))
                        .foregroundStyle(test.skipped ? Color.secondary : (test.passed ? Color.green : Color.red))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(test.name)
                        if let message = test.message {
                            Text(message)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !result.logs.isEmpty {
                Divider()
                Text("Console").font(.headline)
                Text(result.logs.joined(separator: "\n"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The sheet that runs every request in a folder or collection and shows pass or fail.
struct RunnerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.runner {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run: \(session.title)")
                        .font(.title3.weight(.semibold))
                    Text(summary(session))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                Divider()

                List(session.rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            icon(row)
                                .frame(width: 18)
                            MethodBadge(method: row.method)
                            Text(row.name)
                            Spacer()
                            if let result = row.result {
                                if let response = result.response {
                                    Text("\(response.status)")
                                        .font(.system(.body, design: .monospaced).weight(.semibold))
                                        .foregroundStyle(ResponseView.statusColor(response.status))
                                    Text(ResponseView.duration(response.timings.total))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 70, alignment: .trailing)
                                }
                                if !result.tests.isEmpty {
                                    Text("\(result.tests.count - result.failedTests.count)/\(result.tests.count)")
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 44, alignment: .trailing)
                                }
                            }
                            Button("Open") {
                                model.selection = row.id
                                model.closeRunner()
                            }
                            .buttonStyle(.borderless)
                            .help("Close the run and show this request")
                        }
                        if let result = row.result, !result.passed {
                            failures(result)
                                .padding(.leading, 26)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .overlay {
                    if session.rows.isEmpty {
                        Text("There are no requests to run here.")
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
                HStack {
                    if session.isRunning {
                        ProgressView()
                            .controlSize(.small)
                        Button("Stop") { model.stopRun() }
                    } else {
                        Button("Run Again") {
                            model.startRun(collectionID: session.collectionID, folderID: session.folderID)
                        }
                        .disabled(session.rows.isEmpty)
                    }
                    Spacer()
                    Button("Done") { model.closeRunner() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(width: 760, height: 560)
        }
    }

    @ViewBuilder
    private func icon(_ row: RunnerRow) -> some View {
        if row.isRunning {
            ProgressView()
                .controlSize(.small)
        } else if let result = row.result {
            if result.skipped {
                Image(systemName: "forward.end.circle").foregroundStyle(.secondary)
            } else if result.passed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    private func failures(_ result: RequestRunResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let error = result.error {
                Text(error).foregroundStyle(.red)
            }
            if let error = result.scriptError {
                Text("Script error: \(error)").foregroundStyle(.red)
            }
            ForEach(Array(result.failedTests.enumerated()), id: \.offset) { _, test in
                Text("✗ \(test.name)\(test.message.map { " — \($0)" } ?? "")")
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func summary(_ session: RunnerSession) -> String {
        let finished = session.rows.compactMap(\.result)
        let passed = finished.filter { $0.passed && !$0.skipped }.count
        let tests = finished.flatMap(\.tests)
        let testsPassed = tests.filter(\.passed).count
        var parts = ["\(finished.count) of \(session.rows.count) requests run", "\(passed) passed"]
        if !tests.isEmpty {
            parts.append("\(testsPassed) of \(tests.count) tests passed")
        }
        return parts.joined(separator: " · ")
    }
}
