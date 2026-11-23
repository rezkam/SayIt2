import Foundation
import os

/// Local OpenTelemetry-shaped traces, Prometheus-style metric samples derived from them, logs,
/// and the daily usage rollup. No SDK and no network: everything stays under ~/.local/share/sayit2/.

enum AttributeValue: Sendable {
    case string(String), bool(Bool), int(Int), double(Double)
}

enum SpanKind: Int, Sendable {
    case `internal` = 1, server = 2, client = 3
}

enum SpanStatus: Sendable {
    case unset, ok, error(description: String)
}

enum Severity: Int, Sendable {
    case info = 9, warn = 13, error = 17
    var text: String { switch self { case .info: "INFO"; case .warn: "WARN"; case .error: "ERROR" } }
}

struct SpanEvent: Sendable {
    let timestamp: Date
    let name: String
    let attributes: [String: AttributeValue]
}

struct SpanRecord: Sendable {
    let traceId: String
    let spanId: String
    let parentSpanId: String?
    let name: String
    let kind: SpanKind
    let startTime: Date
    let endTime: Date
    let attributes: [String: AttributeValue]
    let events: [SpanEvent]
    let status: SpanStatus
}

final class Span: @unchecked Sendable {
    let traceId: String
    let spanId: String
    let parentSpanId: String?
    let name: String
    let kind: SpanKind
    let startTime = Date()

    private let lock = NSLock()
    private var attributes: [String: AttributeValue] = [:]
    private var events: [SpanEvent] = []
    private var _status: SpanStatus = .unset
    private var ended = false
    private let onEnd: (SpanRecord) -> Void

    init(name: String, parent: Span?, kind: SpanKind, onEnd: @escaping (SpanRecord) -> Void) {
        self.traceId = parent?.traceId ?? Self.randomHex(bytes: 16)
        self.spanId = Self.randomHex(bytes: 8)
        self.parentSpanId = parent?.spanId
        self.name = name
        self.kind = kind
        self.onEnd = onEnd
    }

