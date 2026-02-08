// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftMail",
    platforms: [
		.macOS("11.0"),
		.iOS("14.0"),
		.tvOS("14.0"),
		.watchOS("7.0"),
		.macCatalyst("14.0")
    ],
    products: [
        .library(
            name: "SwiftMail",
            targets: ["SwiftMail"]),
        .executable(
            name: "SwiftIMAPCLI",
            targets: ["SwiftIMAPCLI"]),
        .executable(
            name: "SwiftSMTPCLI",
            targets: ["SwiftSMTPCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/thebarndog/swift-dotenv", from: "2.1.0"),
		.package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-imap", branch: "main"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-testing", exact: "0.12.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SwiftMail",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "OrderedCollections", package: "swift-collections"),
            ]
        ),
        .executableTarget(
            name: "SwiftIMAPCLI",
            dependencies: [
                "SwiftMail",
                .product(name: "SwiftDotenv", package: "swift-dotenv"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
			path: "Demos/SwiftIMAPCLI"
        ),
        .executableTarget(
            name: "SwiftSMTPCLI",
            dependencies: [
                "SwiftMail",
                .product(name: "SwiftDotenv", package: "swift-dotenv"),
            ],
			path: "Demos/SwiftSMTPCLI"
        ),
        .testTarget(
            name: "SwiftIMAPTests",
            dependencies: [
                "SwiftMail",
                .product(name: "Testing", package: "swift-testing"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "SwiftSMTPTests",
            dependencies: [
                "SwiftMail",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "SwiftMailCoreTests",
            dependencies: [
                "SwiftMail",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
    ]
)
