import CCurlShim
import Foundation

public struct HTTPOptions: Sendable {
    public enum Version: Sendable {
        /// Whatever the server and libcurl agree on.
        case automatic
        /// HTTP/2, negotiated over TLS, or by upgrade without it.
        case http2
        /// HTTP/2 from the first byte with no negotiation, as gRPC servers without TLS expect.
        case http2PriorKnowledge
    }

    public var followRedirects = true
    public var timeout: TimeInterval = 30
    public var verifyTLS = true
    public var version = Version.automatic
    /// The certificate to present when a server asks for one (mutual TLS).
    public var clientCertificate: ClientCertificate?
    /// The proxy to send through, already decided to apply to this request.
    public var proxy: ProxySettings?

    public init(followRedirects: Bool = true, timeout: TimeInterval = 30, verifyTLS: Bool = true) {
        self.followRedirects = followRedirects
        self.timeout = timeout
        self.verifyTLS = verifyTLS
    }
}

/// A certificate and private key that identify the caller to a server.
public struct ClientCertificate: Equatable, Sendable {
    /// A PEM certificate, or a PKCS#12 file (.p12 or .pfx) holding the certificate and key together.
    public var certificatePath: String
    /// The PEM private key, when it is not in the certificate file.
    public var keyPath: String?
    public var passphrase: String?

    public init(certificatePath: String, keyPath: String? = nil, passphrase: String? = nil) {
        self.certificatePath = certificatePath
        self.keyPath = keyPath
        self.passphrase = passphrase
    }

    var isPKCS12: Bool {
        ["p12", "pfx"].contains((certificatePath as NSString).pathExtension.lowercased())
    }
}

/// One certificate from the chain a server presented.
public struct TLSCertificate: Equatable, Sendable, Identifiable {
    public var id: Int
    public var subject: String
    public var issuer: String
    public var serialNumber: String?
    public var notBefore: Date?
    public var notAfter: Date?
    public var signatureAlgorithm: String?
    public var publicKey: String?
    /// The names the certificate is valid for, from its Subject Alternative Name.
    public var alternativeNames: [String]
    public var pem: String?

    /// The CN part of the subject, or the whole subject when it has none.
    public var commonName: String { Self.commonName(subject) }
    public var issuerName: String { Self.commonName(issuer) }
    public var isSelfSigned: Bool { subject == issuer }

    static func commonName(_ name: String) -> String {
        for part in name.split(whereSeparator: { $0 == "," || $0 == "/" }) {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("CN") , let equals = trimmed.firstIndex(of: "=") {
                return trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return name
    }

    /// Builds a certificate from libcurl's "Name:value" lines.
    init(id: Int, fields: [(name: String, value: String)]) {
        func field(_ name: String) -> String? {
            fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        func date(_ text: String?) -> Date? {
            guard let text else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            for format in ["yyyy-MM-dd HH:mm:ss 'GMT'", "MMM d HH:mm:ss yyyy 'GMT'", "MMM  d HH:mm:ss yyyy 'GMT'"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: text) { return date }
            }
            return nil
        }
        self.id = id
        subject = field("Subject") ?? ""
        issuer = field("Issuer") ?? ""
        serialNumber = field("Serial Number")
        notBefore = date(field("Start date"))
        notAfter = date(field("Expire date"))
        signatureAlgorithm = field("Signature Algorithm")
        publicKey = [field("Public Key Algorithm"), field("RSA Public Key").map { "\($0) bits" }].compactMap { $0 }.joined(separator: ", ")
        if publicKey?.isEmpty == true { publicKey = nil }
        alternativeNames = (field("X509v3 Subject Alternative Name") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("DNS:") ? String($0.dropFirst(4)) : $0.replacingOccurrences(of: "IP Address:", with: "") }
            .filter { !$0.isEmpty }
        pem = field("Cert")
    }
}

/// What is known about a response's TLS connection.
public struct TLSInfo: Equatable, Sendable {
    /// Such as "TLSv1.3".
    public var protocolVersion: String?
    public var cipher: String?
    /// The server's certificate first, then the certificates that vouch for it.
    public var certificates: [TLSCertificate] = []
    /// False when the request was sent with certificate checking switched off.
    public var verified = true
    /// The client certificate file that was offered, if any.
    public var clientCertificate: String?
}

/// How long each phase of a request took, in seconds.
public struct HTTPTimings: Codable, Equatable, Sendable {
    public var dns: Double = 0
    public var connect: Double = 0
    public var tls: Double = 0
    /// Sending the request, after the connection is ready.
    public var send: Double = 0
    /// Waiting for the first byte of the response.
    public var wait: Double = 0
    public var download: Double = 0
    public var total: Double = 0
    /// Time spent following redirects before the final request. Zero when there were none.
    public var redirect: Double = 0

    public init() {}

    public var phases: [(name: String, seconds: Double)] {
        [("DNS", dns), ("Connect", connect), ("TLS", tls), ("Send", send), ("Wait", wait), ("Download", download)]
    }
}

public struct WireLogEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case info, requestHeader, responseHeader, requestData, responseData
    }

