// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RaterKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "RaterKit", targets: ["RaterKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "RaterKit",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RaterKitTests",
            dependencies: ["RaterKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
