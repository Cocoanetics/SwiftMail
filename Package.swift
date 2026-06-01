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
        // encoding, ProcessInfo.localIPAddress). No release tag yet — pinned to
        // the commit that gives UTType its comprehensive extension/MIME table
        // (Cocoanetics/SwiftCross#2); switch to `from:` once SwiftCross ships a release.
        .package(
            url: "https://github.com/Cocoanetics/SwiftCross",
            revision: "5e3266e381756550b8d2bcfd6638fec9ee16062f"
        ),
        .package(url: "https://github.com/apple/swift-nio", from: "2.0.0"),
        .package(url: "https://github.com/odrobnik/swift-nio-imap", exact: "0.3.2-pre"),
        // Pinned to the upstream commit that merged the Windows-SDK BoringSSL
        // header workarounds (_WINSOCKAPI_/NOMINMAX/NOCRYPT scoped to the
        // CNIOBoringSSL target, apple/swift-nio-ssl#585). Switch to a normal
        // `from:` once a release ships with that fix.
        .package(
            url: "https://github.com/apple/swift-nio-ssl",
            revision: "ae6b517f53289d72b7b0d4495b4609d25065deed"
        ),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-testing", exact: "0.12.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
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
