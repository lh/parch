// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Parch",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.7.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "parch",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Parch"
        ),
        .testTarget(
            name: "ParchTests",
            dependencies: [
                "parch",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/ParchTests"
        ),
    ]
)
