import APIEngine
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A request written out as a command or code, to read and copy.
struct CodeSnippetView: View {
    @Environment(AppModel.self) private var model
    let requestID: UUID
    @AppStorage("snippetLanguage") private var languageID = SnippetLanguage.curl.rawValue

    private var language: SnippetLanguage { SnippetLanguage(rawValue: languageID) ?? .curl }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Copy as Code")
                    .font(.title3.weight(.semibold))
                Spacer()
                Picker("Language", selection: $languageID) {
                    ForEach(SnippetLanguage.allCases) { language in
                        Text(language.label).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(14)
            Divider()
            if let code = model.snippet(requestID, language: language) {
                ReadOnlyCode(text: code, syntax: .log)
            } else {
                EmptyState(systemImage: "curlybraces", title: "Nothing to show", detail: "This request has no URL yet.")
            }
            Divider()
            HStack {
                Text(model.secretsHidden
                     ? "Secrets are hidden, so they are masked here too. Switch Hide Secrets off to copy working code."
                     : "Variables are filled in, so the code may contain secrets.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Done") { model.showingSnippet = nil }
                Button("Copy") {
                    model.copySnippet(requestID, language: language)
                    model.showingSnippet = nil
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.snippet(requestID, language: language) == nil)
            }
            .padding(12)
        }
        .frame(width: 720, height: 480)
    }
}

/// Which certificate to present to which server, for APIs that use mutual TLS.
struct ClientCertificatesView: View {
    @Environment(AppModel.self) private var model
    @State private var rules: [ClientCertificateRule] = []
    @State private var passphrases: [UUID: String] = [:]
    @State private var verifyTLS = true
    @State private var proxy = ProxySettings()
    @State private var proxyPassword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Proxy and Certificates")
                    .font(.title3.weight(.semibold))
                Text("How requests reach servers from this Mac. These settings stay on this Mac and are not part of the workspace. Passwords and passphrases are kept in the Keychain.")
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                // The app's checkbox style draws the box alone, so the words sit beside it.
                check("Send requests through a proxy", isOn: $proxy.enabled)
                if proxy.enabled {
                    field("Address", "http://proxy.example.com:8080, or socks5://127.0.0.1:1080", text: $proxy.url)
                    HStack(spacing: 8) {
                        field("User name", "Only if the proxy asks for one", text: $proxy.username)
                        SecureField("Password", text: $proxyPassword)
                            .textFieldStyle(ThemedTextFieldStyle())
                            .frame(width: 180)
                    }
                    field("Skip for", "Hosts to reach directly, such as localhost, .internal.example.com", text: $proxy.bypass)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                check("Check server certificates", isOn: $verifyTLS)
                Text(verifyTLS
                     ? "Requests fail when a server's certificate cannot be verified. Switch this off to reach a local server with a self-signed certificate."
                     : "Any certificate is accepted, so a connection could be to an impostor. Switch this back on when you are done with local servers.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(verifyTLS ? Theme.textSecondary : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            Text("Client certificates, for servers that ask for one")
                .sectionTitle()
                .padding(.horizontal, 14)
                .padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($rules) { $rule in
                        card($rule)
                    }
                    if rules.isEmpty {
                        Text("No client certificates yet.")
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                }
                .padding(12)
            }

            Divider()
            HStack {
                Button {
                    rules.append(ClientCertificateRule())
                } label: {
                    Label("Add Certificate", systemImage: "plus")
                }
                Spacer()
                Button("Cancel") { model.showingClientCertificates = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 660, height: 640)
        .onAppear {
            verifyTLS = model.verifyTLS
            proxy = model.proxy
            proxyPassword = model.proxyPassword
            rules = model.clientCertificates
            passphrases = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, model.clientCertificatePassphrase($0)) })
        }
    }

    private func check(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Toggle(label, isOn: isOn)
                .labelsHidden()
                .accessibilityLabel(label)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .onTapGesture { isOn.wrappedValue.toggle() }
                .accessibilityHidden(true)
        }
    }

    private func field(_ label: String, _ prompt: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 84, alignment: .leading)
            TextField(prompt, text: text)
                .textFieldStyle(ThemedTextFieldStyle())
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .accessibilityLabel(label)
        }
    }

    private func card(_ rule: Binding<ClientCertificateRule>) -> some View {
        let isBundle = ["p12", "pfx"].contains((rule.wrappedValue.certificatePath as NSString).pathExtension.lowercased())
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: rule.enabled)
                    .labelsHidden()
                    .help("Use this certificate")
                TextField("Host, such as api.example.com, *.example.com or localhost:8443", text: rule.host)
                    .textFieldStyle(ThemedTextFieldStyle())
                    .font(.system(size: 12.5, design: .monospaced))
                IconButton(systemImage: "trash", help: "Remove this certificate") {
                    rules.removeAll { $0.id == rule.wrappedValue.id }
                }
            }
            fileRow("Certificate", path: rule.certificatePath, prompt: "A PEM certificate, or a .p12 or .pfx file with the key inside")
            if !isBundle {
                fileRow("Private key", path: rule.keyPath, prompt: "The PEM key, if it is not in the certificate file")
            }
            HStack(spacing: 8) {
                Text("Passphrase")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 84, alignment: .leading)
                SecureField("Only if the key has one", text: Binding(
                    get: { passphrases[rule.wrappedValue.id] ?? "" },
                    set: { passphrases[rule.wrappedValue.id] = $0 }
                ))
                .textFieldStyle(ThemedTextFieldStyle())
            }
        }
        .font(.system(size: 12.5))
        .padding(12)
        .background(Theme.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
    }

    private func fileRow(_ label: String, path: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 84, alignment: .leading)
            TextField(prompt, text: path)
                .textFieldStyle(ThemedTextFieldStyle())
                .font(.system(size: 12, design: .monospaced))
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.message = "Choose the \(label.lowercased()) file."
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
        }
    }

    private func save() {
        // Rows left blank are dropped rather than saved.
        let kept = rules.filter { !$0.host.trimmingCharacters(in: .whitespaces).isEmpty || !$0.certificatePath.isEmpty }
        model.verifyTLS = verifyTLS
        model.proxy = proxy
        model.setProxyPassword(proxy.username.isEmpty ? "" : proxyPassword)
        model.saveClientCertificates(kept)
        for rule in kept {
            model.setClientCertificatePassphrase(passphrases[rule.id] ?? "", for: rule)
        }
        model.showingClientCertificates = false
    }
}

