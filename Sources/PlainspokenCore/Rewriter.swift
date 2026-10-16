import Foundation
import FoundationModels

public struct RewriterConfig {
    public var instructions: String = Prompts.instructions
    public var temperature: Double = 0.2
    /// Use a one-field structured schema ({"text": ...}) instead of free-form text. Built
    /// dynamically because the @Generable macro plugin ships with Xcode, not the Command Line
    /// Tools. Off by default: in Phase 0 plain text scored as well or better and the guards
    /// already catch preambles.
    public var structuredOutput = false
    public var timeout: TimeInterval = 4
    /// Upper bound on transcript tokens per model call (about 230 words at the default).
    public var maxChunkTokens = 400
    public init() {}
}

public enum RewriteStage: String {
    case rewrite, lightCleanup, raw

    public var label: String {
        switch self {
        case .rewrite: return "rewritten"
        case .lightCleanup: return "light cleanup"
        case .raw: return "raw transcript"
        }
    }

    /// Higher is further down the fallback chain.
    var severity: Int {
        switch self {
        case .rewrite: return 0
        case .lightCleanup: return 1
        case .raw: return 2
        }
    }
}

public struct RewriteResult {
    public var text: String
    public var stage: RewriteStage
    /// Raw model output when it was rejected, for diagnostics.
    public var rejected: String?
    public var failure: String?
    public var seconds: Double
    /// How many pieces the transcript was split into (1 for normal utterances).
    public var chunks = 1
}

public enum RewriterError: Error, CustomStringConvertible {
    case unavailable(String)
    case timeout

    public var description: String {
        switch self {
        case .unavailable(let why): return "model unavailable: \(why)"
        case .timeout: return "timed out"
        }
    }
}

public struct Rewriter {
    public var config: RewriterConfig
    public init(config: RewriterConfig = .init()) { self.config = config }

