import AppKit
import Observation
import SwiftUI

enum HUDPhase: Equatable {
    case hidden
    case idle  // small resting pill that shows the app is alive
    case listening
    case working(String)  // e.g. "Transcribing…"
    case result(String)   // final text, shown briefly
    case notice(String)   // errors and fallbacks
}

@MainActor @Observable
final class HUDModel {
    var phase = HUDPhase.hidden
    var partial = ""
    var style = Prefs.visualizer
    /// False while setup is incomplete (permissions, speech model); the idle pill turns orange.
    var ready = false
}

/// Floating pill at the bottom of the screen. Never takes focus, so the app you're typing
/// into stays frontmost.
@MainActor
final class HUDController {
    let model = HUDModel()
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?
    private var idleEnabled = false
    private var idleTimer: Timer?

    private static let panelSize = NSSize(width: 340, height: 110)

    init(waveform: WaveformBuffer) {
        panel = HUDPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize))
        let host = NSHostingView(rootView: HUDView(model: model, waveform: waveform))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
    }

    func showListening() {
        hideTask?.cancel()
        model.partial = ""
        model.phase = .listening
        present()
    }

    func setPartial(_ text: String) { model.partial = text }

    func showWorking(_ text: String) {
        hideTask?.cancel()
        model.phase = .working(text)
        present()
    }

    func showResult(_ text: String, for seconds: Double = 2.5) {
        model.phase = .result(text)
        present()
        hide(after: seconds)
    }

    func showNotice(_ text: String, for seconds: Double = 3) {
        model.phase = .notice(text)
        present()
        hide(after: seconds)
    }

    /// Returns to the resting pill (or hides completely when the idle indicator is off).
    func hide(after seconds: Double = 0) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled, let self else { return }
            if self.idleEnabled {
                self.model.phase = .idle
                return
            }
            self.model.phase = .hidden
            // Let the fade-out finish before pulling the window.
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled, self.model.phase == .hidden { self.panel.orderOut(nil) }
        }
    }

    /// Turns the always-on resting pill on or off.
    func setIdleEnabled(_ on: Bool) {
        idleEnabled = on
        idleTimer?.invalidate()
        idleTimer = nil
        if on {
            if model.phase == .hidden { model.phase = .idle }
            present()
            // Follow the pointer between displays (and Dock changes) while resting.
            idleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.model.phase == .idle else { return }
                    self.present()
                }
            }
        } else if model.phase == .idle {
            hide()
        }
    }

    func setReady(_ ready: Bool) {
        if model.ready != ready { model.ready = ready }
    }

    private func present() {
        // The screen under the pointer is almost always the one being worked on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = Self.panelSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 14,
            width: size.width, height: size.height
        )
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

private final class HUDPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // the pill draws its own
        appearance = NSAppearance(named: .darkAqua)  // dark translucent material, light-green scope reads well on it
        level = .statusBar
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct HUDView: View {
    let model: HUDModel
    let waveform: WaveformBuffer

    private var visible: Bool { model.phase != .hidden }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            ZStack(alignment: .bottom) {
                if model.phase == .idle {
                    idlePill.transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)))
                } else {
                    pill.transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottom)))
                }
            }
            .opacity(visible ? 1 : 0)
            .animation(.spring(duration: 0.3), value: model.phase == .idle)
            .animation(.spring(duration: 0.3), value: visible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var line: (text: String, color: Color)? {
        switch model.phase {
        case .hidden, .idle: return nil
        case .listening: return model.partial.isEmpty ? nil : (model.partial, .white.opacity(0.85))
        case .working(let t): return (t, .white.opacity(0.6))
        case .result(let t): return (t, .white)
        case .notice(let t): return (t, .orange)
        }
    }

    private var showsVisualizer: Bool {
        switch model.phase {
        case .listening, .working: return true
        default: return false
        }
    }

    /// Tiny resting pill: proof the app is running. Orange while setup is unfinished.
    private var idlePill: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().fill((model.ready ? Color.white : Color.orange).opacity(model.ready ? 0.10 : 0.55)))
            .overlay(Capsule().strokeBorder((model.ready ? Color.white : Color.orange).opacity(0.45), lineWidth: 0.75))
            .frame(width: 38, height: 7)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
    }

    private var pill: some View {
        VStack(spacing: 5) {
            if showsVisualizer {
                VisualizerView(style: model.style, waveform: waveform)
                    .frame(width: 118, height: 22)
                    .opacity(model.phase == .listening ? 1 : 0.35)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            if let line {
                Text(line.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(line.color)
                    .lineLimit(model.phase.isResult ? 2 : 1)
                    .truncationMode(.head)  // newest words stay visible while talking
                    .multilineTextAlignment(.center)
                    .frame(width: 220)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .animation(.spring(duration: 0.25), value: line?.text == nil)
    }
}

private extension HUDPhase {
    var isResult: Bool {
        if case .result = self { return true }
        return false
    }
}
