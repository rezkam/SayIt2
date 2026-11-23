import Foundation

/// Serial queue for all local telemetry file appends, rotation, and usage updates.
let telemetryQueue = DispatchQueue(label: "sayit2.telemetry", qos: .utility)

/// Appends one OTLP/JSON line per record to `<dir>/<name>.jsonl`, rotating at 10 MB (keeping 5).
final class OtelFileWriter: @unchecked Sendable {
    private let directory: URL
    private let maxBytes: off_t = 10 * 1024 * 1024

    init(directory: URL) { self.directory = directory }

    func append(_ payload: [String: Any], to name: String) {
        telemetryQueue.async { [self] in
            guard JSONSerialization.isValidJSONObject(payload),
                  var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return }
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
}

/// Strict OTLP/JSON encoders: 64-bit ints and *UnixNano as strings, enums as ints, hex IDs.
enum OtlpJson {
    private static let scope: [String: Any] = ["name": "sayit2"]

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
        }
    }

    static func attrs(_ dict: [String: AttributeValue]) -> [[String: Any]] {
        dict.sorted { $0.key < $1.key }.map { ["key": $0.key, "value": anyValue($0.value)] }
    }

    static func span(_ s: SpanRecord, resource: [String: AttributeValue]) -> [String: Any] {
        let status: [String: Any] = switch s.status {
        case .unset: ["code": 0]
        case .ok: ["code": 1]
        case .error(let m): m.isEmpty ? ["code": 2] : ["code": 2, "message": m]
        }
        var obj: [String: Any] = [
            "traceId": s.traceId, "spanId": s.spanId, "name": s.name, "kind": s.kind.rawValue,
            "startTimeUnixNano": nano(s.startTime), "endTimeUnixNano": nano(s.endTime),
            "attributes": attrs(s.attributes), "status": status,
        ]
        if let p = s.parentSpanId { obj["parentSpanId"] = p }
        if !s.events.isEmpty {
            obj["events"] = s.events.map { ["timeUnixNano": nano($0.timestamp), "name": $0.name, "attributes": attrs($0.attributes)] }
        }
        return ["resourceSpans": [["resource": ["attributes": attrs(resource)],
            "scopeSpans": [["scope": scope, "spans": [obj]]]]]]
    }

    static func counter(name: String, value: Int, attrs dict: [String: AttributeValue], start: Date, end: Date) -> [String: Any] {
        ["name": name, "sum": [
            "aggregationTemporality": 1, "isMonotonic": true,
            "dataPoints": [["attributes": attrs(dict), "startTimeUnixNano": nano(start), "timeUnixNano": nano(end), "asInt": String(value)]],
        ]]
    }

    static func histogram(name: String, value: Double, unit: String, bounds: [Double],
                          attrs dict: [String: AttributeValue], start: Date, end: Date) -> [String: Any] {
        var counts = Array(repeating: 0, count: bounds.count + 1)
        let bucket = bounds.firstIndex { value <= $0 } ?? bounds.count
        counts[bucket] = 1
        return ["name": name, "unit": unit, "histogram": [
            "aggregationTemporality": 1,
            "dataPoints": [[
                "attributes": attrs(dict), "startTimeUnixNano": nano(start), "timeUnixNano": nano(end),
                "count": "1", "sum": value, "min": value, "max": value,
                "bucketCounts": counts.map(String.init), "explicitBounds": bounds,
            ]],
        ]]
    }

    static func metrics(_ list: [[String: Any]], resource: [String: AttributeValue]) -> [String: Any] {
        ["resourceMetrics": [["resource": ["attributes": attrs(resource)],
            "scopeMetrics": [["scope": scope, "metrics": list]]]]]
    }

    static func log(message: String, name: String?, severity: Severity, traceId: String?, spanId: String?,
                    attributes: [String: AttributeValue], resource: [String: AttributeValue], time: Date) -> [String: Any] {
        let ts = nano(time)
        var obj: [String: Any] = [
            "timeUnixNano": ts, "observedTimeUnixNano": ts, "attributes": attrs(attributes),
            "severityNumber": severity.rawValue, "severityText": severity.text,
            "body": ["stringValue": message],
        ]
        if let traceId, let spanId { obj["traceId"] = traceId; obj["spanId"] = spanId; obj["flags"] = 1 }
        if let name, !name.isEmpty { obj["eventName"] = name }
        return ["resourceLogs": [["resource": ["attributes": attrs(resource)],
            "scopeLogs": [["scope": scope, "logRecords": [obj]]]]]]
    }
}
