// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DynamicIslandMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DynamicIslandMac", targets: ["DynamicIslandMac"]),
        .executable(name: "DynamicIslandPowerHelper", targets: ["DynamicIslandPowerHelper"])
    ],
    targets: [
        .executableTarget(
            name: "DynamicIslandMac",
            path: "Sources/DynamicIslandMac",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "DynamicIslandPowerHelper",
            path: "Sources/DynamicIslandPowerHelper",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "DynamicIslandMacTests",
            dependencies: ["DynamicIslandMac"],
            path: "Tests/DynamicIslandMacTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
