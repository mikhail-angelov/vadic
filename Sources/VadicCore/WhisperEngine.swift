import Foundation
import Darwin

public struct EngineError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct Transcription: Equatable, Sendable {
    public let text: String
    public let engine: String
    /// Why the server was skipped when the CLI fallback produced the text.
    public let fallbackReason: String?
}

/// Keeps a `whisper-server` alive and transcribes through it, falling back to `whisper-cli`.
public actor WhisperEngine {
    public private(set) var config: EngineConfig
    private var language: String
    private var prompt: String
    private let session: URLSession
    private let serverLog: URL?
    private var server: ChildProcess?
    private var cli: ChildProcess?
    private var isShutDown = false

    public init(config: EngineConfig, language: String, prompt: String, session: URLSession = .shared, serverLog: URL? = nil) {
        self.config = config
        self.language = language
        self.prompt = prompt
        self.session = session
        self.serverLog = serverLog
    }

    public func transcribe(_ wav: URL) async throws -> Transcription {
        try checkRunning()
        let serverError: String
        do {
            try await ensureServer()
            return Transcription(text: try await viaServer(wav), engine: "server", fallbackReason: nil)
        } catch {
            serverError = error.localizedDescription
        }
        do {
            return Transcription(text: try await viaCLI(wav), engine: "cli", fallbackReason: serverError)
        } catch {
            throw EngineError("whisper-server: \(serverError); whisper-cli: \(error.localizedDescription)")
        }
    }

    public func ensureServer() async throws {
        try checkRunning()
        let reachable = await isServerReachable()
        // shutdown() may have run while we were suspended; never start a server nobody owns.
        try checkRunning()
        if reachable { return }
        guard config.startServer else {
            throw EngineError("\(config.serverURL.absoluteString) does not respond and startServer is off")
        }
        if server?.isRunning != true { try launchServer() }

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let reachable = await isServerReachable()
            try checkRunning()
            if reachable { return }
            if let server, !server.isRunning {
                throw EngineError("whisper-server exited with code \(server.terminationStatus), see \(serverLog?.path ?? "its log")")
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw EngineError("whisper-server did not start within 120 s")
    }

    /// Applies a new configuration. The server is restarted only when its own settings changed,
    /// so re-reading an unchanged config doesn't reload the model.
    public func reconfigure(config: EngineConfig, language: String, prompt: String) {
        if config != self.config || language != self.language {
            server?.stop()
            server = nil
        }
        self.config = config
        self.language = language
        self.prompt = prompt
    }

    /// Stops the server only if this engine started it, and any running CLI fallback.
    /// The engine refuses further work afterwards.
    public func shutdown() {
        isShutDown = true
        cli?.stop()
        cli = nil
        // Wait for exit so a restarted engine doesn't mistake the dying server for a live one.
        server?.stop()
        server = nil
    }

    private func isServerReachable() async -> Bool {
        let request = URLRequest(url: config.serverURL, timeoutInterval: 1)
        return (try? await session.data(for: request)) != nil
    }

    private func launchServer() throws {
        try checkExecutable(config.serverBinary)
        try checkModel()
        guard let host = config.serverURL.host(), let port = config.serverURL.port else {
            throw EngineError("serverURL needs a host and a port: \(config.serverURL.absoluteString)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.serverBinary)
        process.arguments = ["-m", config.modelPath, "--host", host, "--port", String(port), "-l", language] + (try vadArguments())
        if let serverLog {
            FileManager.default.createFile(atPath: serverLog.path, contents: nil)
            let handle = try FileHandle(forWritingTo: serverLog)
            process.standardOutput = handle
            process.standardError = handle
        }
        server = try ChildProcess(process)
    }

    private func viaServer(_ wav: URL) async throws -> String {
        try checkRunning()
        let boundary = "vadic-\(UUID().uuidString)"
        // The server sends nothing until it is done, so the timeout has to grow with the recording.
        var request = URLRequest(url: config.serverURL.appending(path: "inference"), timeoutInterval: timeout(for: wav))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var fields = [("response_format", "json"), ("language", language), ("temperature", "0")]
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }
        let body = try Multipart.body(boundary: boundary, fields: fields, file: wav)

        let (data, response) = try await session.upload(for: request, from: body)
        try checkRunning()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = try? JSONDecoder().decode(ServerReply.self, from: data)
        if let error = reply?.error { throw EngineError("server returned an error: \(error)") }
        guard status == 200, let text = reply?.text else {
            throw EngineError("HTTP \(status): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return Transcript.normalize(text)
    }

    /// `timeoutSec` plus the audio length (16 kHz mono s16 = 32 000 bytes/s): generous even for the CLI-speed path.
    func timeout(for wav: URL) -> TimeInterval {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int) ?? 0
        return config.timeoutSec + Double(bytes) / 32_000
    }

    private func viaCLI(_ wav: URL) async throws -> String {
        try checkRunning()
        guard cli == nil else { throw EngineError("whisper-cli is already transcribing") }
        try checkExecutable(config.cliBinary)
        try checkModel()
        var args = ["-m", config.modelPath, "-f", wav.path, "-l", language, "-nt", "-np"] + (try vadArguments())
        if !prompt.isEmpty { args += ["--prompt", prompt] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.cliBinary)
        process.arguments = args
        // Launch without suspending the actor: shutdown must see an already started child.
        let (child, output) = try ProcessRunner.start(process)
        cli = child
        defer { cli = nil }
        let result = await output.value
        try checkRunning()
        guard result.status == 0 else {
            throw EngineError("exit code \(result.status): \(result.stderr.suffix(300))")
        }
        return Transcript.normalize(result.stdout)
    }

    private func checkRunning() throws {
        if isShutDown { throw EngineError("engine is shut down") }
        try Task.checkCancellation()
    }

    private func checkExecutable(_ path: String) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw EngineError("\(path) not found (brew install whisper-cpp)")
        }
    }

    private func vadArguments() throws -> [String] {
        guard let vad = config.vadModelPath else { return [] }
        guard FileManager.default.fileExists(atPath: vad) else { throw EngineError("VAD model not found: \(vad)") }
        return ["--vad", "-vm", vad]
    }

    private func checkModel() throws {
        guard FileManager.default.fileExists(atPath: config.modelPath) else {
            throw EngineError("model not found: \(config.modelPath)")
        }
    }
}

private struct ServerReply: Decodable {
    let text: String?
    let error: String?
}

enum Multipart {
    static func body(boundary: String, fields: [(String, String)], file: URL) throws -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: file))
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

