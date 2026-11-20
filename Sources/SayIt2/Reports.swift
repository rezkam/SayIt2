import Foundation
import Sentry

/// Crash and error reports through Sentry.
///
/// Off unless the build was given a DSN (`SAYIT2_SENTRY_DSN`, stored in Info.plist). Reports
/// carry crashes, app hangs, and the short problem messages the pill shows. Never transcripts,
/// audio, device names, settings, or personal data: those never reach these calls, IP addresses
/// and other default personal data are off, and network activity is not recorded.
enum Reports {
    static func start() {
        guard let dsn = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String, !dsn.isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false
            options.enableUncaughtNSExceptionReporting = true
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.enableCaptureFailedRequests = false
        }
    }

    /// A dictation ended with a problem, such as "Can't reach ChatGPT".
    static func problem(_ message: String, provider: Provider) {
        guard SentrySDK.isEnabled else { return }
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(.warning)
            scope.setTag(value: provider.rawValue, key: "provider")
        }
    }
}
