import Foundation

/// Why a rewrite was rejected. Any trip means "fall back to the next stage".
public enum GuardFailure: Equatable, CustomStringConvertible {
    case empty
    case lengthRatio(Double)
    case novelWords(Double, [String])
    case answerLike(String)

    public var description: String {
        switch self {
        case .empty: return "empty output"
        case .lengthRatio(let r): return String(format: "length ratio %.2f outside 0.3-1.3", r)
        case .novelWords(let f, let w):
            return String(format: "%.0f%% novel words (%@)", f * 100, w.prefix(6).joined(separator: ", "))
        case .answerLike(let p): return "starts like an answer/refusal: \"\(p)\""
        }
    }
}

public enum RewriteGuards {
    public static let lengthRange = 0.3...1.3
    public static let maxNovelFraction = 0.15

    /// Openers a small model uses when it answers or refuses instead of rewriting.
    static let answerPrefixes = [
        "sure", "certainly", "of course", "here's", "here is", "here are", "i'm sorry",
        "i am sorry", "sorry", "i can't", "i cannot", "i can not", "as an ai", "as a language model",
        "i'd be happy", "i would be happy", "okay,", "ok,", "absolutely", "rewritten",
    ]

    /// Returns nil when the output is acceptable.
    public static func check(input: String, output: String) -> GuardFailure? {
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { return .empty }

        let inWords = words(input)
        let outWords = words(out)
        if inWords.isEmpty { return .empty }

        let ratio = Double(outWords.count) / Double(inWords.count)
        if !lengthRange.contains(ratio) { return .lengthRatio(ratio) }

        let lowered = out.lowercased()
        let inLowered = input.lowercased()
        for p in answerPrefixes where lowered.hasPrefix(p) && !inLowered.hasPrefix(p) {
            return .answerLike(String(out.prefix(30)))
        }

        // Words in the output that the speaker never said. Numbers and number-words are
        // exempt because the model formats "two thirty" as "2:30".
        let spoken = Set(inWords.map(stem))
        let novel = outWords.filter { w in
            !spoken.contains(stem(w)) && !w.contains(where: \.isNumber)
        }
        let fraction = Double(novel.count) / Double(outWords.count)
        // One stray word ("meet Thursday" -> "meet on Thursday") is fine even in a short sentence.
        if fraction > maxNovelFraction && novel.count > 1 { return .novelWords(fraction, novel) }

        return nil
    }

    /// Lowercased alphanumeric tokens, apostrophes kept inside words.
    public static func words(_ s: String) -> [String] {
        s.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }
            .map { $0.replacingOccurrences(of: "’", with: "'") }
            .filter { !$0.isEmpty }
    }

    /// Crude suffix stripping so "meeting"/"meetings" and "moved"/"move" count as the same word.
    static func stem(_ w: String) -> String {
        var s = w
        if s.hasSuffix("'s") { s.removeLast(2) }
        for suffix in ["ing", "ed", "es", "s"] where s.count > suffix.count + 2 && s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
            break
        }
        return s
    }
}
