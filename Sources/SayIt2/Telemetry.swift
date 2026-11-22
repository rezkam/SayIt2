import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import os

/// Local OpenTelemetry setup (traces, metrics, logs) and the single `event` helper.
final class Telemetry: @unchecked Sendable {
    /// Overridable output root; defaults to ~/.local/share/sayit2.
    static var dataDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/sayit2")

    private static let shared = Telemetry()
    private static let osLog = os.Logger(subsystem: "sayit2", category: "app")

    private let tracerProvider: TracerProviderSdk
    private let meterProvider: MeterProviderSdk
    private let logProcessor: SimpleLogRecordProcessor
    private let tracer: Tracer
    private let logger: OpenTelemetryApi.Logger

    private init() {
        let dir = Self.dataDirectory
        let writer = OtelFileWriter(directory: dir.appendingPathComponent("otel"))
        let resource = Self.makeResource()
        let reader = PeriodicMetricReaderBuilder(exporter: FileMetricExporter(writer: writer)).setInterval(timeInterval: 60).build()
        meterProvider = MeterProviderSdk.builder()
            .setResource(resource: resource)
            .registerView(selector: InstrumentSelector.builder().setInstrument(name: ".*").build(), view: View.builder().build())
            .registerMetricReader(reader: reader)
            .build()
        tracerProvider = TracerProviderBuilder().with(resource: resource)
            .add(spanProcessor: SpanMetricsProcessor(meter: meterProvider.get(name: "sayit2"), usageDirectory: dir))
            .add(spanProcessor: SimpleSpanProcessor(spanExporter: FileSpanExporter(writer: writer)))
            .build()
        logProcessor = SimpleLogRecordProcessor(logRecordExporter: FileLogExporter(writer: writer))
        let loggerProvider = LoggerProviderBuilder().with(resource: resource).with(processors: [logProcessor]).build()
        tracer = tracerProvider.get(instrumentationName: "sayit2")
        logger = loggerProvider.get(instrumentationScopeName: "sayit2")
    }

    static func start() { _ = shared }

    static func startSpan(_ name: String, parent: Span? = nil, kind: SpanKind = .internal) -> Span {
        let builder = shared.tracer.spanBuilder(spanName: name).setSpanKind(spanKind: kind)
        if let parent { builder.setParent(parent) } else { builder.setNoParent() }
        return builder.startSpan()
    }

    /// Writes to both the unified log (unless disabled) and the OTel log stream.
    static func event(_ message: String, name: String? = nil, severity: Severity = .info,
                      span: Span? = nil, attributes: [String: AttributeValue] = [:], unified: Bool = true) {
        if unified { osLog.notice("\(message, privacy: .public)") }
        var builder = shared.logger.logRecordBuilder().setTimestamp(Date()).setSeverity(severity).setBody(.string(message))
        if let name { builder = builder.setEventName(name) }
        if let span { builder = builder.setSpanContext(span.context) }
        if !attributes.isEmpty { builder = builder.setAttributes(attributes) }
        builder.emit()
    }

    /// Flushes spans, metrics, and logs off the main actor.
    static func flush(wait: Bool = false) {
        let work = {
            shared.tracerProvider.forceFlush()
            _ = shared.meterProvider.forceFlush()
            _ = shared.logProcessor.forceFlush()
            telemetryQueue.sync {}
        }
        if wait { work() } else { DispatchQueue.global(qos: .utility).async(execute: work) }
    }

    private static func makeResource() -> Resource {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        return Resource(attributes: [
            "service.name": .string("sayit2"),
            "service.version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"),
            "service.build": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"),
            "os.version": .string("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            "host.arch": .string(arch),
        ])
    }
}

/// Derives metrics from ended spans via one table, and records root dictations into Usage.
private final class SpanMetricsProcessor: SpanProcessor, @unchecked Sendable {
    private enum Rule {
        case duration(DoubleHistogramMeterSdk), count(LongCounterSdk)
        case attrDouble(String, DoubleHistogramMeterSdk), attrInt(String, LongCounterSdk)
    }

    private static let durationBounds: [Double] = [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600]

    let isStartRequired = false, isEndRequired = true
    private let usageDirectory: URL
    private let table: [String: (keys: [String], rules: [Rule])]

    init(meter: MeterSdk, usageDirectory: URL) {
        self.usageDirectory = usageDirectory
        let histogram: (String) -> DoubleHistogramMeterSdk = {
            meter.histogramBuilder(name: $0).setUnit("s").setExplicitBucketBoundariesAdvice(Self.durationBounds).build()
        }
        self.table = [
            "sayit2.dictation": (
                keys: ["gen_ai.provider.name", "gen_ai.request.model", "sayit2.trigger_mode", "sayit2.end_reason", "sayit2.language"],
                rules: [
                    .duration(histogram("sayit2.dictation.duration")),
                    .count(meter.counterBuilder(name: "sayit2.dictation.count").build()),
                    .attrDouble("sayit2.audio.seconds", histogram("sayit2.audio.duration")),
                    .attrDouble("sayit2.finish.seconds", histogram("sayit2.finish.duration")),
                    .attrInt("sayit2.text.characters", meter.counterBuilder(name: "sayit2.text.characters").build()),
                    .attrInt("sayit2.text.words", meter.counterBuilder(name: "sayit2.text.words").build()),
                ]
            ),
            "sayit2.stream": (
                keys: ["server.address", "error.type"],
                rules: [
                    .duration(histogram("sayit2.stream.duration")),
                    .count(meter.counterBuilder(name: "sayit2.stream.count").build()),
                ]
            ),
        ]
    }

    func onStart(parentContext: SpanContext?, span: ReadableSpan) {}
    func shutdown(explicitTimeout: TimeInterval?) {}
    func forceFlush(timeout: TimeInterval?) {}

    func onEnd(span: ReadableSpan) {
        let data = span.toSpanData()
        if let entry = table[data.name] {
            var attrs: [String: AttributeValue] = [:]
            for k in entry.keys { if let v = data.attributes[k] { attrs[k] = v } }
            for rule in entry.rules {
                switch rule {
                case .duration(let h):
                    let s = data.endTime.timeIntervalSince(data.startTime)
                    if s.isFinite { h.record(value: max(0, s), attributes: attrs) }
                case .count(let c): c.add(value: 1, attributes: attrs)
                case .attrDouble(let k, let h):
                    if case .double(let v) = data.attributes[k], v.isFinite { h.record(value: max(0, v), attributes: attrs) }
                case .attrInt(let k, let c):
                    if case .int(let v) = data.attributes[k], v > 0 { c.add(value: v, attributes: attrs) }
                }
            }
        }
        if data.parentSpanId == nil, data.name == "sayit2.dictation" {
            let dir = usageDirectory
            telemetryQueue.async { Usage.record(data, in: dir) }
        }
    }
}
