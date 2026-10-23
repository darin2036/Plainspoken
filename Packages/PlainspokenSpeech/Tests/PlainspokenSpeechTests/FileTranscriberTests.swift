import AVFoundation
import Foundation
import Speech
import Testing

@testable import PlainspokenSpeech

/// These run the real recognizer on speech made with the Mac's own voice, so they need the English
/// model to be installed (it is on any Mac that has used dictation). They are skipped, not failed,
/// when it is not.
private enum Speech {
    static var ready: Bool {
        get async {
            guard SpeechTranscriber.isAvailable else { return false }
            return await SpeechAssets.isInstalled(locale: Locale(identifier: "en_US"), engine: .speechTranscriber)
        }
    }

    /// Spoken text as an audio file, using the system voice.
    static func say(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-test-\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        return url
    }

    /// A movie file with two audio tracks: `first` plays from the start, `second` after a gap.
    static func twoTrackMovie(first: URL, second: URL, secondStartsAt: Double) async throws -> URL {
        let composition = AVMutableComposition()
        for (file, start) in [(first, 0.0), (second, secondStartsAt)] {
            let asset = AVURLAsset(url: file)
            let source = try await asset.loadTracks(withMediaType: .audio)[0]
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: source,
                at: CMTime(seconds: start, preferredTimescale: 600))
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("speech-two-\(UUID().uuidString).mov")
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await session.export(to: out, as: .mov)
        return out
    }

    /// A movie with a picture and no sound.
    static func silentMovie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-silent-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }
}

@Suite(.serialized) struct FileTranscriberTests {
    @Test func transcribesSpeechWithOrderedTimedSegments() async throws {
        try #require(await Speech.ready, "the English speech model is not installed")
        let file = try Speech.say("Let's review the checkout page. Then we will send the notes to the whole team on Thursday.")
        defer { try? FileManager.default.removeItem(at: file) }

        let transcript = try await FileTranscriber.transcribe(fileAt: file, locale: Locale(identifier: "en_US"))
        let text = transcript.text.lowercased()
        #expect(text.contains("checkout") && text.contains("thursday"), "heard: \(transcript.text)")
        #expect(!transcript.segments.isEmpty)
        #expect(zip(transcript.segments, transcript.segments.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(transcript.segments.allSatisfy { $0.end >= $0.start && $0.start >= 0 })
        #expect(transcript.segments.map(\.text).joined(separator: " ") == transcript.text)
    }

    @Test func appliesTheVocabularyToTheFinishedText() async throws {
        try #require(await Speech.ready, "the English speech model is not installed")
        let file = try Speech.say("Let's review the checkout page on Thursday.")
        defer { try? FileManager.default.removeItem(at: file) }

        let plain = try await FileTranscriber.transcribe(fileAt: file, locale: Locale(identifier: "en_US"))
        #expect(plain.text.lowercased().contains("checkout"))
        // An alias turns what the recognizer wrote into the term the person wants.
        let corrected = try await FileTranscriber.transcribe(
            fileAt: file, locale: Locale(identifier: "en_US"), vocabulary: ["Check-Out Screen=checkout page", "THURSDAY"])
        #expect(corrected.text.contains("Check-Out Screen"), "alias not applied: \(corrected.text)")
        #expect(corrected.text.contains("THURSDAY"), "the term's spelling should win: \(corrected.text)")
    }

    @Test func reportsProgressThatEndsAtOne() async throws {
        try #require(await Speech.ready, "the English speech model is not installed")
        let file = try Speech.say("This is a short recording. It has two sentences in it.")
        defer { try? FileManager.default.removeItem(at: file) }

        let seen = Locked<[FileTranscriber.Progress]>([])
        _ = try await FileTranscriber.transcribe(fileAt: file, locale: Locale(identifier: "en_US")) { progress in
            seen.mutate { $0.append(progress) }
        }
        let transcribing = seen.value.filter { $0.stage == .transcribing }.map(\.fraction)
        #expect(transcribing.first == 0 && transcribing.last == 1)
        #expect(zip(transcribing, transcribing.dropFirst()).allSatisfy { $0 <= $1 + 0.0001 }, "progress went backwards: \(transcribing)")
        #expect(transcribing.allSatisfy { (0...1).contains($0) })
    }

    @Test func mixesEveryAudioTrackSoNobodyIsMissingFromTheTranscript() async throws {
        try #require(await Speech.ready, "the English speech model is not installed")
        let one = try Speech.say("The checkout page needs a review.")
        let two = try Speech.say("Then somebody should order bananas.")
        defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: two) }
        let movie = try await Speech.twoTrackMovie(first: one, second: two, secondStartsAt: 6)
        defer { try? FileManager.default.removeItem(at: movie) }
        #expect(try await AVURLAsset(url: movie).loadTracks(withMediaType: .audio).count == 2)

        let transcript = try await FileTranscriber.transcribe(fileAt: movie, locale: Locale(identifier: "en_US"))
        let text = transcript.text.lowercased()
        #expect(text.contains("checkout"), "first track missing: \(transcript.text)")
        #expect(text.contains("banana"), "second track missing: \(transcript.text)")
    }

    @Test func aFileWithNoSoundIsReportedNotSilentlyEmpty() async throws {
        let movie = try await Speech.silentMovie()
        defer { try? FileManager.default.removeItem(at: movie) }
        do {
            _ = try await FileTranscriber.transcribe(fileAt: movie)
            Issue.record("expected an error for a file with no audio")
        } catch let error as TranscriberError {
            if case .noAudio = error {} else { Issue.record("wrong error: \(error)") }
        }
    }

    @Test func cancellingStopsTheWork() async throws {
        try #require(await Speech.ready, "the English speech model is not installed")
        let file = try Speech.say("A sentence that will never be needed because the work is cancelled first.")
        defer { try? FileManager.default.removeItem(at: file) }
        let task = Task { try await FileTranscriber.transcribe(fileAt: file, locale: Locale(identifier: "en_US")) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func aDictationEngineWorksOnFilesToo() async throws {
        try #require(await Speech.ready, "the English speech model is not installed")
        try #require(
            await SpeechAssets.isInstalled(locale: Locale(identifier: "en_US"), engine: .dictationTranscriber),
            "the dictation model is not installed")
        let file = try Speech.say("Please review the checkout page before Thursday.")
        defer { try? FileManager.default.removeItem(at: file) }
        let transcript = try await FileTranscriber.transcribe(fileAt: file, engine: .dictationTranscriber, locale: Locale(identifier: "en_US"))
        #expect(transcript.text.lowercased().contains("checkout"), "heard: \(transcript.text)")
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
