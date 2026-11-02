// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    // Upcoming features: all become the default in Swift 7.
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
    name: "WhatFeature",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "WhatFeatureCore", targets: ["WhatFeatureCore"]),
        .library(name: "WhatFeatureStorage", targets: ["WhatFeatureStorage"]),
        .library(name: "WhatFeatureServer", targets: ["WhatFeatureServer"]),
        .library(name: "WhatFeatureClient", targets: ["WhatFeatureClient"]),
        // For apps: flag values over OFREP. Needs only Core, Foundation and swift-crypto, so it builds for iOS.
        .library(name: "WhatFeatureFlags", targets: ["WhatFeatureFlags"]),
        .executable(name: "whatfeature", targets: ["whatfeature"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.26.0"),
        // Test only: runs the built CLI. Its paths are `FilePath`, from `System` on Apple platforms and
        // swift-system's `SystemPackage` elsewhere, so tests that build one depend on swift-system directly.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.2"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "WhatFeatureCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: swiftSettings + [.strictMemorySafety()]
        ),
        .target(
            name: "WhatFeatureStorage",
            dependencies: [
                "WhatFeatureCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "WhatFeatureAPI",
            dependencies: ["WhatFeatureCore", "WhatFeatureStorage"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "WhatFeatureClient",
            dependencies: [
                "WhatFeatureAPI",
                "WhatFeatureCore",
                "WhatFeatureStorage",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "WhatFeatureFlags",
            dependencies: ["WhatFeatureCore", .product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "WhatFeatureServer",
            dependencies: [
                "WhatFeatureAPI",
                "WhatFeatureCore",
                "WhatFeatureStorage",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "whatfeature",
            dependencies: [
                "WhatFeatureAPI",
                "WhatFeatureClient",
                "WhatFeatureCore",
                "WhatFeatureServer",
                "WhatFeatureStorage",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WhatFeatureCoreTests",
            dependencies: ["WhatFeatureCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WhatFeatureStorageTests",
            dependencies: ["WhatFeatureCore", "WhatFeatureStorage"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WhatFeatureClientTests",
            dependencies: [
                "WhatFeatureClient",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                "WhatFeatureCore",
                "WhatFeatureServer",
                "WhatFeatureStorage",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WhatFeatureCLITests",
            dependencies: [
                "whatfeature",
                "WhatFeatureCore",
                "WhatFeatureServer",
                "WhatFeatureStorage",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WhatFeatureIntegrationTests",
            dependencies: [
                "WhatFeatureCore",
                "WhatFeatureFlags",
                "WhatFeatureServer",
                "WhatFeatureStorage",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WhatFeatureServerTests",
            dependencies: [
                "WhatFeatureCore",
                "WhatFeatureServer",
                "WhatFeatureStorage",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
