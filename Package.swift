// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// The CLI demos are only built where their dependencies actually compile —
// Apple platforms and Linux — and are dropped from the Windows and Android
// cross-builds:
//   • Windows: swift-dotenv does an unguarded `import Darwin` (no Windows
//     support). The manifest runs on the Windows host here, so `os(Windows)`
//     detects it.
//   • Android: ArgumentParser hits a spurious explicit-module dependency cycle.
//     The skiptools/swift-android-action toolchain sets TARGET_OS_ANDROID=1
//     (the manifest itself runs on the Linux host, so os() can't see Android).
// The SwiftMail library and its tests depend on neither, so they are unaffected.
#if os(Windows)
let buildCLIDemos = false
#else
let buildCLIDemos = Context.environment["TARGET_OS_ANDROID"] == nil
#endif

let package = Package(
    name: "SwiftMail",
    platforms: [
		// Floors raised to satisfy the SwiftCross dependency (iOS 15 / tvOS 15 /
		// watchOS 8); SwiftCross's own floor is set by its URLSession.bytes shim.
		.macOS("12.0"),
		.iOS("15.0"),
		.tvOS("15.0"),
		.watchOS("8.0"),
		.macCatalyst("15.0")
    ],
    products: [
        .library(
            name: "SwiftMail",
            targets: ["SwiftMail"])
    ] + (buildCLIDemos ? [
        .executable(
            name: "SwiftIMAPCLI",
            targets: ["SwiftIMAPCLI"]),
        .executable(
            name: "SwiftSMTPCLI",
            targets: ["SwiftSMTPCLI"])
    ] : []),
    dependencies: [
        .package(url: "https://github.com/thebarndog/swift-dotenv", from: "2.1.0"),
		.package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        // Cross-platform Foundation compatibility shims (UTType, charset/IANA
        // encoding, ProcessInfo.localIPAddress).
        .package(url: "https://github.com/Cocoanetics/SwiftCross", from: "1.2.0"),
        // 2.101.3 includes apple/swift-nio#3433, which fixes NIO/NIOPosix
        // compilation with Swift 6.3 and the current Windows SDK.
        .package(url: "https://github.com/apple/swift-nio", from: "2.101.3"),
        // TEMPORARY TEST OVERRIDE (do not merge): apple/swift-nio-imap main plus
        // the pure-Swift isalnum replacement, for Windows compilation.
        .package(url: "https://github.com/odrobnik/swift-nio-imap", branch: "windows-support"),
        // TEMPORARY TEST OVERRIDE (do not merge): full NIOSSL Windows support
        // from the refresh of apple/swift-nio-ssl#567 (Joannis/swift-nio-ssl#1),
        // pending upstream merge + release.
        .package(url: "https://github.com/odrobnik/swift-nio-ssl", branch: "windows-support"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0"),
        // swift-testing releases track toolchain versions: 6.3.2's manifest is
        // swift-tools-version 6.2, so every platform that compiles the test
        // targets needs Swift 6.2+. The macOS CI job selects Xcode 26 for that
        // reason (Linux/Android/Windows runners are already on Swift 6.3.x).
        .package(url: "https://github.com/apple/swift-testing", exact: "6.3.2"),
        // No DocC plugin dependency: Swift Package Index injects it when building
        // the hosted docs (.spi.yml), and Xcode's Build Documentation has DocC
        // built in — declaring it would only tax consumers with extra clones.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
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
                .product(name: "SwiftCross", package: "SwiftCross")
            ]
        )
    ] + (buildCLIDemos ? [
        .executableTarget(
            name: "SwiftIMAPCLI",
            dependencies: [
                "SwiftMail",
                .product(name: "SwiftDotenv", package: "swift-dotenv"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
			path: "Demos/SwiftIMAPCLI"
        ),
        .executableTarget(
            name: "SwiftSMTPCLI",
            dependencies: [
                "SwiftMail",
                .product(name: "SwiftDotenv", package: "swift-dotenv")
            ],
			path: "Demos/SwiftSMTPCLI"
        )
    ] : []) + [
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
                .product(name: "Testing", package: "swift-testing"),
                .product(name: "NIOEmbedded", package: "swift-nio")
            ]
        ),
        .testTarget(
            name: "SwiftMailCoreTests",
            dependencies: [
                "SwiftMail",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
