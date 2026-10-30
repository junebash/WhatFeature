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
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "WhatFeatureCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: swiftSettings + [.strictMemorySafety()]
        ),
        .testTarget(
            name: "WhatFeatureCoreTests",
            dependencies: ["WhatFeatureCore"],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
