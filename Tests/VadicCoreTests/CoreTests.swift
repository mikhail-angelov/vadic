import XCTest
@testable import VadicCore

final class ConfigTests: XCTestCase {
    func testFirstLoadWritesDefaultsAndRoundTrips() throws {
        let dir = try tempDir()
        let paths = Paths(root: dir, voiceInkModels: dir.appending(path: "none"))
        let defaults = Config.defaults(paths: paths)

        let loaded = try ConfigStore.load(from: paths.config, defaults: defaults)
        XCTAssertEqual(loaded, defaults)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.config.path))

        var changed = loaded
        changed.insertMode = .paste
        changed.vocabulary = ["Qdrant"]
        try ConfigStore.save(changed, to: paths.config)
        XCTAssertEqual(try ConfigStore.load(from: paths.config, defaults: defaults), changed)
    }

    func testMissingKeysFallBackToDefaults() throws {
        let dir = try tempDir()
        let defaults = Config.defaults(paths: Paths(root: dir, voiceInkModels: dir))
        let url = dir.appending(path: "c.json")
        try Data(#"{"hotkey":"rightCommand","engine":{"timeoutSec":5}}"#.utf8).write(to: url)

        let loaded = try ConfigStore.load(from: url, defaults: defaults)

        XCTAssertEqual(loaded.hotkey, .rightCommand)
        XCTAssertEqual(loaded.engine.timeoutSec, 5)
        XCTAssertEqual(loaded.engine.serverURL, defaults.engine.serverURL)
        XCTAssertEqual(loaded.muteWhileRecording, defaults.muteWhileRecording)
    }

    func testPromptIsStyleSentencePlusVocabulary() throws {
        let dir = try tempDir()
        var config = Config.defaults(paths: Paths(root: dir, voiceInkModels: dir))
        config.stylePrompt = "Здравствуйте."
        config.vocabulary = ["Structurizr", "Qdrant"]
        XCTAssertEqual(config.prompt, "Здравствуйте. Structurizr, Qdrant.")
        config.vocabulary = []
        XCTAssertEqual(config.prompt, "Здравствуйте.")
        config.stylePrompt = ""
        XCTAssertEqual(config.prompt, "")
    }

    func testDefaultModelPrefersOursThenVoiceInk() throws {
        let dir = try tempDir()
        let paths = Paths(root: dir.appending(path: "Vadic"), voiceInkModels: dir.appending(path: "VoiceInk"))
        let ours = paths.models.appending(path: RemoteModel.whisperTurbo.fileName).path
        let voiceInk = paths.voiceInkModels.appending(path: RemoteModel.whisperTurbo.fileName).path
        XCTAssertEqual(Config.defaults(paths: paths).engine.modelPath, ours, "nothing on disk: ours gets downloaded")

        try FileManager.default.createDirectory(at: paths.voiceInkModels, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: voiceInk, contents: Data())
        XCTAssertEqual(Config.defaults(paths: paths).engine.modelPath, voiceInk)

        try FileManager.default.createDirectory(at: paths.models, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: ours, contents: Data())
        XCTAssertEqual(Config.defaults(paths: paths).engine.modelPath, ours)
    }
}

final class DictationTests: XCTestCase {
    func testStateCycleAndNoOverlap() {
        var sm = DictationStateMachine()
        XCTAssertTrue(sm.startRecording())
        XCTAssertFalse(sm.startRecording(), "second recording must not start")
        XCTAssertTrue(sm.stopRecording())
        XCTAssertEqual(sm.state, .processing)
        XCTAssertFalse(sm.startRecording(), "no recording while processing")
        sm.finishProcessing()
        XCTAssertEqual(sm.state, .idle)
    }

    func testCancelReturnsToIdle() {
        var sm = DictationStateMachine()
        XCTAssertFalse(sm.cancelRecording())
        XCTAssertTrue(sm.startRecording())
        XCTAssertTrue(sm.cancelRecording())
        XCTAssertEqual(sm.state, .idle)
        XCTAssertFalse(sm.stopRecording())
    }

    func testAudioGate() {
        XCTAssertEqual(AudioGate.evaluate(durationSec: 0.1, peakDb: -10, minDurationSec: 0.3, thresholdDb: -45), .tooShort)
        XCTAssertEqual(AudioGate.evaluate(durationSec: 2, peakDb: -60, minDurationSec: 0.3, thresholdDb: -45), .silent)
        XCTAssertEqual(AudioGate.evaluate(durationSec: 2, peakDb: -20, minDurationSec: 0.3, thresholdDb: -45), .accept)
    }

