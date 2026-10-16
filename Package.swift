// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsefulVoice",
    platforms: [.macOS(.v14)],
    dependencies: [
        // In-app updates for release builds (see the Makefile's bundle target and
        // scripts/release-mac.mjs). Same pin as Useful Bot.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // whisper.cpp, precompiled by the upstream project (Metal backend
        // included). v1.9.2 is the newest versioned release that publishes an
        // XCFramework asset; checksum verified against the release download.
        // https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.2
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        ),
        // llama.cpp, precompiled by the upstream project (Metal backend included),
        // for the hidden S1-mini cleanup model. It bundles its own ggml next to the
        // one inside whisper.framework; both are dynamic frameworks, so each keeps
        // its own copy. Only `UsefulVoiceLlama` imports it, and that target imports
        // nothing else, so the two ggml header sets never meet in one Swift module.
        // https://github.com/ggml-org/llama.cpp/releases/tag/b11669
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11669/llama-b11669-xcframework.zip",
            checksum: "937891f26734c29c80817cdf8bf59b139c84a9c6fb36a4ad6ce31cceea608e7c"
        ),
        .target(
            name: "UsefulVoiceLlama",
            dependencies: ["llama"]
        ),
        .target(
            name: "UsefulVoiceCore",
            dependencies: ["whisper"]
        ),
        .executableTarget(
            name: "UsefulVoiceApp",
            dependencies: [
                "UsefulVoiceCore",
                "UsefulVoiceLlama",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(name: "UsefulVoiceCoreTests", dependencies: ["UsefulVoiceCore"]),
        // The app's own display rules (what the HUD says to VoiceOver). The executable
        // target is imported with `@testable`, which SwiftPM supports on macOS.
        .testTarget(name: "UsefulVoiceAppTests", dependencies: ["UsefulVoiceApp", "UsefulVoiceCore", "UsefulVoiceLlama"]),
    ]
)
