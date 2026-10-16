import AppKit
import SwiftUI

/// Dev hook: `Plainspoken --render-settings <dir>` snapshots each Settings tab. The tabs hold
/// AppKit-backed controls, which ImageRenderer can't draw, so each one is hosted in a real
/// (offscreen) window and its view is cached to a bitmap.
@MainActor
func renderSettings(to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let state = AppState.shared
    func snapshot<V: View>(_ view: V, as name: String) {
        let host = NSHostingView(rootView: view.frame(width: 480).background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("wrote \(dir)/\(name).png \(Int(size.width))x\(Int(size.height))")
    }
    snapshot(GeneralSettingsTab(state: state), as: "settings-general")
    snapshot(AppearanceSettingsTab(state: state), as: "settings-appearance")
    snapshot(DictationSettingsTab(state: state), as: "settings-dictation")
}

/// Dev hook behind `--insert-test`.
@MainActor
func runInsertTest(inserter: Inserter, text: String, delay: Double, forcePaste: Bool, activate bundleID: String?, thenSwitchTo other: String? = nil) async {
    func say(_ s: String) { print(s); fflush(stdout) }
    // Describe the clipboard without asking for a particular type: asking for .string on an
    // RTF-only clipboard makes the system add converted plain-text flavors, which would muddy the test.
    func describe() -> String {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.map { "\($0.rawValue)=\(item.data(forType: $0)?.count ?? -1)" }.joined(separator: ",")
        }.joined(separator: " | ")
    }
    let before = describe()
    say("clipboard before: \(before); inserting in \(delay)s")
    try? await Task.sleep(for: .seconds(delay))
    // Bring the named app forward so the test never types into whatever happens to be frontmost.
    if let bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        app.activate()
        try? await Task.sleep(for: .seconds(1))
    }
    let target = inserter.currentTarget()
    if let bundleID, target?.bundleID != bundleID { say("target is \(target?.name ?? "none"), not \(bundleID); aborting"); exit(1) }
    say("target: \(target?.name ?? "none")")
    // Simulates the user switching apps between starting to talk and the text arriving.
    if let other, let app = NSRunningApplication.runningApplications(withBundleIdentifier: other).first {
        app.activate()
        try? await Task.sleep(for: .seconds(1))
        say("switched to \(inserter.currentTarget()?.name ?? "?") before inserting")
    }
    let outcome = await inserter.insert(text, expecting: target, forcePaste: forcePaste)
    try? await Task.sleep(for: .milliseconds(500))
    let after = describe()
    say("outcome: \(outcome.summary)")
    say("clipboard after:  \(after)  (\(after == before ? "unchanged" : "CHANGED"))")
    exit(0)
}

/// Dev hook behind `--mic-test`: lists input devices, captures 2 s, reports format, startup
/// latency and level, then quits. Needs the app's Microphone permission.
@MainActor
func runMicTest(uid: String?) async {
    func say(_ s: String) { print(s); fflush(stdout) }
    say("input devices:")
    for d in AudioDevices.inputs() { say("  \(d.label)  [\(d.id)]\(d.isBuiltIn ? " built-in" : "")") }
    say("system default: \(AudioDevices.systemDefault()?.label ?? "none")")

    let capture = AudioCapture()
    let started = Date()
    do {
        let stream = try capture.start(deviceUID: uid)
        say("capturing from: \(capture.deviceName)")
        var first: Double?
        var frames = 0
        var peak: Float = 0
        var format = ""
        let stopper = Task {
            try? await Task.sleep(for: .seconds(2))
            capture.stop()
        }
        for await buffer in stream {
            if first == nil {
                first = Date().timeIntervalSince(started)
                format = "\(Int(buffer.format.sampleRate)) Hz, \(buffer.format.channelCount) ch"
            }
            frames += Int(buffer.frameLength)
            if let d = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(d[i])) }
            }
        }
        stopper.cancel()
        say(String(format: "first buffer after %.0f ms, format %@, %d frames, peak %.4f",
                   (first ?? 0) * 1000, format, frames, peak))
    } catch {
        say("mic test failed: \(error)")
    }
    exit(0)
}

/// Dev hook: `Plainspoken --render-previews <dir>` writes PNGs of the HUD pieces and exits.
/// Lets visualizer changes be checked without a microphone or screen-recording permission.
@MainActor
func renderPreviews(to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let waveform = WaveformBuffer()
    for _ in 0..<60 { waveform.pushSynthetic(seconds: 1.0 / 60) }

    func save<V: View>(_ view: V, as name: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { print("render failed: \(name)"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("wrote \(dir)/\(name).png")
    }

    // Fire needs many frames to build up heat, so step it by hand with the synthetic voice
    // running, and snapshot both visualizers at a few moments (the voice has gaps between syllables).
    let sim = FireSimulation()
    var n = 0
    var lastSnap = -100
    for step in 0..<400 where n < 5 {
        waveform.pushSynthetic(seconds: 1.0 / 30)
        let frame = sim.step(waveform: waveform)
        // Only snapshot while the synthetic voice is actually sounding.
        let loud = waveform.latest(1024).map(abs).max() ?? 0
        guard step > 40, loud > 0.3, step - lastSnap >= 12, let frame else { continue }
        lastSnap = step
        defer { n += 1 }
        save(OscilloscopeView(waveform: waveform).frame(width: 118, height: 22).background(.black), as: "scope-\(n)")
        save(Image(decorative: frame, scale: 1).interpolation(.none).resizable().frame(width: 118, height: 22).background(.black), as: "fire-\(n)")
    }

    // Resting pill, ready and not ready.
    let idle = HUDModel()
    idle.phase = .idle
    idle.ready = true
    save(HUDView(model: idle, waveform: waveform).frame(width: 340, height: 110).background(Color(white: 0.55)), as: "pill-idle")
    idle.ready = false
    save(HUDView(model: idle, waveform: waveform).frame(width: 340, height: 110).background(Color(white: 0.55)), as: "pill-idle-setup")

    // Full pill with a partial transcript.
    let model = HUDModel()
    model.style = .oscilloscope
    model.phase = .listening
    model.partial = "Let's meet on Tuesday, no wait, Thursday afternoon"
    save(HUDView(model: model, waveform: waveform).frame(width: 340, height: 110).background(Color(white: 0.55)), as: "pill-listening")
    model.phase = .result("Let's meet on Thursday afternoon and send the notes to the whole team.")
    save(HUDView(model: model, waveform: waveform).frame(width: 340, height: 110).background(Color(white: 0.55)), as: "pill-result")
}
