import AVFoundation
import VadicCore

struct Recording {
    let url: URL
    let durationSec: Double
    let peakDb: Float
}

/// Writes 16 kHz mono s16 WAV — exactly what whisper accepts, no conversion step.
@MainActor
final class Recorder {
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var peakDb: Float = -160
    /// Current input level, 0…1, about 20 times a second.
    var onLevel: (Float) -> Void = { _ in }

    func start(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw EngineError("could not start recording from the microphone") }
        self.recorder = recorder
        peakDb = -160
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleMeter() }
        }
    }

    func stop() -> Recording? {
        guard let recorder else { return nil }
        sampleMeter()
        let duration = recorder.currentTime
        recorder.stop()
        reset()
        return Recording(url: recorder.url, durationSec: duration, peakDb: peakDb)
    }

    func cancel() {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        reset()
    }

    private func sampleMeter() {
        guard let recorder else { return }
        recorder.updateMeters()
        peakDb = max(peakDb, recorder.peakPower(forChannel: 0))
        // -50 dB…0 dB mapped onto 0…1; speech sits around -30…-10.
        onLevel(min(1, max(0, (recorder.averagePower(forChannel: 0) + 50) / 50)))
    }

    private func reset() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
    }
}