/// Sends one request many times and shows how long it took: percentiles, a histogram and the error rate.
struct RepeatView: View {
    @Environment(AppModel.self) private var model
    @State private var count = 50
    @State private var concurrency = 1

    var body: some View {
        if let session = model.repeatSession {
            let stats = session.stats
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Repeat")
                            .font(.title3.weight(.semibold))
                        MethodBadge(method: session.method)
                        Text(session.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                    }
                    Text("Sends the request over and over to measure the server. Nothing is added to the history and no variables are saved.")
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(14)
                Divider()

                HStack(spacing: 14) {
                    numberField("Times", value: $count, range: 1...10_000, help: "How many times to send the request, up to 10,000")
                    numberField("At once", value: $concurrency, range: 1...50, help: "How many to have in flight at the same time, up to 50")
                    Spacer()
                    if session.isRunning {
                        ProgressView(value: Double(session.samples.count), total: Double(max(session.count, 1)))
                            .frame(width: 160)
                            .tint(Theme.accent)
                        Text("\(session.samples.count) of \(session.count)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                        Button("Stop") { model.stopRepeat() }
                    } else {
                        Button(session.samples.isEmpty ? "Start" : "Run Again") {
                            model.startRepeat(count: count, concurrency: concurrency)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()

                if session.samples.isEmpty {
                    EmptyState(
                        systemImage: "repeat",
                        title: session.isRunning ? "Sending…" : "Ready",
                        detail: session.isRunning ? "Results appear as responses arrive." : "Choose how many times to send, then press Start."
                    )
                } else {
                    ScrollView {
                        results(session, stats)
                            .padding(14)
                    }
                }

                Divider()
                HStack {
                    Spacer()
                    Button("Done") { model.closeRepeat() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
            }
            .frame(width: 720, height: 600)
            .onAppear {
                count = session.count
                concurrency = session.concurrency
            }
        }
    }

    private func numberField(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, help: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Theme.textSecondary)
            TextField(label, value: value, format: .number.grouping(.never))
                .textFieldStyle(ThemedTextFieldStyle())
                .font(.system(size: 12.5, design: .monospaced))
                .frame(width: 70)
                .onChange(of: value.wrappedValue) { _, new in
                    value.wrappedValue = min(max(new, range.lowerBound), range.upperBound)
                }
        }
        .help(help)
    }

    @ViewBuilder
    private func results(_ session: RepeatSession, _ stats: LatencyStats) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                tile("Sent", "\(stats.count)")
                tile("Errors", "\(stats.errors)", detail: String(format: "%.1f%%", stats.errorRate * 100), color: stats.errors == 0 ? Theme.success : Theme.danger)
                tile("Per second", session.elapsed > 0 ? String(format: "%.1f", Double(stats.count) / session.elapsed) : "–",
                     detail: "over \(ResponseView.duration(session.elapsed))")
            }

            Text("Response time").sectionTitle()
            HStack(spacing: 10) {
                tile("Fastest", ResponseView.duration(stats.minimum))
                tile("Median", ResponseView.duration(stats.p50))
                tile("90%", ResponseView.duration(stats.p90))
                tile("95%", ResponseView.duration(stats.p95))
                tile("99%", ResponseView.duration(stats.p99))
                tile("Slowest", ResponseView.duration(stats.maximum))
            }
            .help("Half of the responses arrived within the median time, 90% within the next figure, and so on.")

            let times = session.samples.compactMap(\.seconds)
            if times.count > 1 {
                histogram(times)
            }

            if !stats.statuses.isEmpty {
                Text("Responses").sectionTitle()
                HStack(spacing: 8) {
                    ForEach(stats.statuses.keys.sorted(), id: \.self) { status in
                        Chip(text: "\(status) × \(stats.statuses[status] ?? 0)", color: ResponseView.statusColor(status))
                    }
                    let failedTests = session.samples.filter { $0.failedTests > 0 }.count
                    if failedTests > 0 {
                        Chip(text: "\(failedTests) with failed tests", color: Theme.danger, mono: false)
                    }
                }
            }

            let problems = Dictionary(grouping: session.samples.compactMap(\.error), by: { $0 }).mapValues(\.count)
            if !problems.isEmpty {
                Text("Did not complete").sectionTitle()
                ForEach(problems.keys.sorted(), id: \.self) { message in
                    Text("\(problems[message] ?? 0) × \(message)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func tile(_ label: String, _ value: String, detail: String? = nil, color: Color = Theme.text) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
    }

    /// How many responses fell in each band of time, fastest on the left.
    private func histogram(_ times: [Double]) -> some View {
        let bands = LatencyStats.histogram(times, bands: 24)
        let tallest = max(bands.map(\.count).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(band.count == 0 ? Theme.raised : Theme.accent)
                        .frame(height: band.count == 0 ? 2 : max(4, 90 * CGFloat(band.count) / CGFloat(tallest)))
                        .frame(maxWidth: .infinity)
                        .help("\(band.count) between \(ResponseView.duration(band.from)) and \(ResponseView.duration(band.to))")
                }
            }
            .frame(height: 92, alignment: .bottom)
            HStack {
                Text(ResponseView.duration(bands.first?.from ?? 0))
                Spacer()
                Text("How many responses took how long")
                Spacer()
                Text(ResponseView.duration(bands.last?.to ?? 0))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Histogram of response times")
    }
}

/// A short confirmation that fades by itself.
struct ToastView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            .padding(.bottom, 22)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
    }
}
