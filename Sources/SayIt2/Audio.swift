import AVFoundation

/// The microphones macOS offers for recording.
enum Microphones {
    static var all: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static var systemDefault: AVCaptureDevice? { AVCaptureDevice.default(for: .audio) }
}

/// Microphone capture, delivered as mono PCM16 at the provider's rate.
///
/// Input only, through AVCaptureSession, like the browser engines the ChatGPT and Claude apps
/// record with. (AVAudioEngine also drives the output side: with Bluetooth headphones as both
/// speaker and microphone, it kept flipping the headset between modes and recorded nothing.)
/// macOS converts to the wire format itself, so there is no separate conversion step.
final class Mic: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// PCM bytes plus a 0...1 voice level, delivered on the main queue.
    var onAudio: ((Data, Float) -> Void)?
    /// The recording device went away and capture moved to this one. On the main queue.
    var onSwitched: ((String) -> Void)?
    /// The microphone stopped working and no other was available. On the main queue.
    var onInterrupted: (() -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "sayit2.microphone")
    private var observers: [NSObjectProtocol] = []

    /// Records from `device`, or from the system default when it is nil.
    func start(sampleRate: Double, device: AVCaptureDevice?) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw Problem(message: "Allow microphone access", retryable: false)
        }
        guard let device = device ?? Microphones.systemDefault else { throw Problem(message: "No microphone", retryable: false) }
        try use(device)
        let output = AVCaptureAudioDataOutput()
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
                self?.disconnected(note.object as? AVCaptureDevice)
            },
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] _ in
                self?.onInterrupted?()
            },
        ]
        queue.async { [session] in session.startRunning() }   // can take a moment; keep the main thread free
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        queue.async { [session] in session.stopRunning() }
    }

    private func use(_ device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw Problem(message: "Microphone unavailable", retryable: false)
        }
        session.addInput(input)
    }

    /// The device in use was unplugged: carry on with the system default instead of ending.
    private func disconnected(_ device: AVCaptureDevice?) {
        guard let current = (session.inputs.first as? AVCaptureDeviceInput)?.device, device == current else { return }
        guard let fallback = Microphones.systemDefault, fallback != current, (try? use(fallback)) != nil else {
            onInterrupted?()
            return
        }
        log.notice("microphone disconnected, switched to the system default")
        onSwitched?(fallback.localizedName)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let copied = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr, !data.isEmpty else { return }
        let energy = data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Int16.self).reduce(Float(0)) { sum, sample in
                let value = Float(sample) / 32768
                return sum + value * value
            }
        }
        let decibels = 10 * log10(max(energy / Float(data.count / 2), 1e-10))
        let level = min(max((decibels + 55) / 40, 0), 1)
        DispatchQueue.main.async { [weak self] in self?.onAudio?(data, level) }
    }
}
