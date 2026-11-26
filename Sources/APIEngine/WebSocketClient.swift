import Foundation
import Security

/// One line in a WebSocket conversation.
public struct WebSocketMessage: Identifiable, Equatable, Sendable {
    public enum Direction: String, Sendable {
        case sent, received
        /// A note from the client itself: connected, closed, an error.
        case system
    }

    public var id = UUID()
    public var date = Date()
    public var direction: Direction
    public var text: String
    /// True when the message was binary. `text` then describes it rather than holding it.
    public var isBinary = false

    public init(direction: Direction, text: String, isBinary: Bool = false) {
        self.direction = direction
        self.text = text
        self.isBinary = isBinary
    }
}

public enum WebSocketEvent: Sendable {
    case connected(subprotocol: String?)
    case message(WebSocketMessage)
    case closed(code: Int, reason: String?)
    case failed(String)
}

/// How a WebSocket connects: the same TLS and proxy choices HTTP requests get.
public struct WebSocketOptions: Sendable {
    public var verifyTLS = true
    public var clientCertificate: ClientCertificate?
    public var proxy: ProxySettings?

    public init(verifyTLS: Bool = true, clientCertificate: ClientCertificate? = nil, proxy: ProxySettings? = nil) {
        self.verifyTLS = verifyTLS
        self.clientCertificate = clientCertificate
        self.proxy = proxy
    }

    /// Takes the choices that apply to WebSockets from an HTTP request's options.
    public init(_ options: HTTPOptions) {
        self.init(verifyTLS: options.verifyTLS, clientCertificate: options.clientCertificate, proxy: options.proxy)
    }
}

public struct WebSocketError: Error, LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
}

/// A WebSocket connection. Events are delivered to the handler on a background thread.
public final class WebSocketClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let onEvent: @Sendable (WebSocketEvent) -> Void
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var finished = false
    private var options = WebSocketOptions()
    private var identity: SecIdentity?

    public init(onEvent: @escaping @Sendable (WebSocketEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// Whether a URL is one a WebSocket connects to.
    public static func isWebSocketURL(_ url: String) -> Bool {
        let lower = url.trimmingCharacters(in: .whitespaces).lowercased()
        return lower.hasPrefix("ws://") || lower.hasPrefix("wss://")
    }

    public func connect(url: URL, headers: [HTTPHeader] = [], options: WebSocketOptions = WebSocketOptions()) {
        self.options = options
        if let certificate = options.clientCertificate {
            do {
                identity = try Self.identity(from: certificate)
            } catch {
                finish(.failed(error.localizedDescription))
                return
            }
        }
        var request = URLRequest(url: url)
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        let configuration = URLSessionConfiguration.ephemeral
        if let proxy = options.proxy, let dictionary = Self.proxyDictionary(proxy) {
            configuration.connectionProxyDictionary = dictionary
        }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        receive()
    }

    public func send(_ text: String) async throws {
        guard let task else { return }
        try await task.send(.string(text))
    }

    /// Closes the connection normally.
    public func close() {
        task?.cancel(with: .normalClosure, reason: nil)
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.onEvent(.message(WebSocketMessage(direction: .received, text: text)))
                self.receive()
            case .success(.data(let data)):
                self.onEvent(.message(WebSocketMessage(direction: .received, text: "\(data.count) bytes of binary data", isBinary: true)))
                self.receive()
            case .success:
                self.receive()
            case .failure(let error):
                // A close is reported through the delegate; only report other failures here.
                self.finish(.failed(error.localizedDescription))
            }
        }
    }

    /// Reports the end of the connection once, whichever path notices it first.
    private func finish(_ event: WebSocketEvent) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }
        onEvent(event)
        session?.invalidateAndCancel()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onEvent(.connected(subprotocol: `protocol`))
    }

    public func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        finish(.closed(code: closeCode.rawValue, reason: reason.flatMap { String(data: $0, encoding: .utf8) }))
    }

    /// Answers the server's TLS questions: whether to trust it, and which certificate to present.
    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            if !options.verifyTLS, let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            if let identity {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// The proxy in the form URLSession takes. A WebSocket goes through an HTTP proxy's
    /// tunnel or a SOCKS proxy; a user name and password are not passed on.
    static func proxyDictionary(_ proxy: ProxySettings) -> [AnyHashable: Any]? {
        var text = proxy.url.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "http://" + text }
        guard let components = URLComponents(string: text), let host = components.host else { return nil }
        let scheme = components.scheme?.lowercased() ?? "http"
        if scheme.hasPrefix("socks") {
            return ["SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": components.port ?? 1080]
        }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        return ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port, "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
    }

    /// Reads a client certificate and its key into the form URLSession presents. A PEM pair
    /// is first packed into PKCS#12 with the Mac's own `openssl`, since that is the only
    /// form the system reads a private key from without putting it in a keychain.
    static func identity(from certificate: ClientCertificate) throws -> SecIdentity {
        guard #available(macOS 15.0, *) else {
            throw WebSocketError(message: "Presenting a client certificate on a WebSocket needs macOS 15 or later.")
        }
        let expand = { (path: String) in (path as NSString).expandingTildeInPath }
        var data: Data
        var passphrase = certificate.passphrase ?? ""
        if certificate.isPKCS12 {
            guard let contents = FileManager.default.contents(atPath: expand(certificate.certificatePath)) else {
                throw WebSocketError(message: "The client certificate file could not be read.")
            }
            data = contents
        } else {
            let exportPassword = UUID().uuidString
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            var arguments = ["pkcs12", "-export", "-in", expand(certificate.certificatePath), "-passout", "env:APC_EXPORT", "-passin", "env:APC_KEY"]
            if let key = certificate.keyPath, !key.isEmpty { arguments += ["-inkey", expand(key)] }
            process.arguments = arguments
            // Passwords go in the environment, not on the command line where other processes could read them.
            process.environment = ["APC_EXPORT": exportPassword, "APC_KEY": passphrase]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty else {
                throw WebSocketError(message: "The client certificate could not be used. Check the certificate and key files and the passphrase.")
            }
            passphrase = exportPassword
        }
        var items: CFArray?
        let importOptions: [CFString: Any] = [kSecImportExportPassphrase: passphrase, kSecImportToMemoryOnly: true]
        let status = SecPKCS12Import(data as CFData, importOptions as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let found = first[kSecImportItemIdentity as String] else {
            throw WebSocketError(message: status == errSecAuthFailed
                ? "The passphrase for the client certificate is not right."
                : "The client certificate could not be used. Check the certificate and key files and the passphrase.")
        }
        return found as! SecIdentity
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failed(error.localizedDescription))
        }
    }
}
