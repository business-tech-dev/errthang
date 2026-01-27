// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "errthang",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "errthang", targets: ["errthang"]),
        .executable(name: "errthang-service", targets: ["errthang-service"]),
        .library(name: "ErrthangCore", targets: ["ErrthangCore"]),
    ],
    dependencies: [],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "CSearch",
            dependencies: []
        ),
        .target(
            name: "ErrthangCore",
            dependencies: ["CSearch"]
        ),
        .executableTarget(
            name: "errthang",
            dependencies: ["ErrthangCore"],
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "errthang-service",
            dependencies: ["ErrthangCore"]
        ),
        .testTarget(
            name: "ErrthangTests",
            dependencies: ["ErrthangCore"]
        ),
    ]
)
