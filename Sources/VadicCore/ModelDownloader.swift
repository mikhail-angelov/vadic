import CryptoKit
import Foundation

/// A model file the app fetches on first launch instead of shipping it inside the bundle.
public struct RemoteModel: Equatable, Sendable {
    public let fileName: String
    public let url: URL
    public let sha256: String
    public let size: Int64

    public static let whisperTurbo = RemoteModel(
        fileName: "ggml-large-v3-turbo-q5_0.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        size: 574_041_195
    )

    public static let sileroVAD = RemoteModel(
        fileName: "ggml-silero-v5.1.2.bin",
        url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
        sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
        size: 885_098
    )

    public static let catalog = [whisperTurbo, sileroVAD]
}

public enum ModelDownloader {
    /// Catalog models the config points at inside `directory` that aren't there yet.
    /// Paths elsewhere are the user's own files and are never downloaded.
    public static func missing(for config: EngineConfig, in directory: URL) -> [RemoteModel] {
        [config.modelPath, config.vadModelPath].compactMap { $0 }.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard !FileManager.default.fileExists(atPath: path),
                  url.deletingLastPathComponent().resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path
            else { return nil }
            return RemoteModel.catalog.first { $0.fileName == url.lastPathComponent }
        }
    }

    /// Downloads into `directory`, checking the SHA-256 before the file takes its final name.
    /// `progress` gets 0…1 at most once per whole percent. Cancelling the task cancels the download.
    public static func download(_ model: RemoteModel, to directory: URL,
                                configuration: URLSessionConfiguration = .default,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = try await fetch(model, configuration: configuration, progress: progress)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard try sha256(of: temp) == model.sha256 else {
            throw EngineError("\(model.fileName): checksum mismatch, the file is corrupt")
        }
        let destination = directory.appending(path: model.fileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    /// The async `download(from:delegate:)` never reports bytes written, so progress needs a session delegate.
    private static func fetch(_ model: RemoteModel, configuration: URLSessionConfiguration,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(model: model, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: model.url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// URLSession calls its delegate serially, so the state needs no lock.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var continuation: CheckedContinuation<URL, Error>?
    private let model: RemoteModel
    private let progress: @Sendable (Double) -> Void
    private var lastPercent = -1
    private var result: Result<URL, Error>?

    init(model: RemoteModel, progress: @escaping @Sendable (Double) -> Void) {
        self.model = model
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.size
        let fraction = min(1, Double(totalBytesWritten) / Double(max(total, 1)))
        let percent = Int(fraction * 100)
        guard percent != lastPercent else { return }
        lastPercent = percent
        progress(fraction)
    }

    /// The system deletes `location` when this returns, so the file is moved out first.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            result = .failure(EngineError("\(model.fileName): HTTP \(status)"))
            return
        }
        let kept = FileManager.default.temporaryDirectory.appending(path: "vadic-\(UUID().uuidString)-\(model.fileName)")
        result = Result { try FileManager.default.moveItem(at: location, to: kept); return kept }
        if lastPercent < 100 { progress(1) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(with: result ?? .failure(EngineError("\(model.fileName): empty response")))
        }
        continuation = nil
    }
}
