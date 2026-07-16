// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeDeck",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeDeck",
            path: "Sources/ClaudeDeck"
        )
    ]
)
