import XCTest
import Darwin
@testable import VadicCore

final class EngineTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
    }

    func testServerRequestCarriesPromptAndLanguage() async throws {
        let dir = try tempDir()
        let wav = dir.appending(path: "a.wav")
        try Data([0, 1]).write(to: wav)
        let captured = Captured()
        StubProtocol.handler = { request in
            if request.url?.path == "/inference" {
                captured.body = request.bodyData
                return (200, Data(#"{"text":" Привет,\n мир.\n"}"#.utf8))
            }
            return (200, Data("ok".utf8))
        }
        let engine = WhisperEngine(config: engineConfig(dir: dir), language: "ru", prompt: "Qdrant, Herdr", session: .stubbed)

        let result = try await engine.transcribe(wav)

        XCTAssertEqual(result, Transcription(text: "Привет, мир.", engine: "server", fallbackReason: nil))
        let body = String(decoding: captured.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nQdrant, Herdr\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nru\r\n"))
        XCTAssertTrue(body.contains("filename=\"a.wav\""))
    }

    func testReconfigureAppliesToNextRequest() async throws {
        let dir = try tempDir()
        let wav = dir.appending(path: "a.wav")
        try Data([0, 1]).write(to: wav)
        let captured = Captured()
        StubProtocol.handler = { request in
            if request.url?.path == "/inference" { captured.body = request.bodyData }
            return (200, Data(#"{"text":"ok"}"#.utf8))
        }
        let engine = WhisperEngine(config: engineConfig(dir: dir), language: "ru", prompt: "Old", session: .stubbed)

        await engine.reconfigure(config: engineConfig(dir: dir), language: "en", prompt: "Qdrant")
        _ = try await engine.transcribe(wav)

        let body = String(decoding: captured.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nQdrant\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen\r\n"))
    }

    func testFallsBackToCLIAndReportsWhy() async throws {
        let dir = try tempDir()
        let wav = dir.appending(path: "a.wav")
        try Data([0, 1]).write(to: wav)
        StubProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        var config = engineConfig(dir: dir)
        config.cliBinary = try script(in: dir, #"printf ' из\n cli\n'"#)

        let result = try await WhisperEngine(config: config, language: "ru", prompt: "", session: .stubbed).transcribe(wav)

        XCTAssertEqual(result.text, "из cli")
        XCTAssertEqual(result.engine, "cli")
        XCTAssertNotNil(result.fallbackReason)
    }

    func testCLIGetsVadFlags() async throws {
        let dir = try tempDir()
        let wav = dir.appending(path: "a.wav")
        try Data([0, 1]).write(to: wav)
        StubProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let vad = dir.appending(path: "silero.bin")
        FileManager.default.createFile(atPath: vad.path, contents: Data())
        var config = engineConfig(dir: dir)
        config.vadModelPath = vad.path
        config.cliBinary = try script(in: dir, #"echo " $*""#)

        let result = try await WhisperEngine(config: config, language: "ru", prompt: "", session: .stubbed).transcribe(wav)

        XCTAssertTrue(result.text.contains("--vad -vm \(vad.path)"), result.text)
    }

    func testServerTimeoutGrowsWithRecording() async throws {
        let dir = try tempDir()
        let wav = dir.appending(path: "long.wav")
        try Data(count: 32_000 * 600).write(to: wav) // 10 minutes
        let engine = WhisperEngine(config: engineConfig(dir: dir), language: "ru", prompt: "")
        let timeout = await engine.timeout(for: wav)
        XCTAssertEqual(timeout, 5 + 600, accuracy: 0.01)
    }

    func testShutDownEngineStartsNothing() async throws {
        let dir = try tempDir()
        let wav = dir.appending(path: "a.wav")
        try Data([0, 1]).write(to: wav)
        StubProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let marker = dir.appending(path: "started")
        var config = engineConfig(dir: dir)
        config.startServer = true
        config.serverBinary = try script(in: dir, "touch '\(marker.path)'", name: "server.sh")
        config.cliBinary = try script(in: dir, "touch '\(marker.path)'", name: "cli.sh")
        let engine = WhisperEngine(config: config, language: "ru", prompt: "", session: .stubbed)

        await engine.shutdown()

        do {
            _ = try await engine.transcribe(wav)
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("shut down"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testShutdownDuringHealthProbeStartsNeitherServerNorCLI() async throws {
        for reachable in [false, true] {
            let dir = try tempDir()
            let wav = dir.appending(path: "a.wav")
            try Data([0, 1]).write(to: wav)
            let marker = dir.appending(path: "started")
            var config = engineConfig(dir: dir)
            config.startServer = true
            config.serverBinary = try script(in: dir, "touch '\(marker.path)'", name: "server.sh")
            config.cliBinary = try script(in: dir, "touch '\(marker.path)'", name: "cli.sh")
            let probeStarted = expectation(description: "health probe started")
            let releaseProbe = DispatchSemaphore(value: 0)
            StubProtocol.handler = { _ in
                probeStarted.fulfill()
                guard releaseProbe.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
                if reachable { return (200, Data("ok".utf8)) }
                throw URLError(.cannotConnectToHost)
            }
            let engine = WhisperEngine(config: config, language: "ru", prompt: "", session: .stubbed)
            let transcription = Task { try await engine.transcribe(wav) }

            await fulfillment(of: [probeStarted], timeout: 5)
            await engine.shutdown()
            releaseProbe.signal()

            do {
                _ = try await transcription.value
                XCTFail("expected stopped engine error")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("shut down"), error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testShutdownStopsCLIThatIgnoresSIGTERM() async throws {
        let dir = try tempDir()
        let wav = dir.appending(path: "a.wav")
        try Data([0, 1]).write(to: wav)
        let pidFile = dir.appending(path: "cli.pid")
        var config = engineConfig(dir: dir)
        config.cliBinary = try script(in: dir, "trap '' TERM\nprintf '%s' \"$$\" > '\(pidFile.path)'\nexec /bin/sleep 30")
        StubProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let engine = WhisperEngine(config: config, language: "ru", prompt: "", session: .stubbed)
        let transcription = Task { try await engine.transcribe(wav) }
        let deadline = Date().addingTimeInterval(5)
        var pid: Int32?
        while Date() < deadline {
            if let contents = try? String(contentsOf: pidFile, encoding: .utf8), let value = Int32(contents) {
                pid = value
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let pid else {
            await engine.shutdown()
            _ = try? await transcription.value
            XCTFail("CLI did not start")
            return
        }
        await engine.shutdown()

        XCTAssertEqual(kill(pid, 0), -1, "CLI must have exited before shutdown returns")
        do {
            _ = try await transcription.value
            XCTFail("expected stopped engine error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("shut down"), error.localizedDescription)
        }
    }

    func testErrorNamesBothCauses() async throws {
        let dir = try tempDir()
        let wav = dir.appending(path: "a.wav")
        try Data([0, 1]).write(to: wav)
        StubProtocol.handler = { request in
            request.url?.path == "/inference" ? (500, Data(#"{"error":"bad audio"}"#.utf8)) : (200, Data())
        }
        var config = engineConfig(dir: dir)
        config.cliBinary = try script(in: dir, "echo 'model load failed' >&2; exit 3")

        do {
            _ = try await WhisperEngine(config: config, language: "ru", prompt: "", session: .stubbed).transcribe(wav)
            XCTFail("expected error")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("bad audio"), message)
            XCTAssertTrue(message.contains("model load failed"), message)
        }
    }

    /// R4 against a real whisper-server: VADIC_IT=1 swift test --filter testVocabularyOnRealServer
    func testVocabularyOnRealServer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VADIC_IT"] == "1", "set VADIC_IT=1")
        let dir = try tempDir()
        var config = Config.defaults(paths: .standard)
        config.engine.serverURL = URL(string: "http://127.0.0.1:8179")!
        let wav = Bundle.module.url(forResource: "Fixtures/vocabulary-ru", withExtension: "wav")!
        let engine = WhisperEngine(config: config.engine, language: "ru", prompt: config.prompt, serverLog: dir.appending(path: "s.log"))
        defer { Task { await engine.shutdown() } }

        let result = try await engine.transcribe(wav)

        XCTAssertEqual(result.engine, "server", result.fallbackReason ?? "")
        XCTAssertTrue(result.text.contains("dependency-cruiser"), result.text)
        XCTAssertTrue(result.text.contains("Qdrant"), result.text)
    }

    private func engineConfig(dir: URL) -> EngineConfig {
        let model = dir.appending(path: "model.bin")
        FileManager.default.createFile(atPath: model.path, contents: Data())
        return EngineConfig(serverURL: URL(string: "http://127.0.0.1:65530")!, startServer: false,
                            serverBinary: "/nonexistent", cliBinary: "/nonexistent",
                            modelPath: model.path, timeoutSec: 5)
    }

    private func script(in dir: URL, _ body: String, name: String = "fake-cli.sh") throws -> String {
        let url = dir.appending(path: name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}

private final class Captured: @unchecked Sendable {
    var body: Data?
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.cannotConnectToHost) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

private extension URLRequest {
    /// Upload bodies reach URLProtocol as a stream.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

extension URLSession {
    static let stubbed: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }()
}
