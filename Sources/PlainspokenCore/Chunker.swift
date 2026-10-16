import Foundation

/// Splits long transcripts on sentence boundaries so each piece fits the model's small
/// (about 4K token) context together with the instructions and the reply.
public enum Chunker {
    /// Conservative: English runs about 4 characters per token, speech transcripts a bit less.
    static let charsPerToken = 3.2

    public static func split(_ text: String, maxTokens: Int) -> [String] {
        let maxChars = max(200, Int(Double(maxTokens) * charsPerToken))
        if text.count <= maxChars { return [text] }

        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s { sentences.append(s) }
        }
        if sentences.isEmpty { sentences = [text] }

        var chunks: [String] = []
        var current = ""
        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { chunks.append(t) }
            current = ""
        }
        for sentence in sentences {
            for piece in breakUp(sentence, maxChars: maxChars) {
                if current.count + piece.count > maxChars { flush() }
                current += piece
            }
        }
        flush()
        return chunks
    }

    /// A single run-on "sentence" longer than a chunk gets cut at word boundaries.
    private static func breakUp(_ s: String, maxChars: Int) -> [String] {
        if s.count <= maxChars { return [s] }
        var pieces: [String] = []
        var current = ""
        for word in s.split(separator: " ", omittingEmptySubsequences: false) {
            if current.count + word.count + 1 > maxChars, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + word
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.enumerated().map { $0.offset < pieces.count - 1 ? $0.element + " " : $0.element }
    }
}
