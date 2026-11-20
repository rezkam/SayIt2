import AVFoundation
import AudioToolbox

/// The microphones macOS offers for recording.
enum Microphones {
    static var all: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static var systemDefault: AVCaptureDevice? { AVCaptureDevice.default(for: .audio) }
}

/// Microphone capture, delivered as mono PCM16 at the provider's rate, with noise suppression and
/// gain control, and a health watch that keeps the recording going when the device misbehaves.
///
/// This follows how the ChatGPT and Claude apps record through their browser engine: input-only
/// capture (AVCaptureSession here; AVAudioEngine also drives the output side and recorded nothing
/// from Bluetooth headphones), then processing, a fallback to the system default, and a watch on
/// whether the microphone is live, silent, or lost.
final class Mic: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// PCM bytes plus a 0...1 voice level, on the main queue.
    var onAudio: ((Data, Float) -> Void)?
    /// Something the user should know, such as a device change, on the main queue.
    var onNotice: ((String) -> Void)?
    /// The microphone stopped working and nothing could replace it, on the main queue.
    var onInterrupted: (() -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "sayit2.microphone")
    private var cleaner: VoiceCleaner?
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
        cleaner = VoiceCleaner(sampleRate: sampleRate)
        let output = AVCaptureAudioDataOutput()
        // macOS converts to the provider's rate itself.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
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
            onNotice?("\(reason), using \(fallback.localizedName)")
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
        var raw = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
        guard !raw.isEmpty, raw.withUnsafeMutableBytes({ bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }) == kCMBlockBufferNoErr else { return }
        let silent = raw.allSatisfy { $0 == 0 }
        let samples = cleaner?.process(raw) ?? raw
        var energy: Float = 0
        var pcm = Data(count: samples.count * 2)
        pcm.withUnsafeMutableBytes { bytes in
            let out = bytes.bindMemory(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                energy += sample * sample
                out[index] = Int16((max(-1, min(1, sample)) * 32767).rounded())
            }
        }
        let decibels = 10 * log10(max(energy / Float(max(samples.count, 1)), 1e-10))
        let level = min(max((decibels + 55) / 40, 0), 1)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastAudio = Date()
            self.silentSince = silent ? (self.silentSince ?? Date()) : nil
            if !pcm.isEmpty { self.onAudio?(pcm, level) }
        }
    }
}

/// Noise suppression with Apple's voice isolation effect, then gain control, applied to captured
/// audio as it arrives. Background noise drops by about 45 dB while speech stays intact (measured);
/// the effect delays audio by about 60 ms. Returns nil if the effect is unavailable, in which case
/// raw audio is used.
final class VoiceCleaner {
    private let engine = AVAudioEngine()
    private let output: AVAudioPCMBuffer
    private var pending: [Float] = []
    private var cursor = 0
    private var gain: Float = 1

    init?(sampleRate: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return nil }
        self.output = output
        let isolation = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        let source = AVAudioSourceNode(format: format) { [unowned self] _, _, frames, list in
            let out = UnsafeMutableAudioBufferListPointer(list)[0].mData!.assumingMemoryBound(to: Float.self)
            for index in 0..<Int(frames) {
                out[index] = self.cursor < self.pending.count ? self.pending[self.cursor] : 0
                self.cursor += 1
            }
            return noErr
        }
        engine.attach(source)
        engine.attach(isolation)
        engine.connect(source, to: isolation, format: format)
        engine.connect(isolation, to: engine.mainMixerNode, format: format)
        do {
            // Offline rendering: no audio device is involved, the engine only runs the effect.
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try engine.start()
        } catch {
            log.notice("noise suppression unavailable")
            return nil
        }
    }

    func process(_ samples: [Float]) -> [Float] {
        pending = samples
        cursor = 0
        var result: [Float] = []
        while result.count < samples.count {
            let frames = AVAudioFrameCount(min(4096, samples.count - result.count))
            guard (try? engine.renderOffline(frames, to: output)) == .success else { return samples }
            result += UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
        }
        // Gain control: move slowly toward a steady speech level (about -20 dBFS), between half
        // and eight times, only while there is speech, so silence is not pumped up.
        let level = sqrt(result.reduce(0) { $0 + $1 * $1 } / Float(max(result.count, 1)))
        if level > 0.003 { gain += (min(max(0.1 / level, 0.5), 8) - gain) * 0.05 }
        return result.map { max(-1, min(1, $0 * gain)) }
    }
}
