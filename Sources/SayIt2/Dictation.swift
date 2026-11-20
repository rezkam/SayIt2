import AppKit

/// One recording, from the key press until its text is handed to the typist.
///
/// It keeps every audio byte the provider has not finalized. If a connection fails, a new
/// one replays that audio, and the typist converges on the new transcript, so a retry can
/// neither lose nor duplicate text.
@MainActor
final class Dictation {
    let handsFree: Bool
    private(set) var isRecording = true
    var onLevel: ((Float) -> Void)?
    /// Recording stopped; the final text is still on its way.
    var onStopped: (() -> Void)?
    /// Everything is done. Carries a message if something went wrong.
    var onEnd: ((String?) -> Void)?

    private let config: Config
    private var provider: Provider { config.provider }
    private let typist: Typist
    private let job: Typist.Job
    private let mic = Mic()
    private let started = Date()
    private var stream: Transcriber?
    private var timer: Timer?

    private var audio = Data()      // captured audio the provider has not finalized
    private var sent = 0            // bytes of `audio` sent on the current connection
    private var trimmed = 0         // bytes removed from `audio` during the current connection
    private var finals: [String] = []
    private var live = ""
    private var failures = 0        // connection failures in a row
    private var renewedLogin = false
    private var catchingUp = false  // a replay is running; its transcript is still behind what was typed
    private var capturing = true    // the microphone is still open; it closes shortly after `stop()`
    private var finishedAt: Date?   // when the provider was told there is no more audio
    private var sawKeyDown = false
    private var ended = false

    init(config: Config, handsFree: Bool, typist: Typist) throws {
        self.config = config
        self.handsFree = handsFree
        self.typist = typist
        if config.provider == .deepgram, config.deepgramKey == nil { throw Problem(message: "Add the Deepgram key in the config") }
        guard let job = typist.begin() else { throw Problem(message: "No app to type into") }
        self.job = job

        mic.onAudio = { [weak self] data, level in
            guard let self, self.capturing else { return }
            self.audio.append(data)
            self.onLevel?(level)
        }
        mic.onInterrupted = { [weak self] in self?.stop() }
        do {
            try mic.start(sampleRate: config.provider.sampleRate)
        } catch {
            typist.keepTyped(job)
            throw error
        }
    }

    /// Opens the connection. Call after the callbacks are set.
    func start() {
        connect()
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The user finished speaking: close the microphone and wait for the remaining text.
    func stop() {
        guard isRecording, !ended else { return }
        isRecording = false
        onStopped?()
        // The end of the last word is still travelling through the audio buffers when the key
        // is released, so the microphone stays open a moment longer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.capturing else { return }
            self.capturing = false
            self.mic.stop()
        }
    }

    /// Abandons the recording, leaving whatever was already typed.
    func cancel() {
        guard !ended else { return }
        close()
        typist.keepTyped(job)
        onEnd?(nil)
    }

    private func connect() {
        let stream: Transcriber
        if provider == .chatgpt {
            stream = ChatGPTStream()
        } else {
            stream = DeepgramStream(config: config)
        }
        self.stream = stream
        sent = 0
        trimmed = 0
        finishedAt = nil

        stream.onInterim = { [weak self, weak stream] text in
            guard let self, self.stream === stream else { return }
            self.failures = 0
            self.live = text
            self.render()
        }
        stream.onFinal = { [weak self, weak stream] text, covered in
            guard let self, self.stream === stream else { return }
            self.failures = 0
            // Keep the part of the interim text this final did not reach, until the next
            // interim replaces it. Otherwise those words would be erased and typed again.
            self.live = self.live.hasPrefix(text) ? String(self.live.dropFirst(text.count)).trimmingCharacters(in: .whitespaces) : ""
            if !text.isEmpty { self.finals.append(text) }
            // The audio behind this final is no longer needed for a replay.
            let cut = min(max(covered - self.trimmed, 0), self.sent)
            self.audio = self.audio.subdata(in: cut..<self.audio.count)
            self.sent -= cut
            self.trimmed += cut
            self.render()
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
        if isRecording {
            // Safety net for a missed release event in hold mode. It only acts once it has
            // seen the key reported as down, so it can never end a recording by mistake.
            let keyDown = CGEventSource.keyState(.combinedSessionState, key: Hotkey.keyCode)
            let keyReleased = !handsFree && sawKeyDown && !keyDown
            sawKeyDown = sawKeyDown || keyDown
            if keyReleased || Date().timeIntervalSince(started) > provider.maxSeconds { stop() }
        }
        guard let stream else { return }
        // Dead connection: no sign of life for 5 s, not even the answer to a ping.
        // Stuck transcription: all audio was handed over and the server then said nothing for 10 s.
        let now = Date()
        let stuck = finishedAt.map { now.timeIntervalSince(max($0, stream.lastMessage)) > 10 } ?? false
        if now.timeIntervalSince(stream.lastActivity) > 5 || stuck {
            stream.cancel()
            self.stream = nil
            return lost(Problem(message: "No response from \(provider.title)"))
        }
        guard stream.isReady else { return }
        // At most 8 messages per tick, so a replay after a reconnect is paced, not dumped at once.
        var budget = 8
        while budget > 0, sent < audio.count, audio.count - sent >= provider.frameBytes || !capturing {
            let count = min(provider.frameBytes, audio.count - sent)
            stream.send(audio: audio.subdata(in: sent..<sent + count))
            sent += count
            budget -= 1
        }
        if !capturing, sent == audio.count, finishedAt == nil {
            finishedAt = now
            stream.finish()
        }
    }

    private func render() {
        let text = currentText
        if catchingUp {
            guard text.unicodeScalars.count >= job.typed.count else { return }
            catchingUp = false
        }
        typist.set(text, for: job)
    }

    private var currentText: String {
        (finals + [live]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func lost(_ problem: Problem) {
        if problem.renewLogin, !renewedLogin {
            // Renew the ChatGPT sign-in once, then connect again. Audio keeps being buffered meanwhile.
            renewedLogin = true
            catchingUp = true
            Task { [weak self] in
                do {
                    try await Credentials.renewChatGPT()
                    guard let self, !self.ended, self.stream == nil else { return }
                    self.connect()
                } catch {
                    self?.complete(problem: (error as? Problem)?.message ?? "Sign in to ChatGPT again")
                }
            }
            return
        }
        failures += 1
        log.notice("connection lost: \(problem.message, privacy: .public), failure \(self.failures)")
        guard problem.retryable, failures <= 2 else { return complete(problem: problem.message) }
        catchingUp = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (failures == 1 ? 0.3 : 1)) { [weak self] in
            guard let self, !self.ended, self.stream == nil else { return }
            self.connect()
        }
    }

    private func complete(problem: String?) {
        guard !ended else { return }
        close()
        let text = currentText
        if catchingUp, problem != nil {
            typist.keepTyped(job)   // an unfinished replay must not erase what was already typed
        } else {
            typist.set(text.isEmpty ? "" : text + " ", for: job, final: true)
        }
        onEnd?(problem)
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