    /// nil when the model is ready, otherwise a human-readable reason.
    public static func availabilityProblem() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "this device is not eligible for Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is not enabled (System Settings > Apple Intelligence & Siri)"
        case .unavailable(.modelNotReady): return "the on-device model is still downloading; try again shortly"
        case .unavailable(let other): return "unavailable: \(other)"
        @unknown default: return "unknown availability state"
        }
    }

    /// Instructions plus the per-utterance extras (custom terms, tone).
    func fullInstructions(toneHint: String?, vocabulary: [String]) -> String {
        var text = config.instructions
        let terms = Vocabulary.terms(from: vocabulary)
        if !terms.isEmpty {
            text += "\n\nThe speaker may mention these names or terms: \(terms.joined(separator: ", ")). "
                + "Speech recognition sometimes mishears them. If a word in the transcript sounds like one of them and fits the sentence, write it exactly as listed."
        }
        if let toneHint { text += "\nTone: \(toneHint)" }
        return text
    }

    /// A session with the model loaded ahead of time. Create it when the user starts talking and
    /// pass it to process() when they stop, so the model's start-up cost is hidden behind speech.
    /// Sessions keep conversation history, so one is good for exactly one utterance.
    public func makeWarmSession(toneHint: String? = nil, vocabulary: [String] = []) -> LanguageModelSession? {
        guard Self.availabilityProblem() == nil else { return nil }
        let session = LanguageModelSession(model: .default, instructions: fullInstructions(toneHint: toneHint, vocabulary: vocabulary))
        session.prewarm(promptPrefix: Prompt(Prompts.wrap("")))
        return session
    }

    /// Full fallback chain: AFM rewrite -> light cleanup -> raw transcript. Never throws.
    /// Long transcripts are split on sentence boundaries and each piece goes down the chain on
    /// its own, so one bad piece doesn't throw away the rest.
    public func process(
        _ transcript: String,
        toneHint: String? = nil,
        vocabulary: [String] = [],
        warm: LanguageModelSession? = nil
    ) async -> RewriteResult {
        let start = Date()
        let raw = Vocabulary.correct(transcript.trimmingCharacters(in: .whitespacesAndNewlines), terms: vocabulary)

        var chunks = [raw]
        // Only long transcripts pay for measuring the token budget.
        if raw.count > 900 {
            chunks = Chunker.split(raw, maxTokens: await chunkTokenBudget(toneHint: toneHint, vocabulary: vocabulary))
        }

        // Sequential on purpose: the on-device model handles one request at a time, so running
        // chunks concurrently only makes the later ones wait and trip their timeouts.
        var results: [RewriteResult] = []
        for (i, chunk) in chunks.enumerated() {
            results.append(await processChunk(chunk, toneHint: toneHint, vocabulary: vocabulary, session: i == 0 ? warm : nil))
        }
        var pieces: [String] = []
        var worst = RewriteStage.rewrite
        var firstFailure: String?
        var firstRejected: String?
        for r in results {
            pieces.append(r.text)
            if r.stage.severity > worst.severity { worst = r.stage }
            if firstFailure == nil { firstFailure = r.failure }
            if firstRejected == nil { firstRejected = r.rejected }
        }
        let text = pieces.enumerated().reduce("") { acc, item in
            acc.isEmpty ? item.element : acc + (acc.hasSuffix("\n") || item.element.hasPrefix("1.") ? "\n" : " ") + item.element
        }
        return RewriteResult(text: text, stage: worst, rejected: firstRejected, failure: firstFailure,
                             seconds: Date().timeIntervalSince(start), chunks: chunks.count)
    }

    private func processChunk(_ raw: String, toneHint: String?, vocabulary: [String], session: LanguageModelSession?) async -> RewriteResult {
        var rejected: String?
        var failure: String?
        do {
            let out = try await rewrite(raw, toneHint: toneHint, vocabulary: vocabulary, session: session)
            if let g = RewriteGuards.check(input: raw, output: out) {
                rejected = out
                failure = g.description
            } else {
                return RewriteResult(text: out, stage: .rewrite, rejected: nil, failure: nil, seconds: 0)
            }
        } catch {
            failure = "\(error)"
        }

        let cleaned = LightCleanup.apply(raw)
        if RewriteGuards.check(input: raw, output: cleaned) == nil {
            return RewriteResult(text: cleaned, stage: .lightCleanup, rejected: rejected, failure: failure, seconds: 0)
        }
        return RewriteResult(text: raw, stage: .raw, rejected: rejected, failure: failure, seconds: 0)
    }

    /// Tokens of transcript one call can take: the context window minus instructions, split
    /// between the input and the (similar-sized) rewritten output.
    func chunkTokenBudget(toneHint: String?, vocabulary: [String]) async -> Int {
        let model = SystemLanguageModel.default
        let instructions = fullInstructions(toneHint: toneHint, vocabulary: vocabulary)
        var used = instructions.count / 3  // conservative estimate where exact counting isn't available
        if #available(macOS 26.4, *) {
            used = (try? await model.tokenCount(for: Instructions(instructions))) ?? used
        }
        let contextBudget = max(150, (model.contextSize - used - 250) / 2)
        // Smaller pieces also keep each call inside the timeout and suit the small model better.
        return min(contextBudget, config.maxChunkTokens)
    }

    /// One AFM call, no guards. Uses `session` if given (a prewarmed one), otherwise a fresh
    /// session, so no context leaks between utterances.
    public func rewrite(
        _ transcript: String,
        toneHint: String? = nil,
        vocabulary: [String] = [],
        session: LanguageModelSession? = nil
    ) async throws -> String {
        if let why = Self.availabilityProblem() { throw RewriterError.unavailable(why) }

        let session = session ?? LanguageModelSession(
            model: .default, instructions: fullInstructions(toneHint: toneHint, vocabulary: vocabulary))
        let prompt = Prompts.wrap(transcript)
        let options = GenerationOptions(temperature: config.temperature)
        let schema = try Self.textSchema()
        let structured = config.structuredOutput
        let timeout = config.timeout

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                if structured {
                    let r = try await session.respond(to: prompt, schema: schema, options: options)
                    return try r.content.value(String.self, forProperty: "text")
                } else {
                    return try await session.respond(to: prompt, options: options).content
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw RewriterError.timeout
            }
            defer { group.cancelAll() }
            let first = try await group.next() ?? ""
            return first.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func textSchema() throws -> GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Rewrite",
            description: "The rewritten text",
            properties: [
                .init(
                    name: "text",
                    description: "The transcript rewritten as the speaker would have typed it. Rewritten text only.",
                    schema: DynamicGenerationSchema(type: String.self)
                )
            ]
        )
        return try GenerationSchema(root: root, dependencies: [])
    }
}
