// swift-tools-version:5.10
import PackageDescription

// Mirrors the official rive-ios 6.24.0 Package.swift exactly so the production
// project can resolve the verified binary without cloning the large rive-ios git history.
let package = Package(
    name: "RiveRuntime",
    platforms: [
        .iOS("14.0"),
        .visionOS("1.0"),
        .tvOS("16.0"),
        .macOS("13.1"),
        .macCatalyst("14.0")
    ],
    products: [
        .library(
            name: "RiveRuntime",
            targets: ["RiveRuntime"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "RiveRuntime",
            url: "https://github.com/rive-app/rive-ios/releases/download/6.24.0/RiveRuntime.xcframework.zip",
            checksum: "df75eff6fc2316c02e9eb1546e45c9b3fc38f3fc337806e2fee00cf8924628e3"
        )
    ]
)
