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
    /// Explains a connection that failed or closed, given the HTTP status and WebSocket close info.
    func closed(status: Int, closeCode: Int, reason: String?) -> Problem {
        Problem(message: "Connection lost", errorType: closeCode > 0 ? "ws_\(closeCode)" : "connection_lost")
    }

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
            end(error as? Problem ?? Problem(message: "Connection failed", errorType: "request_failed"))
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
            guard let error else { return }
            Task { @MainActor in self?.failed(error) }
        }
    }

    private func receive() {
        guard !ended else { return }
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.ended else { return }
                guard case .success(let message) = result else {
                    if case .failure(let error) = result { self.failed(error) } else { self.failed(nil) }
                    return
                }
                self.lastActivity = Date()
                self.lastMessage = Date()
                if !self.sawMessage {
                    self.sawMessage = true
                    self.recordHandshakeHeaders()
                    self.span?.setAttribute(key: "sayit2.stream.first_message.seconds", value: Date().timeIntervalSince(self.startedAt))
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
        span?.setAttribute(key: "sayit2.stream.first_text.seconds", value: Date().timeIntervalSince(startedAt))
        span?.addEvent(name: "first_text")
    }

    private func recordHandshakeHeaders() {
        guard let http = task?.response as? HTTPURLResponse else { return }
        span?.setAttribute(key: "http.response.status_code", value: http.statusCode)
        if let id = http.value(forHTTPHeaderField: "dg-request-id") ?? http.value(forHTTPHeaderField: "x-request-id"), !id.isEmpty {
            span?.setAttribute(key: "sayit2.provider.request_id", value: id)
        }
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

    private func failed(_ error: Error?) {
        guard !ended else { return }
        recordHandshakeHeaders()
        let http = task?.response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let closeCode = task?.closeCode.rawValue ?? 0
        let reason = task?.closeReason.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        if closeCode > 0 { span?.setAttribute(key: "websocket.close.code", value: closeCode) }
        if let reason, !reason.isEmpty { span?.setAttribute(key: "websocket.close.reason", value: String(reason.prefix(120))) }
        let dgError = http?.value(forHTTPHeaderField: "dg-error")?.trimmingCharacters(in: .whitespacesAndNewlines)
        var detail = "stream failed: http \(status), ws \(closeCode)"
        if let reason, !reason.isEmpty { detail += " (\(String(reason.prefix(120))))" }
        if let dgError, !dgError.isEmpty { detail += " [\(String(dgError.prefix(160)))]" }
        if let urlError = error as? URLError { detail += " [URLError \(urlError.code.rawValue)]" }
        Telemetry.event(detail, severity: .error, span: span)
        end(closed(status: status, closeCode: closeCode, reason: reason))
    }
}
