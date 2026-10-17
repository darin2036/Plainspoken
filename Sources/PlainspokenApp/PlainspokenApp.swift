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
                ForEach(state.requiredPermissions) { p in
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
                    Section("No extra permission") {
                        ForEach(HotkeyKey.functionKeys) { Text($0.label).tag($0) }
                    }
                    Section("Needs Input Monitoring") {
                        ForEach(HotkeyKey.modifierKeys) { Text($0.label).tag($0) }
                    }
                }
            } header: {
                Text("Hold to talk")
            } footer: {
                Text("Function keys need no Input Monitoring permission. On most laptops, hold Fn with them or turn on \"Use F1, F2, etc. keys as standard function keys\" in Keyboard settings. Fn/Globe can clash with the system's dictation and emoji shortcuts.")
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

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $state.engine) {
                    ForEach(SpeechEngine.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Speech recognition")
            } footer: {
                Text("Both run on your Mac. Try each with your own voice.")
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
    }
}

private extension View {
    func settingsTabStyle() -> some View {
        self.formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}
