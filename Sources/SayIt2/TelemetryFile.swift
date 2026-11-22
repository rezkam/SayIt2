import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Serial queue for all telemetry encoding, file appends, rotation, and usage updates.
let telemetryQueue = DispatchQueue(label: "sayit2.telemetry", qos: .utility)

/// Appends one OTLP/JSON line per export to `<dir>/<name>.jsonl` (rotating at 10 MB, keeping 5)
/// and optionally POSTs the same OTLP/JSON payload to a configured OTLP/HTTP endpoint.
final class OtelFileWriter: @unchecked Sendable {
    private let directory: URL
    private let maxBytes: off_t = 10 * 1024 * 1024
    private var endpoint: String?
    private var authorization: String?
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    init(directory: URL) { self.directory = directory }

    func configure(endpoint: String?, authorization: String?) {
        let clean = endpoint?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        telemetryQueue.async { [self] in
            self.endpoint = (clean?.isEmpty == false) ? clean : nil
            self.authorization = (authorization?.isEmpty == false) ? authorization : nil
        }
    }

    func append(_ payload: [String: Any], to name: String, writeFile: Bool = true, sendRemote: Bool = true) {
        telemetryQueue.async { [self] in
            let shouldSend = sendRemote && endpoint != nil
            guard writeFile || shouldSend,
                  JSONSerialization.isValidJSONObject(payload),
                  let json = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return }
            if shouldSend { post(json, signal: name) }
            guard writeFile else { return }
            var data = json
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                chmod(directory.path, 0o700)
            }
            let path = directory.appendingPathComponent("\(name).jsonl").path
            var st = stat()
            if stat(path, &st) == 0, st.st_size >= maxBytes {
                for i in stride(from: 4, through: 1, by: -1) {
                    rename(directory.appendingPathComponent("\(name).\(i).jsonl").path,
                           directory.appendingPathComponent("\(name).\(i + 1).jsonl").path)
                }
                rename(path, directory.appendingPathComponent("\(name).1.jsonl").path)
            }
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            data.withUnsafeBytes { raw in
                guard var ptr = raw.baseAddress else { return }
                var left = raw.count
                while left > 0 {
                    let n = Darwin.write(fd, ptr, left)
                    if n <= 0 { break }
                    ptr = ptr.advanced(by: n); left -= n
                }
            }
        }
    }

    private func post(_ data: Data, signal: String) {
        guard let endpoint, let url = URL(string: "\(endpoint)/v1/\(signal)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization { req.setValue(authorization, forHTTPHeaderField: "Authorization") }
        req.httpBody = data
        session.dataTask(with: req).resume()
    }

    func drain() { telemetryQueue.sync {} }
}

/// Strict OTLP/JSON helpers: 64-bit ints and *UnixNano as strings, enums as ints, hex IDs.
enum OtlpJson {
    static func nano(_ date: Date) -> String {
        let t = max(0, date.timeIntervalSince1970), whole = floor(t)
        return String(UInt64(whole) &* 1_000_000_000 &+ UInt64((t - whole) * 1_000_000_000))
    }

    static func anyValue(_ value: AttributeValue) -> [String: Any] {
        switch value {
        case .string(let v): ["stringValue": v]
        case .bool(let v): ["boolValue": v]
        case .int(let v): ["intValue": String(v)]
        case .double(let v): ["doubleValue": v.isFinite ? v : 0.0]
        case .array(let a): ["arrayValue": ["values": a.values.map(anyValue)]]
        case .set(let s): ["kvlistValue": ["values": attrs(s.labels)]]
        default: ["stringValue": value.description]
        }
    }

    static func attrs(_ dict: [String: AttributeValue]) -> [[String: Any]] {
        dict.sorted { $0.key < $1.key }.map { ["key": $0.key, "value": anyValue($0.value)] }
    }

    static func scope(_ info: InstrumentationScopeInfo) -> [String: Any] {
        info.version.map { $0.isEmpty ? ["name": info.name] : ["name": info.name, "version": $0] } ?? ["name": info.name]
    }
}

final class FileSpanExporter: SpanExporter, @unchecked Sendable {
    private let writer: OtelFileWriter
    init(writer: OtelFileWriter) { self.writer = writer }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { writer.drain(); return .success }
    func shutdown(explicitTimeout: TimeInterval?) { writer.drain() }

    @discardableResult
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        guard let first = spans.first else { return .success }
        let encoded = spans.map { s -> [String: Any] in
            let kind = switch s.kind { case .internal: 1; case .server: 2; case .client: 3; case .producer: 4; case .consumer: 5 }
            let status: [String: Any] = switch s.status {
            case .unset: ["code": 0]
            case .ok: ["code": 1]
            case .error(let m): m.isEmpty ? ["code": 2] : ["code": 2, "message": m]
            }
            var obj: [String: Any] = [
                "traceId": s.traceId.hexString, "spanId": s.spanId.hexString, "name": s.name, "kind": kind,
                "startTimeUnixNano": OtlpJson.nano(s.startTime), "endTimeUnixNano": OtlpJson.nano(s.endTime),
                "attributes": OtlpJson.attrs(s.attributes), "status": status,
            ]
            if let p = s.parentSpanId, p.isValid { obj["parentSpanId"] = p.hexString }
            if !s.events.isEmpty {
                obj["events"] = s.events.map { ["timeUnixNano": OtlpJson.nano($0.timestamp), "name": $0.name, "attributes": OtlpJson.attrs($0.attributes)] }
            }
            return obj
        }
        writer.append(["resourceSpans": [["resource": ["attributes": OtlpJson.attrs(first.resource.attributes)],
            "scopeSpans": [["scope": OtlpJson.scope(first.instrumentationScope), "spans": encoded]]]]], to: "traces")
        return .success
    }
}