    public var kind: Kind
    public var text: String
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var statusText: String
    public var httpVersion: String
    public var headers: [HTTPHeader]
    public var body: Data
    public var timings: HTTPTimings
    public var remoteAddress: String?
    /// What was sent and received, as reported by libcurl.
    public var wireLog: [WireLogEntry]
    /// True when the transfer was stopped before the server finished, as with an open event stream.
    public var wasCancelled = false
    /// The TLS connection and the server's certificates. Nil for plain HTTP.
    public var tls: TLSInfo?

    public init(
        status: Int, statusText: String, httpVersion: String, headers: [HTTPHeader], body: Data,
        timings: HTTPTimings, remoteAddress: String?, wireLog: [WireLogEntry], wasCancelled: Bool = false
    ) {
        self.status = status
        self.statusText = statusText
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.timings = timings
        self.remoteAddress = remoteAddress
        self.wireLog = wireLog
        self.wasCancelled = wasCancelled
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The body as text, or nil if it is not valid UTF-8.
    public var text: String? {
        String(data: body, encoding: .utf8)
    }
}

public struct HTTPClientError: Error, LocalizedError, Equatable {
    public var code: Int
    public var message: String

    public var errorDescription: String? { message }
}

/// A switch for stopping a transfer that is in progress.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Callbacks for watching a response as it arrives. They may be called on any thread.
public struct HTTPStreamHandlers: Sendable {
    /// Called once, when the final response's status and headers are known.
    public var onHeaders: (@Sendable (Int, [HTTPHeader]) -> Void)?
    /// Called for each piece of the body.
    public var onData: (@Sendable (Data) -> Void)?

    public init(onHeaders: (@Sendable (Int, [HTTPHeader]) -> Void)? = nil, onData: (@Sendable (Data) -> Void)? = nil) {
        self.onHeaders = onHeaders
        self.onData = onData
    }
}

/// Sends requests with libcurl, which exposes the timings and wire log a debugging tool needs.
public struct HTTPClient: Sendable {
    private static let globalInit: Void = apc_global_init()

    public init() {
        _ = Self.globalInit
    }

    /// - Parameters:
    ///   - handlers: Optional callbacks for watching the response arrive, as an event stream needs.
    ///   - cancellation: Set this to stop the transfer. Cancelling the calling task also stops it.
    public func send(
        _ request: PreparedRequest,
        options: HTTPOptions = HTTPOptions(),
        handlers: HTTPStreamHandlers = HTTPStreamHandlers(),
        cancellation: CancellationFlag? = nil
    ) async throws -> HTTPResponse {
        let flag = cancellation ?? CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try Self.perform(request, options: options, handlers: handlers, flag: flag)
                    })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// Collects output from libcurl's callbacks during one transfer.
    private final class TransferState {
        var body = Data()
        var headerLines: [String] = []
        var log: [WireLogEntry] = []
        var handlers = HTTPStreamHandlers()
        var flag = CancellationFlag()
        var followRedirects = true
        var timeout: TimeInterval = 30
        let started = Date()
        /// Set once the final response's headers have all arrived.
        var status: Int?
        var isEventStream = false
        var timedOut = false

