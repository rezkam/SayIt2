import AVFoundation

/// Microphone capture with exactly one conversion: hardware format to mono PCM16 at the provider's rate.
final class Mic {
    /// PCM bytes plus a 0...1 voice level, delivered on the main queue.
    var onAudio: ((Data, Float) -> Void)?
    /// The input device changed or disappeared. The recording cannot continue.
    var onInterrupted: (() -> Void)?

    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    func start(sampleRate: Double) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw Problem(message: "Allow microphone access", retryable: false)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: wire)
        else { throw Problem(message: "No microphone", retryable: false) }

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / format.sampleRate) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return }
            var consumed = false
            converter.convert(to: output, error: nil) { _, status in
                status.pointee = consumed ? .noDataNow : .haveData
                defer { consumed = true }
                return consumed ? nil : buffer
            }
            let count = Int(output.frameLength)
            guard count > 0, let samples = output.int16ChannelData?[0] else { return }
            var energy: Float = 0
            for index in 0..<count {
                let sample = Float(samples[index]) / 32768
                energy += sample * sample
            }
            let decibels = 10 * log10(max(energy / Float(count), 1e-10))
            let level = min(max((decibels + 55) / 40, 0), 1)
            let data = Data(bytes: samples, count: count * 2)
            DispatchQueue.main.async { self?.onAudio?(data, level) }
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.onInterrupted?() }

        engine.prepare()
        do { try engine.start() } catch {
            stop()
            throw Problem(message: "Microphone unavailable", retryable: false)
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
