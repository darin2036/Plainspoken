import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Transcribes a whole audio or video file on this Mac, with the time each phrase covers. This is the
/// path for recordings; live dictation uses `TranscriptionSession` instead.
public enum FileTranscriber {
    public struct Progress: Sendable, Equatable {
        public enum Stage: Sendable, Equatable {
            /// Downloading or reserving the on-device language model (first use only).
            case preparingModel
            /// Reading the recording.
            case transcribing
        }
        public var stage: Stage
        /// 0...1 within the stage.
        public var fraction: Double

        public init(stage: Stage, fraction: Double) {
            self.stage = stage
            self.fraction = fraction
        }
    }

    /// - Parameters:
    ///   - vocabulary: entries as in `Vocabulary` ("Jira" or "Rovo=bravo|robo"). Terms are given to the
    ///     recognizer, and the finished text is corrected for casing, one-letter slips and aliases.
    ///   - progress: called as work advances, from any thread.
    /// Cancel by cancelling the surrounding task; the call then throws `CancellationError`.
    public static func transcribe(
        fileAt url: URL,
        engine: AppleSpeechEngine = .speechTranscriber,
        locale: Locale = .current,
        vocabulary: [String] = [],
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Transcript {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw TranscriberError.noAudio }
        let duration = (try? await asset.load(.duration).seconds) ?? 0

        let supported = try await SpeechAssets.prepare(locale: locale, engine: engine) {
            progress(Progress(stage: .preparingModel, fraction: $0))
        }
        try Task.checkCancellation()

        // One audio track reads straight from the file. Several (microphone and system sound) are mixed
        // into a temporary file first, so every voice ends up in the transcript.
        let source = try await audioFile(for: asset, url: url, trackCount: audioTracks.count)
        defer { if source.isTemporary { try? FileManager.default.removeItem(at: source.url) } }

        let module = SpeechModules.file(engine, locale: supported)
        let analyzer = SpeechAnalyzer(modules: [module])
        let terms = Vocabulary.terms(from: vocabulary)
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            try await analyzer.setContext(context)
        }

        let collector = Collector(duration: duration, progress: progress)
        let results = Task { () -> Void in
            switch engine {
            case .speechTranscriber:
                for try await r in (module as! SpeechTranscriber).results { collector.add(String(r.text.characters), r.range) }
            case .dictationTranscriber:
                for try await r in (module as! DictationTranscriber).results { collector.add(String(r.text.characters), r.range) }
            }
        }

        progress(Progress(stage: .transcribing, fraction: 0))
        try await withTaskCancellationHandler {
            let audio = try AVAudioFile(forReading: source.url)
            if let last = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            try await results.value
        } onCancel: {
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
        try Task.checkCancellation()
        progress(Progress(stage: .transcribing, fraction: 1))
        return collector.transcript(vocabulary: vocabulary)
    }

    // MARK: Pieces

    /// Gathers the recognizer's final results in order. Safe to call from the results task.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var segments: [TranscriptSegment] = []
        private let duration: Double
        private let progress: @Sendable (Progress) -> Void

        init(duration: Double, progress: @escaping @Sendable (Progress) -> Void) {
            self.duration = duration
            self.progress = progress
        }

        func add(_ text: String, _ range: CMTimeRange) {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            let end = range.end.seconds.isFinite ? range.end.seconds : range.start.seconds
            lock.lock()
            segments.append(TranscriptSegment(text: clean, start: max(0, range.start.seconds), end: max(end, range.start.seconds)))
            lock.unlock()
            if duration > 0 { progress(Progress(stage: .transcribing, fraction: min(0.99, end / duration))) }
        }

        func transcript(vocabulary: [String]) -> Transcript {
            lock.lock()
            let ordered = segments.sorted { $0.start < $1.start }
            lock.unlock()
            let corrected = ordered.map { segment -> TranscriptSegment in
                var segment = segment
                segment.text = Vocabulary.correct(segment.text, terms: vocabulary)
                return segment
            }
            return Transcript(text: corrected.map(\.text).joined(separator: " "), segments: corrected)
        }
    }

    private struct AudioSource {
        let url: URL
        let isTemporary: Bool
    }

    private static func audioFile(for asset: AVURLAsset, url: URL, trackCount: Int) async throws -> AudioSource {
        if trackCount == 1, (try? AVAudioFile(forReading: url)) != nil { return AudioSource(url: url, isTemporary: false) }
        // Mix every audio track into one temporary file.
        let composition = AVMutableComposition()
        let length = try await asset.load(.duration)
        for track in try await asset.loadTracks(withMediaType: .audio) {
            guard let copy = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try copy.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: .zero)
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("speech-mix-\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriberError.conversionFailed("this audio could not be mixed")
        }
        try await session.export(to: output, as: .m4a)
        return AudioSource(url: output, isTemporary: true)
    }
}
