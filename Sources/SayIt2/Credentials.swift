import Foundation

/// The ChatGPT sign-in shared with the ChatGPT desktop app and the codex command line tool,
/// stored in ~/.codex/auth.json. SayIt2 renews it itself when it has expired, and saves the
/// renewed tokens back to the same file so those apps keep working with them.
enum Credentials {
    private static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    /// The token most recently handed to a connection, to tell whether someone else renewed it since.
    private static var lastUsed: String?

    static var hasChatGPTLogin: Bool { tokens() != nil }

    static func chatGPT() throws -> (token: String, account: String) {
        guard let tokens = tokens(), let token = tokens["access_token"] as? String,
              let account = tokens["account_id"] as? String
        else { throw Problem(message: "Sign in to ChatGPT", retryable: false) }
        lastUsed = token
        if expiry(of: token) <= Date() { throw Problem(message: "ChatGPT sign-in expired", retryable: false, renewLogin: true) }
        return (token, account)
    }

    /// Renews the ChatGPT sign-in with its refresh token.
    static func renewChatGPT() async throws {
        let lock = open(file.path + ".lock", O_RDWR | O_CREAT, 0o600)
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        if lock >= 0 {   // the ChatGPT app or codex may be renewing at the same moment
            for _ in 0..<50 where flock(lock, LOCK_EX | LOCK_NB) != 0 { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard let data = try? Data(contentsOf: file),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              let refresh = tokens["refresh_token"] as? String
        else { throw Problem(message: "Sign in to ChatGPT", retryable: false) }
        // Someone else already renewed it.
        if access != lastUsed, expiry(of: access) > Date() { return }

        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refresh),
            URLQueryItem(name: "client_id", value: claims(of: access)?["client_id"] as? String ?? ""),
        ]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)

        let reply: Data, status: Int
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            reply = body
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw Problem(message: "Can't reach ChatGPT")
        }
        guard status == 200, let renewed = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let newAccess = renewed["access_token"] as? String
        else {
            log.notice("ChatGPT renewal refused with status \(status, privacy: .public)")
            throw status >= 500 ? Problem(message: "Can't reach ChatGPT")
                                : Problem(message: "Sign in to ChatGPT again", retryable: false)
        }
        tokens["access_token"] = newAccess
        for key in ["refresh_token", "id_token"] { if let value = renewed[key] as? String { tokens[key] = value } }
        root["tokens"] = tokens
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        root["last_refresh"] = stamp.string(from: Date())
        guard let output = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
        // Write a private temporary file and move it into place, so the file is never half written.
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".auth.json.sayit2")
        guard FileManager.default.createFile(atPath: temporary.path, contents: output, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, file.path) == 0
        else { throw Problem(message: "Could not save the ChatGPT sign-in", retryable: false) }
        log.notice("ChatGPT sign-in renewed")
    }

    private static func tokens() -> [String: Any]? {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["tokens"] as? [String: Any]
    }

    private static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Expiry from the token's own claims. An unreadable token is left for the server to judge.
    private static func expiry(of token: String) -> Date {
        (claims(of: token)?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantFuture
    }
}
