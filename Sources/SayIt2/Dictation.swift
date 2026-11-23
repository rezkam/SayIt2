import AppKit
import OpenTelemetryApi

/// One recording, from the key press until its final text is handed to the typist.
/// Live text only goes to the pill; the text field receives the final text once, at the end.
///
/// It keeps every audio byte the provider has not finalized. If a connection fails, a new
/// one replays that audio, so a retry can neither lose nor duplicate text: nothing reaches the
/// text field until the end.
@MainActor
final class Dictation {
    let handsFree: Bool
    let span: Span
    /// A problem worth showing in the pill while recording, such as a silent microphone.
    var onNotice: ((String) -> Void)?
    private(set) var isRecording = true
    var onLevel: ((Float) -> Void)?
    /// The newest live text, for the pill.
    var onText: ((String) -> Void)?
    /// Recording stopped; the final text is still on its way.
    var onStopped: (() -> Void)?
    /// Everything is done. Carries a message if something went wrong.
    var onEnd: ((String?) -> Void)?

    private let config: Config
    private var provider: Provider { config.provider }
    private let typist: Typist
    private let job: Typist.Job
    private let mic = Mic()
    private var stream: Transcriber?
    private var timer: Timer?

    private var audio = Data()      // captured audio the provider has not finalized
    private var sent = 0            // bytes of `audio` sent on the current connection
    private var trimmed = 0         // bytes removed from `audio` during the current connection
    private var finals: [String] = []
    private var live = ""
    private var failures = 0        // connection failures in this dictation; never reset, so retries always end
    private var renewedLogin = false
    private var catchingUp = false  // a replay is running; its transcript is still behind what was shown
    private var shown = ""           // the best text so far, independent of preview smoothing
    private var displayed = ""
    private var previewShortenedAt: Date?
    private var previewSettled = false
    private var capturing = true    // the microphone is still open; it closes shortly after `stop()`
    private var finishedAt: Date?   // when the provider was told there is no more audio
    private var finishedMono: UInt64?
    private var attempts = 0
    private var sawKeyDown = false
    private var sawAudio = false
    private var captured = 0        // audio bytes recorded, for the log
    private var ended = false

    init(config: Config, handsFree: Bool, typist: Typist) throws {
        self.config = config
        self.handsFree = handsFree
        self.typist = typist

        Telemetry.configure(config)
        let span = Telemetry.startSpan("sayit2.dictation")
        span.setAttribute(key: "gen_ai.provider.name", value: config.provider.rawValue)
        if let model = config.model(for: config.provider) { span.setAttribute(key: "gen_ai.request.model", value: model) }
        span.setAttribute(key: "gen_ai.operation.name", value: "speech_to_text")
        span.setAttribute(key: "sayit2.trigger_mode", value: handsFree ? "hands_free" : "hold")
        self.span = span

        if let hint = config.missingKeyHint {
            throw Self.failStart(span: span, error: Problem(message: hint, retryable: false, errorType: "missing_key"))
        }
        guard let job = typist.begin(parentSpan: span) else {
            throw Self.failStart(span: span, error: Problem(message: "No app to type into", retryable: false, errorType: "no_target_app"))
        }
        self.job = job
        if let bundle = job.bundle { span.setAttribute(key: "sayit2.target_app.bundle_id", value: bundle) }

        mic.onAudio = { [weak self] data, level in
            guard let self, self.capturing else { return }
            if !self.sawAudio {
                self.sawAudio = true
                self.span.addEvent(name: "mic_first_audio")
            }
            self.captured += data.count
            self.audio.append(data)
            self.onLevel?(level)
        }
        mic.onInterrupted = { [weak self] in
            guard let self, self.isRecording else { return }
            self.onNotice?("Microphone lost")
            self.stop()
        }
        mic.onNotice = { [weak self] notice in self?.onNotice?(notice) }
        do {
            try mic.start(sampleRate: config.provider.sampleRate, span: span)
        } catch {
            typist.insert("", for: job)
            throw Self.failStart(span: span, error: error)
        }
    }

    private static func failStart(span: Span, error: Error) -> Problem {
        let problem = error as? Problem ?? Problem(message: "Could not start", retryable: false, errorType: "start_failed")
        Telemetry.event("could not start: \(problem.message)", severity: .error, span: span)
        span.setAttribute(key: "sayit2.end_reason", value: "failed")
        span.setAttribute(key: "sayit2.attempts", value: 0)
        span.setAttribute(key: "error.type", value: problem.errorType ?? problem.message)
        span.status = .error(description: problem.message)
        span.end()
        Telemetry.flush()
        return problem
    }

