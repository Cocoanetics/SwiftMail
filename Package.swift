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
            targets: ["SwiftIMAP", "SwiftSMTP"]),
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
        .package(url: "https://github.com/thebarndog/swift-dotenv", from: "2.1.0"),
		.package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.0.0"),
		.package(url: "https://github.com/apple/swift-nio-imap", branch: "main"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-testing", branch: "main"),
        .package(url: "https://github.com/apple/swift-nio-extras", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio-zlib-support.git", from: "1.0.0"),
        .package(url: "https://github.com/adam-fowler/compress-nio", from: "1.0.0"),
    ],
    targets: [
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
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "CompressNIO", package: "compress-nio"),
            ]
        ),
        .target(
            name: "SwiftSMTP",
            dependencies: [
                "SwiftMailCore",
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
                "SwiftMailCore",
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
