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

    /// When this connection started, to time out if the provider never becomes ready.
    let startedAt = Date()
    /// When the server last showed it is alive: a message, or the answer to a ping.
    /// Pings are used because how often a provider sends transcripts depends on its settings.
    private(set) var lastActivity = Date()
    /// When the server last sent a message.
    private(set) var lastMessage = Date()
    /// Whether audio may be sent yet.
    var isReady: Bool { true }

    private var task: URLSessionWebSocketTask?
    private var pinger: Task<Void, Never>?
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
            pinger = Task { [weak self] in
                while !Task.isCancelled, let task = self?.task {
                    task.sendPing { error in
                        guard error == nil else { return }
                        Task { @MainActor in self?.lastActivity = Date() }
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        } catch {
            end(error as? Problem ?? Problem(message: "Connection failed"))
        }
    }

    /// Drops the connection without reporting anything.
    func cancel() {
        ended = true
        pinger?.cancel()
        task?.cancel()
    }

    func end(_ problem: Problem?) {
        guard !ended else { return }
        cancel()
        onEnd?(problem)
    }

    func send(_ message: URLSessionWebSocketTask.Message) {
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
                self.lastMessage = Date()
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
