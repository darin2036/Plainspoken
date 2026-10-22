import Foundation

public struct TranscriptSegment: Sendable, Equatable {
    public var text: String
    /// Seconds from the start of the recording.
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct Transcript: Sendable, Equatable {
    public var text: String
    public var segments: [TranscriptSegment]

    public init(text: String, segments: [TranscriptSegment]) {
        self.text = text
        self.segments = segments
    }
}

public enum TranscriberError: Error, CustomStringConvertible {
    case unsupportedLocale(String)
    case noAudioFormat
    case conversionFailed(String)
    case noAudio
    case unavailable

    public var description: String {
        switch self {
        case .unsupportedLocale(let l): return "Speech recognition isn't available for \(l) on this Mac"
        case .noAudioFormat: return "No compatible audio format for the speech model"
        case .conversionFailed(let why): return "Audio conversion failed: \(why)"
        case .noAudio: return "This file has no audio to transcribe"
        case .unavailable: return "Speech recognition isn't available on this Mac"
        }
    }
}

extension TranscriberError: LocalizedError {
    /// So `error.localizedDescription` gives the plain sentence an app can show.
    public var errorDescription: String? { description }
}
