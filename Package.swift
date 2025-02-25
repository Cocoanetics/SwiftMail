// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftIMAP",
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/thebarndog/swift-dotenv", from: "2.1.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "SwiftIMAP",
            dependencies: [
                .product(name: "SwiftDotenv", package: "swift-dotenv"),
            ]),
    ]
)
