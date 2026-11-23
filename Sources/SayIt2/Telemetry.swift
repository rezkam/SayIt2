import Foundation
import os

/// Local OpenTelemetry-compatible traces, derived delta metrics, logs, and daily usage rollup.
/// Zero external telemetry SDKs and zero network calls: everything stays under ~/.local/share/sayit2/.

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
    static let durationBounds: [Double] = [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600]

    private let dir: URL
    private let writer: OtelFileWriter
    private let resource: [String: AttributeValue]

    private enum Rule {
        case duration(String), count(String), attrDouble(String, String), attrInt(String, String)
    }

    private static let metricRules: [String: (keys: [String], rules: [Rule])] = [
        "sayit2.dictation": (
            keys: ["gen_ai.provider.name", "gen_ai.request.model", "sayit2.trigger_mode", "sayit2.end_reason", "sayit2.language", "error.type"],
            rules: [
                .duration("sayit2.dictation.duration"),
                .count("sayit2.dictation.count"),
                .attrDouble("sayit2.audio.seconds", "sayit2.audio.duration"),
                .attrDouble("sayit2.finish.seconds", "sayit2.finish.duration"),
                .attrInt("sayit2.text.characters", "sayit2.text.characters"),
                .attrInt("sayit2.text.words", "sayit2.text.words"),
            ]
        ),
        "sayit2.stream": (
            keys: ["gen_ai.provider.name", "gen_ai.request.model", "server.address", "error.type"],
            rules: [
                .duration("sayit2.stream.duration"),
                .count("sayit2.stream.count"),
                .attrDouble("sayit2.stream.connect.seconds", "sayit2.stream.connect.duration"),
                .attrDouble("sayit2.stream.first_text.seconds", "sayit2.stream.first_text.duration"),
            ]
        ),
        "sayit2.insert": (
            keys: ["sayit2.insert.waited"],
            rules: [
                .duration("sayit2.insert.duration"),
                .count("sayit2.insert.count"),
                .attrDouble("sayit2.insert.wait.seconds", "sayit2.insert.wait.duration"),
            ]
        ),
        "sayit2.auth.renew": (
            keys: ["error.type"],
            rules: [
                .duration("sayit2.auth.renew.duration"),
                .count("sayit2.auth.renew.count"),
            ]
        ),
    ]

    private init() {
        dir = Self.dataDirectory
        writer = OtelFileWriter(directory: dir.appendingPathComponent("otel"))
        resource = Self.makeResource()
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
        let payload = OtlpJson.log(message: message, name: name, severity: severity,
                                   traceId: span?.traceId, spanId: span?.spanId,
                                   attributes: attributes, resource: shared.resource, time: Date())
        shared.writer.append(payload, to: "logs")
    }

    /// Waits for queued telemetry writes; called when the app quits.
    static func flush() { telemetryQueue.sync {} }

    private func recordSpan(_ span: SpanRecord) {
        writer.append(OtlpJson.span(span, resource: resource), to: "traces")
        if let entry = Self.metricRules[span.name] {
            var attrs: [String: AttributeValue] = [:]
            for k in entry.keys { if let v = span.attributes[k] { attrs[k] = v } }
            var metrics: [[String: Any]] = []
            for rule in entry.rules {
                switch rule {
                case .duration(let name):
                    let s = span.endTime.timeIntervalSince(span.startTime)
                    if s.isFinite { metrics.append(OtlpJson.histogram(name: name, value: max(0, s), unit: "s", bounds: Self.durationBounds, attrs: attrs, start: span.startTime, end: span.endTime)) }
                case .count(let name):
                    metrics.append(OtlpJson.counter(name: name, value: 1, attrs: attrs, start: span.startTime, end: span.endTime))
                case .attrDouble(let k, let name):
                    if case .double(let v) = span.attributes[k], v.isFinite {
                        metrics.append(OtlpJson.histogram(name: name, value: max(0, v), unit: "s", bounds: Self.durationBounds, attrs: attrs, start: span.startTime, end: span.endTime))
                    }
                case .attrInt(let k, let name):
                    if case .int(let v) = span.attributes[k], v > 0 {
                        metrics.append(OtlpJson.counter(name: name, value: v, attrs: attrs, start: span.startTime, end: span.endTime))
                    }
                }
            }
            if !metrics.isEmpty { writer.append(OtlpJson.metrics(metrics, resource: resource), to: "metrics") }
        }
        if span.parentSpanId == nil, span.name == "sayit2.dictation" {
            let dir = self.dir
            telemetryQueue.async { Usage.record(span, in: dir) }
        }
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
