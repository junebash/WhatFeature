// swift-tools-version: 6.2
import PackageDescription

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
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "WhatFeatureCoreTests",
            dependencies: ["WhatFeatureCore"]
        ),
    ]
)
