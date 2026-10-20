import AVFoundation
import Foundation
import PlainspokenCore

// Whisper: --engine whisper [--whisper-model fast|balanced|accurate] (downloads the model if missing)
// Usage: harness [samples.json] [--temp 0.2] [--no-schema] [--only N] [--instructions file.txt] [--runs K]
// samples.json: [{ "raw": "...", "ideal": "...", "category": "optional" }]

struct Sample: Decodable {
    var raw: String
    var ideal: String
    var category: String?
}

var path = "Harness/samples.json"
var config = RewriterConfig()
var only: Int?
var runs = 1
var pipeline = false  // run the full fallback chain and show what the user would actually get
var audioPath: String?  // --transcribe: run an audio file through the speech stack instead of samples.json
var engine = SpeechEngine.speechTranscriber
var whisperModel = WhisperModel.balanced
var vocabulary: [String] = []  // --vocab "Jira,Rovo": custom terms for the rewrite hint and correction
var stress = 0  // --stress N: repeat every sample N times as one long transcript to exercise chunking
var oneOff: String?  // --text "...": run one transcript through the pipeline
var rewriteTranscript = false  // with --transcribe: also run the transcript through the rewrite pipeline

var argv = Array(CommandLine.arguments.dropFirst())
while !argv.isEmpty {
    let a = argv.removeFirst()
    switch a {
    case "--temp": config.temperature = Double(argv.removeFirst()) ?? config.temperature
    case "--no-schema": config.structuredOutput = false
    case "--schema": config.structuredOutput = true
    case "--pipeline": pipeline = true
    case "--transcribe": audioPath = argv.removeFirst()
    case "--engine":
        let name = argv.removeFirst()
        engine = name.hasPrefix("w") ? .whisper : name.hasPrefix("d") ? .dictationTranscriber : .speechTranscriber
    case "--whisper-model": whisperModel = WhisperModel(rawValue: argv.removeFirst()) ?? whisperModel
    case "--rewrite": rewriteTranscript = true
    case "--vocab": vocabulary = argv.removeFirst().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    case "--stress": stress = Int(argv.removeFirst()) ?? 1
    case "--text": oneOff = argv.removeFirst()
    case "--only": only = Int(argv.removeFirst())
    case "--runs": runs = max(1, Int(argv.removeFirst()) ?? 1)
    case "--instructions":
        config.instructions = (try? String(contentsOfFile: argv.removeFirst(), encoding: .utf8)) ?? config.instructions
    default: path = a
    }
}

if let audioPath {
    do {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        var lastDownload = -1
        let report: @Sendable (Double) -> Void = { p in
            let pct = Int(p * 100)
            if pct / 10 != lastDownload / 10 { lastDownload = pct; print("downloading speech model… \(pct)%") }
        }
        var locale = Locale.current
        if engine == .whisper {
            try await WhisperStore.prepare(whisperModel, allowDownload: true, progress: report)
        } else {
            locale = try await SpeechAssets.prepare(engine: engine, progress: report)
        }
        print("engine=\(engine.rawValue) locale=\(locale.identifier) file=\(audioPath) (\(String(format: "%.1f", Double(file.length) / file.processingFormat.sampleRate))s)")

        // Without --vocab, use the same vocabulary file the app uses.
        let vocab = vocabulary.isEmpty ? VocabularyFile.load() : vocabulary
        let started = Date()
        let session = try await Dictation.start(
            engine: engine,
            whisperLanguage: Locale.current.language.languageCode?.identifier,
            vocabulary: vocab,
            onPartial: { print("  partial: \($0)") }
        )
        let setup = Date().timeIntervalSince(started)
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try file.read(into: buf)
            session.feed(buf)
        }
        let released = Date()
        let transcript = try await session.finish()
        print(String(format: "setup %.2fs, release-to-final %.2fs", setup, Date().timeIntervalSince(released)))
        print("transcript: \(transcript.text)")
        for s in transcript.segments { print(String(format: "  [%.2f-%.2f] %@", s.start, s.end, s.text)) }

        if rewriteTranscript {
            let r = await Rewriter(config: config).process(transcript.text, vocabulary: vocab)
            print(String(format: "rewrite (%@, %.2fs): %@", r.stage.rawValue, r.seconds, r.text))
            if let f = r.failure { print("  fell back because: \(f)") }
        }
    } catch {
        print("Transcription failed: \(error)")
        exit(1)
    }
    exit(0)
}

if let problem = Rewriter.availabilityProblem() {
    print("Foundation Models is not available: \(problem)")
    exit(2)
}

