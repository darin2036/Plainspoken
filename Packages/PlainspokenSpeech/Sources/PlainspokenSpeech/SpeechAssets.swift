import Foundation
import Speech

public enum SpeechAssets {
    /// Locales the engine can recognize, sorted by identifier. Regional variants (en_GB, en_AU,
    /// en_IN...) are separate models, so picking the one that matches the speaker can help with accents.
    public static func supportedLocales(for engine: AppleSpeechEngine) async -> [Locale] {
        let locales: [Locale]
        switch engine {
        case .speechTranscriber: locales = await SpeechTranscriber.supportedLocales
        case .dictationTranscriber: locales = await DictationTranscriber.supportedLocales
        }
        return locales.sorted { $0.identifier < $1.identifier }
    }

    /// Makes sure the on-device model for `locale` is installed and reserved for this app.
    /// Downloads on first run only; `progress` reports 0...1 while downloading.
    /// Returns the locale the model actually uses (e.g. en_CA maps to en_US).
    @discardableResult
    public static func prepare(
        locale: Locale = .current,
        engine: AppleSpeechEngine = .speechTranscriber,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Locale {
        guard let supported = await SpeechModules.supportedLocale(for: engine, equivalentTo: locale) else {
            throw TranscriberError.unsupportedLocale(locale.identifier)
        }
        let module = SpeechModules.live(engine, locale: supported)
        if await AssetInventory.status(forModules: [module]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let watcher = Task {
                while !Task.isCancelled {
                    progress(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { watcher.cancel() }
            try await request.downloadAndInstall()
            progress(1)
        }
        // The system keeps a few locales resident per app; reserving keeps ours from being evicted.
        _ = try? await AssetInventory.reserve(locale: supported)
        return supported
    }

    /// Whether the model for `locale` is already on this Mac, so using it will not download anything.
    /// (The asset status API can say "supported" for a model that is installed, so the list of
    /// installed languages is the reliable answer.)
    public static func isInstalled(locale: Locale, engine: AppleSpeechEngine) async -> Bool {
        guard let supported = await SpeechModules.supportedLocale(for: engine, equivalentTo: locale) else { return false }
        let installed: [Locale]
        switch engine {
        case .speechTranscriber: installed = await SpeechTranscriber.installedLocales
        case .dictationTranscriber: installed = await DictationTranscriber.installedLocales
        }
        return installed.contains { $0.identifier == supported.identifier }
    }
}
