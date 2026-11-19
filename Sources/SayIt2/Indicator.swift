import AppKit

/// The black pill that rises at the bottom of the screen, just above the Dock, while SayIt 2 is listening.
@MainActor
final class Indicator {
    enum State: Equatable { case hidden, listening, handsFree, finishing, waiting }

    /// Voice level, 0...1.
    var level: Float = 0
    /// Called when a problem message has finished showing.
    var onMessageEnd: (() -> Void)?

    private let panel: NSPanel
    private let view = PillView()
    private var timer: Timer?
    private var energy: CGFloat = 0
    private var isShown = false

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
    }

    func show(_ state: State) {
        guard view.message == nil else { return view.state = state }
        view.state = state
        update()
    }

    /// Shows a short problem message for three seconds.
    func flash(_ message: String) {
        view.message = message
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.view.message == message else { return }
            self.view.message = nil
            self.update()
            self.onMessageEnd?()
        }
    }

    private func update() {
        let visible = view.state != .hidden || view.message != nil
        guard visible else { return hide() }
        guard let screen = NSScreen.main else { return }
        // Sit just above the Dock. With the Dock hidden or on a side, that is just above the screen's bottom edge.
        let size = view.fittingSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + 8,
                           width: size.width, height: size.height)
        if isShown {
            panel.setFrame(frame, display: true)
        } else {
            isShown = true
            panel.setFrame(frame.offsetBy(dx: 0, dy: -(size.height + 12)), display: true)   // rise from below
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.19
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.animate() }
            }
        }
        view.needsDisplay = true
    }

    private func hide() {
        guard isShown else { return }
        isShown = false
        timer?.invalidate()
        level = 0
        energy = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: -(panel.frame.height + 12)), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func animate() {
        energy += (CGFloat(level) - energy) * 0.35
        view.energy = energy
        view.time = CACurrentMediaTime()
        view.needsDisplay = true
    }
}

/// Draws the pill: five voice bars, a square while hands-free, or a problem message.
private final class PillView: NSView {
    var state: Indicator.State = .hidden
    var message: String?
    var energy: CGFloat = 0
    var time: CFTimeInterval = 0

    private let height: CGFloat = 30, padding: CGFloat = 12, gap: CGFloat = 8
    private let barWidth: CGFloat = 3, barGap: CGFloat = 2.5, square: CGFloat = 9
    private let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private var barsWidth: CGFloat { 5 * barWidth + 4 * barGap }

    override var fittingSize: NSSize {
        var width = padding * 2 + barsWidth
        if let message { width += gap + (message as NSString).size(withAttributes: [.font: font]).width }
        else if state == .handsFree { width += gap + square }
        return NSSize(width: ceil(width), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: height / 2, yRadius: height / 2)
        NSColor.black.setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()   // keeps the pill visible on dark backgrounds
        pill.lineWidth = 0.5
        pill.stroke()

        let rates: [Double] = [5.1, 7.3, 6.2, 8.4, 5.7], phases: [Double] = [0, 1.3, 2.1, 0.6, 2.9]
        for index in 0..<5 {
            var amount: CGFloat = 0, alpha: CGFloat = 1
            if message != nil {
                amount = 0
            } else if state == .finishing {
                amount = 0.1 + 0.5 * (0.5 + 0.5 * sin(time * 7 - Double(index) * 0.7))
                alpha = 0.75
            } else if state == .waiting {
                amount = 0.2
                alpha = 0.4
            } else {
                amount = 0.15 + 0.85 * abs(sin(time * rates[index] + phases[index])) * energy
            }
            let barHeight = 3 + 12 * amount
            let x = padding + CGFloat(index) * (barWidth + barGap)
            let bar = NSRect(x: x, y: (height - barHeight) / 2, width: barWidth, height: barHeight)
            (message != nil ? NSColor(red: 1, green: 0.42, blue: 0.34, alpha: 1) : NSColor.white.withAlphaComponent(alpha)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }

        let x = padding + barsWidth + gap
        if let message {
            let size = (message as NSString).size(withAttributes: [.font: font])
            (message as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2),
                                       withAttributes: [.font: font, .foregroundColor: NSColor.white])
        } else if state == .handsFree {
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: (height - square) / 2, width: square, height: square), xRadius: 2.5, yRadius: 2.5).fill()
        }
    }
}
