// swift-tools-version: 6.0
// DevshoutCore: pure Swift + Foundation. Must build and test on Linux (no Apple-only frameworks).
import PackageDescription

let package = Package(
    name: "DevshoutCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DevshoutCore", targets: ["DevshoutCore"]),
    ],
    targets: [
        .target(name: "DevshoutCore"),
        .testTarget(
            name: "DevshoutCoreTests",
            dependencies: ["DevshoutCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
