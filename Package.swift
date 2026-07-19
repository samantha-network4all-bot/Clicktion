// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clicktion",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "Clicktion",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Clicktion"
        ),
        .testTarget(
            name: "ClicktionTests",
            dependencies: ["Clicktion"],
            path: "Tests/ClicktionTests"
        )
    ]
)
