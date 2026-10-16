import CoreGraphics
import Foundation

/// Global hold-to-talk detection for a modifier key, via a listen-only CGEventTap
/// (needs Input Monitoring). The tap lives on the main run loop, so callbacks arrive on main.
final class HotkeyMonitor {
    var key: HotkeyKey = .rightOption {
        didSet { isDown = false }
    }
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    var isRunning: Bool { tap != nil }

    /// Returns false when the tap can't be created (usually: Input Monitoring not granted yet).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
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
        tap = nil
        source = nil
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
            let down = event.flags.contains(key.flag)
            guard down != isDown else { return }
            isDown = down
            if down { onPress?() } else { onRelease?() }
        default:
            break
        }
    }

    deinit { stop() }
}
