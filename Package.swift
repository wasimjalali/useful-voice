// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsefulVoice",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UsefulVoiceCore"),
        .executableTarget(name: "UsefulVoiceApp", dependencies: ["UsefulVoiceCore"]),
        .testTarget(name: "UsefulVoiceCoreTests", dependencies: ["UsefulVoiceCore"]),
    ]
)
