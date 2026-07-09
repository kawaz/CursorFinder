// swift-tools-version: 5.9
// LaserGuide 幾何コア (DR-0002〜0008)。UI・AppKit・CoreGraphics 非依存、Foundation まで。
import PackageDescription

let package = Package(
    name: "LaserGuideCore",
    products: [
        .library(name: "LaserGuideCore", targets: ["LaserGuideCore"]),
    ],
    targets: [
        .target(name: "LaserGuideCore", path: "Sources/LaserGuideCore"),
        .testTarget(
            name: "LaserGuideCoreTests",
            dependencies: ["LaserGuideCore"],
            path: "Tests/LaserGuideCoreTests"
        ),
    ]
)
