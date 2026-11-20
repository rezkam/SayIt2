import AVFoundation
import CoreAudio

/// An input device as macOS lists it.
struct Microphone {
    let id: AudioDeviceID
    let name: String

    /// Every device that can record, in the order macOS lists them.
    static func all() -> [Microphone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var count: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &count) == noErr, count > 0 else { return nil }
            return name(of: id).map { Microphone(id: id, name: $0) }
        }
    }

    /// The device macOS records from by default.
    static func systemDefault() -> Microphone? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return name(of: id).map { Microphone(id: id, name: $0) }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
}

/// Microphone capture with exactly one conversion: hardware format to mono PCM16 at the provider's rate.
final class Mic {
    /// PCM bytes plus a 0...1 voice level, delivered on the main queue.
    var onAudio: ((Data, Float) -> Void)?
    /// The microphone stopped working and could not be restarted. The recording cannot continue.
    var onInterrupted: (() -> Void)?

    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var sampleRate: Double = 0
    private var device: AudioDeviceID?
    private var restarts = 0

    /// Records from `device`, or from the system default when it is nil.
    func start(sampleRate: Double, device: AudioDeviceID?) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw Problem(message: "Allow microphone access", retryable: false)
        }
        self.sampleRate = sampleRate
        self.device = device
        // macOS reports a configuration change when the device's format changes, for example
        // when Bluetooth headphones switch to their headset mode as recording starts. That is
        // not the end of the recording: capture restarts with the new format and carries on.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restart() }
        do {
            try capture()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func restart() {
        guard observer != nil else { return }
        restarts += 1
        log.notice("microphone configuration changed, restart \(self.restarts)")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            guard restarts <= 3 else { throw Problem(message: "Microphone keeps changing") }
            try capture()
        } catch {
            log.notice("microphone could not be restarted")
            onInterrupted?()
        }
    }

    /// Points the engine at the device, converts its current format, and starts it.
    private func capture() throws {
        let input = engine.inputNode
        if var device, let unit = input.audioUnit {
            let size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, size) == noErr
            else { throw Problem(message: "Microphone unavailable", retryable: false) }
        }
        let sampleRate = sampleRate
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
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw Problem(message: "Microphone unavailable", retryable: false)
        }
    }
}
