import Foundation
import Speech

/// The two recognizers that ship with macOS. SpeechTranscriber is the newer, faster one;
/// DictationTranscriber is the classic dictation model, which can hear some voices differently.
public enum AppleSpeechEngine: String, CaseIterable, Identifiable, Sendable {
    case speechTranscriber, dictationTranscriber
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .speechTranscriber: return "Apple SpeechTranscriber (newer)"
        case .dictationTranscriber: return "Apple DictationTranscriber (classic)"
        }
    }

    public var bestFor: String {
        switch self {
        case .speechTranscriber: return "Most people. Fast, light, and a good default."
        case .dictationTranscriber: return "When SpeechTranscriber mishears you and you want a second opinion."
        }
    }

    public var benefit: String {
        switch self {
        case .speechTranscriber: return "Built into macOS, so no download beyond a small language model. Shows words as you speak."
        case .dictationTranscriber: return "Built into macOS, with punctuation as you speak. Handles some voices differently, so try it."
        }
    }

    public var tradeoff: String {
        switch self {
        case .speechTranscriber: return "Can struggle with accents and some speech patterns (fast, mumbled or non-native speech), because it uses one model per region."
        case .dictationTranscriber: return "Slightly older model, and shares the same difficulty with accents and some speech patterns."
        }
    }
}

/// Builds the speech module for an engine and finds the locale it supports.
enum SpeechModules {
    /// Live dictation: reports partial (volatile) results as the person speaks.
    static func live(_ engine: AppleSpeechEngine, locale: Locale) -> any SpeechModule {
        switch engine {
        case .speechTranscriber:
            return SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        case .dictationTranscriber:
            return DictationTranscriber(
                locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        }
    }

    /// Whole files: only final results, each with the time it covers.
    static func file(_ engine: AppleSpeechEngine, locale: Locale) -> any SpeechModule {
        switch engine {
        case .speechTranscriber:
            return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        case .dictationTranscriber:
            return DictationTranscriber(
                locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                reportingOptions: [], attributeOptions: [.audioTimeRange])
        }
    }

    static func supportedLocale(for engine: AppleSpeechEngine, equivalentTo locale: Locale) async -> Locale? {
        switch engine {
        case .speechTranscriber: return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        case .dictationTranscriber: return await DictationTranscriber.supportedLocale(equivalentTo: locale)
        }
    }
}
