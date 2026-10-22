# PlainspokenSpeech

The speech layer shared by [Plainspoken](../../README.md) (live dictation) and Relaytake (captions for screen recordings). MIT licensed, Apple frameworks only, **no third-party dependencies**. It never pulls in WhisperKit: Whisper stays in Plainspoken.

Everything runs on the Mac. Speech recognition is Apple's on-device `SpeechAnalyzer`; Apple's language models are downloaded by macOS itself the first time a language is used.

## What is in it

| Piece | What it does |
|---|---|
| `AppleSpeechEngine` | `SpeechTranscriber` (newer) and `DictationTranscriber` (classic), with plain-language descriptions for a picker. |
| `SpeechAssets` | Lists supported languages (including regional models such as English (India)), prepares and reserves a model with download progress, and says whether one is already installed. |
| `FileTranscriber` | Transcribes a whole audio or video file with the time each phrase covers. Mixes every audio track, reports progress, cancels cleanly, applies the vocabulary. |
| `TranscriptionSession` | Live dictation: feed microphone buffers, get partial and final text. |
| `Vocabulary` / `VocabularyFileStore` | Custom terms: given to the recognizer, then used to fix casing, one-letter slips and aliases (`Rovo=bravo\|robo`). The store keeps them in a plain text file in Application Support. |
| `NetworkGuard` | Refuses every web request the app makes, except inside an approved window, so "nothing leaves your Mac" is enforced and not assumed. |

## Using it

```swift
// Package.swift
.package(path: "../Plainspoken/Packages/PlainspokenSpeech"),
// target dependency
.product(name: "PlainspokenSpeech", package: "PlainspokenSpeech"),
```

```swift
NetworkGuard.install()   // once, at launch

let transcript = try await FileTranscriber.transcribe(
    fileAt: recordingURL,
    engine: .speechTranscriber,
    locale: Locale(identifier: "en_IN"),
    vocabulary: VocabularyFileStore(appName: "MyApp").load()
) { progress in /* progress.stage, progress.fraction */ }

for segment in transcript.segments { print(segment.start, segment.end, segment.text) }
```

## Checking it

```bash
scripts/test.sh                         # unit tests plus real recognizer runs on generated speech
swift build && .build/debug/speech-harness recording.mp4          # counts and timings only
.build/debug/speech-harness recording.mp4 --vocab "Jira,Rovo=bravo" --engine dictation --show
.build/debug/speech-harness --locales
```

`speech-harness` prints counts and timings, not the words, unless you pass `--show`, so a private recording is not echoed to a terminal. The tests that run the recognizer are skipped, not failed, if the English model is not installed.

`scripts/test.sh` adds the Testing framework paths that the Xcode Command Line Tools need; with full Xcode plain `swift test` works.
