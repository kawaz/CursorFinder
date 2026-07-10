// nsScreenPointToCG (NSEvent y-up → CG y-down 変換、DR-0005) の純関数部テスト
//
// 変換式は `cgY = primaryHeight - nsY` (x は不変)。基準高さは必ず primary スクリーン
// (= Cocoa 座標原点 (0,0) を持つ NSScreen.screens.first) の高さであること。
// `NSScreen.main` (キーボードフォーカスのある画面) を使うとフォーカス画面と primary の
// 高さ差の分だけ Y がズレる (2026-07-10 実機第 3 ラウンド #2 のクリックサークル下ズレ bug)。
// 環境依存の NSScreen 読みはテストから排除し、高さ注入オーバーロードで式だけを固定する。
import XCTest
@testable import LaserGuideDev

final class PermissionMonitorTests: XCTestCase {

    /// Cocoa 下端 (nsY=0) は CG では primary の高さ位置 (= 画面最下端)。
    func testBottomOfPrimaryMapsToPrimaryHeight() {
        let cg = PermissionMonitor.nsScreenPointToCG(NSPoint(x: 100, y: 0), primaryHeight: 1080)
        XCTAssertEqual(cg, CGPoint(x: 100, y: 1080))
    }

    /// Cocoa 上端 (nsY=primaryHeight) は CG では y=0 (top-left origin)。
    func testTopOfPrimaryMapsToZero() {
        let cg = PermissionMonitor.nsScreenPointToCG(NSPoint(x: 100, y: 1080), primaryHeight: 1080)
        XCTAssertEqual(cg, CGPoint(x: 100, y: 0))
    }

    /// primary より上に配置されたスクリーン上の点 (nsY > primaryHeight) は CG では負の y になる
    /// (kawaz 実機の LG (上) + 内蔵 (下) 構成で LG 側は CG y が負領域、DR-0005 / findings 記録の実配置)。
    func testPointOnScreenAbovePrimaryMapsToNegativeY() {
        let cg = PermissionMonitor.nsScreenPointToCG(NSPoint(x: 500, y: 1080 + 500), primaryHeight: 1080)
        XCTAssertEqual(cg, CGPoint(x: 500, y: -500))
    }

    /// x 座標は変換で不変 (y-flip のみが変換の仕事)。
    func testXIsPreserved() {
        let cg = PermissionMonitor.nsScreenPointToCG(NSPoint(x: -320, y: 200), primaryHeight: 900)
        XCTAssertEqual(cg.x, -320)
    }
}