        /// Called at the blank line that ends a block of headers.
        func headersEnded() {
            let (status, _, headers) = HTTPClient.parse(headerLines)
            // A redirect that will be followed is not the final response.
            let isRedirect = (300..<400).contains(status) && headers.contains { $0.name.lowercased() == "location" }
            // 1xx responses are interim too.
            if (followRedirects && isRedirect) || (100..<200).contains(status) { return }
            self.status = status
            isEventStream = headers.contains { $0.name.lowercased() == "content-type" && $0.value.lowercased().contains("text/event-stream") }
            handlers.onHeaders?(status, headers)
        }
    }

    /// Splits raw header lines into the status, the reason phrase and the headers.
    fileprivate static func parse(_ lines: [String]) -> (status: Int, statusText: String, headers: [HTTPHeader]) {
        var status = 0
        var statusText = ""
        var headers: [HTTPHeader] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("HTTP/") {
                let pieces = trimmed.split(separator: " ", maxSplits: 2)
                status = pieces.count > 1 ? Int(pieces[1]) ?? 0 : 0
                statusText = pieces.count > 2 ? String(pieces[2]) : ""
            } else if let colon = trimmed.firstIndex(of: ":") {
                headers.append(HTTPHeader(
                    name: String(trimmed[..<colon]),
                    value: trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                ))
            }
        }
        return (status, statusText, headers)
    }

    private static func perform(
        _ request: PreparedRequest, options: HTTPOptions, handlers: HTTPStreamHandlers, flag: CancellationFlag
    ) throws -> HTTPResponse {
        do {
            return try performOnce(request, options: options, handlers: handlers, flag: flag, capAtTLS12: false)
        } catch let error as HTTPClientError where error.code == Int(CURLE_SSL_CONNECT_ERROR.rawValue) && options.clientCertificate != nil {
            // The Mac's TLS library cannot complete a TLS 1.3 handshake with a client
            // certificate against some servers (OpenSSL 3 and later answer "decode error").
            // The same handshake works over TLS 1.2, so try that once before giving up.
            guard !flag.isCancelled,
                  var response = try? performOnce(request, options: options, handlers: handlers, flag: flag, capAtTLS12: true)
            else { throw error }
            response.wireLog.insert(WireLogEntry(
                kind: .info,
                text: "The first handshake failed while presenting the client certificate (\(error.message)). Sent again over TLS 1.2."
            ), at: 0)
            return response
        }
    }

    private static func performOnce(
        _ request: PreparedRequest, options: HTTPOptions, handlers: HTTPStreamHandlers, flag: CancellationFlag, capAtTLS12: Bool
    ) throws -> HTTPResponse {
        guard let handle = curl_easy_init() else {
            throw HTTPClientError(code: -1, message: "Could not start libcurl.")
        }
        defer { curl_easy_cleanup(handle) }

        let state = TransferState()
        state.handlers = handlers
        state.flag = flag
        state.followRedirects = options.followRedirects
        state.timeout = options.timeout
        let statePointer = Unmanaged.passUnretained(state).toOpaque()

        _ = apc_setopt_str(handle, CURLOPT_URL, request.url)
        _ = apc_setopt_str(handle, CURLOPT_CUSTOMREQUEST, request.method)
        _ = apc_setopt_str(handle, CURLOPT_ACCEPT_ENCODING, "")
        _ = apc_setopt_long(handle, CURLOPT_FOLLOWLOCATION, options.followRedirects ? 1 : 0)
        _ = apc_setopt_long(handle, CURLOPT_MAXREDIRS, 10)
        _ = apc_setopt_long(handle, CURLOPT_CONNECTTIMEOUT_MS, Int(options.timeout * 1000))
        // The overall timeout is enforced in the progress callback, so that an event stream,
        // which is meant to stay open, is not cut off.
        _ = apc_setopt_long(handle, CURLOPT_NOPROGRESS, 0)
        _ = apc_setopt_ptr(handle, CURLOPT_XFERINFODATA, statePointer)
        _ = apc_setopt_progress_cb(handle) { userdata, _, _, _, _ in
            guard let userdata else { return 0 }
            let state = Unmanaged<TransferState>.fromOpaque(userdata).takeUnretainedValue()
            if state.flag.isCancelled { return 1 }
            if !state.isEventStream, Date().timeIntervalSince(state.started) > state.timeout {
                state.timedOut = true
                return 1
            }
            return 0
        }
        _ = apc_setopt_long(handle, CURLOPT_NOSIGNAL, 1)
        switch options.version {
        case .automatic: break
        // CURL_HTTP_VERSION_2_0 and CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE.
        case .http2: _ = apc_setopt_long(handle, CURLOPT_HTTP_VERSION, 3)
        case .http2PriorKnowledge: _ = apc_setopt_long(handle, CURLOPT_HTTP_VERSION, 5)
        }
        if !options.verifyTLS {
            _ = apc_setopt_long(handle, CURLOPT_SSL_VERIFYPEER, 0)
            _ = apc_setopt_long(handle, CURLOPT_SSL_VERIFYHOST, 0)
        }
        // Ask for the server's certificate chain, for the TLS inspector.
        _ = apc_setopt_long(handle, CURLOPT_CERTINFO, 1)
        if let certificate = options.clientCertificate {
            let expand = { (path: String) in (path as NSString).expandingTildeInPath }
            _ = apc_setopt_str(handle, CURLOPT_SSLCERT, expand(certificate.certificatePath))
            if certificate.isPKCS12 { _ = apc_setopt_str(handle, CURLOPT_SSLCERTTYPE, "P12") }
            if let key = certificate.keyPath, !key.isEmpty { _ = apc_setopt_str(handle, CURLOPT_SSLKEY, expand(key)) }
            if let passphrase = certificate.passphrase, !passphrase.isEmpty { _ = apc_setopt_str(handle, CURLOPT_KEYPASSWD, passphrase) }
        }
        if let proxy = options.proxy {
            _ = apc_setopt_str(handle, CURLOPT_PROXY, proxy.url.trimmingCharacters(in: .whitespaces))
            if !proxy.username.isEmpty {
                _ = apc_setopt_str(handle, CURLOPT_PROXYUSERNAME, proxy.username)
                _ = apc_setopt_str(handle, CURLOPT_PROXYPASSWORD, proxy.password ?? "")
            }
        } else {
            // Never pick a proxy up from the environment: the app's own setting is the only one.
            _ = apc_setopt_str(handle, CURLOPT_PROXY, "")
        }
        if capAtTLS12 {
            // CURL_SSLVERSION_MAX_TLSv1_2
            _ = apc_setopt_long(handle, CURLOPT_SSLVERSION, 6 << 16)
        }
        if request.method == "HEAD" {
            _ = apc_setopt_long(handle, CURLOPT_NOBODY, 1)
        }

        // Headers
        var headerList: UnsafeMutablePointer<curl_slist>?
        defer { curl_slist_free_all(headerList) }
        for header in request.headers {
            // libcurl's syntax for a header with an empty value is "Name;".
            let line = header.value.isEmpty ? "\(header.name);" : "\(header.name): \(header.value)"
            headerList = curl_slist_append(headerList, line)
        }
        if request.body != nil {
            // Stop libcurl adding headers of its own that the request did not ask for.
            headerList = curl_slist_append(headerList, "Expect:")
            if request.header("Content-Type") == nil {
                headerList = curl_slist_append(headerList, "Content-Type:")
            }
        }
        _ = apc_setopt_slist(handle, CURLOPT_HTTPHEADER, headerList)

        // Body
        if let body = request.body {
            _ = apc_setopt_off(handle, CURLOPT_POSTFIELDSIZE_LARGE, Int64(body.count))
            if body.isEmpty {
                _ = apc_setopt_str(handle, CURLOPT_COPYPOSTFIELDS, "")
            } else {
                body.withUnsafeBytes { bytes in
                    _ = apc_setopt_data(handle, CURLOPT_COPYPOSTFIELDS, bytes.baseAddress)
                }
            }
        }

        // Callbacks
        _ = apc_setopt_ptr(handle, CURLOPT_WRITEDATA, statePointer)
        _ = apc_setopt_write_cb(handle, CURLOPT_WRITEFUNCTION) { pointer, size, count, userdata in
            guard let pointer, let userdata else { return 0 }
            let state = Unmanaged<TransferState>.fromOpaque(userdata).takeUnretainedValue()
            let length = size * count
            let chunk = pointer.withMemoryRebound(to: UInt8.self, capacity: length) { Data(bytes: $0, count: length) }
            state.body.append(chunk)
            if state.status != nil { state.handlers.onData?(chunk) }
            return length
        }
        _ = apc_setopt_ptr(handle, CURLOPT_HEADERDATA, statePointer)
        _ = apc_setopt_write_cb(handle, CURLOPT_HEADERFUNCTION) { pointer, size, count, userdata in
            guard let pointer, let userdata else { return 0 }
            let state = Unmanaged<TransferState>.fromOpaque(userdata).takeUnretainedValue()
            let length = size * count
            let line = pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
                String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
            }
            // Each redirect starts a new block of headers; keep only the last one.
            if line.hasPrefix("HTTP/") { state.headerLines.removeAll() }
            state.headerLines.append(line)
            if line == "\r\n" || line == "\n" { state.headersEnded() }
            return length
        }
        _ = apc_setopt_long(handle, CURLOPT_VERBOSE, 1)
        _ = apc_setopt_ptr(handle, CURLOPT_DEBUGDATA, statePointer)
        _ = apc_setopt_debug_cb(handle) { _, type, data, size, userdata in
            guard let data, let userdata else { return 0 }
            let state = Unmanaged<TransferState>.fromOpaque(userdata).takeUnretainedValue()
            func text() -> String {
                data.withMemoryRebound(to: UInt8.self, capacity: size) {
                    String(decoding: UnsafeBufferPointer(start: $0, count: size), as: UTF8.self)
                }.trimmingCharacters(in: .newlines)
            }
            switch type {
            case CURLINFO_TEXT:
                state.log.append(WireLogEntry(kind: .info, text: text()))
            case CURLINFO_HEADER_OUT:
                state.log.append(WireLogEntry(kind: .requestHeader, text: text()))
            case CURLINFO_HEADER_IN:
                state.log.append(WireLogEntry(kind: .responseHeader, text: text()))
            case CURLINFO_DATA_OUT:
                state.log.append(WireLogEntry(kind: .requestData, text: "\(size) bytes sent"))
            case CURLINFO_DATA_IN:
                state.log.append(WireLogEntry(kind: .responseData, text: "\(size) bytes received"))
            default:
                break
            }
            return 0
        }

        let code = curl_easy_perform(handle)
        var wasCancelled = false
        if code == CURLE_ABORTED_BY_CALLBACK {
            if state.timedOut {
                throw HTTPClientError(code: Int(code.rawValue), message: "The request timed out after \(Int(options.timeout)) seconds.")
            }
            // Stopping a response that had already started keeps what arrived, as with an event stream.
            guard state.status != nil else {
                throw HTTPClientError(code: Int(code.rawValue), message: "The request was cancelled.")
            }
            wasCancelled = true
        } else if code != CURLE_OK {
            var message = String(cString: curl_easy_strerror(code))
            // libcurl's own words for these are vague about which side the trouble is on.
            if options.clientCertificate != nil, code == CURLE_SSL_CERTPROBLEM {
                message = "The client certificate could not be used. Check the certificate and key files and the passphrase."
            }
            if code == CURLE_PEER_FAILED_VERIFICATION {
                message = "The server's certificate could not be verified. It may be self-signed, expired, or for a different host."
            }
            throw HTTPClientError(code: Int(code.rawValue), message: message)
        }

        // Status and headers
        var versionCode = 0
        _ = apc_getinfo_long(handle, CURLINFO_HTTP_VERSION, &versionCode)
        var addressPointer: UnsafePointer<CChar>?
        _ = apc_getinfo_str(handle, CURLINFO_PRIMARY_IP, &addressPointer)
        let (status, statusText, headers) = parse(state.headerLines)

        // Timings. libcurl reports each as time elapsed since the start, so subtract neighbours.
        func seconds(_ info: CURLINFO) -> Double {
            var value = 0.0
            _ = apc_getinfo_double(handle, info, &value)
            return value
        }
        let nameLookup = seconds(CURLINFO_NAMELOOKUP_TIME)
        let connect = seconds(CURLINFO_CONNECT_TIME)
        let appConnect = seconds(CURLINFO_APPCONNECT_TIME)
        let preTransfer = seconds(CURLINFO_PRETRANSFER_TIME)
        let startTransfer = seconds(CURLINFO_STARTTRANSFER_TIME)
        let total = seconds(CURLINFO_TOTAL_TIME)
        let connected = max(connect, appConnect)

        var timings = HTTPTimings()
        timings.dns = nameLookup
        timings.connect = max(0, connect - nameLookup)
        timings.tls = appConnect > 0 ? max(0, appConnect - connect) : 0
        timings.send = max(0, preTransfer - connected)
        timings.wait = max(0, startTransfer - preTransfer)
        timings.download = max(0, total - startTransfer)
        timings.total = total
        timings.redirect = seconds(CURLINFO_REDIRECT_TIME)

        let version: String
        switch versionCode {
        case 1: version = "HTTP/1.0"
        case 2: version = "HTTP/1.1"
        case 3: version = "HTTP/2"
        case 30: version = "HTTP/3"
        default: version = "HTTP"
        }

        var response = HTTPResponse(
            status: status,
            statusText: statusText,
            httpVersion: version,
            headers: headers,
            body: state.body,
            timings: timings,
            remoteAddress: addressPointer.map { String(cString: $0) },
            wireLog: state.log,
            wasCancelled: wasCancelled
        )
        response.tls = tlsInfo(handle, log: state.log, options: options)
        return response
    }

    /// Reads the certificate chain from libcurl, and the protocol and cipher from its log.
    private static func tlsInfo(_ handle: UnsafeMutableRawPointer, log: [WireLogEntry], options: HTTPOptions) -> TLSInfo? {
        var info = TLSInfo()
        var pointer: UnsafeMutablePointer<curl_certinfo>?
        if apc_getinfo_certinfo(handle, &pointer) == CURLE_OK, let chain = pointer?.pointee, let lists = chain.certinfo {
            for index in 0..<Int(chain.num_of_certs) {
                var fields: [(name: String, value: String)] = []
                var node = lists[index]
                while let current = node {
                    let line = String(cString: current.pointee.data)
                    if let colon = line.firstIndex(of: ":") {
                        fields.append((String(line[..<colon]), String(line[line.index(after: colon)...])))
                    }
                    node = current.pointee.next
                }
                info.certificates.append(TLSCertificate(id: index, fields: fields))
            }
        }
        // "SSL connection using TLSv1.3 / AEAD-CHACHA20-POLY1305-SHA256 / …"
        for entry in log where entry.kind == .info {
            guard let range = entry.text.range(of: "SSL connection using ") else { continue }
            let parts = entry.text[range.upperBound...].split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            info.protocolVersion = parts.first
            info.cipher = parts.count > 1 ? parts[1] : nil
        }
        guard !info.certificates.isEmpty || info.protocolVersion != nil else { return nil }
        info.verified = options.verifyTLS
        info.clientCertificate = options.clientCertificate?.certificatePath
        return info
    }
}
