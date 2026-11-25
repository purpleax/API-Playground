import APIEngine
import SwiftUI

struct ResponseView: View {
    @Environment(AppModel.self) private var model
    let requestID: UUID

    enum Tab: String, CaseIterable, Identifiable {
        case body = "Body", headers = "Headers", tests = "Tests", timing = "Timing", log = "Log", history = "History"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .body
    @State private var pretty = true

    var body: some View {
        let state = model.responses[requestID]
        let result = finished(state)
        VStack(alignment: .leading, spacing: 0) {
            statusBar(result)
                .frame(height: 30)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(title(tab, result)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            if tab == .history {
                HistoryView(requestID: requestID, current: result?.response)
            } else if case .sending = state {
                VStack {
                    Spacer()
                    ProgressView("Sending…")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let result {
                if tab == .tests {
                    ScrollView {
                        TestResultsView(result: result)
                            .padding(12)
                    }
                } else if let response = result.response, let prepared = result.prepared {
                    content(response, prepared)
                } else if result.skipped {
                    placeholder("The request was skipped", systemImage: "forward.end", detail: "A pre-request script called pm.execution.skipRequest().")
                } else {
                    placeholder("The request failed", systemImage: "exclamationmark.triangle", detail: result.error ?? "Unknown error")
                }
            } else {
                placeholder("Send the request to see its response", systemImage: "paperplane", detail: "Press ⌘↩ or click Send.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func finished(_ state: ResponseState?) -> RequestRunResult? {
        if case .finished(let result) = state { return result }
        return nil
    }

    private func title(_ tab: Tab, _ result: RequestRunResult?) -> String {
        guard let result else { return tab.rawValue }
        switch tab {
        case .headers:
            return result.response.map { "Headers (\($0.headers.count))" } ?? tab.rawValue
        case .tests:
            if result.tests.isEmpty { return result.scriptError == nil ? "Tests" : "Tests !" }
            return "Tests (\(result.tests.count - result.failedTests.count)/\(result.tests.count))"
        default:
            return tab.rawValue
        }
    }

    @ViewBuilder
    private func statusBar(_ result: RequestRunResult?) -> some View {
        if let result, let response = result.response {
            HStack(spacing: 8) {
                Text("\(response.status) \(response.statusText)")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Self.statusColor(response.status), in: RoundedRectangle(cornerRadius: 5))
                pill(Self.duration(response.timings.total))
                pill(ByteCountFormatter.string(fromByteCount: Int64(response.body.count), countStyle: .file))
                pill(response.httpVersion)
                if !result.tests.isEmpty || result.scriptError != nil {
                    let failed = result.failedTests.count + (result.scriptError == nil ? 0 : 1)
                    Label(failed == 0 ? "Tests passed" : "\(failed) failed", systemImage: failed == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(failed == 0 ? Color.green : Color.red)
                }
                Spacer()
            }
        } else {
            HStack {
                Text("Response")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }

    private func placeholder(_ title: String, systemImage: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        }
    }

    @ViewBuilder
    private func content(_ response: HTTPResponse, _ prepared: PreparedRequest) -> some View {
        switch tab {
        case .body:
            VStack(alignment: .leading, spacing: 0) {
                if !prepared.unresolved.isEmpty {
                    Label("No value for: \(prepared.unresolved.joined(separator: ", ")). The {{placeholders}} were sent as written.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    Divider()
                }
                if response.body.isEmpty {
                    placeholder("Empty body", systemImage: "doc", detail: "The server sent no content.")
                } else if let text = response.text {
                    let formatted = LineDiff.prettyJSON(response.body)
                    if formatted != nil {
                        Toggle("Format JSON", isOn: $pretty)
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        Divider()
                    }
                    ReadOnlyCode(text: pretty ? (formatted ?? text) : text)
                } else {
                    placeholder("Binary data", systemImage: "doc.zipper", detail: "\(response.body.count) bytes that are not text.")
                }
            }
        case .headers:
            Table(response.headers.enumerated().map { HeaderRow(id: $0.offset, header: $0.element) }) {
                TableColumn("Name") { Text($0.header.name).textSelection(.enabled) }
                    .width(min: 120, ideal: 220)
                TableColumn("Value") { Text($0.header.value).textSelection(.enabled) }
            }
            .font(.system(.body, design: .monospaced))
        case .timing:
            ScrollView {
                TimingView(timings: response.timings, remoteAddress: response.remoteAddress)
                    .padding(12)
            }
        case .log:
            ReadOnlyCode(text: Self.logText(response.wireLog))
        case .tests, .history:
            EmptyView()
        }
    }

    private struct HeaderRow: Identifiable {
        let id: Int
        let header: HTTPHeader
    }

    static func statusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        default: return .red
        }
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }

    static func logText(_ log: [WireLogEntry]) -> String {
        log.map { entry in
            let prefix: String
            switch entry.kind {
            case .info: prefix = "* "
            case .requestHeader, .requestData: prefix = "> "
            case .responseHeader, .responseData: prefix = "< "
            }
            // "\r\n" is a single Character in Swift, so split on any newline rather than on "\n".
            return entry.text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
                .map { prefix + $0 }
                .joined(separator: "\n")
        }
        .joined(separator: "\n")
    }
}

/// A waterfall of where the time went.
struct TimingView: View {
    let timings: HTTPTimings
    let remoteAddress: String?

    private static let colors: [Color] = [.teal, .orange, .purple, .blue, .green, .pink]

    var body: some View {
        let phases = timings.phases
        // Phases start after any redirects, so the bars line up against the full total.
        let scale = max(timings.total, phases.map(\.seconds).reduce(0, +), 0.000001)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                let start = phases.prefix(index).map(\.seconds).reduce(0, +)
                HStack(spacing: 10) {
                    Text(phase.name)
                        .frame(width: 80, alignment: .leading)
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Self.colors[index % Self.colors.count])
                            .frame(width: max(2, geometry.size.width * phase.seconds / scale))
                            .offset(x: geometry.size.width * start / scale)
                    }
                    .frame(height: 14)
                    Text(ResponseView.duration(phase.seconds))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 80, alignment: .trailing)
                }
            }
            Divider()
            row("Total", ResponseView.duration(timings.total))
            if timings.redirect > 0 {
                row("Redirects", ResponseView.duration(timings.redirect))
            }
            if let remoteAddress {
                row("Server address", remoteAddress)
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

/// Past responses to this request, and a line-by-line comparison against the current one.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    let requestID: UUID
    let current: HTTPResponse?

    @State private var entries: [HistoryEntry] = []
    @State private var selected: UUID?

    var body: some View {
        VSplitView {
            List(entries, selection: $selected) { entry in
                HStack {
                    Text("\(entry.status)")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(ResponseView.statusColor(entry.status))
                    Text(entry.date.formatted(date: .abbreviated, time: .standard))
                    Spacer()
                    Text(ResponseView.duration(entry.timings.total))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .tag(entry.id)
            }
            .frame(minHeight: 90, idealHeight: 150)
            .overlay {
                if entries.isEmpty {
                    Text("No past responses yet")
                        .foregroundStyle(.secondary)
                }
            }

            comparison
                .frame(minHeight: 120, maxHeight: .infinity)
        }
        .task(id: model.historyVersion) {
            entries = model.historyEntries(requestID)
        }
    }

    @ViewBuilder
    private var comparison: some View {
        if let entry = entries.first(where: { $0.id == selected }) {
            // Compare against the response on screen, or the newest saved one if nothing was sent yet.
            let newer: (label: String, body: Data)? = current.map { ("the current response", $0.body) }
                ?? entries.first.map { ("the newest response", $0.body) }
            if let newer {
                let lines = LineDiff.diff(old: Self.comparable(entry.body), new: Self.comparable(newer.body))
                VStack(alignment: .leading, spacing: 0) {
                    Text(lines.allSatisfy { $0.kind == .same }
                         ? "Identical to \(newer.label)."
                         : "Changes from this response to \(newer.label):")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider()
                    DiffView(lines: lines)
                }
            }
        } else {
            VStack {
                Spacer()
                Text("Select a past response to compare it with the current one.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private static func comparable(_ data: Data) -> String {
        LineDiff.prettyJSON(data) ?? String(decoding: data, as: UTF8.self)
    }
}

struct DiffView: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 6) {
                        Text(marker(line.kind))
                            .frame(width: 12)
                        Text(line.text.isEmpty ? " " : line.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(line.kind))
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
        }
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .same: return " "
        case .added: return "+"
        case .removed: return "−"
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .same: return .clear
        case .added: return .green.opacity(0.18)
        case .removed: return .red.opacity(0.18)
        }
    }
}