if let oneOff {
    let r = await Rewriter(config: config).process(oneOff, vocabulary: vocabulary)
    print("in:  \(oneOff)")
    print("out: \(r.text)")
    print(String(format: "stage=%@ chunks=%d %.2fs", r.stage.rawValue, r.chunks, r.seconds))
    if let f = r.failure { print("note: \(f)") }
    exit(0)
}

guard let data = FileManager.default.contents(atPath: path),
      var samples = try? JSONDecoder().decode([Sample].self, from: data)
else {
    print("Could not read samples from \(path)")
    exit(1)
}
if let only { samples = samples.indices.contains(only - 1) ? [samples[only - 1]] : [] }

if stress > 0 {
    // One long transcript made of every sample's raw text, repeated.
    let long = (0..<stress).flatMap { _ in samples.map { $0.raw.hasSuffix(".") ? $0.raw : $0.raw + "." } }.joined(separator: " ")
    let r = await Rewriter(config: config).process(long, vocabulary: vocabulary)
    print("input: \(long.count) chars, \(long.split(separator: " ").count) words")
    print("output: \(r.text.count) chars in \(r.chunks) chunk(s), stage=\(r.stage.rawValue), \(String(format: "%.2fs", r.seconds))")
    if let f = r.failure { print("note: \(f)") }
    print("\n" + r.text.prefix(600) + "…")
    exit(0)
}

func norm(_ s: String) -> [String] { RewriteGuards.words(s) }

/// Word-level longest-common-subsequence similarity, 0...1.
func similarity(_ a: String, _ b: String) -> Double {
    let x = norm(a), y = norm(b)
    if x.isEmpty && y.isEmpty { return 1 }
    if x.isEmpty || y.isEmpty { return 0 }
    var dp = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
    for i in 1...x.count {
        for j in 1...y.count {
            dp[i][j] = x[i - 1] == y[j - 1] ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1])
        }
    }
    return 2 * Double(dp[x.count][y.count]) / Double(x.count + y.count)
}

print("temp=\(config.temperature) structured=\(config.structuredOutput) samples=\(samples.count) runs=\(runs)\n")

let rewriter = Rewriter(config: config)
var guardPass = 0, exact = 0, close = 0, total = 0
var latencies: [Double] = []

for (i, s) in samples.enumerated() {
    for run in 1...runs {
        total += 1
        let start = Date()
        var output = "", note = "", guardOK = false
        if pipeline {
            let r = await rewriter.process(s.raw, vocabulary: vocabulary)
            output = r.text
            guardOK = true
            note = r.stage == .rewrite ? "" : "FELL BACK to \(r.stage.rawValue): \(r.failure ?? "")"
        } else {
            do {
                output = try await rewriter.rewrite(s.raw, vocabulary: vocabulary)
                if let g = RewriteGuards.check(input: s.raw, output: output) { note = "GUARD FAIL: \(g)" } else { guardOK = true }
            } catch {
                note = "ERROR: \(error)"
            }
        }
        let secs = Date().timeIntervalSince(start)
        latencies.append(secs)

        let sim = similarity(output, s.ideal)
        let isExact = norm(output) == norm(s.ideal)
        if guardOK { guardPass += 1 }
        if guardOK && isExact { exact += 1 }
        if guardOK && sim >= 0.85 { close += 1 }

        let tag = s.category.map { " [\($0)]" } ?? ""
        let verdict = !guardOK ? "GUARD-FAIL" : isExact ? "EXACT" : sim >= 0.85 ? "CLOSE" : "DIFFERS"
        print("#\(i + 1)\(runs > 1 ? ".\(run)" : "")\(tag)  \(verdict)  sim=\(String(format: "%.2f", sim))  \(String(format: "%.2fs", secs))")
        print("  raw:    \(s.raw)")
        print("  output: \(output)")
        print("  ideal:  \(s.ideal)")
        if !note.isEmpty { print("  note:   \(note)") }
        print()
    }
}

func pct(_ n: Int) -> String { String(format: "%d/%d (%.0f%%)", n, total, total == 0 ? 0 : Double(n) / Double(total) * 100) }
latencies.sort()
let median = latencies.isEmpty ? 0 : latencies[latencies.count / 2]
print("Guards passed:        \(pct(guardPass))")
print("Match ideal exactly:  \(pct(exact))   (ignoring case/punctuation)")
print("Close to ideal (>=.85): \(pct(close))")
print(String(format: "Latency: median %.2fs, max %.2fs", median, latencies.last ?? 0))
print("\nExact/close are proxies. The Phase 0 bar is 'acceptable without edits' - read the DIFFERS rows yourself.")