final class FileMetricExporter: MetricExporter, @unchecked Sendable {
    private let writer: OtelFileWriter
    private let temporality: AggregationTemporality
    private let writeFile: Bool
    private let sendRemote: Bool
    init(writer: OtelFileWriter, temporality: AggregationTemporality = .delta, writeFile: Bool = true, sendRemote: Bool = false) {
        self.writer = writer
        self.temporality = temporality
        self.writeFile = writeFile
        self.sendRemote = sendRemote
    }
    func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality { temporality }
    func flush() -> ExportResult { writer.drain(); return .success }
    func shutdown() -> ExportResult { writer.drain(); return .success }

    func export(metrics: [MetricData]) -> ExportResult {
        guard let first = metrics.first else { return .success }
        let encoded = metrics.compactMap { m -> [String: Any]? in
            guard !m.data.points.isEmpty else { return nil }
            var obj: [String: Any] = ["name": m.name]
            if !m.description.isEmpty { obj["description"] = m.description }
            if !m.unit.isEmpty { obj["unit"] = m.unit }
            let temp = m.data.aggregationTemporality == .delta ? 1 : 2
            switch m.type {
            case .LongSum, .DoubleSum: obj["sum"] = ["aggregationTemporality": temp, "isMonotonic": m.isMonotonic, "dataPoints": m.data.points.compactMap(numberPoint)]
            case .LongGauge, .DoubleGauge: obj["gauge"] = ["dataPoints": m.data.points.compactMap(numberPoint)]
            case .Histogram: obj["histogram"] = ["aggregationTemporality": temp, "dataPoints": m.data.points.compactMap(histogramPoint)]
            default: return nil
            }
            return obj
        }
        guard !encoded.isEmpty else { return .success }
        writer.append(["resourceMetrics": [["resource": ["attributes": OtlpJson.attrs(first.resource.attributes)],
            "scopeMetrics": [["scope": OtlpJson.scope(first.instrumentationScopeInfo), "metrics": encoded]]]]],
            to: "metrics", writeFile: writeFile, sendRemote: sendRemote)
        return .success
    }

    private func numberPoint(_ point: PointData) -> [String: Any]? {
        var obj: [String: Any] = ["attributes": OtlpJson.attrs(point.attributes),
            "startTimeUnixNano": String(point.startEpochNanos), "timeUnixNano": String(point.endEpochNanos)]
        if let p = point as? LongPointData { obj["asInt"] = String(p.value) }
        else if let p = point as? DoublePointData { obj["asDouble"] = p.value.isFinite ? p.value : 0.0 }
        else { return nil }
        return obj
    }

    private func histogramPoint(_ point: PointData) -> [String: Any]? {
        guard let p = point as? HistogramPointData else { return nil }
        var obj: [String: Any] = ["attributes": OtlpJson.attrs(p.attributes),
            "startTimeUnixNano": String(p.startEpochNanos), "timeUnixNano": String(p.endEpochNanos),
            "count": String(p.count), "sum": p.sum.isFinite ? p.sum : 0.0,
            "bucketCounts": p.counts.map { String($0) }, "explicitBounds": p.boundaries.map { $0.isFinite ? $0 : 0.0 }]
        if p.hasMin && p.min.isFinite { obj["min"] = p.min }
        if p.hasMax && p.max.isFinite { obj["max"] = p.max }
        return obj
    }
}

final class FileLogExporter: LogRecordExporter, @unchecked Sendable {
    private let writer: OtelFileWriter
    init(writer: OtelFileWriter) { self.writer = writer }
    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { writer.drain(); return .success }
    func shutdown(explicitTimeout: TimeInterval?) { writer.drain() }

    func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
        guard let first = logRecords.first else { return .success }
        let encoded = logRecords.map { r -> [String: Any] in
            let ts = OtlpJson.nano(r.timestamp)
            var obj: [String: Any] = ["timeUnixNano": ts, "observedTimeUnixNano": r.observedTimestamp.map(OtlpJson.nano) ?? ts, "attributes": OtlpJson.attrs(r.attributes)]
            if let s = r.severity { obj["severityNumber"] = s.rawValue; obj["severityText"] = s.description }
            if let body = r.body { obj["body"] = OtlpJson.anyValue(body) }
            if let ctx = r.spanContext, ctx.isValid {
                obj["traceId"] = ctx.traceId.hexString; obj["spanId"] = ctx.spanId.hexString; obj["flags"] = Int(ctx.traceFlags.byte)
            }
            if let eventName = r.eventName, !eventName.isEmpty { obj["eventName"] = eventName }
            return obj
        }
        writer.append(["resourceLogs": [["resource": ["attributes": OtlpJson.attrs(first.resource.attributes)],
            "scopeLogs": [["scope": OtlpJson.scope(first.instrumentationScopeInfo), "logRecords": encoded]]]]], to: "logs")
        return .success
    }
}
