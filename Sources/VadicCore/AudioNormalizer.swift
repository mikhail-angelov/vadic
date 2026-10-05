import Accelerate
import AVFoundation

public enum AudioNormalizer {
    /// Scales a recording in place so its peak sits just below full scale. Whisper drops quiet words:
    /// on real dictations peaking at -13…-24 dBFS it lost whole phrases that it recognized once normalized.
    public static func normalize(_ url: URL, targetPeak: Float = 0.99) throws {
        guard let normalized = try normalizedCopy(of: url, targetPeak: targetPeak) else { return }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: normalized)
    }

    /// Writes the scaled audio next to `url`; nil for an empty or fully silent file.
    private static func normalizedCopy(of url: URL, targetPeak: Float) throws -> URL? {
        let input = try AVAudioFile(forReading: url)
        guard input.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length))
        else { return nil }
        try input.read(into: buffer)
        guard let channels = buffer.floatChannelData else { return nil }

        let count = vDSP_Length(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var peak: Float = 0
        for channel in 0..<channelCount {
            var channelPeak: Float = 0
            vDSP_maxmgv(channels[channel], 1, &channelPeak, count)
            peak = max(peak, channelPeak)
        }
        guard peak > 0 else { return nil }
        var gain = targetPeak / peak
        for channel in 0..<channelCount {
            vDSP_vsmul(channels[channel], 1, &gain, channels[channel], 1, count)
        }

        let output = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: output, settings: input.fileFormat.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return output
    }
}
