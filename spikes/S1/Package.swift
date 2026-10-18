// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "S1",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "S1Capture", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ToneHelper", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Analyze", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