/// Owns a launched child and its exit notification; waiting does not depend on a thread's run loop.
final class ChildProcess: Sendable {
    private let process: Process
    private let exited = DispatchGroup()

    init(_ process: Process) throws {
        self.process = process
        exited.enter()
        let exited = exited
        process.terminationHandler = { _ in exited.leave() }
        do {
            try process.run()
        } catch {
            exited.leave()
            throw error
        }
    }

    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32 { process.terminationStatus }

    func waitUntilExit() { exited.wait() }

    /// Give a child two seconds to exit, then kill it so shutdown cannot wait forever.
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        if exited.wait(timeout: .now() + 2) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
    }
}

enum ProcessRunner {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// stderr goes to a temp file so a chatty tool cannot fill the pipe and deadlock.
    /// Starts synchronously; only draining output and waiting happen in the background.
    static func start(_ process: Process) throws -> (ChildProcess, Task<Result, Never>) {
        let errURL = FileManager.default.temporaryDirectory.appending(path: "vadic-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = Pipe()
        let errorHandle: FileHandle
        let child: ChildProcess
        do {
            errorHandle = try FileHandle(forWritingTo: errURL)
            process.standardOutput = out
            process.standardError = errorHandle
            child = try ChildProcess(process)
        } catch {
            try? FileManager.default.removeItem(at: errURL)
            throw error
        }
        let output = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    defer {
                        try? errorHandle.close()
                        try? out.fileHandleForReading.close()
                        try? FileManager.default.removeItem(at: errURL)
                    }
                    let stdout = out.fileHandleForReading.readDataToEndOfFile()
                    child.waitUntilExit()
                    let stderr = (try? Data(contentsOf: errURL)) ?? Data()
                    continuation.resume(returning: Result(
                        status: process.terminationStatus,
                        stdout: String(decoding: stdout, as: UTF8.self),
                        stderr: String(decoding: stderr, as: UTF8.self)
                    ))
                }
            }
        }
        return (child, output)
    }
}
