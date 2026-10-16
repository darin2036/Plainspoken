import AVFoundation

struct InputDevice: Identifiable, Hashable {
    /// AVCaptureDevice.uniqueID, which is also the CoreAudio device UID. Stable across reboots.
    let id: String
    let name: String
    let isBluetooth: Bool
    let isBuiltIn: Bool

    /// Name with a hint for Bluetooth mics, which switch headphones to call mode when used.
    var label: String { isBluetooth ? "\(name) (Bluetooth)" : name }
}

enum AudioDevices {
    // CoreAudio transport types ('blue', 'blea', 'bltn'); AVCaptureDevice.transportType reports them.
    private static let bluetooth: [Int32] = [0x626C7565, 0x626C6561]
    private static let builtIn: Int32 = 0x626C746E

    static func inputs() -> [InputDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map(describe).sorted { a, b in
            // Built-in first, then alphabetical.
            if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// What "System default" currently resolves to.
    static func systemDefault() -> InputDevice? {
        AVCaptureDevice.default(for: .audio).map(describe)
    }

    private static func describe(_ d: AVCaptureDevice) -> InputDevice {
        InputDevice(id: d.uniqueID, name: d.localizedName,
                    isBluetooth: bluetooth.contains(d.transportType),
                    isBuiltIn: d.transportType == builtIn)
    }
}
