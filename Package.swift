// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CivCubedBot",
    dependencies: [
        .package(url: "https://github.com/MahdiBM/DiscordBM.git", branch: "main"),
        .package(url: "https://github.com/vapor/async-kit.git", from: "1.0.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.0.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "CivCubedBot",
            dependencies: [
                .product(name: "DiscordBM", package: "DiscordBM"),
                .product(name: "AsyncKit", package: "async-kit"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
            ]
        )
    ]
)
