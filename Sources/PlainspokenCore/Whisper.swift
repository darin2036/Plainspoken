import AVFoundation
import Foundation
import WhisperKit

/// Whisper sizes offered in settings. The WhisperKit package is only code; each model is a
/// separate Core ML download from Hugging Face that happens after the user agrees to it.
public enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case fast, balanced, accurate
    public var id: String { rawValue }

    /// Folder name in the argmaxinc/whisperkit-coreml repository.
    public var variant: String {
        switch self {
        case .fast: return "openai_whisper-base"
        case .balanced: return "openai_whisper-small"
        case .accurate: return "openai_whisper-large-v3-v20240930_turbo_632MB"
        }
    }

    public var label: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .accurate: return "Most accurate"
        }
    }

    /// Download size, measured from the repository.
    public var downloadMB: Int {
        switch self {
        case .fast: return 147
        case .balanced: return 486
        case .accurate: return 646
        }
    }

    public var downloadLabel: String { "about \(downloadMB) MB" }

    public var bestFor: String {
        switch self {
        case .fast: return "Quick notes in clear speech and a quiet room."
        case .balanced: return "Everyday dictation. A good first model to try for an accent."
        case .accurate: return "Strong accents, noisy rooms and technical vocabulary."
        }
    }

    public var benefit: String {
        switch self {
        case .fast: return "Smallest download and the quickest result."
        case .balanced: return "Noticeably more accurate than Fast without a huge download."
        case .accurate: return "Best accuracy of the three, and it handles accents the most reliably."
        }
    }

    public var tradeoff: String {
        switch self {
        case .fast: return "Makes the most mistakes, especially with accents and unusual words."
        case .balanced: return "Slower than Fast, and may still slip on heavy accents."
        case .accurate: return "Largest download, the most memory, and the longest wait after you let go."
        }
    }
}

/// Where Whisper models live on disk, and whether a given one is fully downloaded.
public enum WhisperStore {
    static let repo = "argmaxinc/whisperkit-coreml"

    public static var base: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Plainspoken/WhisperModels", isDirectory: true)
    }

    static func folder(for model: WhisperModel) -> URL {
        base.appendingPathComponent("models/\(repo)/\(model.variant)", isDirectory: true)
    }

    /// Written once a download finishes, so a half-finished download never counts as installed.
    /// Its contents are the repository revision the download came from.
    private static func marker(for model: WhisperModel) -> URL {
        folder(for: model).appendingPathComponent(".plainspoken-complete")
    }

    /// The Hugging Face commit the model was downloaded from, so a later update check can tell
    /// whether the repository has moved on. Nil for installs that predate this or if the lookup failed.
    public static func installedRevision(_ model: WhisperModel) -> String? {
        guard let text = try? String(contentsOf: marker(for: model), encoding: .utf8) else { return nil }
        let revision = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return revision.isEmpty ? nil : revision
    }

    /// Latest commit of the model repository. Best effort: a failure just means no revision is recorded.
    private static func latestRevision() async -> String? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["sha"] as? String
    }

    public static func isInstalled(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: marker(for: model).path)
    }

    /// Size on disk in MB, or nil when it isn't installed.
    public static func installedMB(_ model: WhisperModel) -> Int? {
        guard isInstalled(model),
              let files = FileManager.default.enumerator(at: folder(for: model), includingPropertiesForKeys: [.fileSizeKey])
        else { return nil }
        var total = 0
        for case let url as URL in files { total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total / 1_000_000
    }

    public static func remove(_ model: WhisperModel) async {
        await WhisperRuntime.shared.unload(model)
        try? FileManager.default.removeItem(at: folder(for: model))
    }

    /// Downloads the model if needed (progress is 0...1) and loads it, so the first dictation is quick.
    public static func prepare(_ model: WhisperModel, allowDownload: Bool,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        if !isInstalled(model) {
            guard allowDownload else { throw WhisperSetupError.notInstalled }
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            // The only place the app may touch the network. Loading inside the window also lets
            // WhisperKit fetch and cache its tokenizer now, so later loads are fully offline.
            let revision = try await NetworkGuard.allowing { () async throws -> String? in
                // Read the revision first so it names what we are about to fetch, not something newer.
                let revision = await latestRevision()
                _ = try await WhisperKit.download(variant: model.variant, downloadBase: base, from: repo) { p in
                    progress(p.fractionCompleted)
                }
                try await WhisperRuntime.shared.load(model)
                return revision
            }
            // Written last: "installed" means the model and tokenizer are both on disk.
            try Data((revision ?? "").utf8).write(to: marker(for: model))
        } else {
            // Network is blocked here. If anything is missing this fails instead of fetching it.
            try await WhisperRuntime.shared.load(model)
        }
        progress(1)
    }
}

