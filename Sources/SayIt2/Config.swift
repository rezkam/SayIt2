import Foundation

/// Something went wrong in a way worth telling the user about.
struct Problem: Error {
    let message: String
    var retryable = true
    /// The ChatGPT sign-in was rejected as expired; renewing it may fix this.
    var renewLogin = false
}

enum Provider: String, CaseIterable {
    case chatgpt, deepgram

    var title: String { self == .chatgpt ? "ChatGPT" : "Deepgram Nova-3" }
    /// Wire sample rate: the rates the reference apps were captured using.
    var sampleRate: Double { self == .chatgpt ? 48000 : 16000 }
    /// Bytes per audio message: 2,048 samples for ChatGPT, 100 ms for Deepgram.
    var frameBytes: Int { self == .chatgpt ? 4096 : 3200 }
    /// Most audio messages sent per 40 ms tick, which caps how fast a replay after a reconnect
    /// runs. ChatGPT's recognizer gave up on a long replay at 8.5x real time and kept up at 3.2x.
    var framesPerTick: Int { self == .chatgpt ? 3 : 8 }
}

/// All settings, read from the plain text file ~/.config/sayit2/config before every dictation.
struct Config {
    var provider = Provider.chatgpt
    var deepgramKey: String?
    var deepgramURL = "wss://api.deepgram.com/v1/listen"
    /// Every `deepgram.<name> = <value>` line, sent to Deepgram as a query parameter.
    var deepgramParameters: [URLQueryItem] = []
    /// When true, raw provider messages and final transcripts are written to otel/logs.jsonl.
    var telemetryTranscripts = false
    /// Optional OTLP/HTTP JSON base endpoint (e.g. Grafana Cloud) and Authorization header.
    var telemetryEndpoint: String?
    var telemetryAuthorization: String?

    var deepgramModel: String { deepgramParameters.first { $0.name == "model" }?.value ?? "nova-3" }

    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/sayit2/config")
    /// These describe the audio SayIt2 sends, so the file cannot change them.
    private static let fixed = ["encoding": "linear16", "sample_rate": "16000", "channels": "1"]

