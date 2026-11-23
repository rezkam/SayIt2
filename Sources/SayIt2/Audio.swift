import AVFoundation
import OpenTelemetryApi

/// Microphone capture, delivered as mono PCM16 at the provider's rate, with a health watch that
/// keeps the recording going when the device misbehaves.
///
/// This follows how the ChatGPT and Claude apps record through their browser engine: input-only
/// capture (AVCaptureSession here; AVAudioEngine also drives the output side and recorded nothing
/// from Bluetooth headphones), a fallback to the system default, and a watch on whether the
/// microphone is live, silent, or lost. Audio is sent as captured: Apple's voice isolation made
/// the recognizers invent text from background noise.
final class Mic: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// PCM bytes plus a 0...1 voice level, on the main queue.
    var onAudio: ((Data, Float) -> Void)?
    /// A problem the user should know about, such as a muted microphone, on the main queue.
    var onNotice: ((String) -> Void)?
    /// The microphone stopped working and nothing could replace it, on the main queue.
    var onInterrupted: (() -> Void)?
    /// The dictation span to attach mic logs and events to.
    var span: Span?

    private let session = AVCaptureSession()
    /// Once the session runs, it is only touched on this queue: starting or stopping it while
    /// another thread changes its inputs raises an exception that ends the app.
    private let queue = DispatchQueue(label: "sayit2.microphone")
    private var observers: [NSObjectProtocol] = []
    /// The microphone recording, or about to after a recovery. On the main queue, for the
    /// disconnect notice.
    private var inUse: AVCaptureDevice?
    // Health, on the main queue.
    private var started = Date()
    private var lastAudio: Date?
    private var silentSince: Date?
    private var warnedSilent = false
    private var recoveries = 0

    /// Records from the system default microphone.
    func start(sampleRate: Double, span: Span? = nil) throws {
        self.span = span
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw Problem(message: "Allow microphone access", retryable: false, errorType: "mic_permission")
        }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw Problem(message: "No microphone", retryable: false, errorType: "no_microphone")
        }
        try use(device)
        inUse = device
        let kind = Self.kind(of: device)
        span?.setAttribute(key: "sayit2.mic.type", value: kind)
        let output = AVCaptureAudioDataOutput()
        // macOS delivers exactly the wire format: the provider's rate, mono, 16-bit.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw Problem(message: "Microphone unavailable", retryable: false, errorType: "mic_unavailable")
        }
        session.addOutput(output)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main) { [weak self] note in
                guard let self, note.object as? AVCaptureDevice == self.inUse else { return }
                self.recover(because: "Microphone disconnected")
            },
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] _ in
                self?.recover(because: "Microphone stopped")
            },
        ]
        started = Date()
        Telemetry.event("recording from the \(kind) microphone", span: span)
        queue.async { [session] in session.startRunning() }   // can take a moment; keep the main thread free
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        queue.async { [session] in session.stopRunning() }
    }

    /// Called regularly while recording. Lost means no audio for a while (3 s to get going at
    /// first, for Bluetooth headsets); silent means only exact zeros, such as a muted device.
    func checkHealth() {
        guard !observers.isEmpty else { return }
        let now = Date()
        if now.timeIntervalSince(lastAudio ?? started) > (lastAudio == nil ? 3 : 2) {
            recover(because: "Microphone not responding")
        } else if let silentSince, now.timeIntervalSince(silentSince) > 2, !warnedSilent {
            warnedSilent = true
            span?.addEvent(name: "mic_silent")
            Telemetry.event("microphone silent", severity: .warn, span: span)
            onNotice?("Microphone is muted or silent")
        }
    }

    /// The kind of device, for the log (device names are left out of it).
    private static func kind(of device: AVCaptureDevice) -> String {
        switch device.transportType {
        case Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn): "built-in"
        case Int32(bitPattern: kAudioDeviceTransportTypeBluetooth), Int32(bitPattern: kAudioDeviceTransportTypeBluetoothLE): "Bluetooth"
        case Int32(bitPattern: kAudioDeviceTransportTypeUSB): "USB"
        default: "other"
        }
    }

    /// The session's own view of its microphone, on `queue`.
    private var current: AVCaptureDevice? { (session.inputs.first as? AVCaptureDeviceInput)?.device }

    private func use(_ device: AVCaptureDevice) throws {
        let unavailable = Problem(message: "Microphone unavailable", retryable: false, errorType: "mic_unavailable")
        // Open the new microphone first: if it cannot be opened, the one in use stays.
        guard let input = try? AVCaptureDeviceInput(device: device) else { throw unavailable }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        guard session.canAddInput(input) else { throw unavailable }
        session.addInput(input)
    }

    /// Keeps recording: moves to the system default, or restarts the same device if it is the
    /// default. Gives up after two attempts in one dictation.
    private func recover(because reason: String) {
        recoveries += 1
        span?.setAttribute(key: "sayit2.mic.recoveries", value: recoveries)
        span?.addEvent(name: "mic_recovery", attributes: ["reason": .string(reason), "attempt": .int(recoveries)])
        Telemetry.event("\(reason), recovery \(self.recoveries)", severity: .warn, span: span)
        guard recoveries <= 2 else {
            span?.addEvent(name: "mic_interrupted")
            Telemetry.event("microphone lost after \(self.recoveries - 1) recoveries", severity: .error, span: span)
            onInterrupted?()
            return
        }
        let fallback = AVCaptureDevice.default(for: .audio)
        inUse = fallback ?? inUse
        started = Date()
        lastAudio = nil
        let activeSpan = span
        queue.async { [self] in
            session.stopRunning()
            if let fallback, fallback != current, (try? use(fallback)) != nil {
                let kind = Self.kind(of: fallback)
                activeSpan?.setAttribute(key: "sayit2.mic.type", value: kind)
                Telemetry.event("switched to the system default: \(kind)", severity: .warn, span: activeSpan)
            }
            session.startRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var pcm = Data(count: CMBlockBufferGetDataLength(block))
        guard !pcm.isEmpty, pcm.withUnsafeMutableBytes({ bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }) == kCMBlockBufferNoErr else { return }
        var energy: Float = 0
        var silent = true
        pcm.withUnsafeBytes { bytes in
            for sample in bytes.bindMemory(to: Int16.self) {
                if sample != 0 { silent = false }
                let value = Float(sample) / 32768
                energy += value * value
            }
        }
        let decibels = 10 * log10(max(energy / Float(pcm.count / 2), 1e-10))
        let level = min(max((decibels + 55) / 40, 0), 1)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastAudio = Date()
            self.silentSince = silent ? (self.silentSince ?? Date()) : nil
            self.onAudio?(pcm, level)
        }
    }
}
