import CCurlShim
import Foundation

public struct HTTPOptions: Sendable {
    public var followRedirects = true
    public var timeout: TimeInterval = 30
    public var verifyTLS = true

    public init(followRedirects: Bool = true, timeout: TimeInterval = 30, verifyTLS: Bool = true) {
        self.followRedirects = followRedirects
        self.timeout = timeout
        self.verifyTLS = verifyTLS
    }
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
        if !options.verifyTLS {
            _ = apc_setopt_long(handle, CURLOPT_SSL_VERIFYPEER, 0)
            _ = apc_setopt_long(handle, CURLOPT_SSL_VERIFYHOST, 0)
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
            let message = String(cString: curl_easy_strerror(code))
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

        return HTTPResponse(
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
    }
}
