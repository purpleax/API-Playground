import APIEngine
import AppKit
import SwiftUI

/// One request sent many times over, to see how its speed varies.
struct RepeatSession: Identifiable {
    let id = UUID()
    var requestID: UUID
    var name: String
    var method: String
    /// How many times to send, and how many to have in flight at once.
    var count = 50
    var concurrency = 1
    var samples: [RepeatSample] = []
    var isRunning = false
    /// How long the whole run took, start to finish.
    var elapsed: TimeInterval = 0

    var stats: LatencyStats { LatencyStats(samples) }
}

/// An environment that has been imported and is waiting to be told which collection it joins.
struct PendingEnvironment: Identifiable {
    let id = UUID()
    var environment: APIEnvironment
    var warnings: [String]
}

/// Where an imported environment's variables go.
enum EnvironmentDestination: Hashable {
    case collection(UUID)
    case newCollection
    case skip
}

extension AppModel {
    // MARK: Copying a request as code

    /// The request as it would be sent now, with a stored OAuth 2 token and cookies applied,
    /// which is what a command copied out of the app should carry.
    func exportable(_ requestID: UUID) -> PreparedRequest? {
        guard let index = collectionIndex(containingRequest: requestID), let request = collections[index].request(id: requestID) else { return nil }
        var auth = collections[index].effectiveAuth(forRequest: requestID)
        if case .oauth2(let config) = auth, let token = executor.tokens?.token(for: config.id) {
            let prefix = config.headerPrefix.trimmingCharacters(in: .whitespaces)
            auth = prefix.isEmpty || prefix == "Bearer"
                ? .bearer(token: token.accessToken)
                : .apiKey(key: "Authorization", value: "\(prefix) \(token.accessToken)", placement: .header)
        }
        guard var prepared = try? RequestBuilder.prepare(request, auth: auth, resolver: resolver(forCollection: index)) else { return nil }
        if prepared.header("Cookie") == nil, let url = URL(string: prepared.url), let cookies = cookieJar.header(for: url) {
            prepared.headers.append(HTTPHeader(name: "Cookie", value: cookies))
        }
        return prepared
    }

    /// Whether a request can be written out as an HTTP command. WebSocket and gRPC requests cannot.
    func canExport(_ requestID: UUID) -> Bool {
        guard let request = request(requestID) else { return false }
        return !request.isGRPC && !isWebSocket(requestID)
    }

    /// The request as code. While secrets are hidden, they are masked in the code too.
    func snippet(_ requestID: UUID, language: SnippetLanguage) -> String? {
        guard canExport(requestID), let prepared = exportable(requestID) else { return nil }
        let code = CodeSnippet.generate(prepared, language: language)
        return redactor(for: requestID)?.redact(code) ?? code
    }

