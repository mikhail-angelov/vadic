import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable {
    public var date: Date
    public var durationSec: Double
    public var text: String?
    public var engine: String?
    public var model: String
    public var insertMode: InsertMode
    public var inserted: Bool
    public var frontApp: String?
    public var error: String?

    public init(date: Date, durationSec: Double, text: String?, engine: String?, model: String,
                insertMode: InsertMode, inserted: Bool, frontApp: String?, error: String?) {
        self.date = date
        self.durationSec = durationSec
        self.text = text
        self.engine = engine
        self.model = model
        self.insertMode = insertMode
        self.inserted = inserted
        self.frontApp = frontApp
        self.error = error
    }
}

/// One folder per dictation: audio.wav + text.txt + meta.json.
public struct HistoryStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Moves `audio` into the entry folder, or deletes it when `keepAudio` is off and transcription succeeded.
    /// Audio of a failed dictation is always kept so it can be retried.
    @discardableResult
    public func save(_ entry: HistoryEntry, audio: URL, keepAudio: Bool) throws -> URL {
        let fm = FileManager.default
        let dir = root.appending(path: Self.folderName(for: entry.date))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if let text = entry.text {
            try Data(text.utf8).write(to: dir.appending(path: "text.txt"), options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: dir.appending(path: "meta.json"), options: .atomic)

        // Audio is touched last: if writing text or meta failed, the recording is still there to recover.
        if keepAudio || entry.error != nil {
            try fm.moveItem(at: audio, to: dir.appending(path: "audio.wav"))
        } else {
            try fm.removeItem(at: audio)
        }
        return dir
    }

    /// Drops audio older than `audioDays` and whole entries older than `historyDays`; 0 keeps forever.
    public func prune(audioDays: Double, historyDays: Double, now: Date = Date()) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let formatter = Self.formatter()
        for dir in dirs {
            guard let date = formatter.date(from: dir.lastPathComponent) else { continue }
            let ageDays = now.timeIntervalSince(date) / 86_400
            if historyDays > 0, ageDays > historyDays {
                try? fm.removeItem(at: dir)
            } else if audioDays > 0, ageDays > audioDays {
                try? fm.removeItem(at: dir.appending(path: "audio.wav"))
            }
        }
    }

    static func folderName(for date: Date) -> String {
        formatter().string(from: date)
    }

    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return f
    }
}
