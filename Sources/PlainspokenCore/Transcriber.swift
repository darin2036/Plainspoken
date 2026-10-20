import AVFoundation
import CoreMedia
import Foundation
import Speech

public struct TranscriptSegment: Sendable {
    public var text: String
    /// Seconds from the start of the recording. Kept for pause-based hints (not used in prompts yet).
    public var start: Double
    public var end: Double
}

public struct Transcript: Sendable {
    public var text: String
    public var segments: [TranscriptSegment]
}

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

    /// The Apple engine whose model APIs apply. Whisper never goes through them.
    var apple: SpeechEngine { self == .whisper ? .speechTranscriber : self }
}

/// One push-to-talk utterance: feed it microphone buffers, then call finish() for the transcript.
public protocol DictationSession: AnyObject, Sendable {
    func feed(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> Transcript
    func cancel() async
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
            return try await TranscriptionSession.start(locale: locale, engine: engine, vocabulary: vocabulary, onPartial: onPartial)
        }
    }
}

public enum TranscriberError: Error, CustomStringConvertible {
    case unsupportedLocale(String)
    case noAudioFormat
    case conversionFailed(String)

    public var description: String {
        switch self {
        case .unsupportedLocale(let l): return "Speech recognition isn't available for \(l) on this Mac"
        case .noAudioFormat: return "No compatible audio format for the speech model"
        case .conversionFailed(let why): return "Audio conversion failed: \(why)"
        }
    }
}

/// Builds the speech module for an engine. Dictation is configured by hand rather than with a
/// preset so it can report volatile (partial) results with punctuation.
private func makeModule(_ engine: SpeechEngine, locale: Locale) -> any SpeechModule {
    switch engine.apple {
    case .speechTranscriber, .whisper:
        return SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
    case .dictationTranscriber:
        return DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }
}

private func supportedLocale(for engine: SpeechEngine, equivalentTo locale: Locale) async -> Locale? {
    switch engine.apple {
    case .speechTranscriber, .whisper: return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    case .dictationTranscriber: return await DictationTranscriber.supportedLocale(equivalentTo: locale)
    }
}

// MARK: - Assets

public enum SpeechAssets {
    /// Locales the engine can recognize, sorted by identifier. Regional variants (en_GB, en_AU,
    /// en_IN...) are separate models, so picking the one that matches the speaker can help with accents.
    public static func supportedLocales(for engine: SpeechEngine) async -> [Locale] {
        let locales: [Locale]
        switch engine.apple {
        case .speechTranscriber, .whisper: locales = await SpeechTranscriber.supportedLocales
        case .dictationTranscriber: locales = await DictationTranscriber.supportedLocales
        }
        return locales.sorted { $0.identifier < $1.identifier }
    }

    /// Makes sure the on-device model for `locale` is installed and reserved for this app.
    /// Downloads on first run only; `progress` reports 0...1 while downloading.
    /// Returns the locale the model actually uses (e.g. en_CA maps to en_US).
    @discardableResult
    public static func prepare(
        locale: Locale = .current,
        engine: SpeechEngine = .speechTranscriber,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Locale {
        guard let supported = await supportedLocale(for: engine, equivalentTo: locale) else {
            throw TranscriberError.unsupportedLocale(locale.identifier)
        }
        let module = makeModule(engine, locale: supported)
        if await AssetInventory.status(forModules: [module]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let watcher = Task {
                while !Task.isCancelled {
                    progress(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { watcher.cancel() }
            try await request.downloadAndInstall()
            progress(1)
        }
        // The system keeps a few locales resident per app; reserving keeps ours from being evicted.
        _ = try? await AssetInventory.reserve(locale: supported)
        return supported
    }
}

// MARK: - Live session

/// One push-to-talk utterance: feed it microphone buffers, then call finish() for the transcript.
public final class TranscriptionSession: DictationSession, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Error>?

    private let lock = NSLock()
    private var finalized: [TranscriptSegment] = []
    private var volatile = ""
    private let onPartial: @Sendable (String) -> Void

    /// `vocabulary` is passed to the recognizer as contextual strings (names, product terms).
    public static func start(
        locale: Locale = .current,
        engine: SpeechEngine = .speechTranscriber,
        vocabulary: [String] = [],
        onPartial: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> TranscriptionSession {
        guard let supported = await supportedLocale(for: engine, equivalentTo: locale) else {
            throw TranscriberError.unsupportedLocale(locale.identifier)
        }
        let module = makeModule(engine, locale: supported)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriberError.noAudioFormat
        }

        let context = AnalysisContext()
        let terms = Vocabulary.terms(from: vocabulary)
        if !terms.isEmpty { context.contextualStrings[.general] = terms }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [module], analysisContext: context)
        try await analyzer.prepareToAnalyze(in: format)

        let session = TranscriptionSession(analyzer: analyzer, continuation: continuation, format: format, onPartial: onPartial)
        session.resultsTask = Task { [session] in
            switch engine.apple {
            case .speechTranscriber, .whisper:
                let t = module as! SpeechTranscriber
                for try await r in t.results { session.handle(String(r.text.characters), r.range, r.isFinal) }
            case .dictationTranscriber:
                let t = module as! DictationTranscriber
                for try await r in t.results { session.handle(String(r.text.characters), r.range, r.isFinal) }
            }
        }
        return session
    }

    private init(analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation,
                 format: AVAudioFormat, onPartial: @escaping @Sendable (String) -> Void) {
        self.analyzer = analyzer
        self.inputContinuation = continuation
        self.format = format
        self.onPartial = onPartial
    }

    private func handle(_ text: String, _ range: CMTimeRange, _ isFinal: Bool) {
        let partial: String
        lock.lock()
        if isFinal {
            finalized.append(TranscriptSegment(text: text, start: range.start.seconds, end: range.end.seconds))
            volatile = ""
        } else {
            volatile = text
        }
        partial = Self.join(finalized.map(\.text) + [volatile])
        lock.unlock()
        onPartial(partial)
    }

    private static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Converts to the analyzer's format and queues the buffer. Safe to call from the audio thread.
    public func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = try? convert(buffer) else { return }
        inputContinuation.yield(AnalyzerInput(buffer: converted))
    }

    /// Ends the input, waits for the recognizer to finalize, and returns everything it heard.
    public func finish() async throws -> Transcript {
        inputContinuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await resultsTask?.value
        return lock.withLock {
            // If nothing was ever finalized, fall back to whatever partial text is left.
            var segments = finalized
            let tail = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty, segments.isEmpty {
                segments.append(TranscriptSegment(text: tail, start: 0, end: 0))
            }
            return Transcript(text: Self.join(segments.map(\.text)), segments: segments)
        }
    }

    public func cancel() async {
        inputContinuation.finish()
        resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter == nil || converterSourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converterSourceFormat = buffer.format
        }
        guard let converter else { throw TranscriberError.conversionFailed("no converter for \(buffer.format)") }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw TranscriberError.conversionFailed("couldn't allocate output buffer")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw TranscriberError.conversionFailed(error?.localizedDescription ?? "unknown") }
        return out
    }
}
