import Foundation

/// The single application state: idle → recording → processing → idle. Overlapping recordings are impossible.
public enum DictationState: Equatable, Sendable {
    case idle
    case recording(since: Date)
    case processing
}

public struct DictationStateMachine: Sendable {
    public private(set) var state: DictationState = .idle

    public init() {}

    public mutating func startRecording(at date: Date = Date()) -> Bool {
        guard state == .idle else { return false }
        state = .recording(since: date)
        return true
    }

    public mutating func stopRecording() -> Bool {
        guard case .recording = state else { return false }
        state = .processing
        return true
    }

    public mutating func cancelRecording() -> Bool {
        guard case .recording = state else { return false }
        state = .idle
        return true
    }

    public mutating func finishProcessing() {
        if state == .processing { state = .idle }
    }
}

/// Rejects accidental taps and silent recordings before they reach the engine.
public enum AudioGate {
    public enum Verdict: Equatable, Sendable {
        case accept, tooShort, silent
    }

    public static func evaluate(durationSec: Double, peakDb: Float, minDurationSec: Double, thresholdDb: Float) -> Verdict {
        if durationSec < minDurationSec { return .tooShort }
        if peakDb < thresholdDb { return .silent }
        return .accept
    }
}

public enum Transcript {
    /// whisper prints one segment per line and may split a word across segments
    /// ("dependency-cru\niser"); a segment that starts a new word carries its own leading space.
    public static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

public enum Replacer {
    public static func apply(_ rules: [Replacement], to text: String) -> String {
        // Longest variants first so "депенденси крузер" wins over a rule for "крузер".
        let pairs = rules.flatMap { rule in rule.from.map { ($0, rule.to) } }.sorted { $0.0.count > $1.0.count }
        var result = text
        for (variant, target) in pairs {
            let tokens = variant.split { $0 == " " || $0 == "-" }.map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !tokens.isEmpty else { continue }
            let pattern = #"(?<![\p{L}\p{N}])"# + tokens.joined(separator: #"[\s\-]+"#) + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: target)
            )
        }
        return result
    }
}
