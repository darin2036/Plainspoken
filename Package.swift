// swift-tools-version: 6.2
import PackageDescription

// A plain SwiftPM package: PlainspokenCore holds the logic, PlainspokenApp is the menu bar app
// (scripts/build-app.sh wraps its binary into build/Plainspoken.app), Harness is the CLI for
// tuning the rewrite and speech pipeline.
let package = Package(
    name: "Plainspoken",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "harness", targets: ["Harness"]),
        .executable(name: "Plainspoken", targets: ["PlainspokenApp"]),
    ],
    dependencies: [
        // Optional Whisper engine. The package is only code; the models download on demand.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1"),
    ],
    targets: [
        .target(
            name: "PlainspokenCore",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PlainspokenApp",
            dependencies: ["PlainspokenCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Harness",
            dependencies: ["PlainspokenCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