    func testReplacerFixesKnownMisrecognitions() {
        let rules = [
            Replacement(from: ["строкчуризр", "строк чурезер"], to: "Structurizr"),
            Replacement(from: ["qdrant", "гдрент"], to: "Qdrant"),
            Replacement(from: ["dependency cruiser", "депенденси крузер"], to: "dependency-cruiser"),
        ]
        let text = "Открываю Строк Чурезер и гдрент, qdrant уже, смотрю Депенденси-крузер и dependency cruiser."
        XCTAssertEqual(Replacer.apply(rules, to: text),
                       "Открываю Structurizr и Qdrant, Qdrant уже, смотрю dependency-cruiser и dependency-cruiser.")
    }

    func testReplacerMatchesWholeWordsOnly() {
        let rules = [Replacement(from: ["кот"], to: "Cat")]
        XCTAssertEqual(Replacer.apply(rules, to: "кот, котёл, скот"), "Cat, котёл, скот")
        XCTAssertEqual(Replacer.apply([Replacement(from: ["a$b"], to: "$1")], to: "x a$b y"), "x $1 y")
    }

    func testNormalizeJoinsSplitSegments() {
        // Real whisper-server output for the vocabulary fixture.
        let raw = " Проверка диктовки.\n Открываю строкчуризр и Qdrant, потом смотрю dependency-cru\niser.\n"
        XCTAssertEqual(Transcript.normalize(raw), "Проверка диктовки. Открываю строкчуризр и Qdrant, потом смотрю dependency-cruiser.")
        XCTAssertEqual(Transcript.normalize(" [BLANK_AUDIO]\n"), "")
    }
}

final class HistoryStoreTests: XCTestCase {
    func testSavesAudioTextAndMeta() throws {
        let dir = try tempDir()
        let audio = try fakeAudio(in: dir)
        let folder = try HistoryStore(root: dir.appending(path: "History")).save(entry(text: "привет", error: nil), audio: audio, keepAudio: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "audio.wav").path))
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "text.txt"), encoding: .utf8), "привет")
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "meta.json"))) as! [String: Any]
        XCTAssertEqual(meta["engine"] as? String, "server")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testDropsAudioWhenDisabledButKeepsItOnError() throws {
        let dir = try tempDir()
        let store = HistoryStore(root: dir.appending(path: "History"))

        let ok = try store.save(entry(text: "ok", error: nil), audio: try fakeAudio(in: dir), keepAudio: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ok.appending(path: "audio.wav").path))

        var failed = entry(text: nil, error: "boom")
        failed.date = Date().addingTimeInterval(1)
        let bad = try store.save(failed, audio: try fakeAudio(in: dir), keepAudio: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.appending(path: "audio.wav").path))
    }

    func testFailedHistoryWritesPreserveSourceAudio() throws {
        let dir = try tempDir()
        let store = HistoryStore(root: dir.appending(path: "History"))
        for filename in ["text.txt", "meta.json"] {
            let e = entry(text: "привет", error: nil)
            let folder = store.root.appending(path: HistoryStore.folderName(for: e.date))
            // A directory in place of either output file forces a real filesystem write failure.
            try FileManager.default.createDirectory(at: folder.appending(path: filename), withIntermediateDirectories: true)
            let audio = try fakeAudio(in: dir)

            XCTAssertThrowsError(try store.save(e, audio: audio, keepAudio: false))
            XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2, 3]))
            try FileManager.default.removeItem(at: folder)
        }
    }

    func testPruneDropsOldAudioThenOldEntries() throws {
        let dir = try tempDir()
        let store = HistoryStore(root: dir.appending(path: "History"))
        let now = Date()
        func make(daysAgo: Double) throws -> URL {
            var e = entry(text: "t", error: nil)
            e.date = now.addingTimeInterval(-daysAgo * 86_400)
            return try store.save(e, audio: try fakeAudio(in: dir), keepAudio: true)
        }
        let fresh = try make(daysAgo: 0.5)
        let older = try make(daysAgo: 3)
        let ancient = try make(daysAgo: 40)

        store.prune(audioDays: 1, historyDays: 30, now: now)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: fresh.appending(path: "audio.wav").path))
        XCTAssertFalse(fm.fileExists(atPath: older.appending(path: "audio.wav").path))
        XCTAssertTrue(fm.fileExists(atPath: older.appending(path: "text.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: ancient.path))
    }

    private func entry(text: String?, error: String?) -> HistoryEntry {
        HistoryEntry(date: Date(), durationSec: 1.5, text: text, engine: "server", model: "m.bin",
                     insertMode: .paste, inserted: true, frontApp: "com.apple.TextEdit", error: error)
    }

    private func fakeAudio(in dir: URL) throws -> URL {
        let url = dir.appending(path: "\(UUID().uuidString).wav")
        try Data([1, 2, 3]).write(to: url)
        return url
    }
}

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "vadic-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
