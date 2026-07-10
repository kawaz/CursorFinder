// swift-tools-version: 5.9
// LaserGuide v3 開発用アプリ (SPM executable)。
//
// - Core (LaserGuideCore) の純関数 reduce を main run loop 上で駆動する薄い Store runtime
// - CGEventTap による mouseMoved 監視 + tap callback 内での同期 event.location 書き換え
// - 各ディスプレイに透明オーバーレイ NSWindow を張り、SwiftUI Canvas でレーザーを描画
//
// リリース用 xcodeproj への配線はスコープ外。`swift run laserguide-dev` で起動して
// 動作確認する開発用途。
import PackageDescription

let package = Package(
    name: "LaserGuideDev",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "laserguide-dev", targets: ["LaserGuideDev"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .executableTarget(
            name: "LaserGuideDev",
            dependencies: [
                .product(name: "LaserGuideCore", package: "Core"),
            ],
            path: "Sources/LaserGuideDev",
            // DR-0008: キャリブレーション UI の WKWebView 資産。Bundle.module で読む
            // (CalibrationWindowController が index.html / main.js を loadFileURL する)。
            resources: [.copy("Resources/calibration")]
        ),
        .testTarget(
            name: "LaserGuideDevTests",
            dependencies: [
                "LaserGuideDev",
                .product(name: "LaserGuideCore", package: "Core"),
            ],
            path: "Tests/LaserGuideDevTests"
        ),
    ]
)
