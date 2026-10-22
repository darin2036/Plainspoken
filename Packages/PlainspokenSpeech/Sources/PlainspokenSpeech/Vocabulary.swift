import Foundation

/// Deterministic fixes for the user's custom terms after speech recognition: right casing
/// ("confluence" -> "Confluence"), one-letter slips ("Jera" -> "Jira"), and explicit aliases for
/// words the recognizer keeps mishearing. An entry is a plain term ("Jira") or a term with
/// aliases ("Rovo=bravo|robo"). Guessing fuzzier matches would also rewrite real words and names,
/// so anything else is left to the user's aliases.
public enum Vocabulary {
    /// The terms alone, without aliases. These go to the recognizer and the rewrite prompt.
    public static func terms(from entries: [String]) -> [String] {
        entries.map { entry in
            String(entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    public static func correct(_ text: String, terms entries: [String]) -> String {
        let terms = Self.terms(from: entries)
        if terms.isEmpty { return text }

        var out = text
        // Explicit aliases first: "bravo" -> "Rovo".
        for entry in entries {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let canonical = parts[0].trimmingCharacters(in: .whitespaces)
            guard !canonical.isEmpty else { continue }
            for alias in parts[1].split(separator: "|").map({ $0.trimmingCharacters(in: .whitespaces) }) where !alias.isEmpty {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: alias).replacingOccurrences(of: " ", with: "\\s+") + "\\b"
                out = out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: canonical),
                                               options: [.regularExpression, .caseInsensitive])
            }
        }
        // Multi-word terms first, exact match ignoring case ("opus guard" -> "Opus Guard").
        for term in terms where term.contains(" ") {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: term).replacingOccurrences(of: " ", with: "\\s+") + "\\b"
            out = out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: term),
                                           options: [.regularExpression, .caseInsensitive])
        }

        let singles = terms.filter { !$0.contains(" ") }
        if singles.isEmpty { return out }
        let exact = Dictionary(singles.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })

        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z'’]*") else { return out }
        let ns = out as NSString
        var result = ""
        var cursor = 0
        for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let word = ns.substring(with: m.range)
            result += replacement(for: word, exact: exact, terms: singles) ?? word
            cursor = m.range.location + m.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func replacement(for word: String, exact: [String: String], terms: [String]) -> String? {
        let lower = word.lowercased()
        if let t = exact[lower] { return t }
        guard lower.count >= 4 else { return nil }
        for t in terms {
            let tl = t.lowercased()
            guard tl.count >= 4, tl.first == lower.first, abs(tl.count - lower.count) <= 1 else { continue }
            // One edit for ordinary terms, two for long ones like "Confluence".
            let allowed = tl.count >= 9 ? 2 : 1
            if editDistance(lower, tl) <= allowed { return t }
        }
        return nil
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
