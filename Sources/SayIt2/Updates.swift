import AppKit
import Sparkle

/// Checks for new releases with Sparkle, once a day and on request.
///
/// A newer version found by the daily check is not shown in a window. It appears as an
/// "Update to X.Y.Z…" item at the top of the menu, and the menu bar icon gets a badge.
/// Sparkle downloads the update, verifies its signature, and installs it.
@MainActor
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    /// The version waiting to be installed, if a check found one.
    private(set) var available: String?
    var onChange: (() -> Void)?
    /// False in builds without an update feed (local builds that were not made for release).
    let isEnabled = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: isEnabled, updaterDelegate: nil, userDriverDelegate: self)

    func start() {
        _ = controller
    }

    @objc func check() {
        controller.checkForUpdates(nil)
    }

    // Gentle reminders: a background app should not interrupt with a window on a scheduled check.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        Task { @MainActor in
            guard !handleShowingUpdate else { return }
            self.available = version
            self.onChange?()
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.clear() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.clear() }
    }

    private func clear() {
        guard available != nil else { return }
        available = nil
        onChange?()
    }
}
