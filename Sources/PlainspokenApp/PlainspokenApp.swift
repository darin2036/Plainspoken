import SwiftUI
import PlainspokenCore

@main
struct PlainspokenApp: App {
    private let state = AppState.shared

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--render-previews"), i + 1 < CommandLine.arguments.count {
            renderPreviews(to: CommandLine.arguments[i + 1])
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-settings"), i + 1 < CommandLine.arguments.count {
            renderSettings(to: CommandLine.arguments[i + 1])
            exit(0)
        }
        AppState.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            Image(systemName: state.isListening ? "waveform" : "mic")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(state: state)
        }
    }
}

struct MenuView: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plainspoken").font(.headline)

            if state.isListening {
                Label("Listening…", systemImage: "waveform").foregroundStyle(.red)
            } else if state.isFinalizing {
                Label("Finishing transcript…", systemImage: "ellipsis").foregroundStyle(.secondary)
            } else if state.allGranted && state.hotkeyActive && state.speechModel == .ready {
                Text("Hold \(state.hotkey.shortLabel) to talk").foregroundStyle(.secondary)
            } else {
                Text("Setup needed").foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Permission.allCases) { p in
                    PermissionRow(permission: p, granted: state.granted[p] == true)
                }
            }

            SpeechModelRow(model: state.speechModel)

            Label(state.activeMicName, systemImage: "mic")
                .font(.caption).foregroundStyle(.secondary)

            if let note = state.statusNote {
                Text(note).font(.caption).foregroundStyle(.red)
            }
            if !state.partialText.isEmpty {
                Text(state.partialText).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let transcript = state.lastTranscript {
                VStack(alignment: .leading, spacing: 4) {
                    Text(transcript).font(.callout).textSelection(.enabled)
                    if let heard = state.lastHeard, heard != transcript {
                        Text("Heard: \(heard)").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Button("Copy text") { state.copyLastTranscript() }.controlSize(.small)
                }
            }
            if let timing = state.lastTiming {
                Text(timing).font(.caption).foregroundStyle(.secondary)
            }
            if let last = state.lastRecording {
                Text(last).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 290)
    }
}

struct PermissionRow: View {
    let permission: Permission
    let granted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 0) {
                Text(permission.title)
                Text(permission.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant") { permission.request() }
                    .controlSize(.small)
            }
        }
    }
}

struct SpeechModelRow: View {
    let model: SpeechModelState

    var body: some View {
        HStack(spacing: 8) {
            switch model {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Speech model ready (on-device)")
            case .preparing(let fraction):
                ProgressView().controlSize(.small)
                Text(fraction.map { "Downloading speech model… \(Int($0 * 100))%" } ?? "Preparing speech model…")
            case .failed(let why):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(why).font(.caption)
            }
        }
        .font(.callout)
    }
}

struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsTab(state: state)
                .tabItem { Label("Appearance", systemImage: "waveform") }
            DictationSettingsTab(state: state)
                .tabItem { Label("Dictation", systemImage: "text.bubble") }
        }
        .frame(width: 480)
    }
}

/// Each tab is a grouped form: a short control per row, with the explanation in a quiet footer
/// instead of caption text wedged between rows.
struct GeneralSettingsTab: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section {
                Picker("Key", selection: $state.hotkey) {
                    ForEach(HotkeyKey.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Hold to talk")
            } footer: {
                Text("Fn/Globe can clash with the system's dictation and emoji shortcuts.")
            }

            Section {
                Picker("Input", selection: $state.micUID) {
                    Text("System default (\(state.systemDefaultInput?.label ?? "none"))").tag("")
                    ForEach(state.inputDevices) { Text($0.label).tag($0.id) }
                    if !state.micUID.isEmpty, !state.inputDevices.contains(where: { $0.id == state.micUID }) {
                        Text("Selected microphone (not connected)").tag(state.micUID)
                    }
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("Choose the Mac's built-in microphone to keep Bluetooth headphones in high-quality listening mode. A Bluetooth mic switches them to call mode, which adds latency.")
            }

            Section {
                Toggle("Paste when no text box is detected", isOn: $state.pasteWhenNoTextBox)
            } header: {
                Text("Typing")
            } footer: {
                Text("On: Plainspoken pastes even if it can't see a text box, and leaves the text on your clipboard in case it didn't land. Off: it only copies the text to your clipboard.")
            }
        }
        .settingsTabStyle()
    }
}

struct AppearanceSettingsTab: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section {
                Picker("Style", selection: $state.visualizer) {
                    ForEach(VisualizerStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Button("Preview with a test voice") { state.previewVisualizer() }
            } header: {
                Text("Listening display")
            } footer: {
                Text("What the bar at the bottom of the screen shows while you talk.")
            }

            Section {
                Toggle("Show a small pill when idle", isOn: $state.showIdleIndicator)
            } header: {
                Text("Idle indicator")
            } footer: {
                Text("A tiny pill shows the app is running. It turns orange while setup is incomplete.")
            }
        }
        .settingsTabStyle()
    }
}

