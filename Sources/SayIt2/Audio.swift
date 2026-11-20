import AVFoundation

/// The microphones macOS offers for recording.
enum Microphones {
    static var all: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static var systemDefault: AVCaptureDevice? { AVCaptureDevice.default(for: .audio) }
}

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

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "sayit2.microphone")
    private var observers: [NSObjectProtocol] = []
    // Health, on the main queue.
    private var started = Date()
    private var lastAudio: Date?
    private var silentSince: Date?
    private var warnedSilent = false
    private var recoveries = 0

    /// Records from `device`, or from the system default when it is nil.
    func start(sampleRate: Double, device: AVCaptureDevice?) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw Problem(message: "Allow microphone access", retryable: false)
        }
        guard let device = device ?? Microphones.systemDefault else { throw Problem(message: "No microphone", retryable: false) }
        try use(device)
        let output = AVCaptureAudioDataOutput()
        // macOS delivers exactly the wire format: the provider's rate, mono, 16-bit.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw Problem(message: "Microphone unavailable", retryable: false) }
        session.addOutput(output)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main) { [weak self] note in
                guard let self, note.object as? AVCaptureDevice == self.current else { return }
                self.recover(because: "Microphone disconnected")
            },
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] _ in
                self?.recover(because: "Microphone stopped")
            },
        ]
        started = Date()
        log.notice("recording from the \(Self.kind(of: device), privacy: .public) microphone")
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
            log.notice("microphone silent")
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

    private var current: AVCaptureDevice? { (session.inputs.first as? AVCaptureDeviceInput)?.device }

    private func use(_ device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw Problem(message: "Microphone unavailable", retryable: false)
        }
        session.addInput(input)
    }

    /// Keeps recording: moves to the system default, or restarts the same device if it is the
    /// default. Gives up after two attempts in one dictation.
    private func recover(because reason: String) {
        recoveries += 1
        log.notice("\(reason, privacy: .public), recovery \(self.recoveries)")
        guard recoveries <= 2 else {
            onInterrupted?()
            return
        }
        let fallback = Microphones.systemDefault
        if let fallback, fallback != current, (try? use(fallback)) != nil {
            log.notice("switched to the system default: \(Self.kind(of: fallback), privacy: .public)")
        }
        started = Date()
        lastAudio = nil
        queue.async { [session] in
            session.stopRunning()
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
