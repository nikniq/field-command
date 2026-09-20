// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FieldCommand",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "FieldCommand", path: "Sources/FieldCommand")
    ]
)
