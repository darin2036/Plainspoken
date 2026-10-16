import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

private let log = Logger(subsystem: "io.github.darin2036.Plainspoken", category: "insert")

/// The app that had focus when recording started.
struct InsertTarget: Equatable {
    let pid: pid_t
    let bundleID: String?
    let name: String
}

enum InsertOutcome: Equatable {
    case accessibility                 // written straight into the focused field
    case paste                         // via Cmd+V, clipboard restored afterwards
    case pastedBlind                   // Cmd+V with no text box detected; text deliberately left on the clipboard
    case copiedOnly(String)            // not typed; text left on the clipboard on purpose. Reason shown to the user
    case refused(String)               // deliberately not inserted (e.g. password field)

    var summary: String {
        switch self {
        case .accessibility: return "typed via Accessibility"
        case .paste: return "pasted"
        case .pastedBlind: return "pasted without a detected text box (text also left on the clipboard)"
        case .copiedOnly(let why): return "copied only: \(why)"
        case .refused(let why): return "not inserted: \(why)"
        }
    }

    var succeeded: Bool {
        switch self {
        case .accessibility, .paste, .pastedBlind: return true
        default: return false
        }
    }
}

/// Puts text into whatever field has focus. Tries Accessibility first (no clipboard involved),
/// then falls back to pasting with the user's clipboard saved and restored. If the user has
/// switched apps since they started talking, nothing is typed; the text goes to the clipboard
/// instead so it isn't lost and isn't sent to the wrong place.
@MainActor
final class Inserter {
    func currentTarget() -> InsertTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return InsertTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName ?? "another app")
    }

    func insert(_ text: String, expecting target: InsertTarget?, forcePaste: Bool = false) async -> InsertOutcome {
        guard Permission.accessibility.isGranted else {
            copyToClipboard(text)
            return .copiedOnly("Accessibility permission is needed to type for you")
        }
        if let target, let now = currentTarget(), now.pid != target.pid {
            copyToClipboard(text)
            return .copiedOnly("focus moved from \(target.name) to \(now.name)")
        }

        // Only type into something that looks like a text box. If focus is on a button, the
        // desktop, or a page that doesn't expose its fields, keep the text safe on the clipboard
        // instead of firing Cmd+V into the void (or into the wrong control).
        guard let element = focusedElement(pid: target?.pid ?? currentTarget()?.pid), isTextInput(element) else {
            if Prefs.pasteWhenNoTextBox {
                // We can't tell whether this landed, so don't restore the clipboard: if it
                // didn't, the text is still there to paste by hand.
                await insertViaPaste(text, restoreClipboard: false)
                return .pastedBlind
            }
            copyToClipboard(text)
            return .copiedOnly("no text box detected. Click into one and paste")
        }
        if isSecure(element) { return .refused("password field") }
        if !forcePaste, await insertViaAccessibility(text, into: element) { return .accessibility }
        // A text box that won't take Accessibility writes (many Electron/web fields, terminals): paste.
        await insertViaPaste(text)
        return .paste
    }

    // MARK: Accessibility

    /// The focused UI element of the target app, falling back to the system-wide focus.
    private func focusedElement(pid: pid_t?) -> AXUIElement? {
        func focus(of root: AXUIElement) -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        if let pid {
            let app = AXUIElementCreateApplication(pid)
            // Electron and Chromium apps keep their accessibility tree off until a client asks for it.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if let element = focus(of: app) { return element }
        }
        return focus(of: AXUIElementCreateSystemWide())
    }

    /// Text fields and areas, plus anything whose selection or value can be written (web
    /// contenteditable, custom editors that report an unusual role).
    private func isTextInput(_ element: AXUIElement) -> Bool {
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]
        if let role = string(element, kAXRoleAttribute), textRoles.contains(role) { return true }
        func settable(_ attribute: String) -> Bool {
            var result: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(element, attribute as CFString, &result) == .success && result.boolValue
        }
        return settable(kAXSelectedTextAttribute) || settable(kAXSelectedTextRangeAttribute)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == "AXSecureTextField" || string(element, kAXRoleAttribute) == "AXSecureTextField"
    }

    /// Writes into the selection (which replaces it, or inserts at the caret). Apps often report
    /// success without doing anything, so the field's value is read back to confirm, and a
    /// field whose value can't be read is left to the paste path rather than risk typing twice.
    private func insertViaAccessibility(_ text: String, into element: AXUIElement) async -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue,
              let before = string(element, kAXValueAttribute) else { return false }

        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }
        for delay in [60, 200] {
            try? await Task.sleep(for: .milliseconds(delay))
            if let after = string(element, kAXValueAttribute), after != before { return true }
        }
        log.info("AX write reported success but the field didn't change; falling back to paste")
        return false
    }

    // MARK: Paste

    private typealias SavedItem = [NSPasteboard.PasteboardType: Data]

    private func insertViaPaste(_ text: String, restoreClipboard: Bool = true) async {
        let pb = NSPasteboard.general
        let saved: [SavedItem] = (pb.pasteboardItems ?? []).map { item in
            var copy = SavedItem()
            for type in item.types { if let data = item.data(forType: type) { copy[type] = data } }
            return copy
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        // Tells clipboard managers not to record this temporary entry.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        let ours = pb.changeCount

        postCommandV()
        try? await Task.sleep(for: .milliseconds(300))

        // If anything else touched the clipboard in the meantime, leave their data alone.
        guard restoreClipboard, pb.changeCount == ours else { return }
        pb.clearContents()
        if !saved.isEmpty {
            pb.writeObjects(saved.map { dict in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            })
        }
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = Self.keyCode(forCharacter: "v") ?? CGKeyCode(kVK_ANSI_V)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    /// The key that types `character` on the current layout, so Cmd+V works on Dvorak and friends.
    private static func keyCode(forCharacter character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeys, 4, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length) == String(character) {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
