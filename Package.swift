// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clicktion",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Clicktion",
            path: "Sources/Clicktion"
        )
    ]
)