    /// Opens the connection. Call after the callbacks are set.
    func start() {
        connect()
        guard !ended else { return }
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The user finished speaking: close the microphone and wait for the remaining text.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        span.addEvent(name: "recording_stopped")
        onStopped?()
        // The end of the last word is still travelling through the audio buffers when the key
        // is released, so the microphone stays open a moment longer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.capturing else { return }
            self.capturing = false
            self.span.addEvent(name: "mic_stopped")
            self.mic.stop()
        }
    }

    /// Abandons the recording without inserting anything, but only while no words have been
    /// recognized. Once there are words it finishes normally, so speech is never thrown away.
    func cancel() {
        guard !ended else { return }
        guard shown.isEmpty else { return stop() }
        close()
        typist.insert("", for: job)
        endSpan(reason: "cancelled", text: "", problem: nil)
        onEnd?(nil)
    }

    private func connect() {
        attempts += 1
        let stream: Transcriber = switch provider {
        case .chatgpt: ChatGPTStream()
        case .deepgram: DeepgramStream(config: config)
        case .elevenlabs: ElevenLabsStream(config: config, previousText: finals.joined(separator: " "))
        }
        stream.span = Telemetry.startSpan("sayit2.stream", parent: span, kind: .client)
        stream.span?.setAttribute(key: "gen_ai.provider.name", value: provider.rawValue)
        if let model = config.model(for: provider) {
            stream.span?.setAttribute(key: "gen_ai.request.model", value: model)
        }
        stream.span?.setAttribute(key: "sayit2.stream.attempt", value: attempts)
        stream.logTranscripts = config.telemetryTranscripts
        self.stream = stream
        sent = 0
        trimmed = 0
        live = ""
        finishedAt = nil
        finishedMono = nil

        stream.onInterim = { [weak self, weak stream] text in
            guard let self, self.stream === stream else { return }
            self.live = text
            self.render()
        }
        stream.onFinal = { [weak self, weak stream] text, covered in
            guard let self, self.stream === stream else { return }
            if !text.isEmpty {
                self.finals.append(text)
                self.previewSettled = true
            }
            // The audio behind this final is no longer needed for a replay.
            let cut = min(max(covered - self.trimmed, 0), self.sent)
            self.audio = self.audio.subdata(in: cut..<self.audio.count)
            self.sent -= cut
            self.trimmed += cut
        }
        stream.onStopRequested = { [weak self] in self?.stop() }
        stream.onEnd = { [weak self, weak stream] problem in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            if let problem { self.lost(problem) } else { self.complete(problem: nil) }
        }
        stream.start()
    }

    /// Runs every 40 ms: sends audio, notices a dead connection, and enforces the limits.
    private func tick() {
        if capturing { mic.checkHealth() }
        if isRecording, !handsFree {
            // Safety net for a missed release event in hold mode. It only acts once it has
            // seen the key reported as down, so it can never end a recording by mistake.
            if CGEventSource.keyState(.combinedSessionState, key: Hotkey.keyCode) {
                sawKeyDown = true
            } else if sawKeyDown {
                stop()
            }
        }
        if previewShortenedAt != nil { paintPreview() }
        guard let stream else { return }
        // Dead connection: no sign of life for 5 s, not even the answer to a ping.
        // Handshake stall: the socket is open, yet the provider did not become ready within 10 s.
        // Stuck transcription: all audio was handed over and the server then said nothing for 10 s.
        let now = Date()
        let notReady = !stream.isReady && now.timeIntervalSince(stream.startedAt) > 10
        let stuck = finishedAt.map { now.timeIntervalSince($0) > 15 || now.timeIntervalSince(max($0, stream.lastMessage)) > 10 } ?? false
        if now.timeIntervalSince(stream.lastActivity) > 5 || notReady || stuck {
            let reason = notReady ? "handshake_timeout" : stuck ? "finish_timeout" : "activity_timeout"
            return stream.end(Problem(message: "No response from \(provider.title)", errorType: reason))
        }
        guard stream.isReady else { return }
        // A limited number of messages per tick, so a replay after a reconnect is paced, not dumped at once.
        var budget = provider.framesPerTick
        while budget > 0, stream.acceptsAudio, sent < audio.count, audio.count - sent >= provider.frameBytes || !capturing {
            let count = min(provider.frameBytes, audio.count - sent)
            stream.send(audio: audio.subdata(in: sent..<sent + count))
            sent += count
            budget -= 1
        }
        if !capturing, sent == audio.count, finishedAt == nil {
            finishedAt = now
            finishedMono = DispatchTime.now().uptimeNanoseconds
            span.addEvent(name: "finish_requested")
            stream.finish()
        }
    }

    private func render() {
        let text = currentText
        if catchingUp {
            // A replay starts over; keep showing the earlier text until it catches up.
            guard text.count >= shown.count else { return }
            catchingUp = false
        }
        shown = text
        paintPreview()
    }

    private func paintPreview() {
        if provider == .elevenlabs, !previewSettled, shown.count < displayed.count {
            // Let a transient shorter hypothesis recover before the pill rewinds.
            let now = Date()
            let since = previewShortenedAt ?? now
            previewShortenedAt = since
            guard now.timeIntervalSince(since) >= 1.2 else { return }
        }
        previewShortenedAt = nil
        previewSettled = false
        guard displayed != shown else { return }
        displayed = shown
        onText?(shown)
    }

    private var currentText: String {
        (finals + [live]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func lost(_ problem: Problem) {
        if problem.renewLogin, !renewedLogin {
            // Renew the ChatGPT sign-in, then connect again. Audio keeps being buffered meanwhile.
            renewedLogin = true
            catchingUp = true
            Task { [weak self] in
                do {
                    try await Credentials.renewChatGPT(parentSpan: self?.span)
                    guard let self, !self.ended, self.stream == nil else { return }
                    self.connect()
                } catch {
                    guard let self, !self.ended else { return }
                    // Not renewed. If the server was only out of reach, the retry renews again.
                    self.renewedLogin = false
                    self.lost(error as? Problem ?? Problem(message: "Sign in to ChatGPT again", retryable: false, errorType: "auth_rejected"))
                }
            }
            return
        }
        failures += 1
        let willRetry = problem.retryable && failures <= 3
        Telemetry.event("connection lost: \(problem.message) (\(problem.errorType ?? "unknown")), failure \(self.failures)",
                        severity: willRetry ? .warn : .error, span: span)
        // At most three reconnects per dictation. A replay can produce live text and still fail
        // again, so progress must not reset this count, or a failing dictation never ends.
        guard willRetry else { return complete(problem: problem) }
        catchingUp = true
        let delay: TimeInterval = [0.5, 2, 5][failures - 1]
        span.addEvent(name: "retry_scheduled", attributes: [
            "attempt": .int(failures + 1), "delay_seconds": .double(delay),
            "error.type": .string(problem.errorType ?? problem.message),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.ended, self.stream == nil else { return }
            self.connect()
        }
    }

    private func complete(problem: Problem?) {
        guard !ended else { return }
        close()
        // After a failure, insert the best text received so far rather than losing the speech.
        let raw = problem != nil && catchingUp ? shown : currentText
        let text = config.replaceInFinalText(raw)
        if text != raw { span.setAttribute(key: "sayit2.text.replaced", value: true) }
        let seconds = Double(captured) / 2 / provider.sampleRate
        Telemetry.event("dictation finished: \(String(format: "%.1f", seconds)) s of audio, \(text.count) characters",
                        severity: problem == nil ? .info : .error, span: span)
        typist.insert(text.isEmpty ? "" : text + " ", for: job)
        if config.telemetryTranscripts {
            Telemetry.event(shown, name: "sayit2.transcript.live", span: span, unified: false)
            Telemetry.event(text, name: "sayit2.transcript.final", span: span, unified: false)
        }
        endSpan(reason: problem == nil ? "completed" : "failed", text: text, problem: problem)
        onEnd?(problem?.message)
    }

    private func endSpan(reason: String, text: String, problem: Problem?) {
        span.setAttribute(key: "sayit2.audio.seconds", value: Double(captured) / 2 / provider.sampleRate)
        span.setAttribute(key: "sayit2.text.characters", value: text.count)
        span.setAttribute(key: "sayit2.text.words", value: text.split(whereSeparator: \.isWhitespace).count)
        span.setAttribute(key: "sayit2.end_reason", value: reason)
        span.setAttribute(key: "sayit2.attempts", value: attempts)
        if let finishedMono {
            span.setAttribute(key: "sayit2.finish.seconds", value: Double(DispatchTime.now().uptimeNanoseconds - finishedMono) / 1e9)
        }
        if let lang = Usage.language(of: text) { span.setAttribute(key: "sayit2.language", value: lang) }
        if let problem {
            span.setAttribute(key: "error.type", value: problem.errorType ?? problem.message)
            span.status = .error(description: problem.message)
        } else {
            span.status = .ok
        }
        span.end()
        Telemetry.flush()
    }

    private func close() {
        ended = true
        isRecording = false
        capturing = false
        timer?.invalidate()
        mic.stop()
        stream?.cancel()
        stream = nil
    }
}
