import AVFoundation
import CryptoKit
import XCTest
@testable import VadicCore

final class AudioNormalizerTests: XCTestCase {
    func testQuietRecordingIsRaisedToNearFullScale() throws {
        let url = try writeWav(fromFixtureScaledBy: 0.05)
        XCTAssertLessThan(try peak(of: url), 0.1)

        try AudioNormalizer.normalize(url)

        XCTAssertEqual(try peak(of: url), 0.99, accuracy: 0.01)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
    }

    func testSilenceIsLeftAlone() throws {
        let url = try writeWav(fromFixtureScaledBy: 0)
        let before = try Data(contentsOf: url)
        try AudioNormalizer.normalize(url)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    private func writeWav(fromFixtureScaledBy scale: Float) throws -> URL {
        let input = try AVAudioFile(forReading: Bundle.module.url(forResource: "Fixtures/vocabulary-ru", withExtension: "wav")!)
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length))!
        try input.read(into: buffer)
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] *= scale }
        let url = try tempDir().appending(path: "quiet.wav")
        let output = try AVAudioFile(forWriting: url, settings: input.fileFormat.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try output.write(from: buffer)
        return url
    }

    private func peak(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (0..<Int(buffer.frameLength)).reduce(0) { max($0, abs(buffer.floatChannelData![0][$1])) }
    }
}

final class ModelDownloaderTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
    }

    func testMissingListsOnlyCatalogFilesInOurDirectory() throws {
        let dir = try tempDir()
        var config = Config.defaults(paths: Paths(root: dir, voiceInkModels: dir)).engine
        config.modelPath = dir.appending(path: "Models/\(RemoteModel.whisperTurbo.fileName)").path
        config.vadModelPath = dir.appending(path: "Models/\(RemoteModel.sileroVAD.fileName)").path
        let models = dir.appending(path: "Models")
        XCTAssertEqual(ModelDownloader.missing(for: config, in: models), [.whisperTurbo, .sileroVAD])

        config.modelPath = "/elsewhere/\(RemoteModel.whisperTurbo.fileName)"
        config.vadModelPath = nil
        XCTAssertEqual(ModelDownloader.missing(for: config, in: models), [], "user's own paths are never downloaded")

        config.vadModelPath = models.appending(path: RemoteModel.sileroVAD.fileName).path
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: config.vadModelPath!, contents: Data())
        XCTAssertEqual(ModelDownloader.missing(for: config, in: models), [])
    }

    func testDownloadVerifiesChecksumBeforePlacingFile() async throws {
        let payload = Data("model-bytes".utf8)
        StubProtocol.handler = { _ in (200, payload) }
        let dir = try tempDir()
        let good = model(sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(), size: payload.count)

        try await ModelDownloader.download(good, to: dir, configuration: .stubbed)

        XCTAssertEqual(try Data(contentsOf: dir.appending(path: good.fileName)), payload)
    }

    func testCorruptDownloadIsRejected() async throws {
        StubProtocol.handler = { _ in (200, Data("truncated".utf8)) }
        let dir = try tempDir()
        let expected = model(sha256: String(repeating: "0", count: 64), size: 100)

        do {
            try await ModelDownloader.download(expected, to: dir, configuration: .stubbed)
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checksum"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: expected.fileName).path))
    }

    /// Real download of the small VAD model: VADIC_IT=1 swift test --filter testRealDownload
    func testRealDownload() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VADIC_IT"] == "1", "set VADIC_IT=1")
        let dir = try tempDir()
        let progress = ProgressLog()
        try await ModelDownloader.download(.sileroVAD, to: dir) { progress.append($0) }
        XCTAssertEqual(try ModelDownloader.sha256(of: dir.appending(path: RemoteModel.sileroVAD.fileName)), RemoteModel.sileroVAD.sha256)
        XCTAssertEqual(progress.values.last ?? 0, 1, accuracy: 0.001)
    }

    private func model(sha256: String, size: Int) -> RemoteModel {
        RemoteModel(fileName: "test.bin", url: URL(string: "https://example.invalid/test.bin")!, sha256: sha256, size: Int64(size))
    }
}

private extension URLSessionConfiguration {
    static var stubbed: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return config
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    var values: [Double] { lock.withLock { stored } }
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
}
