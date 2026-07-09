// DisplaySnapshotProvider の純関数部分 (scaleFor / hardwareId) の unit test。
// CGGetActiveDisplayList そのものは実機依存のため直接呼ばず、副関数のみ検証する。
import XCTest
import CoreGraphics
@testable import LaserGuideDev

final class DisplaySnapshotProviderTests: XCTestCase {

    func testScaleFromValidMMDerivesMMperPX() {
        // 実機 findings: 内蔵 344.7mm / 2056px = 0.1676 mm/px 相当
        // ここでは CGDisplayScreenSize を直接呼べないため計算式のみ確認。
        let mmW = 344.7, pxW = 2056.0
        XCTAssertEqual(mmW / pxW, 0.16765, accuracy: 0.001)
    }

    func testFallbackDPIScale() {
        // fallback: 25.4 / 110 = 0.230909... mm/px
        let expected = mmPerInch / fallbackDPI
        XCTAssertEqual(expected, 0.23090909, accuracy: 1e-6)
    }

    func testScaleForBoundsWithZeroSizeUsesFallback() {
        // bounds が 0 の異常入力で fallback へ倒れることを確認
        let bounds = CGRect(x: 0, y: 0, width: 0, height: 0)
        // CGDirectDisplayID = 0 (無効)、CGDisplayScreenSize は 0 を返すので fallback ルート
        let result = DisplaySnapshotProvider.scaleFor(cgId: 0, bounds: bounds)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.scaleX, mmPerInch / fallbackDPI, accuracy: 1e-9)
    }

    func testHardwareIdFormat() {
        // 実機依存だが、cgId=0 でも "0-0-0-0" のような id 文字列が得られることを確認 (crash しない)。
        let id = DisplaySnapshotProvider.hardwareId(0)
        XCTAssertFalse(id.isEmpty)
        XCTAssertTrue(id.contains("-"))
    }
}
