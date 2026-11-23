import Foundation
import OpenTelemetryApi

/// One streaming connection to a provider. Subclasses describe the provider's messages.
@MainActor
class Transcriber {
    /// Text that may still change. Replaces the previous interim text.
    var onInterim: ((String) -> Void)?
    /// Text that will not change, and how many audio bytes of this connection it covers.
    /// Follow with onInterim to publish the new uncommitted tail in the same update.
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
    var acceptsAudio: Bool { true }
    var span: Span?
    var logTranscripts = false

    private var task: URLSessionWebSocketTask?
    private var pinger: Task<Void, Never>?
    private var ended = false
    private var sawMessage = false
    private var sawText = false
    private var spanEnded = false

    func request() throws -> URLRequest { fatalError("subclass") }
    func opened() {}
    func received(_ message: [String: Any]) {}
    func send(audio: Data) {}
    /// No more audio: ask the server for the remaining text.
    func finish() {}
    /// Explains a connection that failed or closed, given the HTTP status of the handshake.
    func closed(status: Int) -> Problem { Problem(message: "Connection lost") }

    func start() {
        if let orig = onInterim {
            onInterim = { [weak self] text in
                if !text.isEmpty { self?.noteFirstText() }
                orig(text)
            }
        }
        if let orig = onFinal {
            onFinal = { [weak self] text, covered in
                if !text.isEmpty { self?.noteFirstText() }
                orig(text, covered)
            }
        }
        do {
            let req = try request()
            if let host = req.url?.host { span?.setAttribute(key: "server.address", value: host) }
            let task = URLSession.shared.webSocketTask(with: req)
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
        endSpan(problem: nil)
        pinger?.cancel()
        task?.cancel()
    }

    func end(_ problem: Problem?) {
        guard !ended else { return }
        endSpan(problem: problem)
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
        guard !ended else { return }
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.ended else { return }
                guard case .success(let message) = result else { return self.failed() }
                self.lastActivity = Date()
                self.lastMessage = Date()
                if !self.sawMessage {
                    self.sawMessage = true
                    self.span?.addEvent(name: "first_message")
                }
                if case .string(let text) = message {
                    if self.logTranscripts {
                        Telemetry.event(text, name: "sayit2.provider.message", span: self.span, unified: false)
                    }
                    if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                        self.received(object)
                    }
                }
                self.receive()
            }
        }
    }

    private func noteFirstText() {
        guard !sawText else { return }
        sawText = true
        span?.addEvent(name: "first_text")
    }

    private func endSpan(problem: Problem?) {
        guard !spanEnded else { return }
        spanEnded = true
        if let problem {
            span?.setAttribute(key: "error.type", value: problem.errorType ?? problem.message)
            span?.status = .error(description: problem.message)
        } else {
            span?.status = .ok
        }
        span?.end()
    }

    private func failed() {
        end(closed(status: (task?.response as? HTTPURLResponse)?.statusCode ?? 0))
    }
}
