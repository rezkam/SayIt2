import AppKit
import Foundation
import Network

/// Serves Resources/stats.html and live usage_stats.json on 127.0.0.1 when opened from the menu.
final class StatsServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sayit2.stats", qos: .utility)
    private var listener: NWListener?
    private var port: UInt16?
    private let htmlURL: () -> URL?
    private let statsURL: () -> URL
    private let onOpen: @MainActor (URL) -> Void

    init(htmlURL: @escaping () -> URL? = { Bundle.main.url(forResource: "stats", withExtension: "html") },
         statsURL: @escaping () -> URL = { Telemetry.dataDirectory.appendingPathComponent("usage_stats.json") },
         onOpen: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.htmlURL = htmlURL
        self.statsURL = statsURL
        self.onOpen = onOpen
    }

    @MainActor
    func open() {
        if let port {
            openBrowser(port: port)
            return
        }
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: params) else { return }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                guard let port = listener?.port?.rawValue else { return }
                Task { @MainActor [weak self] in
                    self?.port = port
                    self?.openBrowser(port: port)
                }
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.listener = nil
                    self?.port = nil
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
    }

    @MainActor
    private func openBrowser(port: UInt16) {
        if let url = URL(string: "http://127.0.0.1:\(port)/") {
            onOpen(url)
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
            let parts = (lines.first ?? "").split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1].split(separator: "?", maxSplits: 1)[0]) : ""
            let inm = lines.dropFirst().first { $0.lowercased().hasPrefix("if-none-match:") }
                .map { $0.dropFirst(14).trimmingCharacters(in: .whitespaces) }

            if path == "/" || path == "/index.html" {
                if let url = htmlURL(), let body = try? Data(contentsOf: url) {
                    send(conn, status: "200 OK", type: "text/html; charset=utf-8", body: body)
                } else {
                    send(conn, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
                }
            } else if path == "/usage_stats.json" {
                let url = statsURL()
                var st = stat()
                if stat(url.path, &st) == 0 {
                    let etag = "\"\(st.st_mtimespec.tv_sec)-\(st.st_mtimespec.tv_nsec)-\(st.st_size)\""
                    if inm == etag {
                        send(conn, status: "304 Not Modified", type: nil, etag: etag, body: Data())
                        return
                    }
                    if let body = try? Data(contentsOf: url) {
                        send(conn, status: "200 OK", type: "application/json; charset=utf-8", etag: etag, body: body)
                        return
                    }
                }
                send(conn, status: "200 OK", type: "application/json; charset=utf-8",
                     body: Data("{\"schemaVersion\":1,\"days\":{}}".utf8))
            } else {
                send(conn, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
            }
        }
    }

    private func send(_ conn: NWConnection, status: String, type: String?, etag: String? = nil, body: Data) {
        var header = "HTTP/1.1 \(status)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if let type { header += "Content-Type: \(type)\r\nContent-Length: \(body.count)\r\n" }
        if let etag { header += "ETag: \(etag)\r\n" }
        header += "\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        conn.send(content: packet, completion: .contentProcessed { _ in conn.cancel() })
    }
}
