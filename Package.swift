// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "JingXu",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "JingXuCore", targets: ["JingXuCore"]),
        .executable(name: "JingXuApp", targets: ["JingXuApp"]),
        .executable(name: "JingXuChecks", targets: ["JingXuChecks"]),
        .executable(name: "JingXuCalibration", targets: ["JingXuCalibration"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0")
    ],
    targets: [
        .target(
            name: "JingXuCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "JingXuAutomation",
            dependencies: ["JingXuCore", .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio")]
        ),
        .executableTarget(
            name: "JingXuApp",
            dependencies: ["JingXuCore", "JingXuAutomation"]
        ),
        .executableTarget(
            name: "JingXuCalibration",
            dependencies: ["JingXuCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "JingXuChecks",
            dependencies: ["JingXuCore", "JingXuAutomation", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Tests/JingXuChecks"
        )
    ]
)
