// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsefulVoice",
    platforms: [.macOS(.v14)],
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
        .target(
            name: "UsefulVoiceCore",
            dependencies: ["whisper"]
        ),
        .executableTarget(name: "UsefulVoiceApp", dependencies: ["UsefulVoiceCore"]),
        .testTarget(name: "UsefulVoiceCoreTests", dependencies: ["UsefulVoiceCore"]),
    ]
)
