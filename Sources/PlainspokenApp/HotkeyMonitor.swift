import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Global hold-to-talk detection. Modifier keys use a listen-only CGEventTap (needs Input
/// Monitoring) that only sees modifier changes. Function keys use a Carbon system hotkey, which
/// needs no permission and never sees other keystrokes. Callbacks arrive on the main thread.
final class HotkeyMonitor {
    var key: HotkeyKey = .rightOption {
        didSet {
            guard key != oldValue else { return }
            let wasRunning = isRunning
            stop()
            if wasRunning { start() }
        }
    }
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isDown = false

    var isRunning: Bool { tap != nil || hotKeyRef != nil }

    /// Returns false when the hotkey can't be set up (modifier keys: usually Input Monitoring
    /// not granted yet; function keys: another app or the system already owns the key).
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        return key.isModifier ? startTap() : startHotKey()
    }

    private func startHotKey() -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x504C_534E), id: 1) // 'PLSN'
        guard RegisterEventHotKey(UInt32(key.rawValue), 0, id, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return false }

        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var handler: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            monitor.handleHotKey(pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
            return noErr
        }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            UnregisterEventHotKey(ref)
            return false
        }
        hotKeyRef = ref
        handlerRef = handler
        return true
    }

    private func handleHotKey(pressed: Bool) {
        guard pressed != isDown else { return }
        isDown = pressed
        if pressed { onPress?() } else { onRelease?() }
    }

    private func startTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        tap = nil
        source = nil
        hotKeyRef = nil
        handlerRef = nil
        isDown = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system turns slow taps off; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard code == key.rawValue else { return }
            guard let flag = key.flag else { return }
            let down = event.flags.contains(flag)
            guard down != isDown else { return }
            isDown = down
            if down { onPress?() } else { onRelease?() }
        default:
            break
        }
    }

    deinit { stop() }
}
