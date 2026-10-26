// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "sift", targets: ["Sift"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.7.3"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "SiftCore", dependencies: ["CSQLite", .product(name: "Markdown", package: "swift-markdown")]),
        .target(name: "SiftCLI", dependencies: ["SiftCore"]),
        .executableTarget(name: "Sift", dependencies: ["SiftCLI"]),
        .testTarget(name: "SiftCoreTests", dependencies: ["SiftCore"]),
        .testTarget(name: "SiftCLITests", dependencies: ["SiftCLI", "SiftCore"]),
        .testTarget(name: "SiftIntegrationTests", dependencies: ["CSQLite"]),
    ]
)
