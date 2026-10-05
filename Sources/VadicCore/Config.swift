import Foundation

public enum InsertMode: String, Codable, Sendable {
    /// type: synthesized keystrokes, the clipboard is never touched; paste: Cmd+V, clipboard restored;
    /// clipboard: text is only put on the clipboard.
    case type, paste, clipboard
}

public enum HotkeyKey: String, Codable, Sendable {
    case rightOption, rightCommand, rightControl, fn
}

public struct EngineConfig: Codable, Equatable, Sendable {
    public var serverURL: URL
    public var startServer: Bool
    public var serverBinary: String
    public var cliBinary: String
    public var modelPath: String
    public var timeoutSec: Double
    /// Silero VAD model (ggml-silero-*.bin). When set, whisper skips non-speech parts.
    public var vadModelPath: String?
}

/// Fixes what the model keeps getting wrong: any of `from` (case-insensitive, whole words,
/// spaces and hyphens interchangeable) becomes `to`.
public struct Replacement: Codable, Equatable, Sendable {
    public var from: [String]
    public var to: String

    public init(from: [String], to: String) {
        self.from = from
        self.to = to
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var language: String
    /// A sentence in the target language that primes whisper for punctuation, capitals and "ё".
    public var stylePrompt: String
    public var vocabulary: [String]
    public var replacements: [Replacement]
    public var hotkey: HotkeyKey
    public var insertMode: InsertMode
    public var keepAudio: Bool
    /// History cleanup in days, 0 keeps forever: audio goes first, text later.
    public var audioRetentionDays: Double
    public var historyRetentionDays: Double
    /// Mute system output while recording so other apps (YouTube, music) don't talk over the mic.
    public var muteWhileRecording: Bool
    /// Floating recording/recognizing indicator at the bottom of the screen.
    public var overlay: Bool
    /// Press Return after a successful insert (send in chats and terminals).
    public var pressReturn: Bool
    /// Add a space after inserted text so consecutive dictations don't run together.
    public var appendSpace: Bool
    public var minDurationSec: Double
    /// A recording stops by itself after this long (stuck key, forgotten hold) and is transcribed as usual.
    public var maxRecordingMinutes: Double
    public var silenceThresholdDb: Float
    public var engine: EngineConfig

    /// Style sentence plus vocabulary: the sentence keeps punctuation, the terms keep their spelling.
    public var prompt: String {
        let terms = vocabulary.isEmpty ? "" : vocabulary.joined(separator: ", ") + "."
        return [stylePrompt, terms].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func defaults(paths: Paths, fileManager: FileManager = .default) -> Config {
        // A model VoiceInk already downloaded is reused; otherwise ours is fetched on first launch.
        let ours = paths.models.appending(path: RemoteModel.whisperTurbo.fileName)
        let voiceInk = paths.voiceInkModels.appending(path: RemoteModel.whisperTurbo.fileName)
        let model = !fileManager.fileExists(atPath: ours.path) && fileManager.fileExists(atPath: voiceInk.path) ? voiceInk : ours
        // Without VAD whisper turns noise-only recordings (keyboard clicks, a cough) into "Продолжение следует...".
        let vad = paths.models.appending(path: RemoteModel.sileroVAD.fileName)
        return Config(
            language: "ru",
            stylePrompt: "Здравствуйте, как ваши дела? Приятно познакомиться.",
            vocabulary: ["Structurizr", "Qdrant", "dependency-cruiser", "Herdr"],
            replacements: [
                Replacement(from: ["строкчуризр", "строкчурезр", "строк чурезер", "структуризатор"], to: "Structurizr"),
                Replacement(from: ["qdrant", "гдрент", "кдрент", "кдренд"], to: "Qdrant"),
                Replacement(from: ["dependency cruiser", "депенденси крузер", "депенденци крузер", "дипенденцию cruiser"], to: "dependency-cruiser"),
            ],
            hotkey: .rightOption,
            insertMode: .type,
            keepAudio: true,
            audioRetentionDays: 1,
            historyRetentionDays: 30,
            muteWhileRecording: true,
            overlay: true,
            pressReturn: false,
            appendSpace: true,
            minDurationSec: 0.3,
            maxRecordingMinutes: 20,
            silenceThresholdDb: -45,
            engine: EngineConfig(
                serverURL: URL(string: "http://127.0.0.1:8178")!,
                startServer: true,
                serverBinary: "/opt/homebrew/bin/whisper-server",
                cliBinary: "/opt/homebrew/bin/whisper-cli",
                modelPath: model.path,
                timeoutSec: 60,
                vadModelPath: vad.path
            )
        )
    }
}

public struct Paths: Sendable {
    public let root: URL
    public let voiceInkModels: URL

    public init(root: URL, voiceInkModels: URL) {
        self.root = root
        self.voiceInkModels = voiceInkModels
    }

    public static let standard: Paths = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Paths(
            root: support.appending(path: "Vadic"),
            voiceInkModels: support.appending(path: "com.prakashjoshipax.VoiceInk/WhisperModels")
        )
    }()

    public var config: URL { root.appending(path: "config.json") }
    public var history: URL { root.appending(path: "History") }
    public var models: URL { root.appending(path: "Models") }
    public var recordings: URL { root.appending(path: "tmp") }
    public var serverLog: URL { root.appending(path: "whisper-server.log") }
}

public enum ConfigStore {
    /// Reads the config, writing `defaults` first if the file does not exist yet.
    public static func load(from url: URL, defaults: Config) throws -> Config {
        if !FileManager.default.fileExists(atPath: url.path) {
            try save(defaults, to: url)
            return defaults
        }
        // Keys missing from the file (e.g. options added in a newer version) fall back to defaults.
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults))
        let user = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let merged = try JSONSerialization.data(withJSONObject: merge(base, user))
        return try JSONDecoder().decode(Config.self, from: merged)
    }

    private static func merge(_ base: Any, _ override: Any) -> Any {
        guard let base = base as? [String: Any], let override = override as? [String: Any] else { return override }
        return base.merging(override) { merge($0, $1) }
    }

    public static func save(_ config: Config, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
