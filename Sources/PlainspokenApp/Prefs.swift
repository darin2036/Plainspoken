import CoreGraphics
import PlainspokenCore
import Foundation

/// Modifier keys usable as a hold-to-talk key. Raw value is the hardware key code, so
/// right and left variants are distinguishable.
enum HotkeyKey: Int, CaseIterable, Identifiable {
    case rightOption = 61
    case rightCommand = 54
    case rightControl = 62
    case rightShift = 60
    case fn = 63

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .rightShift: return "Right Shift (⇧)"
        case .fn: return "Fn / Globe"
        }
    }

    var shortLabel: String {
        switch self {
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        case .rightShift: return "Right Shift"
        case .fn: return "Fn"
        }
    }

    /// Flag that is set while any key of this modifier family is held.
    var flag: CGEventFlags {
        switch self {
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        case .rightShift: return .maskShift
        case .fn: return .maskSecondaryFn
        }
    }
}

enum Prefs {
    private static let hotkeyKey = "hotkey"

    static var hotkey: HotkeyKey {
        get { HotkeyKey(rawValue: UserDefaults.standard.integer(forKey: hotkeyKey)) ?? .rightOption }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: hotkeyKey) }
    }

    /// UID of the chosen microphone; empty means "follow the system default".
    static var micUID: String {
        get { UserDefaults.standard.string(forKey: "micUID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "micUID") }
    }

    /// When no text box is detected: true (default) pastes anyway, since many apps hide their
    /// fields from Accessibility, and leaves the text on the clipboard as a safety net.
    /// false only copies the text to the clipboard.
    static var pasteWhenNoTextBox: Bool {
        get { UserDefaults.standard.object(forKey: "pasteWhenNoTextBox") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pasteWhenNoTextBox") }
    }

    /// Small always-on pill at the bottom of the screen. On by default.
    static var showIdleIndicator: Bool {
        get { UserDefaults.standard.object(forKey: "showIdleIndicator") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showIdleIndicator") }
    }

    static var visualizer: VisualizerStyle {
        get { VisualizerStyle(rawValue: UserDefaults.standard.string(forKey: "visualizer") ?? "") ?? .oscilloscope }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "visualizer") }
    }

    static var engine: SpeechEngine {
        get { SpeechEngine(rawValue: UserDefaults.standard.string(forKey: "speechEngine") ?? "") ?? .speechTranscriber }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "speechEngine") }
    }

    static var whisperModel: WhisperModel {
        get { WhisperModel(rawValue: UserDefaults.standard.string(forKey: "whisperModel") ?? "") ?? .balanced }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "whisperModel") }
    }

    /// Whisper language code (e.g. "en"); empty means "match the system language".
    static var whisperLanguage: String {
        get { UserDefaults.standard.string(forKey: "whisperLanguage") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "whisperLanguage") }
    }

    /// Identifier of the chosen recognition locale (e.g. "en_AU"); empty means "follow the system".
    static var localeID: String {
        get { UserDefaults.standard.string(forKey: "speechLocale") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "speechLocale") }
    }

    /// Check GitHub for a newer release about once a day. On by default; the one standing network
    /// request the app makes, so it has its own switch.
    static var autoCheckUpdates: Bool {
        get { UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoCheckUpdates") }
    }

    static var lastUpdateCheck: Date {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    /// Older versions kept the vocabulary in preferences. Move it into the vocabulary file once.
    static func migrateVocabularyToFile() {
        let old = UserDefaults.standard.stringArray(forKey: "vocabulary") ?? []
        let existed = FileManager.default.fileExists(atPath: VocabularyFile.url.path)
        VocabularyFile.ensureExists(seed: existed ? [] : old)
        if !old.isEmpty { UserDefaults.standard.removeObject(forKey: "vocabulary") }
    }
}
