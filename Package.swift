// swift-tools-version:5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftMail",
    platforms: [
        .macOS("11.0")
    ],
    products: [
        // Products define the executables and libraries a package produces
        .library(
            name: "SwiftIMAP",
            targets: ["SwiftIMAP"]),
        .library(
            name: "SwiftSMTP",
            targets: ["SwiftSMTP"]),
        .library(
            name: "SwiftMailCore",
            targets: ["SwiftMailCore"]),
        .executable(
            name: "SwiftIMAPCLI",
            targets: ["SwiftIMAPCLI"]),
        .executable(
            name: "SwiftSMTPCLI",
            targets: ["SwiftSMTPCLI"])
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/thebarndog/swift-dotenv", from: "2.1.0"),
        .package(url: "https://github.com/apple/swift-nio-imap", branch: "main"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-testing", branch: "main"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "SwiftMailCore",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "SwiftIMAP",
            dependencies: [
                "SwiftMailCore",
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .target(
            name: "SwiftSMTP",
            dependencies: [
                "SwiftMailCore",
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .executableTarget(
            name: "SwiftIMAPCLI",
            dependencies: [
                "SwiftIMAP",
                .product(name: "SwiftDotenv", package: "swift-dotenv"),
            ],
			path: "Demos/SwiftIMAPCLI"
        ),
        .executableTarget(
            name: "SwiftSMTPCLI",
            dependencies: [
                "SwiftSMTP",
                .product(name: "SwiftDotenv", package: "swift-dotenv"),
            ],
			path: "Demos/SwiftSMTPCLI"
        ),
        .testTarget(
            name: "SwiftIMAPTests",
            dependencies: [
                "SwiftIMAP",
                .product(name: "Testing", package: "swift-testing")
            ],
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "SwiftSMTPTests",
            dependencies: [
                "SwiftSMTP",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "SwiftMailCoreTests",
            dependencies: [
                "SwiftMailCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
    ]
)