    var status: SpanStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }

    func setAttribute(key: String, value: String) { lock.withLock { attributes[key] = .string(value) } }
    func setAttribute(key: String, value: Int) { lock.withLock { attributes[key] = .int(value) } }
    func setAttribute(key: String, value: Double) { lock.withLock { attributes[key] = .double(value) } }
    func setAttribute(key: String, value: Bool) { lock.withLock { attributes[key] = .bool(value) } }

    func addEvent(name: String, attributes: [String: AttributeValue] = [:]) {
        lock.withLock { events.append(SpanEvent(timestamp: Date(), name: name, attributes: attributes)) }
    }

    func end() {
        let record: SpanRecord? = lock.withLock {
            guard !ended else { return nil }
            ended = true
            return SpanRecord(traceId: traceId, spanId: spanId, parentSpanId: parentSpanId, name: name,
                              kind: kind, startTime: startTime, endTime: Date(),
                              attributes: attributes, events: events, status: _status)
        }
        if let record { onEnd(record) }
    }

    private static func randomHex(bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

final class Telemetry: @unchecked Sendable {
    /// Overridable output root; defaults to ~/.local/share/sayit2.
    static var dataDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/sayit2")

    private static let shared = Telemetry()
    private static let osLog = os.Logger(subsystem: "sayit2", category: "app")
    static var databaseURL: URL { dataDirectory.appendingPathComponent("telemetry.sqlite") }

    private let dir: URL
    private let store: TelemetryStore
    private let resource: String

    /// How an ended span becomes metric samples: its duration, a count of one, or one of its
    /// numeric attributes, each under a metric name and unit.
    private enum Rule {
        case duration(String), count(String, unit: String), attribute(String, String, unit: String)
    }

    private static let metricRules: [String: (keys: [String], rules: [Rule])] = [
        "sayit2.dictation": (
            keys: ["gen_ai.provider.name", "gen_ai.request.model", "sayit2.trigger_mode", "sayit2.end_reason", "sayit2.language",
                   "sayit2.mic.type", "sayit2.audio.noise", "error.type"],
            rules: [
                .duration("sayit2.dictation.duration"),
                .count("sayit2.dictation.count", unit: "{dictation}"),
                .attribute("sayit2.audio.seconds", "sayit2.audio.duration", unit: "s"),
                .attribute("sayit2.finish.seconds", "sayit2.finish.duration", unit: "s"),
                .attribute("sayit2.release.seconds", "sayit2.release.duration", unit: "s"),
                .attribute("sayit2.audio.backlog.max_seconds", "sayit2.audio.backlog.max", unit: "s"),
                .attribute("sayit2.text.final_change", "sayit2.text.final_change", unit: "1"),
                .attribute("sayit2.partials.revisions", "sayit2.partials.revisions", unit: "{revision}"),
                .attribute("sayit2.rewrites.words", "sayit2.rewrites.words", unit: "{word}"),
                .attribute("sayit2.rewrites.max_words", "sayit2.rewrites.max_words", unit: "{word}"),
                .attribute("sayit2.audio.snr_db", "sayit2.audio.snr", unit: "dB"),
                .attribute("sayit2.text.characters", "sayit2.text.characters", unit: "{character}"),
                .attribute("sayit2.text.words", "sayit2.text.words", unit: "{word}"),
            ]
        ),
        "sayit2.stream": (
            keys: ["gen_ai.provider.name", "gen_ai.request.model", "server.address", "error.type"],
            rules: [
                .duration("sayit2.stream.duration"),
                .count("sayit2.stream.count", unit: "{connection}"),
                .attribute("sayit2.stream.connect.seconds", "sayit2.stream.connect.duration", unit: "s"),
                .attribute("sayit2.stream.first_text.seconds", "sayit2.stream.first_text.duration", unit: "s"),
                .attribute("sayit2.stream.first_text_after_audio.seconds", "sayit2.stream.first_text_after_audio.duration", unit: "s"),
                .attribute("sayit2.stream.replay.seconds", "sayit2.stream.replay.duration", unit: "s"),
            ]
        ),
        "sayit2.insert": (
            keys: ["sayit2.insert.waited"],
            rules: [
                .duration("sayit2.insert.duration"),
                .count("sayit2.insert.count", unit: "{insertion}"),
                .attribute("sayit2.insert.wait.seconds", "sayit2.insert.wait.duration", unit: "s"),
            ]
        ),
        "sayit2.auth.renew": (
            keys: ["error.type"],
            rules: [
                .duration("sayit2.auth.renew.duration"),
                .count("sayit2.auth.renew.count", unit: "{renewal}"),
            ]
        ),
    ]

    private init() {
        dir = Self.dataDirectory
        store = TelemetryStore(url: Self.databaseURL)
        resource = TelemetryStore.json(Self.makeResource())
    }

    static func startSpan(_ name: String, parent: Span? = nil, kind: SpanKind = .internal) -> Span {
        Span(name: name, parent: parent, kind: kind) { record in
            shared.recordSpan(record)
        }
    }

    /// Writes to both the unified log (unless disabled) and the local OTel log stream.
    static func event(_ message: String, name: String? = nil, severity: Severity = .info,
                      span: Span? = nil, attributes: [String: AttributeValue] = [:], unified: Bool = true) {
        if unified {
            switch severity {
            case .error: osLog.error("\(message, privacy: .public)")
            case .warn: osLog.warning("\(message, privacy: .public)")
            case .info: osLog.notice("\(message, privacy: .public)")
            }
        }
        shared.store.insertLog(time: Date(), severity: severity, name: name, body: message,
                               traceId: span?.traceId, spanId: span?.spanId, attributes: attributes)
    }

    /// Waits for queued telemetry writes; called when the app quits.
    static func flush() { telemetryQueue.sync {} }

    private func recordSpan(_ span: SpanRecord) {
        store.insert(span: span, resource: resource, samples: Self.samples(for: span))
        if span.parentSpanId == nil, span.name == "sayit2.dictation" {
            let dir = self.dir
            telemetryQueue.async { Usage.record(span, in: dir) }
        }
    }

    /// The metric samples one ended span yields, labelled with the rule's attribute keys.
    static func samples(for span: SpanRecord) -> [(name: String, unit: String, value: Double, labels: String)] {
        var samples: [(name: String, unit: String, value: Double, labels: String)] = []
        if let entry = metricRules[span.name] {
            let labels = TelemetryStore.json(span.attributes.filter { entry.keys.contains($0.key) })
            for rule in entry.rules {
                switch rule {
                case .duration(let name):
                    samples.append((name, "s", max(0, span.endTime.timeIntervalSince(span.startTime)), labels))
                case .count(let name, let unit):
                    samples.append((name, unit, 1, labels))
                case .attribute(let key, let name, let unit):
                    switch span.attributes[key] {
                    case .double(let v) where v.isFinite: samples.append((name, unit, v, labels))
                    case .int(let v): samples.append((name, unit, Double(v), labels))
                    default: break
                    }
                }
            }
        }
        return samples
    }

    private static func makeResource() -> [String: AttributeValue] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        return [
            "service.name": .string("sayit2"),
            "service.version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"),
            "service.build": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"),
            "os.version": .string("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            "host.arch": .string(arch),
        ]
    }
}
