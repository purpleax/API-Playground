import Foundation

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

/// A WebSocket connection. Events are delivered to the handler on a background thread.
public final class WebSocketClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let onEvent: @Sendable (WebSocketEvent) -> Void
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var finished = false

    public init(onEvent: @escaping @Sendable (WebSocketEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// Whether a URL is one a WebSocket connects to.
    public static func isWebSocketURL(_ url: String) -> Bool {
        let lower = url.trimmingCharacters(in: .whitespaces).lowercased()
        return lower.hasPrefix("ws://") || lower.hasPrefix("wss://")
    }

    public func connect(url: URL, headers: [HTTPHeader] = []) {
        var request = URLRequest(url: url)
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
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

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failed(error.localizedDescription))
        }
    }
}