    /// Reads the file, creating it with every option listed if it does not exist yet.
    static func load() -> Config {
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data(template.utf8), attributes: [.posixPermissions: 0o600])
        }
        var config = Config()
        for (key, value) in entries((try? String(contentsOf: file, encoding: .utf8)) ?? "") {
            if key == "provider" {
                config.provider = Provider(rawValue: value) ?? config.provider
            } else if key == "deepgram.api_key" {
                config.deepgramKey = value.isEmpty ? nil : value
            } else if key == "deepgram.url" {
                if !value.isEmpty { config.deepgramURL = value }
            } else if key == "telemetry.transcripts" {
                config.telemetryTranscripts = value.lowercased() == "true"
            } else if key == "telemetry.otlp.endpoint" {
                config.telemetryEndpoint = value.isEmpty ? nil : value
            } else if key == "telemetry.otlp.authorization" {
                config.telemetryAuthorization = value.isEmpty ? nil : value
            } else if key.hasPrefix("deepgram."), !value.isEmpty, fixed[String(key.dropFirst(9))] == nil {
                config.deepgramParameters.append(URLQueryItem(name: String(key.dropFirst(9)), value: value))
            }
        }
        // Without a model Deepgram silently falls back to its old `base` model.
        if !config.deepgramParameters.contains(where: { $0.name == "model" }) {
            config.deepgramParameters.append(URLQueryItem(name: "model", value: "nova-3"))
        }
        config.deepgramParameters += fixed.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return config
    }

    /// All active `key = value` pairs in the config file, creating it from the template if missing.
    static func allEntries() -> [[String]] {
        _ = load()
        return entries((try? String(contentsOf: file, encoding: .utf8)) ?? "").map { [$0.key, $0.value] }
    }

    static func set(_ key: String, to value: String) -> Bool { update([key: [value]]) }

    /// Updates each key in `changes` in place (an empty array removes its active lines), keeping
    /// comments and unrelated keys intact. Returns false without writing if the file cannot be read.
    static func update(_ changes: [String: [String]]) -> Bool {
        _ = load()
        let target = file.resolvingSymlinksInPath()
        guard let text = try? String(contentsOf: target, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")
        for key in changes.keys.sorted() {
            let k = key.trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty, !k.hasPrefix("#"), !k.contains("="), !k.contains(where: \.isNewline) else { continue }
            let values = (changes[key] ?? [])
                .map { $0.components(separatedBy: .newlines).joined().trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let index = lines.firstIndex { entries($0).first?.key == k }
            lines.removeAll { entries($0).first?.key == k }
            guard !values.isEmpty else { continue }
            let pos = index ?? (lines.last == "" ? lines.count - 1 : lines.count)
            lines.insert(contentsOf: values.map { "\(k) = \($0)" }, at: pos)
        }
        let temp = target.deletingLastPathComponent().appendingPathComponent(".config.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: Data(lines.joined(separator: "\n").utf8), attributes: [.posixPermissions: 0o600]),
              rename(temp.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        return true
    }

    /// `key = value` pairs, skipping blank lines and lines that start with `#`.
    private static func entries(_ text: String) -> [(key: String, value: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && !parts[0].hasPrefix("#") ? (parts[0], parts[1]) : nil
        }
    }

    private static let template = """
    # SayIt2 settings. Saved changes apply to the next dictation.
    # Lines starting with # are ignored.

    # Which service transcribes: chatgpt or deepgram. The menu bar menu changes this line.
    provider = chatgpt

    # ---------- ChatGPT ----------
    # Uses the sign-in of the ChatGPT desktop app on this Mac. Nothing to set.
    # The text is inserted exactly as ChatGPT returns it.

    # ---------- Deepgram ----------
    deepgram.api_key =

    # Server. Regional servers take the same key and keep processing in that region:
    # wss://api.eu.deepgram.com/v1/listen, wss://api.au.deepgram.com/v1/listen,
    # wss://api.in.deepgram.com/v1/listen
    deepgram.url = wss://api.deepgram.com/v1/listen

    # Every other deepgram.* line is sent to Deepgram as a query parameter of its
    # live streaming API. Remove the leading # to use one.
    # Reference: https://developers.deepgram.com/reference/speech-to-text/listen-streaming
    # If Deepgram refuses a value, the pill says "Deepgram rejected the config".

    # nova-3 is the general model. Also: nova-3-medical, nova-3-pharma. A misspelled name
    # is refused. Flux models are not supported: they use a different endpoint and protocol.
    deepgram.model = nova-3
    # multi detects the language as you speak (English, Persian and 53 others).
    # Or set one language, for example en or fa.
    deepgram.language = multi
    # Languages to expect, one line each. Only used with language = multi, where they
    # bias detection without restricting it. A code multi does not support is refused.
    deepgram.language_hint = en
    deepgram.language_hint = fa
    # Live text while you speak. With false, text only appears in finished chunks.
    deepgram.interim_results = true
    # Milliseconds of silence that end a phrase. Deepgram's default is 10.
    deepgram.endpointing = 300

    # Formatting. Without any of these, Deepgram returns plain lowercase text.
    # Punctuation, capitals, and formatted numbers and dates. Includes punctuate,
    # so do not enable both:
    deepgram.smart_format = true
    # Punctuation and capitals only:
    # deepgram.punctuate = true
    # Numbers as digits:
    # deepgram.numerals = true
    # Spoken commands such as "comma" and "new line" (needs punctuate):
    # deepgram.dictation = true
    # deepgram.profanity_filter = true

    # Vocabulary.
    # Names, product terms and jargon to recognize better (Nova-3). One term per line,
    # repeated as needed. No commas and no weights: the whole value is one term.
    # Keep it to the 20 to 50 terms that matter.
    # deepgram.keyterm = Deepgram
    # deepgram.keyterm = routing number
    # Replace one term with another:
    # deepgram.replace = say it:SayIt
    # deepgram.search = phrase

    # Privacy.
    # Remove sensitive values: true, pci, numbers, aggressive_numbers, ssn
    # deepgram.redact = pci
    # deepgram.redact_usage = true
    # Opt out of Deepgram's model improvement program:
    # deepgram.mip_opt_out = true

    # Other.
    # deepgram.detect_entities = true
    # deepgram.utterance_end_ms = 1000
    # deepgram.vad_events = true
    # deepgram.tag = sayit2
    # deepgram.extra = key:value
    # deepgram.version = latest

    # Set by SayIt2 to match the audio it sends, and ignored here:
    # encoding = linear16, sample_rate = 16000, channels = 1.
    # Not useful for typing dictation: callback, callback_method, multichannel,
    # diarize_model (speaker labels), keywords (models older than Nova-3).

    # ---------- Telemetry ----------
    # When true, the exact provider messages and the final text are written to
    # ~/.local/share/sayit2/otel/logs.jsonl for debugging; off by default.
    # telemetry.transcripts = false
    # Optional OTLP/HTTP JSON endpoint (such as Grafana Cloud) to also send traces,
    # metrics, and logs. Leave unset to keep telemetry local only.
    # telemetry.otlp.endpoint = https://otlp-gateway-example.grafana.net/otlp
    # telemetry.otlp.authorization = Basic ...

    """
}
