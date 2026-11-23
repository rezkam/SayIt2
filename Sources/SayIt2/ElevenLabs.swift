import Foundation
import OpenTelemetryApi

/// Scribe sends a base commit first, then optional timestamps and text transformations.
@MainActor
final class ElevenLabsStream: Transcriber {
    private struct Segment {
        let original: String
        let receivedAt = Date()
        var covered: Int?
        var replacement: String?
    }

    private let config: Config
    private let previousText: String
    private var initialContext = ""
    private var keytermLibrary: [String] = []
    private var normalizeFullStops = true
    private var ready = false
    private var automatic = false
    private var replacementEvent: String?
    private var segments: [Segment] = []
    private var partial = ""
    private var sent = 0
    private var lastCommit = 0
    private var pendingCommit: Int?
    private var turnProbability = 0.0
    private var finishing = false
    private var stopCommitSent = false
    private var deadline: Task<Void, Never>?
    private var settle: Task<Void, Never>?
    private var ended = false
    private var sawCommit = false
    private var missedRedaction = false
    private var redacting: Bool { replacementEvent == "redacted_transcript" }
    override var isReady: Bool { ready }

    init(config: Config, previousText: String) {
        self.config = config
        self.previousText = String(previousText.suffix(49))
    }

    override func request() throws -> URLRequest {
        let options = config.parameters(for: .elevenlabs)
        func value(_ name: String) -> String? { options.first { $0.name == name }?.value }
        func enabled(_ name: String) -> Bool { value(name)?.lowercased() == "true" }
        func invalid(_ message: String) -> Problem { Problem(message: message, retryable: false) }
        let strategy = value("commit_strategy") ?? "manual"
        let edit = value("transcript_edit")
        let redact = value("entity_redaction") != nil
        let diarize = enabled("diarize")
        let inferNames = enabled("infer_speaker_names")
        let keyterms = options.filter { $0.name == "keyterms" }.compactMap(\.value)
        keytermLibrary = options.filter { $0.name == "keyterm_library" }.compactMap(\.value)
        initialContext = previousText.isEmpty ? (value("previous_text") ?? "") : previousText
        normalizeFullStops = value("normalize_full_stops")?.lowercased() != "false"
        guard ["manual", "vad", "turn_prediction"].contains(strategy), (edit?.count ?? 0) <= 2000 else {
            throw invalid("Check the ElevenLabs commit strategy and editing instruction")
        }
        if edit != nil, redact || value("entity_detection") != nil {
            throw invalid("ElevenLabs editing cannot be combined with entity detection or redaction")
        }
        if enabled("filter_background_audio"), enabled("include_timestamps") || diarize {
            throw invalid("ElevenLabs background filtering cannot be combined with timestamps or speaker labels")
        }
        if inferNames, !diarize || redact {
            throw invalid("ElevenLabs speaker names need speaker labels and no redaction")
        }
        if value("model_id") == "scribe_v2_realtime", strategy == "turn_prediction" || enabled("multilang_mode") || diarize || !keytermLibrary.isEmpty {
            throw invalid("Selected ElevenLabs options require Scribe v3 Live")
        }
        if let interval = value("keepalive_interval_ms"), !(Int(interval).map { (500...10000).contains($0) } ?? false) {
            throw invalid("ElevenLabs keepalive interval must be 500 to 10,000 ms")
        }
        if let seconds = value("vad_silence_threshold_secs"), !(Double(seconds).map { (0.192...3).contains($0) } ?? false) {
            throw invalid("ElevenLabs VAD silence threshold must be 0.192 to 3 seconds")
        }
        if keyterms.count > 50 || keyterms.reduce(0, { $0 + $1.count }) > 1000 {
            throw invalid("ElevenLabs keyterms allow up to 50 terms and 1,000 characters")
        }
        if keytermLibrary.count > 10000 || keytermLibrary.contains(where: { $0.count > 50 }) ||
            keytermLibrary.reduce(0, { $0 + $1.utf8.count }) > 2_000_000 {
            throw invalid("ElevenLabs keyterm library exceeds provider limits")
        }
        automatic = strategy != "manual"
        replacementEvent = redact ? "redacted_transcript" : edit != nil ? "edited_transcript" : nil
        let local = ["keyterm_library", "previous_text", "normalize_full_stops", "token"]
        let query = options.filter { !local.contains($0.name) }
        if redact { logTranscripts = false }
        var url = URLComponents(string: config.url(for: .elevenlabs))
        url?.queryItems = query
        guard let endpoint = url?.url, let key = config.key(for: .elevenlabs) else { throw invalid("Check the ElevenLabs key in Settings") }
        var request = URLRequest(url: endpoint)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        return request
    }

