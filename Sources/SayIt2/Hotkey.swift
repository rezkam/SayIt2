import AppKit

/// The Right Option gesture, with the timings of ChatGPT's desktop dictation:
/// hold (100 ms) to dictate while held, double-tap (400 ms) for hands-free, tap to stop.
@MainActor
final class Hotkey {
    static let keyCode: CGKeyCode = 61          // Right Option
    private static let deviceMask: UInt = 0x40  // Right Option bit in the device-dependent flags

    var onStart: ((_ handsFree: Bool) -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Whether a recording is running, and whether it is hands-free.
    var recording: () -> (active: Bool, handsFree: Bool) = { (false, false) }

    private var monitor: Any?
    private var isDown = false
    private var startedHandsFree = false    // this press started hands-free, so its release means nothing
    private var pendingStart: DispatchWorkItem?
    private var lastTap: Date?

    /// Starts listening. Needs Accessibility permission; without it macOS delivers no key events.
    func install() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func handle(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == syntheticEventTag { return }
        if event.type == .flagsChanged, event.keyCode == Self.keyCode {
            let down = event.modifierFlags.rawValue & Self.deviceMask != 0
            if down != isDown {
                isDown = down
                down ? pressed() : released()
            }
        } else if event.type == .keyDown, isDown {
            otherKey()
        }
    }

    private func pressed() {
        let state = recording()
        if state.active {
            if state.handsFree { onStop?() }
            return
        }
        if let lastTap, Date().timeIntervalSince(lastTap) <= 0.4 {
            self.lastTap = nil
            startedHandsFree = true
            onStart?(true)
            return
        }
        lastTap = nil
        let start = DispatchWorkItem { [weak self] in
            self?.pendingStart = nil
            self?.onStart?(false)
        }
        pendingStart = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: start)
    }

    private func released() {
        if startedHandsFree {
            startedHandsFree = false
        } else if let pendingStart {
            pendingStart.cancel()   // released within 100 ms: a tap
            self.pendingStart = nil
            lastTap = Date()
        } else if recording() == (true, false) {
            onStop?()
        }
    }

    /// Another key while Right Option is down: the user is typing a symbol, not dictating.
    private func otherKey() {
        lastTap = nil
        if let pendingStart {
            pendingStart.cancel()
            self.pendingStart = nil
        } else if recording() == (true, false) {
            onCancel?()
        }
    }
}
