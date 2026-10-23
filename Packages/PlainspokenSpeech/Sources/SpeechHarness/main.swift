import Foundation
import PlainspokenSpeech

// speech-harness: run a recording through the shared speech layer and report what came back.
//
//   speech-harness FILE [options]
//     --engine speech|dictation   which Apple recognizer (default speech)
//     --locale en_US              language model (default: this Mac's language)
//     --vocab "Jira,Rovo=bravo"   custom vocabulary, comma separated (aliases after =, split with |)
//     --vocab-file PATH           vocabulary file, one entry per line
//     --out PATH                  write the transcript text to a file
//     --json PATH                 write segments (text, start, end) as JSON
//     --show                      also print the transcript text and segments
//   speech-harness --locales [--engine speech|dictation]
//
// Without --show only counts and timings are printed, so a private recording is not echoed to a terminal.

NetworkGuard.install()  // the speech layer must work with the network blocked

var path: String?
var engine = AppleSpeechEngine.speechTranscriber
var locale = Locale.current
var vocabulary: [String] = []
var out: String?
var jsonOut: String?
var show = false
var listLocales = false

var args = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
while !args.isEmpty {
    let arg = args.removeFirst()
    func value() -> String {
        if args.isEmpty { fail("\(arg) needs a value") }
        return args.removeFirst()
    }
    switch arg {
    case "--engine":
        switch value() {
        case "speech": engine = .speechTranscriber
        case "dictation": engine = .dictationTranscriber
        default: fail("--engine must be speech or dictation")
        }
    case "--locale": locale = Locale(identifier: value())
    case "--vocab": vocabulary += value().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    case "--vocab-file":
        let file = value()
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { fail("can't read \(file)") }
        vocabulary += VocabularyFileStore.parse(text)
    case "--out": out = value()
    case "--json": jsonOut = value()
    case "--show": show = true
    case "--locales": listLocales = true
    case "-h", "--help": fail("usage: speech-harness FILE [--engine speech|dictation] [--locale en_US] [--vocab ...] [--vocab-file PATH] [--out PATH] [--json PATH] [--show] | --locales")
    default:
        if arg.hasPrefix("--") { fail("unknown option \(arg)") }
        path = arg
    }
}

if listLocales {
    let locales = await SpeechAssets.supportedLocales(for: engine)
    print("\(locales.count) locales for \(engine.label):")
    print(locales.map(\.identifier).joined(separator: " "))
    exit(0)
}
guard let path else { fail("give a file to transcribe (see --help)") }
let url = URL(fileURLWithPath: path)
guard FileManager.default.fileExists(atPath: url.path) else { fail("no such file: \(path)") }

let started = Date()
var lastStage = ""
do {
    let transcript = try await FileTranscriber.transcribe(fileAt: url, engine: engine, locale: locale, vocabulary: vocabulary) { progress in
        let stage = progress.stage == .preparingModel ? "preparing speech model" : "transcribing"
        if stage != lastStage {
            lastStage = stage
            FileHandle.standardError.write(Data("  \(stage)…\n".utf8))
        }
    }
    let elapsed = Date().timeIntervalSince(started)
    let words = transcript.text.split(whereSeparator: \.isWhitespace).count
    let covered = transcript.segments.last?.end ?? 0
    let ordered = zip(transcript.segments, transcript.segments.dropFirst()).allSatisfy { $0.start <= $1.start }
    print("file:        \(url.lastPathComponent)")
    print("engine:      \(engine.label)  locale: \(locale.identifier)  vocabulary entries: \(vocabulary.count)")
    print("segments:    \(transcript.segments.count)   words: \(words)   covers: 0–\(String(format: "%.1f", covered)) s")
    print("in order:    \(ordered ? "yes" : "NO")")
    print("took:        \(String(format: "%.1f", elapsed)) s")
    if let out { try transcript.text.write(toFile: out, atomically: true, encoding: .utf8); print("text →       \(out)") }
    if let jsonOut {
        let rows = transcript.segments.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: jsonOut))
        print("segments →   \(jsonOut)")
    }
    if show {
        print("\ntranscript: \(transcript.text)")
        for s in transcript.segments { print(String(format: "  [%.2f-%.2f] ", s.start, s.end) + s.text) }
    }
} catch {
    FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
    exit(1)
}
