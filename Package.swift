// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swiftly-play",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
    ],
    targets: [
        .target(name: "WAVBufferCore"),
        .executableTarget(
            name: "wavbuffer",
            dependencies: [
                "WAVBufferCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "wavbufferSmokeTests",
            dependencies: ["wavbuffer"]
        ),
        .testTarget(
            name: "wavbufferTests",
            dependencies: [
                "WAVBufferCore",
                "wavbuffer",
            ]
        ),
    ]
)
