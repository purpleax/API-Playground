import APIEngine
import SwiftUI

struct ResponseView: View {
    @Environment(AppModel.self) private var model
    let requestID: UUID

    enum Tab: String, CaseIterable, Identifiable {
        case body = "Body", events = "Events", headers = "Headers", cookies = "Cookies", tests = "Tests", timing = "Timing", log = "Log", history = "History"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .body
    @State private var pretty = true

    var body: some View {
        let state = model.responses[requestID]
        let result = finished(state)
        let redactor = model.redactor(for: requestID)
        VStack(alignment: .leading, spacing: 0) {
            statusBar(result)
                .frame(height: 32)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

            let stream = model.live[requestID]
            let tabs = visibleTabs(result, stream)
            ThemedTabBar(tabs: tabs.map { tabItem($0, result, stream) }, selection: $tab)
                .onChange(of: tabs) { _, now in
                    // Jump to the events when a stream starts, and off a tab that has gone away.
                    if now.contains(.events), tab == .body { tab = .events }
                    if !now.contains(tab) { tab = .body }
                }

            if tab == .history {
                HistoryView(requestID: requestID, current: result?.response, redactor: redactor)
            } else if case .sending = state, let stream, stream.isEventStream {
                EventListView(events: stream.events, redactor: redactor, isLive: true)
            } else if case .sending = state {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                        .tint(Theme.accent)
                    Text("Sending…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let result {
                if tab == .tests {
                    ScrollView {
                        TestResultsView(result: result, redactor: redactor)
                            .padding(12)
                    }
                } else if let response = result.response, let prepared = result.prepared {
                    content(response, prepared, redactor)
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

    /// Events and Cookies appear only for a response that has them.
    private func visibleTabs(_ result: RequestRunResult?, _ stream: LiveStream?) -> [Tab] {
        let response = result?.response
        let isEventStream = stream?.isEventStream == true
            || response?.header("Content-Type")?.lowercased().contains("text/event-stream") == true
        let setsCookies = response?.headers.contains { $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame } == true
        return Tab.allCases.filter { tab in
            switch tab {
            case .events: return isEventStream
            case .cookies: return setsCookies
            default: return true
            }
        }
    }

    private func tabItem(_ tab: Tab, _ result: RequestRunResult?, _ stream: LiveStream?) -> TabItem<Tab> {
        if tab == .events, let stream {
            return TabItem(id: tab, title: tab.rawValue, badge: String(stream.events.count), badgeColor: Theme.success)
        }
        guard let result else { return TabItem(id: tab, title: tab.rawValue) }
        switch tab {
        case .events:
            return TabItem(id: tab, title: tab.rawValue, badge: result.response.map { String(ServerSentEventParser.events(in: $0.body).count) })
        case .cookies:
            let count = result.response?.headers.filter { $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame }.count ?? 0
            return TabItem(id: tab, title: tab.rawValue, badge: String(count))
        case .headers:
            return TabItem(id: tab, title: tab.rawValue, badge: result.response.map { String($0.headers.count) })
        case .tests:
            let failed = result.failedTests.count + (result.scriptError == nil ? 0 : 1)
            if result.tests.isEmpty && failed == 0 { return TabItem(id: tab, title: tab.rawValue) }
            return TabItem(
                id: tab, title: tab.rawValue,
                badge: "\(result.tests.count - result.failedTests.count)/\(result.tests.count)",
                badgeColor: failed == 0 ? Theme.success : Theme.danger
            )
        default:
            return TabItem(id: tab, title: tab.rawValue)
        }
    }

    @ViewBuilder
    private func statusBar(_ result: RequestRunResult?) -> some View {
        if let result, let response = result.response {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.statusColor(response.status, grpc: response.httpVersion == "gRPC"))
                        .frame(width: 7, height: 7)
                        .shadow(color: Self.statusColor(response.status, grpc: response.httpVersion == "gRPC"), radius: 4)
                    Text("\(response.status) \(response.statusText)".trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Self.statusColor(response.status, grpc: response.httpVersion == "gRPC"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Self.statusColor(response.status, grpc: response.httpVersion == "gRPC").opacity(0.14), in: Capsule())
                .fixedSize()
                if response.wasCancelled {
                    Chip(text: "Stopped", color: Theme.warning, mono: false)
                        .help("This response was stopped before the server finished sending it.")
                }
                pill(ByteCountFormatter.string(fromByteCount: Int64(response.body.count), countStyle: .file))
                if let name = model.pinnedShown[requestID] {
                    Label("Pinned: \(name)", systemImage: "pin.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Theme.warning.opacity(0.13), in: Capsule())
                        .lineLimit(1)
                        .help("This is a saved response, not a live one. Send the request to replace it.")
                } else {
                    pill(Self.duration(response.timings.total))
                    pill(response.httpVersion)
                }
                if !result.tests.isEmpty || result.scriptError != nil {
                    let failed = result.failedTests.count + (result.scriptError == nil ? 0 : 1)
                    Label(failed == 0 ? "Passed" : "\(failed) failed", systemImage: failed == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(failed == 0 ? Theme.success : Theme.danger)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer()
                if model.pinnedShown[requestID] == nil {
                    IconButton(systemImage: "pin", help: "Pin this response: keep it with the request to show again or serve from a mock") {
                        model.pinResponse(requestID)
                    }
                }
                pinnedMenu
            }
        } else if let stream = model.live[requestID], let status = stream.status {
            // The response has started but not finished: an event stream, or a slow download.
            HStack(spacing: 8) {
                Chip(text: "\(status)", color: Self.statusColor(status))
                if stream.isEventStream {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.success).frame(width: 7, height: 7).shadow(color: Theme.success, radius: 4)
                        Text("Streaming").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.success)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.success.opacity(0.13), in: Capsule())
                }
                pill(ByteCountFormatter.string(fromByteCount: Int64(stream.bytes), countStyle: .file))
                Spacer()
            }
        } else {
            HStack {
                Text("Response")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                pinnedMenu
            }
        }
    }

    /// Lists the request's pinned responses, to show one or remove it.
    @ViewBuilder
    private var pinnedMenu: some View {
        let examples = model.request(requestID)?.examples ?? []
        if !examples.isEmpty {
            Menu {
                ForEach(Array(examples.enumerated()), id: \.offset) { _, example in
                    Button("Show \"\(example.name)\"") { model.showPinned(requestID, example) }
                }
                Divider()
                Menu("Remove") {
                    ForEach(Array(examples.enumerated()), id: \.offset) { _, example in
                        Button(example.name, role: .destructive) { model.removePinned(requestID, name: example.name) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill").font(.system(size: 10))
                    Text("\(examples.count)").font(.system(size: 11.5, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Theme.warning.opacity(0.13), in: Capsule())
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pinned responses")
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Theme.raised, in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }

    private func placeholder(_ title: String, systemImage: String, detail: String) -> some View {
        EmptyState(systemImage: systemImage, title: title, detail: detail)
    }

    @ViewBuilder
    private func content(_ response: HTTPResponse, _ prepared: PreparedRequest, _ redactor: Redactor?) -> some View {
        switch tab {
        case .body:
            VStack(alignment: .leading, spacing: 0) {
                if !prepared.unresolved.isEmpty {
                    Label("No value for: \(prepared.unresolved.joined(separator: ", ")). The {{placeholders}} were sent as written.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.warning.opacity(0.10))
                }
                if response.body.isEmpty {
                    placeholder("Empty body", systemImage: "doc", detail: "The server sent no content.")
                } else if let text = response.text {
                    let formatted = LineDiff.prettyJSON(response.body)
                    if formatted != nil {
                        HStack {
                            Spacer()
                            Toggle(isOn: $pretty) { Text("Format") }
                                .toggleStyle(PillToggleStyle())
                                .help("Indent the JSON for reading")
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }
                    let shown = pretty ? (formatted ?? text) : text
                    ReadOnlyCode(text: redactor?.redact(shown) ?? shown)
                } else {
                    placeholder("Binary data", systemImage: "doc.zipper", detail: "\(response.body.count) bytes that are not text.")
                }
            }
        case .headers:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(response.headers.enumerated()), id: \.offset) { index, header in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(header.name)
                                .foregroundStyle(Theme.Syntax.key.color)
                                .frame(width: 210, alignment: .leading)
                            Text(redactor?.header(name: header.name, value: header.value) ?? header.value)
                                .foregroundStyle(Theme.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(index.isMultiple(of: 2) ? Color.clear : Theme.raised.opacity(0.45))
                    }
                }
                .padding(.vertical, 6)
            }
        case .timing:
            ScrollView {
                TimingView(timings: response.timings, remoteAddress: response.remoteAddress)
                    .padding(12)
            }
        case .log:
            ReadOnlyCode(text: Self.logText(response.wireLog, redactor: redactor), syntax: .log)
        case .events:
            EventListView(events: ServerSentEventParser.events(in: response.body), redactor: redactor)
        case .cookies:
            ScrollView {
                let cookies = response.headers
                    .filter { $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame }
                    .compactMap { header in URL(string: prepared.url).flatMap { CookieJar.parse(header.value, from: $0) } }
                CookieRows(cookies: cookies, redactor: redactor)
                    .padding(.vertical, 6)
            }
        case .tests, .history:
            EmptyView()
        }
    }

    /// - Parameter grpc: gRPC's status codes count up from 0 for OK, unlike HTTP's.
    static func statusColor(_ status: Int, grpc: Bool = false) -> Color {
        if grpc { return status == 0 ? Theme.success : Theme.danger }
        return Theme.status(status)
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }

    static func logText(_ log: [WireLogEntry], redactor: Redactor? = nil) -> String {
        log.map { entry in
            let prefix: String
            switch entry.kind {
            case .info: prefix = "* "
            case .requestHeader, .requestData: prefix = "> "
            case .responseHeader, .responseData: prefix = "< "
            }
            // "\r\n" is a single Character in Swift, so split on any newline rather than on "\n".
            return entry.text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
                .map { prefix + (redactor?.headerLine(String($0)) ?? String($0)) }
                .joined(separator: "\n")
        }
        .joined(separator: "\n")
    }
}

/// A waterfall of where the time went.
struct TimingView: View {
    let timings: HTTPTimings
    let remoteAddress: String?

    private static let colors: [Color] = [Theme.info, Theme.warning, Theme.violet, Theme.accentAlt, Theme.success, Theme.danger]

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
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.raised)
                            Capsule()
                                .fill(Self.colors[index % Self.colors.count])
                                .shadow(color: Self.colors[index % Self.colors.count].opacity(0.5), radius: 4)
                                .frame(width: max(4, geometry.size.width * phase.seconds / scale))
                                .offset(x: min(geometry.size.width - 4, geometry.size.width * start / scale))
                        }
                    }
                    .frame(height: 10)
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
    var redactor: Redactor?

    @State private var entries: [HistoryEntry] = []
    @State private var selected: UUID?

    var body: some View {
        VSplitView {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(entries) { entry in
                        SelectableRow(isSelected: selected == entry.id) {
                            selected = entry.id
                        } content: {
                            Chip(text: "\(entry.status)", color: ResponseView.statusColor(entry.status, grpc: entry.method == "GRPC"))
                            Text(entry.date.formatted(date: .abbreviated, time: .standard))
                                .font(.system(size: 12.5))
                            Spacer()
                            Text(ResponseView.duration(entry.timings.total))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 90, idealHeight: 150)
            .overlay {
                if entries.isEmpty {
                    Text("No past responses yet")
                        .foregroundStyle(Theme.textSecondary)
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
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider()
                    DiffView(lines: redactor.map { r in lines.map { DiffLine(kind: $0.kind, text: r.redact($0.text)) } } ?? lines)
                }
            }
        } else {
            VStack {
                Spacer()
                Text("Select a past response to compare it with the current one.")
                    .foregroundStyle(Theme.textSecondary)
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
        case .added: return Theme.success.opacity(0.16)
        case .removed: return Theme.danger.opacity(0.16)
        }
    }
}
