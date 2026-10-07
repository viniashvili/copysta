// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "copysta",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "copysta",
            path: "Sources/copysta",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
