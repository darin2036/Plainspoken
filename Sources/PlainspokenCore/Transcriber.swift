import AVFoundation
import Foundation

// The speech layer (Apple's engines, language models, vocabulary, the offline guard) lives in the
// PlainspokenSpeech package so other apps can share it. It is re-exported, so code that imports
// PlainspokenCore still sees Transcript, DictationSession, Vocabulary, NetworkGuard and the rest.
@_exported import PlainspokenSpeech

/// Two on-device engines ship with macOS: SpeechTranscriber is the newer, faster one, and
/// DictationTranscriber is the classic dictation model with a punctuation switch. Whisper is an
/// optional extra that downloads its model only after the user agrees to it.
public enum SpeechEngine: String, CaseIterable, Identifiable, Sendable {
    case speechTranscriber, dictationTranscriber, whisper
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .speechTranscriber: return "Apple SpeechTranscriber (newer)"
        case .dictationTranscriber: return "Apple DictationTranscriber (classic)"
        case .whisper: return "Whisper (optional download)"
        }
    }

    public var bestFor: String {
        switch self {
        case .speechTranscriber: return "Most people. Fast, light, and a good default."
        case .dictationTranscriber: return "When SpeechTranscriber mishears you and you want a second opinion."
        case .whisper: return "Accents or vocabulary the Apple engines keep getting wrong."
        }
    }

    public var benefit: String {
        switch self {
        case .speechTranscriber: return "Built into macOS, so no download beyond a small language model. Shows words as you speak."
        case .dictationTranscriber: return "Built into macOS, with punctuation as you speak. Handles some voices differently, so try it."
        case .whisper: return "Trained on a huge range of accents and languages, so it is often the most forgiving of how you speak."
        }
    }

    public var tradeoff: String {
        switch self {
        case .speechTranscriber: return "Can struggle with accents and some speech patterns (fast, mumbled or non-native speech), because it uses one model per region."
        case .dictationTranscriber: return "Slightly older model, and shares the same difficulty with accents and some speech patterns."
        case .whisper: return "A one-time download of 150 to 650 MB, more memory, and text appears only after you release the key."
        }
    }

}

extension SpeechEngine {
    /// The Apple engine whose model APIs apply. Whisper never goes through them.
    public var apple: AppleSpeechEngine { self == .dictationTranscriber ? .dictationTranscriber : .speechTranscriber }
}

public enum Dictation {
    /// Starts a session on whichever engine is selected. `whisperLanguage` is a Whisper language
    /// code such as "en"; nil lets Whisper detect it.
    public static func start(
        engine: SpeechEngine,
        locale: Locale = .current,
        whisperLanguage: String? = nil,
        vocabulary: [String] = [],
        onPartial: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> any DictationSession {
        switch engine {
        case .whisper:
            return WhisperSession(language: whisperLanguage, vocabulary: Vocabulary.terms(from: vocabulary))
        case .speechTranscriber, .dictationTranscriber:
            return try await TranscriptionSession.start(locale: locale, engine: engine.apple, vocabulary: vocabulary, onPartial: onPartial)
        }
    }
}

extension SpeechAssets {
    /// Locales the engine can recognize. Whisper has its own list of languages, so it uses Apple's here.
    public static func supportedLocales(for engine: SpeechEngine) async -> [Locale] {
        await supportedLocales(for: engine.apple)
    }

    /// Makes sure the on-device model for `locale` is installed. See the shared package for details.
    @discardableResult
    public static func prepare(
        locale: Locale = .current, engine: SpeechEngine, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Locale {
        try await prepare(locale: locale, engine: engine.apple, progress: progress)
    }
}
