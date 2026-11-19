import AppKit
import ApplicationServices

/// Marks key events SayIt 2 posts, so its own hotkey listener can ignore them.
let syntheticEventTag: Int64 = 0x5341_5932

/// Types transcripts into the app that was focused when dictation started.
///
/// Each job remembers exactly what it has typed. One loop makes that equal the newest
/// transcript: type what is missing, or backspace to the common prefix first. Only the
/// newest transcript matters, so updates can never be applied twice or out of order.
@MainActor
final class Typist {
    final class Job {
        let app: pid_t
        fileprivate(set) var typed: [Unicode.Scalar] = []
        fileprivate var target: [Unicode.Scalar] = []
        fileprivate var isFinal = false

        fileprivate init(app: pid_t) {
            self.app = app
        }
    }

    /// Called when typing starts or stops waiting, and when everything has been typed.
    var onChange: (() -> Void)?
    /// The target app is not in front, so typing is paused until it returns.
    private(set) var isWaiting = false
    var isBusy: Bool { !jobs.isEmpty }

    private var jobs: [Job] = []
    private var running = false
    private let source = CGEventSource(stateID: .privateState)

    init() {
        source?.localEventsSuppressionInterval = 0
    }

    /// Starts a job for the app that has keyboard focus right now.
    /// Text still waiting for a different app is abandoned.
    func begin() -> Job? {
        guard let app = Self.focusedApp() else { return nil }
        jobs.removeAll { $0.app != app }
        let job = Job(app: app)
        jobs.append(job)
        run()
        return job
    }

    /// Sets the newest transcript. After `final`, the job accepts no more changes.
    func set(_ text: String, for job: Job, final: Bool = false) {
        guard !job.isFinal else { return }
        job.target = text.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            $0.properties.generalCategory == .control ? " " : $0
        }
        job.isFinal = final
    }

    /// Ends a job leaving whatever has been typed so far.
    func keepTyped(_ job: Job) {
        guard !job.isFinal else { return }
        job.target = job.typed
        job.isFinal = true
    }

    static func focusedApp() -> pid_t? {
        var value: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            var app: pid_t = 0
            if AXUIElementGetPid(value as! AXUIElement, &app) == .success { return app }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func run() {
        guard !running else { return }
        running = true
        Task {
            while let job = jobs.first {
                if job.typed == job.target {
                    if job.isFinal { jobs.removeFirst() } else { try? await Task.sleep(for: .milliseconds(15)) }
                    continue
                }
                if NSRunningApplication(processIdentifier: job.app) == nil {
                    jobs.removeFirst()   // the target app quit
                    continue
                }
                guard Self.focusedApp() == job.app else {
                    setWaiting(true)
                    try? await Task.sleep(for: .milliseconds(150))
                    continue
                }
                setWaiting(false)
                let common = zip(job.typed, job.target).prefix { $0 == $1 }.count
                if job.typed.count > common {
                    post(key: 51)   // backspace: one Unicode scalar
                    job.typed.removeLast()
                } else {
                    let chunk = Self.chunk(job.target[common...])
                    post(key: 49, text: chunk.flatMap { Array(String($0).utf16) })
                    job.typed.append(contentsOf: chunk)
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
            running = false
            isWaiting = false
            onChange?()
        }
    }

    private func setWaiting(_ waiting: Bool) {
        guard isWaiting != waiting else { return }
        isWaiting = waiting
        onChange?()
    }

    /// The next scalars to type: as many as fit in 20 UTF-16 units, the safe size for one key event.
    private static func chunk(_ scalars: ArraySlice<Unicode.Scalar>) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        var units = 0
        for scalar in scalars {
            units += String(scalar).utf16.count
            if units > 20 { break }
            result.append(scalar)
        }
        return result
    }

    /// Posts one key press. Modifier flags are cleared so a held Right Option does not change the meaning.
    private func post(key: CGKeyCode, text: [UniChar] = []) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = []
            if !text.isEmpty { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }
}
