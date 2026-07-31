// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoteMic",
    platforms: [.macOS(.v13)],
    products: [
        .executable(
            name: "RemoteMic",
            targets: ["RemoteMic"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .executableTarget(
            name: "RemoteMic",
            dependencies: [
                "AudioExceptionGuard",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/RemoteMic"
        ),
        .target(
            name: "AudioExceptionGuard",
            path: "Sources/AudioExceptionGuard",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "RemoteMicTests",
            dependencies: ["RemoteMic"],
            path: "Tests/RemoteMicTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
