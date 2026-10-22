import Foundation

/// A custom vocabulary kept in a plain text file the user can open in any editor, for example
/// `~/Library/Application Support/Relaytake/vocabulary.txt`. One entry per line; blank lines and lines
/// starting with `#` are ignored. An entry is a term ("Jira") or a term with aliases for words the
/// recognizer mishears ("Rovo=bravo|robo"). It is read fresh each time, so edits apply next time.
public struct VocabularyFileStore: Sendable {
    public let url: URL
    private let appName: String

    /// `appName` names the folder under Application Support. Pass `directory` to put the file elsewhere (tests).
    public init(appName: String, directory: URL? = nil) {
        self.appName = appName
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
        url = base.appendingPathComponent("vocabulary.txt")
    }

    var header: String {
        """
        # \(appName) custom vocabulary
        #
        # One name or term per line. Lines starting with # are ignored.
        # Edits take effect the next time speech is recognized; no restart needed.
        #
        # If the recognizer keeps mishearing a word, add what it hears after an equals sign.
        # Separate several with |. For example:
        #   Rovo=bravo|robo
        #
        """
    }

    /// Creates the file with the explanatory header (and `seed` entries) if it doesn't exist yet.
    @discardableResult
    public func ensureExists(seed: [String] = []) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let body = header + "\n" + seed.joined(separator: "\n") + (seed.isEmpty ? "" : "\n")
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// The entries in the file; empty if it doesn't exist.
    public func load() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Self.parse(text)
    }

    public static func parse(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// For cheap change detection.
    public var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