    override func send(audio: Data) {
        let first = sent == 0
        sent += audio.count
        var frame = audio
        if frame.count < Provider.elevenlabs.frameBytes {
            frame.append(Data(count: Provider.elevenlabs.frameBytes - frame.count))
        }
        let uncommitted = sent - lastCommit
        let commit = !automatic && pendingCommit == nil &&
            (uncommitted >= 28 * 32000 || (uncommitted >= 20 * 32000 && turnProbability >= 0.9))
        if commit { pendingCommit = sent }
        sendChunk(frame, commit: commit, first: first)
    }

    private func sendChunk(_ audio: Data, commit: Bool, first: Bool = false) {
        var message: [String: Any] = ["message_type": "input_audio_chunk", "sample_rate": 16000,
                                      "audio_base_64": audio.base64EncodedString(), "commit": commit]
        if first {
            if !initialContext.isEmpty { message["previous_text"] = initialContext }
            if !keytermLibrary.isEmpty { message["keyterm_library"] = keytermLibrary }
        }
        guard let json = try? JSONSerialization.data(withJSONObject: message) else { return }
        send(.string(String(decoding: json, as: UTF8.self)))
    }

    override func finish() {
        finishing = true
        if sent == 0 { return end(nil) }
        requestStopCommit()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            let missingFinal = !self.stopCommitSent || self.pendingCommit != nil
            self.end(missingFinal && (!self.automatic || !self.partial.isEmpty)
                     ? Problem(message: "ElevenLabs did not finish", retryable: false) : nil)
        }
        finishIfDrained()
    }

    private func requestStopCommit() {
        guard finishing, !stopCommitSent, pendingCommit == nil else { return }
        stopCommitSent = true
        if lastCommit < sent {
            pendingCommit = sent
            sendChunk(Data(), commit: true)
        }
    }

    private func finishIfDrained() {
        guard stopCommitSent, pendingCommit == nil, segments.isEmpty else { return }
        if !automatic { return end(nil) }
        // An automatic commit can cross the stop request. Drain late text before closing.
        guard partial.isEmpty, settle == nil else { return }
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            self.end(nil)
        }
    }

    override func received(_ message: [String: Any]) {
        let type = message["message_type"] as? String ?? ""
        let text = message["text"] as? String ?? ""
        switch type {
        case "session_started": ready = true
        case "partial_transcript":
            if !text.isEmpty { settle?.cancel(); settle = nil }
            if !(finishing && text.isEmpty && pendingCommit != nil) { partial = text }
            turnProbability = message["turn_probability"] as? Double ?? 0
        case "committed_transcript":
            if automatic { settle?.cancel(); settle = nil }
            // Once automatic text is committed, the connection is no longer replayable.
            // Release delivered audio rather than retaining it for the whole dictation.
            if !text.isEmpty { sawCommit = true }
            let covered: Int? = automatic ? (sawCommit ? sent : 0) : pendingCommit
            if let boundary = pendingCommit {
                if !automatic { lastCommit = boundary }
                pendingCommit = nil
            }
            if covered == nil {
                // An unsolicited commit has no known audio boundary. Do not replay it.
                segments.append(Segment(original: text))
                partial = ""
                return end(Problem(message: "ElevenLabs committed audio unexpectedly", retryable: false))
            }
            segments.append(Segment(original: text, covered: covered))
            if !text.isEmpty || !finishing { partial = "" }
            turnProbability = 0
            requestStopCommit()
        case "edited_transcript", "redacted_transcript":
            if type == replacementEvent {
                let candidates = segments.indices.filter { segments[$0].replacement == nil }
                let index = candidates.first { segments[$0].original == text }
                    ?? candidates.first { segments[$0].original.split(whereSeparator: \.isWhitespace) == text.split(whereSeparator: \.isWhitespace) }
                if let index {
                    segments[index].replacement = message[type == "edited_transcript" ? "edited_text" : "redacted_text"] as? String
                }
            }
        case "committed_transcript_with_timestamps", "diarized_transcript", "speakers_merged", "speaker_names", "committed_transcript_entities": break
        case "commit_throttled":
            span?.addEvent(name: "commit_throttled")
            pendingCommit = nil
            if finishing, stopCommitSent {
                if !automatic || !partial.isEmpty { return end(nil) }
            } else {
                requestStopCommit()
            }
        case "auth_error", "quota_exceeded", "unaccepted_terms", "invalid_request", "input_error", "chunk_size_exceeded":
            return fail(type, retryable: false)
        case "insufficient_audio_activity":
            return fail(type, retryable: false)
        case "rate_limited", "queue_overflow", "resource_exhausted", "transcriber_error", "session_time_limit_exceeded", "error":
            return fail(type, retryable: true)
        default: return
        }
        flush()
        finishIfDrained()
    }

    private func flush(force: Bool = false) {
        while let segment = segments.first,
              force || (segment.covered != nil && (segment.original.isEmpty || replacementEvent == nil ||
                  segment.replacement != nil || Date().timeIntervalSince(segment.receivedAt) >= 5)) {
            segments.removeFirst()
            let withheld = redacting && !segment.original.isEmpty && segment.replacement == nil
            if withheld { missedRedaction = true }
            let output = segment.replacement ?? (withheld ? "[redaction unavailable]" : segment.original)
            onFinal?(displayText(output), segment.covered ?? lastCommit)
        }
        let live = redacting
            ? segments.map { $0.replacement ?? ($0.original.isEmpty ? "" : "[redacting…]") } + (partial.isEmpty ? [] : ["[redacting…]"])
            : segments.map { $0.replacement ?? $0.original } + [partial]
        onInterim?(live.filter { !$0.isEmpty }.map(displayText).joined(separator: " "))
    }

    private func displayText(_ text: String) -> String {
        // Match replacements against raw provider text first. Leave East Asian and mixed scripts alone.
        guard normalizeFullStops, text.contains("。"),
              text.range(of: #"[[\p{Latin}\p{Arabic}]&&\p{L}]"#, options: .regularExpression) != nil,
              text.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\p{Bopomofo}\p{Yi}]"#, options: .regularExpression) == nil else { return text }
        return text.replacingOccurrences(of: "。", with: ".")
    }

    override func end(_ problem: Problem?) {
        guard !ended else { return }
        ended = true
        deadline?.cancel()
        settle?.cancel()
        flush(force: true)
        var problem = problem
        if redacting, !partial.isEmpty {
            missedRedaction = true
            onFinal?("[redaction unavailable]", lastCommit)
            onInterim?("")
        }
        if missedRedaction { problem = Problem(message: "ElevenLabs redaction unavailable", retryable: false) }
        // Scribe does not document an exact automatic-commit audio byte offset. Replaying
        // after a committed segment could insert it twice, so keep recognized text and stop.
        if automatic, sawCommit { problem?.retryable = false }
        super.end(problem)
    }

    private func fail(_ type: String, retryable: Bool) {
        let message = switch type {
        case "auth_error": "Check the ElevenLabs key in Settings"
        case "quota_exceeded": "ElevenLabs quota exceeded"
        case "unaccepted_terms": "Accept the Scribe terms in ElevenLabs"
        case "insufficient_audio_activity": "ElevenLabs ended the stream after silence"
        case "invalid_request", "input_error", "chunk_size_exceeded": "ElevenLabs rejected the config or audio"
        default: "ElevenLabs connection interrupted"
        }
        end(Problem(message: message, retryable: retryable, errorType: type))
    }

    override func closed(status: Int) -> Problem {
        switch status {
        case 401, 403: Problem(message: "Check the ElevenLabs key in Settings", retryable: false)
        case 400, 422: Problem(message: "ElevenLabs rejected the config", retryable: false)
        default: Problem(message: "ElevenLabs connection lost")
        }
    }
}
