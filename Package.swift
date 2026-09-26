// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kanade",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Kanade", path: "Sources/Kanade")
    ]
)