struct DictationSettingsTab: View {
    @Bindable var state: AppState
    @State private var locales: [Locale] = []
    @State private var showHelp = false

    private var engineBinding: Binding<SpeechEngine> {
        Binding(get: { state.engine }, set: { state.chooseEngine($0) })
    }

    private var whisperModelBinding: Binding<WhisperModel> {
        Binding(get: { state.whisperModel }, set: { state.chooseWhisperModel($0) })
    }

    private var downloading: Bool {
        if case .preparing = state.speechModel { return state.engine == .whisper }
        return false
    }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: engineBinding) {
                    ForEach(SpeechEngine.allCases) { Text($0.label).tag($0) }
                }
                if state.engine == .whisper {
                    Picker("Whisper model", selection: whisperModelBinding) {
                        ForEach(WhisperModel.allCases) { Text("\($0.label) (\($0.downloadLabel))").tag($0) }
                    }
                    Picker("Language", selection: $state.whisperLanguage) {
                        Text("Match system").tag("")
                        ForEach(WhisperLanguages.all, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    if downloading { SpeechModelRow(model: state.speechModel) }
                } else {
                    Picker("Language & accent", selection: $state.localeID) {
                        Text("Match system").tag("")
                        ForEach(locales, id: \.identifier) { locale in
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                .tag(locale.identifier)
                        }
                        // Keep a saved choice visible even if the list hasn't loaded or the engine lacks it.
                        if !state.localeID.isEmpty, !locales.contains(where: { $0.identifier == state.localeID }) {
                            Text(state.localeID).tag(state.localeID)
                        }
                    }
                }
            } header: {
                Text("Speech recognition")
            } footer: {
                if state.engine == .whisper {
                    Text("Whisper runs on your Mac. It doesn't have regional variants, so it relies on being trained on many accents. Text appears after you let go of the key.")
                } else {
                    Text("Regional variants such as English (Australia) or English (India) use separate models, so choose the one closest to how you speak. A new model downloads the first time you pick it.")
                }
            }
            .task(id: state.engine) {
                locales = await SpeechAssets.supportedLocales(for: state.engine)
            }

            Section {
                Label {
                    Text("Apple's engines keep the app small and quick, but they can struggle with accents and some speech patterns. If that's you, Whisper is more forgiving, in exchange for a one-time download and a short wait after you let go of the key.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                }
                Button("Help me choose…") { showHelp = true }
                    .accessibilityHint("Opens a short guide to the speech engines and Whisper sizes")
            }
            .sheet(isPresented: $showHelp) {
                HelpMeChooseSheet(state: state, isPresented: $showHelp)
            }

            let _ = state.whisperStoreVersion
            let installed = WhisperModel.allCases.filter { WhisperStore.isInstalled($0) }
            if !installed.isEmpty {
                Section {
                    ForEach(installed) { model in
                        let size = WhisperStore.installedMB(model).map { "\($0) MB" } ?? ""
                        HStack {
                            Text(model.label)
                            Spacer()
                            Text(size).foregroundStyle(.secondary)
                            Button("Remove") { state.removeWhisperModel(model) }
                        }
                    }
                } header: {
                    Text("Downloaded Whisper models")
                } footer: {
                    Text("Removing a model frees the space. You can download it again whenever you like.")
                }
            }

            Section {
                LabeledContent("Entries", value: state.vocabularyCount == 1 ? "1 term" : "\(state.vocabularyCount) terms")
                HStack {
                    Button("Open Vocabulary File") { state.openVocabularyFile() }
                    Button("Show in Finder") { state.revealVocabularyFile() }
                }
            } header: {
                Text("Custom vocabulary")
            } footer: {
                Text("A plain text file with one name or term per line. Edit it in any editor; changes apply to your next dictation. If the recognizer keeps mishearing a word, write Term=heard, such as Rovo=bravo|robo.")
            }
        }
        .settingsTabStyle()
        .confirmationDialog(
            "Choose a Whisper size to download",
            isPresented: $state.choosingWhisperModel
        ) {
            ForEach(WhisperModel.allCases) { model in
                Button("\(model.label), \(model.downloadLabel)") { state.downloadWhisper(model) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Whisper is a one-time download, then works offline. Fast suits clear speech, Balanced suits everyday use and is a good first try for an accent, and Most accurate is best for strong accents or noisy rooms. You can change size or remove it later.")
        }
        .alert(
            "Download Whisper \(state.pendingWhisperDownload?.label ?? "")?",
            isPresented: Binding(get: { state.pendingWhisperDownload != nil }, set: { if !$0 { state.pendingWhisperDownload = nil } }),
            presenting: state.pendingWhisperDownload
        ) { model in
            Button("Download \(model.downloadLabel)") { state.confirmWhisperDownload() }
            Button("Cancel", role: .cancel) { state.pendingWhisperDownload = nil }
        } message: { model in
            Text("Whisper needs a one-time download of \(model.downloadLabel). After that it works offline and your audio never leaves your Mac. You can remove it later in this tab.")
        }
    }
}

/// The "Help me choose" pop-up: quick picks by situation first, then each option's trade-offs.
struct HelpMeChooseSheet: View {
    @Bindable var state: AppState
    @Binding var isPresented: Bool

    private struct Pick: Identifiable {
        let id = UUID()
        let situation: String
        let name: String
        let recommendation: String
        let engine: SpeechEngine
        let size: WhisperModel?
    }

    private let picks = [
        Pick(situation: "It understands me fine", name: "Apple SpeechTranscriber", recommendation: "Apple SpeechTranscriber. Nothing extra to download.",
             engine: .speechTranscriber, size: nil),
        Pick(situation: "It mishears my accent, or I speak fast or not in my first language",
             name: "Whisper Balanced", recommendation: "Whisper Balanced. A good first thing to try.", engine: .whisper, size: .balanced),
        Pick(situation: "I have a strong accent, a speech difference or disability, a noisy room, or lots of technical terms",
             name: "Whisper Most accurate", recommendation: "Whisper Most accurate. Typically the most forgiving of how you speak.", engine: .whisper, size: .accurate),
        Pick(situation: "I'm short on disk space but want better accuracy",
             name: "Whisper Fast", recommendation: "Whisper Fast. The smallest download, though less accurate than the larger sizes.", engine: .whisper, size: .fast),
    ]

    private func isCurrent(_ engine: SpeechEngine, _ size: WhisperModel?) -> Bool {
        state.engine == engine && (engine != .whisper || state.whisperModel == size)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Help me choose").font(.title2).fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)
                    Text("Apple's engines keep the app small and quick, but they can struggle with accents and some speech patterns. Whisper is more forgiving, in exchange for a one-time download and a short wait after you let go of the key. Everything runs on your Mac either way, and you can switch back at any time.")
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Pick by situation").font(.headline).accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(picks) { pick in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pick.situation).fontWeight(.medium)
                                    Text(pick.recommendation).foregroundStyle(.secondary)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                if isCurrent(pick.engine, pick.size) {
                                    Text("In use").foregroundStyle(.secondary)
                                } else {
                                    Button("Use this") { choose(pick.engine, pick.size) }
                                        .accessibilityLabel("Use \(pick.name)")
                                }
                            }
                            .accessibilityElement(children: .contain)
                        }
                    }

                    Text("All the options").font(.headline).accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(SpeechEngine.allCases) { engine in
                            ChoiceGuideRow(title: engine.label, bestFor: engine.bestFor, benefit: engine.benefit,
                                           tradeoff: engine.tradeoff, inUse: state.engine == engine)
                            if engine == .whisper {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(WhisperModel.allCases) { model in
                                        ChoiceGuideRow(title: "Whisper \(model.label), \(model.downloadLabel)", bestFor: model.bestFor,
                                                       benefit: model.benefit, tradeoff: model.tradeoff,
                                                       inUse: isCurrent(.whisper, model))
                                    }
                                }
                                .padding(.leading, 14)
                            }
                        }
                    }
                    Text("Names and technical terms the recognizer keeps getting wrong can also be fixed with your custom vocabulary file, with any engine.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 600)
    }

    private func choose(_ engine: SpeechEngine, _ size: WhisperModel?) {
        isPresented = false
        // Let the sheet finish closing so a download prompt isn't swallowed by it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { state.use(engine, whisper: size) }
    }
}

/// One option in the "Help me choose" list: who it suits, what you gain, what it costs.
struct ChoiceGuideRow: View {
    let title: String
    let bestFor: String
    let benefit: String
    let tradeoff: String
    let inUse: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).fontWeight(.semibold)
                if inUse {
                    Text("In use")
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
            }
            Text(bestFor).font(.callout)
            Label { Text(benefit).foregroundStyle(.secondary) } icon: {
                Image(systemName: "plus.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
            }
            .accessibilityLabel("Benefit: \(benefit)")
            Label { Text(tradeoff).foregroundStyle(.secondary) } icon: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            }
            .accessibilityLabel("Trade-off: \(tradeoff)")
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)\(inUse ? ", in use" : ""). Best for: \(bestFor)")
    }
}

private extension View {
    func settingsTabStyle() -> some View {
        self.formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}
