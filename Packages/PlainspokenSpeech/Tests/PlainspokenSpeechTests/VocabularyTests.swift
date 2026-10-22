import Foundation
import Testing

@testable import PlainspokenSpeech

@Suite struct VocabularyTests {
    @Test func termsDropAliasesAndBlanks() {
        #expect(Vocabulary.terms(from: ["Jira", "Rovo=bravo|robo", "  ", "=nothing", " Priya "]) == ["Jira", "Rovo", "Priya"])
    }

    @Test func fixesCasingAndOneLetterSlips() {
        let terms = ["Jira", "Confluence"]
        #expect(Vocabulary.correct("open the jira board", terms: terms) == "open the Jira board")
        #expect(Vocabulary.correct("a Jera ticket", terms: terms) == "a Jira ticket")  // one letter off
        #expect(Vocabulary.correct("in confluense", terms: terms) == "in Confluence")  // long terms allow two edits
    }

    @Test func doesNotRewriteRealWordsThatMerelyLookSimilar() {
        let terms = ["Jira"]
        #expect(Vocabulary.correct("Jerry fixed it", terms: terms) == "Jerry fixed it")
        #expect(Vocabulary.correct("the ria and the era", terms: terms) == "the ria and the era")  // short words are left alone
        #expect(Vocabulary.correct("anything", terms: []) == "anything")
    }

    @Test func aliasesReplaceWhatTheRecognizerKeepsMishearing() {
        let entries = ["Rovo=bravo|robo", "pull request=pool request"]
        #expect(Vocabulary.correct("ask Bravo about the pool request", terms: entries) == "ask Rovo about the pull request")
        #expect(Vocabulary.correct("a ROBO moment", terms: entries) == "a Rovo moment")  // case-insensitive
        #expect(Vocabulary.correct("robotics", terms: entries) == "robotics")  // whole words only
    }

    @Test func multiWordTermsKeepTheirCasing() {
        #expect(Vocabulary.correct("welcome to opus guard today", terms: ["Opus Guard"]) == "welcome to Opus Guard today")
    }
}

@Suite struct VocabularyFileStoreTests {
    private func makeStore() throws -> (VocabularyFileStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speech-vocab-\(UUID().uuidString)")
        return (VocabularyFileStore(appName: "TestApp", directory: directory), directory)
    }

    @Test func parsesEntriesAndSkipsCommentsAndBlankLines() {
        #expect(VocabularyFileStore.parse("# note\n\n  Jira \nRovo=bravo\n   # indented comment\r\nPriya\n") == ["Jira", "Rovo=bravo", "Priya"])
    }

    @Test func createsAHelpfulFileOnceAndNeverOverwritesIt() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.load().isEmpty && store.modificationDate == nil)

        store.ensureExists(seed: ["Jira"])
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(text.contains("TestApp custom vocabulary") && text.contains("Rovo=bravo|robo"))
        #expect(store.load() == ["Jira"])

        try "Priya\n".write(to: store.url, atomically: true, encoding: .utf8)  // the user edits it
        store.ensureExists(seed: ["Overwritten"])
        #expect(store.load() == ["Priya"])
        #expect(store.modificationDate != nil)
    }

    @Test func eachAppGetsItsOwnFolder() {
        #expect(VocabularyFileStore(appName: "Relaytake").url.path.hasSuffix("Application Support/Relaytake/vocabulary.txt"))
        #expect(VocabularyFileStore(appName: "Plainspoken").url.path.hasSuffix("Application Support/Plainspoken/vocabulary.txt"))
    }
}

@Suite struct EngineTests {
    @Test func bothAppleEnginesAreDescribedForAPicker() {
        #expect(AppleSpeechEngine.allCases.count == 2)
        for engine in AppleSpeechEngine.allCases {
            #expect(!engine.label.isEmpty && !engine.bestFor.isEmpty && !engine.benefit.isEmpty && !engine.tradeoff.isEmpty)
        }
        #expect(Set(AppleSpeechEngine.allCases.map(\.id)).count == 2)
    }

    @Test func theTranscriptModelCompares() {
        let a = Transcript(text: "hi", segments: [TranscriptSegment(text: "hi", start: 0, end: 1)])
        #expect(a == Transcript(text: "hi", segments: [TranscriptSegment(text: "hi", start: 0, end: 1)]))
        #expect(String(describing: TranscriberError.noAudio).contains("no audio"))
        #expect(String(describing: TranscriberError.unsupportedLocale("xx")).contains("xx"))
    }
}

@Suite(.serialized) struct NetworkGuardTests {
    @Test func blocksWebRequestsExceptInsideAnApprovedWindow() async {
        let web = URLRequest(url: URL(string: "https://example.com/model")!)
        let local = URLRequest(url: URL(fileURLWithPath: "/tmp/x"))
        #expect(NetworkGuard.canInit(with: web))  // blocked by default
        #expect(!NetworkGuard.canInit(with: local))  // files are not the network
        await NetworkGuard.allowing {
            #expect(!NetworkGuard.canInit(with: web))  // the guard steps aside during an approved download
        }
        #expect(NetworkGuard.canInit(with: web))  // and returns afterwards
    }

    @Test func aBlockedRequestFailsInsteadOfGoingOnline() async {
        NetworkGuard.install()
        do {
            _ = try await URLSession.shared.data(from: URL(string: "https://example.com/")!)
            Issue.record("the request should have been blocked")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

@Suite struct LocaleTests {
    @Test func listsSupportedLanguagesInOrder() async {
        let locales = await SpeechAssets.supportedLocales(for: .speechTranscriber)
        #expect(!locales.isEmpty)
        #expect(locales.map(\.identifier) == locales.map(\.identifier).sorted())
        #expect(locales.contains { $0.identifier.hasPrefix("en") })
    }

    @Test func rejectsALanguageTheEngineDoesNotKnow() async {
        await #expect(throws: TranscriberError.self) {
            try await SpeechAssets.prepare(locale: Locale(identifier: "tlh"), engine: .speechTranscriber)  // Klingon
        }
    }
}