public enum WhisperSetupError: Error, CustomStringConvertible {
    case notInstalled
    case notLoaded

    public var description: String {
        switch self {
        case .notInstalled: return "The Whisper model isn't downloaded"
        case .notLoaded: return "The Whisper model isn't loaded"
        }
    }
}

/// Keeps one loaded WhisperKit around; loading compiles Core ML models and takes a few seconds.
actor WhisperRuntime {
    static let shared = WhisperRuntime()
    private var kit: WhisperKit?
    private var loaded: WhisperModel?

    func load(_ model: WhisperModel) async throws {
        if loaded == model, kit != nil { return }
        kit = nil
        loaded = nil
        let config = WhisperKitConfig(
            downloadBase: WhisperStore.base,
            modelFolder: WhisperStore.folder(for: model).path,
            tokenizerFolder: WhisperStore.base,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        kit = try await WhisperKit(config)
        loaded = model
    }

    func unload(_ model: WhisperModel) async {
        guard loaded == model else { return }
        await kit?.unloadModels()
        kit = nil
        loaded = nil
    }

    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> [TranscriptionSegmentText] {
        guard let kit else { throw WhisperSetupError.notLoaded }
        var options = DecodingOptions(task: .transcribe, language: language, skipSpecialTokens: true,
                                      withoutTimestamps: false)
        if language == nil { options.detectLanguage = true }
        // Names and product terms go in as a prompt, which nudges Whisper toward their spelling.
        if !vocabulary.isEmpty, let tokenizer = kit.tokenizer {
            let text = " " + vocabulary.joined(separator: ", ")
            let tokens = tokenizer.encode(text: text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            options.promptTokens = Array(tokens.prefix(200))
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap(\.segments).map {
            TranscriptionSegmentText(text: $0.text, start: Double($0.start), end: Double($0.end))
        }
    }
}

struct TranscriptionSegmentText: Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// Languages Whisper can transcribe, as (code, display name) sorted by name.
public enum WhisperLanguages {
    public static var all: [(code: String, name: String)] {
        Constants.languageCodes
            .map { ($0, Locale.current.localizedString(forLanguageCode: $0) ?? $0) }
            .sorted { $0.1 < $1.1 }
    }
}

/// Whisper has no streaming path here: it records the whole push-to-talk utterance, then
/// transcribes it in one pass once the key is released.
public final class WhisperSession: DictationSession, @unchecked Sendable {
    private static let sampleRate = 16_000.0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private let lock = NSLock()
    private var samples: [Float] = []
    private let language: String?
    private let vocabulary: [String]

    public init(language: String?, vocabulary: [String]) {
        self.language = language
        self.vocabulary = vocabulary
    }

    public func feed(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converterSourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converterSourceFormat = buffer.format
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = out.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    public func finish() async throws -> Transcript {
        let audio = lock.withLock { samples }
        // Under a third of a second is a stray tap, and Whisper tends to invent text for silence.
        guard audio.count > Int(Self.sampleRate / 3) else { return Transcript(text: "", segments: []) }
        let parts = try await WhisperRuntime.shared.transcribe(audio, language: language, vocabulary: vocabulary)
        let segments = parts
            .map { TranscriptSegment(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), start: $0.start, end: $0.end) }
            .filter { !$0.text.isEmpty }
        return Transcript(text: segments.map(\.text).joined(separator: " "), segments: segments)
    }

    public func cancel() async {
        lock.withLock { samples.removeAll() }
    }
}
