import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import IOKit.hid

enum Permission: CaseIterable, Identifiable {
    case microphone, inputMonitoring, accessibility

    var id: Self { self }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }

    var reason: String {
        switch self {
        case .microphone: return "Hear what you say"
        case .inputMonitoring: return "Detect the hold-to-talk key"
        case .accessibility: return "Type the result into other apps"
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    /// Shows the system prompt where one exists, otherwise sends the user to System Settings.
    /// macOS only prompts once per permission; after a denial Settings is the only way back.
    @MainActor func request() {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                openSettings()
            }
        case .inputMonitoring:
            // Input Monitoring only lists an app after it has asked. Ask every way macOS
            // recognizes (the event-tap attempt is what reliably adds the entry), then open Settings.
            let granted = CGRequestListenEventAccess() || IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            AppState.shared.attemptHotkeyTap()
            if !granted { openSettings() }
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { openSettings() }
        }
    }

    func openSettings() {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        case .accessibility: pane = "Privacy_Accessibility"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
