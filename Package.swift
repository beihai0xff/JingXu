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
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
    ],
    targets: [
        .target(
            name: "JingXuCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "JingXuApp",
            dependencies: ["JingXuCore"]
        ),
        .executableTarget(
            name: "JingXuCalibration",
            dependencies: ["JingXuCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "JingXuChecks",
            dependencies: ["JingXuCore", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Tests/JingXuChecks"
        )
    ]
)
