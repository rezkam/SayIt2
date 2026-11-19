import Foundation

enum Credentials {
    /// The ChatGPT desktop app's own sign-in, read on every connection.
    /// SayIt 2 never writes or refreshes it: the ChatGPT app owns the refresh token.
    static func chatGPT() throws -> (token: String, account: String) {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              let account = tokens["account_id"] as? String,
              expiry(of: token) > Date()
        else { throw Problem(message: "Open ChatGPT to sign in", retryable: false) }
        return (token, account)
    }

    /// Expiry from the token's own claims. An unreadable token is left for the server to judge.
    private static func expiry(of token: String) -> Date {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return .distantFuture }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double else { return .distantFuture }
        return Date(timeIntervalSince1970: exp)
    }
}
