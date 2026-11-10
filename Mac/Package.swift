// swift-tools-version: 6.2
// DevshoutMac: macOS-only code (audio, engines, hotkeys, paste, Keychain, PTY) + the devshout-cli spike tool.
import PackageDescription

let package = Package(
    name: "DevshoutMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DevshoutMac", targets: ["DevshoutMac"]),
        .executable(name: "devshout-cli", targets: ["devshout-cli"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        // ASR + VAD only: traits [] drops TTS, diarisation and NeMo ITN.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.3", traits: []),
        // WhisperKit lives in Argmax's OSS SDK package.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "3.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
    ],
    targets: [
        .target(
            name: "DevshoutMac",
            dependencies: [
                .product(name: "DevshoutCore", package: "Core"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "devshout-cli",
            dependencies: [
                "DevshoutMac",
                .product(name: "DevshoutCore", package: "Core"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
