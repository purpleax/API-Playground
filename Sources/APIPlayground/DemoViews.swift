import APIEngine
import AppKit
import SwiftUI

// MARK: - Mock server

/// Starts and stops the mock server for a collection, and shows its routes and the requests it received.
struct MockView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The collection to offer a mock for when none is running.
    let collectionID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Mock Server").font(.system(size: 17, weight: .bold))
                if let session = model.mock {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill").foregroundStyle(Theme.success).font(.caption)
                        Text("Serving \"\(session.collectionName)\" at")
                        Text(session.url)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(session.url, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(GhostButtonStyle())
                        .help("Copy the address")
                    }
                    if let variable = session.baseVariable {
                        Text("Requests that start with {{\(variable)}} now go to the mock until it stops.")
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("This collection's URLs do not start with a shared variable, so point requests at the address above yourself.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Text("Answers requests on this Mac with each request's pinned responses, so a demo needs no backend and no network.")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(14)
            Divider()

            if let session = model.mock {
                HSplitView {
                    routeList(session.routes)
                        .frame(minWidth: 300)
                    hitList(session.hits)
                        .frame(minWidth: 260)
                }
            } else if let collection = model.collections.first(where: { $0.id == collectionID }) {
                routeList(MockServer.routes(for: collection))
            } else {
                Spacer()
            }

            Divider()
            HStack {
                if model.mock != nil {
                    Button("Stop Mock") { model.stopMock() }
                } else if let collectionID {
                    Button("Start Mock") { model.startMock(collectionID: collectionID) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 820, height: 540)
    }

    private func routeList(_ routes: [MockRoute]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Routes").sectionTitle().padding(.horizontal, 12).padding(.vertical, 8)
            List(routes) { route in
                HStack(spacing: 8) {
                    MethodBadge(method: route.method)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.path)
                            .font(.system(.body, design: .monospaced))
                        Text(route.name)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if route.examples.isEmpty {
                        Label("Nothing pinned", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                            .help("Send this request once and pin the response, or the mock answers 501.")
                    } else {
                        Text(route.examples.count == 1 ? "1 response" : "\(route.examples.count) responses")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .overlay {
                if routes.isEmpty {
                    Text("This collection has no requests.").foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func hitList(_ hits: [MockHit]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Requests received").sectionTitle().padding(.horizontal, 12).padding(.vertical, 8)
            List(hits) { hit in
                HStack(spacing: 8) {
                    Text("\(hit.status)")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(ResponseView.statusColor(hit.status))
                    MethodBadge(method: hit.method)
                    Text(hit.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Text(hit.date.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .overlay {
                if hits.isEmpty {
                    Text("Nothing yet").foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

// MARK: - Demo sequence editor

struct SequenceEditorView: View {
    @Environment(AppModel.self) private var model
    let reference: SequenceReference

    var body: some View {
        let requests = model.collections.first { $0.id == reference.collectionID }?.allRequests ?? []
        let sequence = Binding<DemoSequence>(
            get: { model.sequence(reference) ?? DemoSequence(id: reference.sequenceID) },
            set: { model.updateSequence($0, in: reference.collectionID) }
        )
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Demo name", text: sequence.name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                Text("While presenting, each step shows its note and sends its request when you press Space.")
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(sequence.wrappedValue.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .frame(width: 22, alignment: .trailing)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 4) {
                                MenuPicker(title: requests.first { $0.id == step.requestID }.map { "\($0.method) \($0.name)" } ?? "Choose a request", selection: Binding(
                                    get: { step.requestID },
                                    set: { sequence.wrappedValue.steps[index].requestID = $0 }
                                )) {
                                    ForEach(requests) { request in
                                        Text("\(request.method) \(request.name)").tag(request.id)
                                    }
                                }
                                .labelsHidden()
                                TextField("What to say at this step", text: Binding(
                                    get: { step.note },
                                    set: { sequence.wrappedValue.steps[index].note = $0 }
                                ), axis: .vertical)
                                .textFieldStyle(ThemedTextFieldStyle())
                                .lineLimit(1...4)
                            }
                            VStack(spacing: 2) {
                                Button {
                                    sequence.wrappedValue.steps.swapAt(index, index - 1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .disabled(index == 0)
                                .help("Move up")
                                Button {
                                    sequence.wrappedValue.steps.swapAt(index, index + 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .disabled(index == sequence.wrappedValue.steps.count - 1)
                                .help("Move down")
                            }
                            .buttonStyle(GhostButtonStyle())
                            Button {
                                sequence.wrappedValue.steps.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(GhostButtonStyle())
                            .help("Remove this step")
                            .padding(.top, 3)
                        }
                    }
                    Button {
                        if let first = requests.first {
                            sequence.wrappedValue.steps.append(DemoStep(requestID: model.selection ?? first.id))
                        }
                    } label: {
                        Label("Add Step", systemImage: "plus")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(requests.isEmpty)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Button("Delete Demo", role: .destructive) { model.deleteSequence(reference) }
                Spacer()
                Button("Present") { model.present(reference) }
                    .disabled(sequence.wrappedValue.steps.isEmpty)
                Button("Done") { model.editingSequence = nil }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 540)
    }
}

// MARK: - Presentation mode

/// A simplified, large-type view for showing a request and its response to an audience.
/// Secrets are always masked here.
struct PresentationView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let state = model.presentation, let step = state.step, let request = model.request(step.requestID) {
            let redactor = model.redactor(for: request.id) ?? Redactor()
            VStack(alignment: .leading, spacing: 0) {
                // Title bar
                HStack(alignment: .firstTextBaseline) {
                    Text(state.title)
                        .font(.title3)
                        .foregroundStyle(Theme.textSecondary)
                    if state.steps.count > 1 {
                        Text("Step \(state.index + 1) of \(state.steps.count)")
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Label("Secrets hidden", systemImage: "eye.slash")
                        .foregroundStyle(Theme.textSecondary)
                    Button("Exit") { model.stopPresenting() }
                    }
                .padding(.horizontal, 28)
                .padding(.top, 34)

                VStack(alignment: .leading, spacing: 10) {
                    Text(request.name)
                        .font(.system(size: 38, weight: .heavy))
                        .foregroundStyle(Theme.text)
                    if !step.note.isEmpty {
                        Text(step.note)
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(request.method.uppercased())
                            .font(.system(size: 17, weight: .heavy, design: .monospaced))
                            .foregroundStyle(Theme.method(request.method))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.method(request.method).opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                        Text(redactor.url(model.preview(request.id)?.url ?? request.url))
                            .font(.system(size: 20, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)

                Divider()

                HSplitView {
                    requestBody(request, redactor)
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    responsePane(request, redactor)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider()
                controls(state, request)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
            }
            .buttonStyle(SecondaryButtonStyle(large: true))
            .foregroundStyle(Theme.text)
            .background {
                ZStack {
                    Theme.canvas
                    // A soft glow in two corners, in the signature colours.
                    RadialGradient(colors: [Theme.accent.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 620)
                    RadialGradient(colors: [Theme.accentAlt.opacity(0.14), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 700)
                }
                .ignoresSafeArea()
            }
            .onAppear { installKeyHandler() }
            .onDisappear { removeKeyHandler() }
        }
    }

    @State private var keyMonitor: Any?

    /// Presentation keys are handled directly, because a plain Space or arrow key is not a
    /// reliable button shortcut: Space sends, the arrows move, P shows the pinned response, Esc exits.
    private func installKeyHandler() {
        removeKeyHandler()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let model = AppModel.shared
            guard let step = model.presentation?.step,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  // Leave typing alone while a sheet or alert is up.
                  event.window?.attachedSheet == nil else { return event }
            switch event.keyCode {
            case 49, 36, 76:  // Space, Return, Enter
                model.send(step.requestID)
            case 123:  // Left arrow
                model.presentationMove(by: -1)
            case 124:  // Right arrow
                model.presentationMove(by: 1)
            case 53:  // Escape
                model.stopPresenting()
            case 35:  // P
                if let example = model.request(step.requestID)?.examples.first {
                    model.showPinned(step.requestID, example)
                }
            default:
                return event
            }
            return nil
        }
    }

    private func removeKeyHandler() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    @ViewBuilder
    private func requestBody(_ request: RequestItem, _ redactor: Redactor) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Request body")
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
            let prepared = model.preview(request.id)
            if let data = prepared?.body, let text = String(data: data, encoding: .utf8), !text.isEmpty {
                ReadOnlyCode(text: redactor.redact(LineDiff.prettyJSON(data) ?? text), fontSize: 16)
                    .padding(.horizontal, 16)
            } else {
                Text("None")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 28)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func responsePane(_ request: RequestItem, _ redactor: Redactor) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Response")
                    .font(.headline)
                    .foregroundStyle(Theme.textSecondary)
                if case .finished(let result) = model.responses[request.id], let response = result.response {
                    Text("\(response.status) \(response.statusText)")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ResponseView.statusColor(response.status))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(ResponseView.statusColor(response.status).opacity(0.16), in: Capsule())
                    if let name = model.pinnedShown[request.id] {
                        Label("Pinned: \(name)", systemImage: "pin.fill")
                            .foregroundStyle(Theme.warning)
                    } else {
                        Text(ResponseView.duration(response.timings.total))
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                        if !result.tests.isEmpty {
                            let failed = result.failedTests.count
                            Label(failed == 0 ? (result.tests.count == 1 ? "1 test passed" : "\(result.tests.count) tests passed") : "\(failed) of \(result.tests.count) tests failed",
                                  systemImage: failed == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(failed == 0 ? Theme.success : Theme.danger)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)

            switch model.responses[request.id] {
            case nil:
                hint("Press Space to send")
            case .sending:
                VStack {
                    Spacer()
                    ProgressView("Sending…").controlSize(.large)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            case .finished(let result):
                if let response = result.response {
                    if response.body.isEmpty {
                        hint("The server sent no content")
                    } else {
                        ReadOnlyCode(text: redactor.redact(LineDiff.prettyJSON(response.body) ?? response.text ?? "\(response.body.count) bytes of binary data"), fontSize: 16)
                            .padding(.horizontal, 16)
                    }
                } else {
                    hint(result.error ?? "The request did not complete")
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 20))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func controls(_ state: PresentationState, _ request: RequestItem) -> some View {
        HStack(spacing: 12) {
            Button {
                model.presentationMove(by: -1)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(state.index == 0)

            Button {
                model.send(request.id)
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(PrimaryButtonStyle(large: true))

            if let example = request.examples.first {
                Button {
                    model.showPinned(request.id, example)
                } label: {
                    Label("Show Pinned", systemImage: "pin")
                }
                .help("Show the pinned response instead of calling the API")
            }

            Button {
                model.presentationMove(by: 1)
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(state.index >= state.steps.count - 1)

            Spacer()
            Text("Space sends · ← → move · P shows the pinned response · Esc exits")
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
