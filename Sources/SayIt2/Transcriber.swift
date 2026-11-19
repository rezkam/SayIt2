import Foundation

/// One streaming connection to a provider. Subclasses describe the provider's messages.
@MainActor
class Transcriber {
    /// Text that may still change. Replaces the previous interim text.
    var onInterim: ((String) -> Void)?
    /// Text that will not change, and how many audio bytes of this connection it covers.
    var onFinal: ((String, Int) -> Void)?
    /// The server asked the client to wrap up.
    var onStopRequested: (() -> Void)?
    /// The connection is over: nil after a clean finish, otherwise what went wrong.
    var onEnd: ((Problem?) -> Void)?

    /// When the server last sent anything. A long silence means the connection is dead.
    private(set) var lastActivity = Date()
    /// Whether audio may be sent yet.
    var isReady: Bool { true }

    private var task: URLSessionWebSocketTask?
    private var ended = false

    func request() throws -> URLRequest { fatalError("subclass") }
    func opened() {}
    func received(_ message: [String: Any]) {}
    func send(audio: Data) {}
    /// No more audio: ask the server for the remaining text.
    func finish() {}
    /// Explains a connection that failed or closed, given the HTTP status of the handshake.
    func closed(status: Int) -> Problem { Problem(message: "Connection lost") }

    func start() {
        do {
            let task = URLSession.shared.webSocketTask(with: try request())
            self.task = task
            task.resume()
            opened()
            receive()
        } catch {
            end(error as? Problem ?? Problem(message: "Connection failed"))
        }
    }

    /// Drops the connection without reporting anything.
    func cancel() {
        ended = true
        task?.cancel()
    }

    func end(_ problem: Problem?) {
        guard !ended else { return }
        ended = true
        task?.cancel()
        onEnd?(problem)
    }

    func send(text: String) { send(.string(text)) }
    func send(data: Data) { send(.data(data)) }

    private func send(_ message: URLSessionWebSocketTask.Message) {
        task?.send(message) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.failed() }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.ended else { return }
                guard case .success(let message) = result else { return self.failed() }
                self.lastActivity = Date()
                if case .string(let text) = message,
                   let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    self.received(object)
                }
                self.receive()
            }
        }
    }

    private func failed() {
        end(closed(status: (task?.response as? HTTPURLResponse)?.statusCode ?? 0))
    }
}
