import AppKit
import AVFoundation
import Observation
import os
import FoundationModels
import PlainspokenCore

private let log = Logger(subsystem: "io.github.darin2036.Plainspoken", category: "app")

enum SpeechModelState: Equatable {
    case preparing(Double?)  // download fraction, nil while just checking
    case ready
    case failed(String)
}

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    private(set) var granted: [Permission: Bool] = [:]
    private(set) var isListening = false
    private(set) var isFinalizing = false
    private(set) var hotkeyActive = false
    private(set) var speechModel = SpeechModelState.preparing(nil)
    private(set) var partialText = ""
    /// What the user would get typed: the rewritten text (or its fallback).
    private(set) var lastTranscript: String?
    /// What the recognizer heard, before any rewriting.
    private(set) var lastHeard: String?
    private(set) var lastTiming: String?
    private(set) var lastRecording: String?
    private(set) var statusNote: String?

    var hotkey: HotkeyKey = Prefs.hotkey {
        didSet {
            Prefs.hotkey = hotkey
            monitor.key = hotkey
        }
    }

    private(set) var inputDevices: [InputDevice] = AudioDevices.inputs()
    private(set) var systemDefaultInput: InputDevice? = AudioDevices.systemDefault()

    /// Chosen microphone UID; empty follows the system default.
    var micUID: String = Prefs.micUID {
        didSet { Prefs.micUID = micUID }
    }

    /// The microphone a recording would use right now, for display.
    var activeMicName: String {
        if !micUID.isEmpty {
            if let d = inputDevices.first(where: { $0.id == micUID }) { return d.label }
            return "Selected mic not connected, using \(systemDefaultInput?.label ?? "default")"
        }
        return systemDefaultInput.map { "\($0.label), system default" } ?? "No microphone"
    }

    var pasteWhenNoTextBox: Bool = Prefs.pasteWhenNoTextBox {
        didSet { Prefs.pasteWhenNoTextBox = pasteWhenNoTextBox }
    }

    var showIdleIndicator: Bool = Prefs.showIdleIndicator {
        didSet {
            Prefs.showIdleIndicator = showIdleIndicator
            hud.setIdleEnabled(showIdleIndicator)
        }
    }

    var visualizer: VisualizerStyle = Prefs.visualizer {
        didSet {
            Prefs.visualizer = visualizer
            hud.model.style = visualizer
        }
    }

    var engine: SpeechEngine = Prefs.engine {
        didSet {
            Prefs.engine = engine
            prepareSpeechModel()
        }
    }

    /// Recognition locale identifier; empty follows the system locale.
    var localeID: String = Prefs.localeID {
        didSet {
            Prefs.localeID = localeID
            prepareSpeechModel()
        }
    }

    /// How many entries the vocabulary file currently holds (the file is the source of truth).
    private(set) var vocabularyCount = 0

    var allGranted: Bool { Permission.allCases.allSatisfy { granted[$0] == true } }

    @ObservationIgnored private let monitor = HotkeyMonitor()
    @ObservationIgnored private let audio = AudioCapture()
    @ObservationIgnored private(set) lazy var hud = HUDController(waveform: audio.waveform)
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var speechLocale = Locale.current
    @ObservationIgnored private var started = false
    @ObservationIgnored private var vocabularyStamp: Date?
    @ObservationIgnored private let rewriter = Rewriter()
    @ObservationIgnored private let inserter = Inserter()
    /// The app that was frontmost when the key went down; text is only typed there.
    @ObservationIgnored private var insertTarget: InsertTarget?
    /// Model session loaded while the user talks, so the rewrite doesn't pay start-up cost.
    @ObservationIgnored private var warmSession: LanguageModelSession?
    @ObservationIgnored private var releasedAt = Date()

    func start() {
        guard !started else { return }
        started = true

        monitor.key = hotkey
        monitor.onPress = { [weak self] in MainActor.assumeIsolated { self?.beginRecording() } }
        monitor.onRelease = { [weak self] in MainActor.assumeIsolated { self?.endRecording() } }

        Prefs.migrateVocabularyToFile()
        refresh()
        hud.setIdleEnabled(showIdleIndicator)
        // Microphones come and go (headphones connect, USB mics get plugged in).
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshInputDevices() }
            }
        }
        // Permissions are granted in System Settings while we run, so poll instead of asking
        // the user to relaunch. Cheap: three preflight calls per second.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        // First launch: surface the checklist's system prompts right away.
        for p in Permission.allCases where p != .accessibility && !p.isGranted { p.request() }
        prepareSpeechModel()

        // Dev hook: `Plainspoken --insert-test "text" [seconds] [paste]` waits, then inserts into the
        // focused field of whatever app is frontmost, and reports how and whether the clipboard survived.
        if let i = CommandLine.arguments.firstIndex(of: "--insert-test"), i + 1 < CommandLine.arguments.count {
            let args = Array(CommandLine.arguments[(i + 1)...])
            Task { await runInsertTest(inserter: inserter, text: args[0], delay: Double(args.dropFirst().first ?? "") ?? 3, forcePaste: args.contains("paste"), activate: args.first { $0.hasPrefix("app=") }.map { String($0.dropFirst(4)) }, thenSwitchTo: args.first { $0.hasPrefix("switch=") }.map { String($0.dropFirst(7)) }) }
        }

        // Dev hook: `Plainspoken --mic-test [uid]` records 2 s from a mic, prints what arrived, and quits.
        if let i = CommandLine.arguments.firstIndex(of: "--mic-test") {
            let uid = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
            Task { await runMicTest(uid: uid) }
        }

        // Dev hook: `Plainspoken --preview-hud` shows the HUD with a test voice right after launch.
        if CommandLine.arguments.contains("--preview-hud") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                previewVisualizer()
                // Prove the visualizer is animating: canvas redraws per second.
                for _ in 0..<4 {
                    let before = visualizerFrames
                    try? await Task.sleep(for: .seconds(1))
                    print("visualizer redraws/s: \(visualizerFrames - before)"); fflush(stdout)
                }
            }
        }
    }

    /// Re-reads the file only when it changed on disk (a stat per tick is cheap).
    private func refreshVocabularyCount() {
        let stamp = VocabularyFile.modificationDate
        guard stamp != vocabularyStamp || vocabularyStamp == nil else { return }
        vocabularyStamp = stamp
        vocabularyCount = VocabularyFile.load().count
    }

    func openVocabularyFile() {
        NSWorkspace.shared.open(VocabularyFile.ensureExists())
    }

    func revealVocabularyFile() {
        NSWorkspace.shared.activateFileViewerSelecting([VocabularyFile.ensureExists()])
    }

    func attemptHotkeyTap() {
        if !monitor.isRunning { monitor.start() }
        if hotkeyActive != monitor.isRunning { hotkeyActive = monitor.isRunning }
    }

    func refreshInputDevices() {
        inputDevices = AudioDevices.inputs()
        systemDefaultInput = AudioDevices.systemDefault()
    }

    func refresh() {
        for p in Permission.allCases {
            let value = p.isGranted
            if granted[p] != value { granted[p] = value }
        }
        // Keep trying to create the tap. It succeeds once Input Monitoring is granted, and the
        // failed attempts are what make macOS list this app under Input Monitoring in the first place.
        attemptHotkeyTap()
        refreshVocabularyCount()
        if hotkeyActive != monitor.isRunning { hotkeyActive = monitor.isRunning }
        hud.setReady(allGranted && hotkeyActive && speechModel == .ready)
    }

    /// Shows the HUD with a synthetic voice so a style can be judged without talking.
    func previewVisualizer() {
        previewTask?.cancel()
        guard !isListening else { return }
        hud.showListening()
        let waveform = audio.waveform
        previewTask = Task { [weak self] in
            for _ in 0..<(60 * 5) {
                if Task.isCancelled { return }
                waveform.pushSynthetic(seconds: 1.0 / 60)
                try? await Task.sleep(for: .milliseconds(16))
            }
            if !Task.isCancelled { self?.hud.hide() }
        }
    }

    func copyLastTranscript() {
        guard let lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    // MARK: Speech model

    /// Installs the on-device speech model if needed (first run downloads it, then it's offline).
    func prepareSpeechModel() {
        prepareTask?.cancel()
        speechModel = .preparing(nil)
        let engine = engine
        let requested = localeID.isEmpty ? Locale.current : Locale(identifier: localeID)
        prepareTask = Task { [weak self] in
            do {
                let locale = try await SpeechAssets.prepare(locale: requested, engine: engine) { fraction in
                    Task { @MainActor in
                        if case .preparing = self?.speechModel { self?.speechModel = .preparing(fraction) }
                    }
                }
                guard !Task.isCancelled else { return }
                self?.speechLocale = locale
                self?.speechModel = .ready
            } catch {
                guard !Task.isCancelled else { return }
                self?.speechModel = .failed("\(error)")
                log.error("speech model prepare failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Recording

    private func beginRecording() {
        guard !isListening else { return }
        previewTask?.cancel()
        guard granted[.microphone] == true else {
            statusNote = "Microphone access is needed"
            hud.showNotice("Microphone access is needed")
            Permission.microphone.request()
            return
        }
        guard speechModel == .ready else {
            statusNote = "Speech model isn't ready yet"
            hud.showNotice("Speech model isn't ready yet")
            return
        }
        do {
            // Audio starts immediately; buffers queue in the stream while the recognizer spins up.
            refreshInputDevices()
            insertTarget = inserter.currentTarget()
            warmSession = rewriter.makeWarmSession(vocabulary: VocabularyFile.load())
            let stream = try audio.start(deviceUID: micUID.isEmpty ? nil : micUID)
            isListening = true
            statusNote = nil
            partialText = ""
            hud.showListening()

            let engine = engine, locale = speechLocale, vocabulary = VocabularyFile.load()
            let sessionTask = Task {
                try await TranscriptionSession.start(
                    locale: locale, engine: engine, vocabulary: vocabulary,
                    onPartial: { text in
                        Task { @MainActor in
                            AppState.shared.partialText = text
                            AppState.shared.hud.setPartial(text)
                        }
                    }
                )
            }

            recordingTask = Task { [weak self] in
                var frames = 0
                var peak: Float = 0
                var rate = 0.0
                var session: TranscriptionSession?
                var sessionError: Error?
                do { session = try await sessionTask.value } catch { sessionError = error }

                for await buffer in stream {
                    frames += Int(buffer.frameLength)
                    rate = buffer.format.sampleRate
                    peak = max(peak, Self.peak(of: buffer))
                    session?.feed(buffer)
                }

                let seconds = rate > 0 ? Double(frames) / rate : 0
                let db = peak > 0 ? 20 * log10(peak) : -.infinity
                let summary = String(format: "Heard %.1fs of audio, peak %@", seconds,
                                     db.isFinite ? String(format: "%.0f dB", db) : "silence")
                log.info("\(summary, privacy: .public)")
                await self?.finishUtterance(session: session, error: sessionError, summary: summary)
            }
        } catch {
            statusNote = "Couldn't start the microphone: \(error)"
            hud.showNotice("Couldn't start the microphone")
            log.error("audio start failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func endRecording() {
        guard isListening else { return }
        audio.stop()
        isListening = false
        releasedAt = Date()
        hud.showWorking("Transcribing…")
    }

    private func finishUtterance(session: TranscriptionSession?, error: Error?, summary: String) async {
        lastRecording = summary
        guard let session else {
            statusNote = "Speech recognition failed to start: \(error.map { "\($0)" } ?? "unknown")"
            hud.showNotice("Speech recognition failed to start")
            return
        }
        isFinalizing = true
        defer { isFinalizing = false }
        do {
            let transcript = try await session.finish()
            let heardAt = Date()
            partialText = ""
            guard !transcript.text.isEmpty else {
                lastTranscript = nil
                lastHeard = nil
                statusNote = "Didn't catch anything"
                hud.showNotice("Didn't catch anything")
                return
            }

            // Rewrite: AFM, then light cleanup, then the raw transcript.
            hud.showWorking("Rewriting…")
            let warm = warmSession
            warmSession = nil
            let result = await rewriter.process(transcript.text, vocabulary: VocabularyFile.load(), warm: warm)

            let transcribeTime = heardAt.timeIntervalSince(releasedAt)
            if result.stage != .rewrite {
                statusNote = "Rewrite fell back to \(result.stage.label): \(result.failure ?? "unknown reason")"
                log.error("rewrite fallback: \(result.failure ?? "?", privacy: .public)")
            }

            // Type it into the app that had focus when recording started.
            let outcome = await inserter.insert(result.text, expecting: insertTarget)
            insertTarget = nil
            let total = Date().timeIntervalSince(releasedAt)
            lastHeard = transcript.text
            lastTranscript = result.text
            lastTiming = String(format: "Transcribed in %.1fs, rewritten in %.1fs (%@), %@",
                                transcribeTime, result.seconds, result.stage.label, outcome.summary)
            log.info("release-to-text \(total, format: .fixed(precision: 2))s, stage \(result.stage.rawValue, privacy: .public), chunks \(result.chunks), \(outcome.summary, privacy: .public)")

            switch outcome {
            case .accessibility, .paste:
                hud.showResult(result.text, for: result.stage == .rewrite ? 1.5 : 4)
            case .pastedBlind:
                statusNote = "No text box detected; pasted anyway. The text is also on your clipboard."
                hud.showResult(result.text, for: 3)
            case .copiedOnly(let why):
                statusNote = "Not typed (\(why)). The text is on your clipboard."
                hud.showNotice("Copied to clipboard: \(why)", for: 5)
            case .refused(let why):
                statusNote = "Not inserted: \(why)"
                hud.showNotice("Not inserted: \(why)", for: 4)
            }
        } catch {
            statusNote = "Transcription failed: \(error)"
            hud.showNotice("Transcription failed")
            log.error("finish failed: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[c][i])) }
        }
        return peak
    }
}
