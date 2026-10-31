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
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WhatFeatureCore", targets: ["WhatFeatureCore"]),
        .library(name: "WhatFeatureStorage", targets: ["WhatFeatureStorage"]),
        .library(name: "WhatFeatureServer", targets: ["WhatFeatureServer"]),
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
            name: "WhatFeatureServer",
            dependencies: [
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
                "WhatFeatureServer",
                "WhatFeatureStorage",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Hummingbird", package: "hummingbird"),
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