    func copySnippet(_ requestID: UUID, language: SnippetLanguage) {
        guard let code = snippet(requestID, language: language) else {
            notice = Notice(title: "Nothing to copy", message: "This request cannot be written as \(language.label). Check that it has a URL.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        showToast(secretsHidden ? "Copied as \(language.label), with secrets masked" : "Copied as \(language.label)")
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.snappy(duration: 0.2)) { toast = text }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
    }

    // MARK: Client certificates

    private static var clientCertificateFile: URL {
        supportDirectory.appendingPathComponent("Client Certificates.json")
    }

    static func loadClientCertificates() -> [ClientCertificateRule] {
        guard let data = try? Data(contentsOf: clientCertificateFile) else { return [] }
        return (try? JSONDecoder().decode([ClientCertificateRule].self, from: data)) ?? []
    }

    func saveClientCertificates(_ rules: [ClientCertificateRule]) {
        // A removed rule's passphrase goes with it.
        for old in clientCertificates where !rules.contains(where: { $0.id == old.id }) {
            Self.secrets.delete(old.passphraseKey)
        }
        clientCertificates = rules
        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rules).write(to: Self.clientCertificateFile, options: .atomic)
        } catch {
            show("Could not save the client certificates", error)
        }
    }

    func clientCertificatePassphrase(_ rule: ClientCertificateRule) -> String {
        Self.secrets.get(rule.passphraseKey) ?? ""
    }

    func setClientCertificatePassphrase(_ passphrase: String, for rule: ClientCertificateRule) {
        if passphrase.isEmpty {
            Self.secrets.delete(rule.passphraseKey)
        } else {
            Self.secrets.set(passphrase, for: rule.passphraseKey)
        }
    }

    // MARK: Proxy

    static func loadProxy() -> ProxySettings {
        guard let data = UserDefaults.standard.data(forKey: "proxy") else { return ProxySettings() }
        return (try? JSONDecoder().decode(ProxySettings.self, from: data)) ?? ProxySettings()
    }

    var proxyPassword: String {
        Self.secrets.get(ProxySettings.passwordKey) ?? ""
    }

    func setProxyPassword(_ password: String) {
        if password.isEmpty {
            Self.secrets.delete(ProxySettings.passwordKey)
        } else {
            Self.secrets.set(password, for: ProxySettings.passwordKey)
        }
    }

    // MARK: Settings that came with an import

    /// Takes on the cookies, client certificates and proxy found in another app's export,
    /// and returns lines for the import report.
    func apply(_ settings: ImportedSettings) -> [String] {
        var lines: [String] = []
        func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }

        if !settings.cookies.isEmpty {
            var jar = cookieJar
            for cookie in settings.cookies {
                jar.cookies.removeAll { $0.id == cookie.id }
                jar.cookies.append(cookie)
            }
            jar.removeExpired()
            setCookies(jar)
            lines.append("Imported \(count(settings.cookies.count, "cookie")) from “\(settings.source)”.")
        }

        var rules = clientCertificates
        var added: [ImportedSettings.Certificate] = []
        for certificate in settings.certificates {
            let rule = certificate.rule
            if rules.contains(where: { $0.host == rule.host && $0.certificatePath == rule.certificatePath }) { continue }
            rules.append(rule)
            added.append(certificate)
        }
        if !added.isEmpty {
            saveClientCertificates(rules)
            for certificate in added {
                if let passphrase = certificate.passphrase { setClientCertificatePassphrase(passphrase, for: certificate.rule) }
            }
            lines.append("Imported \(count(added.count, "client certificate")) from “\(settings.source)”: \(added.map(\.rule.host).joined(separator: ", ")).")
            let missing = added.filter { !FileManager.default.fileExists(atPath: ($0.rule.certificatePath as NSString).expandingTildeInPath) }
            if !missing.isEmpty {
                lines.append("The certificate \(missing.count == 1 ? "file" : "files") for \(missing.map(\.rule.host).joined(separator: ", ")) could not be found. Choose \(missing.count == 1 ? "it" : "them") again in Request > Proxy and Certificates.")
            }
        }

        if let found = settings.proxy {
            if proxy.url.trimmingCharacters(in: .whitespaces).isEmpty {
                var saved = found
                saved.password = nil
                proxy = saved
                if let password = found.password, !password.isEmpty { setProxyPassword(password) }
                lines.append("Set the proxy to \(found.url), from “\(settings.source)”. It now applies to every request. Change it in Request > Proxy and Certificates.")
            } else if proxy.url != found.url {
                lines.append("“\(settings.source)” uses the proxy \(found.url). It was not applied, because a proxy is already set here.")
            }
        }
        return lines
    }

    // MARK: Repeat runner

    func openRepeat(_ requestID: UUID) {
        guard let request = request(requestID), canExport(requestID) else { return }
        repeatTask?.cancel()
        repeatSession = RepeatSession(requestID: requestID, name: request.name, method: request.method)
    }

    func closeRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
        repeatSession = nil
    }

    func stopRepeat() {
        repeatTask?.cancel()
    }

    /// Sends the request `count` times, `concurrency` at once. Each send starts from the
    /// same variables and nothing is saved from it, so the run measures the server and
    /// leaves the workspace and the history as they were.
    func startRepeat(count: Int, concurrency: Int) {
        guard var session = repeatSession, !session.isRunning,
              let index = collectionIndex(containingRequest: session.requestID),
              let request = collections[index].request(id: session.requestID) else { return }
        let total = min(max(count, 1), 10_000)
        let width = min(max(concurrency, 1), 50)
        session.count = total
        session.concurrency = width
        session.samples = []
        session.elapsed = 0
        session.isRunning = true
        repeatSession = session

        let sessionID = session.id
        let collection = collections[index]
        var seed = RunState(
            globals: globals, collectionVariables: collection.variables, environment: activeEnvironment?.variables ?? []
        )
        seed.cookies = cookieJar
        let initial = seed
        let executor = executor
        let started = Date()

        repeatTask = Task {
            await RepeatRunner.run(count: total, concurrency: width) {
                var state = initial
                return RepeatSample(await executor.run(request, in: collection, state: &state))
            } each: { sample in
                guard repeatSession?.id == sessionID else { return false }
                repeatSession?.samples.append(sample)
                repeatSession?.elapsed = Date().timeIntervalSince(started)
                return true
            }
            if repeatSession?.id == sessionID {
                repeatSession?.isRunning = false
                repeatSession?.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    // MARK: For Shortcuts and the menu bar

    /// Sends a request and waits for the result, as the Send button would.
    func sendAndWait(_ id: UUID) async -> RequestRunResult? {
        guard let index = collectionIndex(containingRequest: id), let request = collections[index].request(id: id) else { return nil }
        let collection = collections[index]
        var initial = RunState(
            globals: globals, collectionVariables: collection.variables, environment: activeEnvironment?.variables ?? []
        )
        initial.cookies = cookieJar
        var state = initial
        responses[id] = .sending
        let result = await executor.run(request, in: collection, state: &state)
        saveRun(state, since: initial, collectionID: collection.id)
        record(result)
        return result
    }

    /// Runs every request in a collection in order and waits for the results.
    func runAndWait(collectionID: UUID) async -> [RequestRunResult] {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return [] }
        let collection = collections[index]
        var initial = RunState(
            globals: globals, collectionVariables: collection.variables, environment: activeEnvironment?.variables ?? []
        )
        initial.cookies = cookieJar
        var state = initial
        var results: [RequestRunResult] = []
        for request in collection.allRequests {
            let result = await executor.run(request, in: collection, state: &state)
            record(result)
            results.append(result)
        }
        saveRun(state, since: initial, collectionID: collectionID)
        return results
    }
}
