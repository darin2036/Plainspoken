import Foundation

/// Deterministic fallback: strip fillers, fix spacing, capitalize. Never changes meaning.
public enum LightCleanup {
    static let fillerPatterns = [
        #"(?i)\b(um+|uh+|er+|erm|hmm+)\b[,.]?\s*"#,
        #"(?i)\b(you know|i mean|kind of|sort of),\s+"#,
        #"(?i)\bso,?\s+like,?\s+"#,
    ]

    public static func apply(_ text: String) -> String {
        var s = text
        for pattern in fillerPatterns {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = s.first else { return s }
        s = first.uppercased() + s.dropFirst()
        s = s.replacingOccurrences(of: #"\bi\b(?=[\s,.'’])"#, with: "I", options: .regularExpression)
        if let last = s.last, !".!?".contains(last) { s += "." }
        return s
    }
}
