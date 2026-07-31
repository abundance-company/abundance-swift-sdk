// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AbundanceDeviceKit",
    platforms: [
        .iOS(.v17),
        // macOS keeps the whole non-UI stack host-testable and lets the
        // AbundanceBroker contract types run server-side.
        .macOS(.v14),
    ],
    products: [
        .library(name: "AbundanceDeviceKit", targets: ["AbundanceDeviceKit"])
    ],
    targets: [
        .target(name: "AbundanceDeviceKit"),
        .testTarget(
            name: "AbundanceDeviceKitTests",
            dependencies: ["AbundanceDeviceKit"]
        ),
    ]
)
