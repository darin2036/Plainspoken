import Foundation

/// The user's custom vocabulary lives in a plain text file they can open in any editor:
/// ~/Library/Application Support/Plainspoken/vocabulary.txt
/// One entry per line. Blank lines and lines starting with # are ignored. An entry is a term
/// ("Jira") or a term with aliases for words the recognizer mishears ("Rovo=bravo|robo").
/// It is read fresh each time it's needed, so edits take effect on the next dictation.
/// The reading and writing is the shared store in the PlainspokenSpeech package.
public enum VocabularyFile {
    private static let store = VocabularyFileStore(appName: "Plainspoken")

    public static var url: URL { store.url }

    /// Creates the file with the explanatory header (and `seed` entries) if it doesn't exist yet.
    @discardableResult
    public static func ensureExists(seed: [String] = []) -> URL { store.ensureExists(seed: seed) }

    /// The entries in the file; empty if it doesn't exist.
    public static func load() -> [String] { store.load() }

    /// For cheap change detection.
    public static var modificationDate: Date? { store.modificationDate }
}
