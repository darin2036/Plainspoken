import CoreGraphics
import PlainspokenCore
import Foundation

/// Keys usable as a hold-to-talk key. Raw value is the hardware key code, so right and left
/// modifier variants are distinguishable. Modifiers are watched with an event tap (needs Input
/// Monitoring); function keys are registered as a system hotkey, which needs no permission.
enum HotkeyKey: Int, CaseIterable, Identifiable {
    case rightOption = 61
    case rightCommand = 54
    case rightControl = 62
    case rightShift = 60
    case leftControl = 59
    case leftOption = 58
    case leftCommand = 55
    case leftShift = 56
    case fn = 63
    case f1 = 122, f2 = 120, f3 = 99, f4 = 118, f5 = 96, f6 = 97
    case f7 = 98, f8 = 100, f9 = 101, f10 = 109, f11 = 103, f12 = 111

    var id: Int { rawValue }

    /// Modifier keys need the event tap; everything else is a plain registered hotkey.
    var isModifier: Bool { flag != nil }

    static let modifierKeys: [HotkeyKey] = allCases.filter(\.isModifier)
    static let functionKeys: [HotkeyKey] = allCases.filter { !$0.isModifier }

    var label: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .rightShift: return "Right Shift (⇧)"
        case .leftControl: return "Left Control (⌃)"
        case .leftOption: return "Left Option (⌥)"
        case .leftCommand: return "Left Command (⌘)"
        case .leftShift: return "Left Shift (⇧)"
        case .fn: return "Fn / Globe"
        default: return shortLabel
        }
    }

    var shortLabel: String {
        switch self {
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        case .rightShift: return "Right Shift"
        case .leftControl: return "Left Control"
        case .leftOption: return "Left Option"
        case .leftCommand: return "Left Command"
        case .leftShift: return "Left Shift"
        case .fn: return "Fn"
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        }
    }

    /// Flag that is set while any key of this modifier family is held; nil for non-modifier keys.
    var flag: CGEventFlags? {
        switch self {
        case .rightOption, .leftOption: return .maskAlternate
        case .rightCommand, .leftCommand: return .maskCommand
        case .rightControl, .leftControl: return .maskControl
        case .rightShift, .leftShift: return .maskShift
        case .fn: return .maskSecondaryFn
        default: return nil
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

    /// Older versions kept the vocabulary in preferences. Move it into the vocabulary file once.
    static func migrateVocabularyToFile() {
        let old = UserDefaults.standard.stringArray(forKey: "vocabulary") ?? []
        let existed = FileManager.default.fileExists(atPath: VocabularyFile.url.path)
        VocabularyFile.ensureExists(seed: existed ? [] : old)
        if !old.isEmpty { UserDefaults.standard.removeObject(forKey: "vocabulary") }
    }
}
