// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "sift", targets: ["Sift"]),
        .library(name: "SiftCore", targets: ["SiftCore"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "SiftCore", dependencies: ["CSQLite"]),
        .target(name: "SiftCLI", dependencies: ["SiftCore"]),
        .executableTarget(name: "Sift", dependencies: ["SiftCLI"]),
        .executableTarget(name: "SiftVerification", dependencies: ["SiftCore", "SiftCLI"], path: "Tests/Verification"),
        .testTarget(name: "SiftCoreTests", dependencies: ["SiftCore"]),
        .testTarget(name: "SiftCLITests", dependencies: ["SiftCLI"]),
        .testTarget(name: "SiftIntegrationTests", dependencies: ["CSQLite"]),
    ]
)
