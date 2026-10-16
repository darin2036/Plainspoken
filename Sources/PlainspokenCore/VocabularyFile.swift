import Foundation

/// The user's custom vocabulary lives in a plain text file they can open in any editor:
/// ~/Library/Application Support/Plainspoken/vocabulary.txt
/// One entry per line. Blank lines and lines starting with # are ignored. An entry is a term
/// ("Jira") or a term with aliases for words the recognizer mishears ("Rovo=bravo|robo").
/// It is read fresh each time it's needed, so edits take effect on the next dictation.
public enum VocabularyFile {
    public static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plainspoken", isDirectory: true)
            .appendingPathComponent("vocabulary.txt")
    }

    static let header = """
    # Plainspoken custom vocabulary
    #
    # One name or term per line. Lines starting with # are ignored.
    # Edits take effect the next time you dictate; no restart needed.
    #
    # If the recognizer keeps mishearing a word, add what it hears after an equals sign.
    # Separate several with |. For example:
    #   Rovo=bravo|robo
    #
    """

    /// Creates the file with the explanatory header (and `seed` entries) if it doesn't exist yet.
    @discardableResult
    public static func ensureExists(seed: [String] = []) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let body = header + "\n" + seed.joined(separator: "\n") + (seed.isEmpty ? "" : "\n")
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// The entries in the file; empty if it doesn't exist.
    public static func load() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// For cheap change detection.
    public static var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
