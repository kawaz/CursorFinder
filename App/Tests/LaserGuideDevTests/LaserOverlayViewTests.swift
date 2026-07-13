// LaserOverlayView 用の純関数テスト (DR-0013 決定 1: ウィンドウ枠アウトライン描画)
//
// windowFrameLocalRect(windowFrame:displayBounds:) は震源ウィンドウ frame (CG グローバル論理)
// を自 display の view-local (top-left 原点、px) にクリップして返す純関数。モニタまたぎの
// ウィンドウはそれぞれの overlay が本関数で自分の担当部分を計算し、非交差の overlay は
// 描画をスキップする (LaserOverlayView.focusFlashView が判定に使う)。
//
// 検証輪郭 (DR-0013 検証):
//   (a) windowFrame 全体が自 display 内 → shifted view-local rect
//   (b) windowFrame の一部だけが自 display と重なる (px intersection)
//   (c) windowFrame が自 display の完全外 → nil
//   (d) 境界で接するだけ (幅 or 高さ 0 の intersection) → nil (「重ならない」扱い)
import XCTest
import CoreGraphics
@testable import LaserGuideDev
import LaserGuideCore

final class LaserOverlayViewTests: XCTestCase {

    // (a): windowFrame が自 display 内に完全に収まる場合、返却 rect は windowFrame を displayBounds.min
    //      で減算しただけの「shifted」view-local rect。次のフォーカス変化までここが描画対象になる。
    func testWindowFrameLocalRectShiftsToViewLocalWhenFullyInside() {
        // display bounds: 内蔵 Retina を模した実機値 (原点 0,0 の primary 想定)
        let display = LogicalRect(minX: 0, minY: 0, maxX: 2056, maxY: 1329)
        // window: display の内部にある通常の矩形
        let window = LogicalRect(minX: 100, minY: 200, maxX: 500, maxY: 700)

        guard let result = windowFrameLocalRect(windowFrame: window, displayBounds: display) else {
            XCTFail("windowFrame は display に完全包含なので nil ではなく shifted rect が返るはず")
            return
        }
        XCTAssertEqual(result.minX, 100, accuracy: 1e-9, "displayBounds.minX=0 を減算しただけ")
        XCTAssertEqual(result.minY, 200, accuracy: 1e-9)
        XCTAssertEqual(result.maxX, 500, accuracy: 1e-9)
        XCTAssertEqual(result.maxY, 700, accuracy: 1e-9)
    }

    // (a'): display の原点が非ゼロ (二次モニタで CG global の 負座標領域にある LG UltraGear 等) でも
    //       減算だけで view-local に落ちる。DR-0005 の「pose を経由しない、CG global 単純減算」規律
    //       (LaserGeometry.viewLocal と同じ思想) を windowFrame にも適用することの固定。
    func testWindowFrameLocalRectHandlesNonZeroOriginDisplay() {
        // LG UltraGear を模した display (原点が (-258, -1440))
        let display = LogicalRect(minX: -258, minY: -1440, maxX: 3182, maxY: 0)
        // window: display 内部の任意矩形 (負座標を含む)
        let window = LogicalRect(minX: -100, minY: -1000, maxX: 500, maxY: -500)

        guard let result = windowFrameLocalRect(windowFrame: window, displayBounds: display) else {
            XCTFail("負原点 display 内の window は shifted rect を返すはず")
            return
        }
        // (-100) - (-258) = 158
        XCTAssertEqual(result.minX, 158, accuracy: 1e-9)
        // (-1000) - (-1440) = 440
        XCTAssertEqual(result.minY, 440, accuracy: 1e-9)
        // 500 - (-258) = 758
        XCTAssertEqual(result.maxX, 758, accuracy: 1e-9)
        // (-500) - (-1440) = 940
        XCTAssertEqual(result.maxY, 940, accuracy: 1e-9)
    }

    // (b): windowFrame が display 境界を跨ぐ場合、intersection だけを view-local に返す。
    //      「モニタまたぎのウィンドウは各 overlay が自分の担当部分だけを描く」DR-0013 決定 1 の
    //      核心を固定する (跨いだ側の overlay は自分側の切り取り rect を持つ)。
    func testWindowFrameLocalRectClipsToIntersectionOnBoundaryCrossing() {
        // 左 display: 0..1000 × 0..800
        let leftDisplay = LogicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 800)
        // window: 左 display の右半分 + 右 display 側にはみ出す (600..1300 × 100..500)
        let window = LogicalRect(minX: 600, minY: 100, maxX: 1300, maxY: 500)

        guard let result = windowFrameLocalRect(windowFrame: window, displayBounds: leftDisplay) else {
            XCTFail("左 display と 400px 幅の overlap があるので描画対象、nil であってはならない")
            return
        }
        // intersection: 600..1000 × 100..500 → view-local (600, 100)-(1000, 500)
        XCTAssertEqual(result.minX, 600, accuracy: 1e-9, "window.minX と display.minX の max")
        XCTAssertEqual(result.minY, 100, accuracy: 1e-9)
        XCTAssertEqual(result.maxX, 1000, accuracy: 1e-9, "window.maxX と display.maxX の min (display 端で clip)")
        XCTAssertEqual(result.maxY, 500, accuracy: 1e-9)
    }

    // (c): windowFrame が完全に自 display の外にあれば nil。この overlay は描画をスキップする。
    //      隣モニタで発火したフォーカスフラッシュを、自 overlay が空 rect で描画しようとしない保証。
    func testWindowFrameLocalRectReturnsNilWhenWindowIsCompletelyOutside() {
        let display = LogicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 800)
        // 右隣モニタ (x=1000..) のみを占めるウィンドウ
        let outsideWindow = LogicalRect(minX: 1200, minY: 100, maxX: 1800, maxY: 500)

        let result = windowFrameLocalRect(windowFrame: outsideWindow, displayBounds: display)

        XCTAssertNil(result, "display の外にあるウィンドウは描画対象外 (nil で描画スキップ)")
    }

    // (d): 境界で接するだけ (幅 or 高さ 0 の intersection) は「重ならない」扱いで nil。
    //      継ぎ目 (display 境界) にきっかり載る windowFrame で空 rect の描画を発火させないためのガード
    //      (SwiftUI の 0px rect は不要な GraphicsContext 呼び出しになるだけで実害はないが、
    //       意図として「重なりが厳密に必要」を明示する)。
    func testWindowFrameLocalRectReturnsNilOnEdgeTouch() {
        let display = LogicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 800)
        // 右端で接する window (minX = display.maxX)
        let rightEdgeTouch = LogicalRect(minX: 1000, minY: 100, maxX: 1500, maxY: 500)
        XCTAssertNil(windowFrameLocalRect(windowFrame: rightEdgeTouch, displayBounds: display),
                     "境界で接するだけの window は nil (幅 0 の intersection)")

        // 上端で接する window (minY = display.maxY)
        let bottomEdgeTouch = LogicalRect(minX: 200, minY: 800, maxX: 600, maxY: 1000)
        XCTAssertNil(windowFrameLocalRect(windowFrame: bottomEdgeTouch, displayBounds: display),
                     "境界で接するだけの window は nil (高さ 0 の intersection)")
    }
}
