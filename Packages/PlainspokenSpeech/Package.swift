// swift-tools-version: 6.2
import PackageDescription

// The speech layer shared by Plainspoken (live dictation) and Relaytake (captions for recordings):
// Apple's on-device engines, language models, custom vocabulary, and a guard that keeps the app
// offline. It depends on nothing but Apple frameworks. Whisper (and WhisperKit) stay in Plainspoken
// so that apps using this package do not download or build them.
let package = Package(
    name: "PlainspokenSpeech",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PlainspokenSpeech", targets: ["PlainspokenSpeech"]),
        .executable(name: "speech-harness", targets: ["SpeechHarness"]),
    ],
    targets: [
        .target(name: "PlainspokenSpeech", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "SpeechHarness", dependencies: ["PlainspokenSpeech"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PlainspokenSpeechTests", dependencies: ["PlainspokenSpeech"]),
    ]
)
